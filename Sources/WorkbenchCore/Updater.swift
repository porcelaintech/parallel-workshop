import Foundation
import CryptoKit

/// 版本更新：查询 GitHub Releases 最新版并一键更新。
/// 安全设计（开源未签名分发模型）：
/// 1. 下载必须具有有效 SHA256 并通过强校验；
/// 2. 新应用先落地到 /Applications 内临时名，校验 Bundle ID 后再原子换名（mv 同卷原子），
///    任何一步失败都回滚恢复旧版本，绝不出现「旧版已删、新版未装」；
/// 3. 每个子进程检查退出码，非零即视为失败；
/// 4. 安装完成后对新应用去除隔离属性（未签名应用的启动必要步骤；用户主动点击更新即知情同意）。
public enum Updater {
    public struct Release {
        public let version: String
        public let dmgURL: String?
        public let notes: String?
        public let dmgSHA256: String?

        public init(version: String, dmgURL: String?, notes: String?, dmgSHA256: String?) {
            self.version = version
            self.dmgURL = dmgURL
            self.notes = notes
            self.dmgSHA256 = dmgSHA256
        }
    }

    public enum UpdateError: LocalizedError, Equatable {
        case invalidRepository
        case invalidRelease
        case unsupportedRelease
        case missingAsset
        case invalidChecksum
        case httpStatus(Int)
        case timedOut
        case network(String)
        case invalidApplication
        case relaunchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidRepository: return "更新仓库地址无效"
            case .invalidRelease: return "更新信息格式或版本号无效"
            case .unsupportedRelease: return "更新渠道返回了草稿或预发布版本"
            case .missingAsset: return "此版本缺少有效的 macOS 安装包"
            case .invalidChecksum: return "更新缺少有效 SHA-256，已中止"
            case .httpStatus(403), .httpStatus(429): return "更新服务暂时限制请求，请稍后重试"
            case .httpStatus(404): return "更新版本尚未发布"
            case .httpStatus(let status): return "更新服务返回错误（HTTP \(status)）"
            case .timedOut: return "连接更新服务超时，请检查网络后重试"
            case .network(let detail): return "无法连接更新服务：\(detail)"
            case .invalidApplication: return "新版本应用路径无效，无法重新启动"
            case .relaunchFailed(let detail): return "无法准备重新启动：\(detail)"
            }
        }
    }

    /// 仓库配置：环境变量 PWB_REPO 优先
    public static var repo: String {
        ProcessInfo.processInfo.environment["PWB_REPO"] ?? "porcelaintech/parallel-workshop"
    }

    /// 是否 Mac App Store 构建（打包脚本写入 Info.plist 的 PWBChannel=appstore）。
    /// App Store 政策禁止应用自助更新，此标记让更新检查自动关闭（更新由 App Store 提供）。
    public static var isAppStoreBuild: Bool {
        Bundle.main.infoDictionary?["PWBChannel"] as? String == "appstore"
    }

    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    /// 默认更新正式安装位置；PWB_INSTALL_DEST 仅供隔离集成测试使用。
    public static var installDestination: String {
        let override = ProcessInfo.processInfo.environment["PWB_INSTALL_DEST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (override?.isEmpty == false ? override! : "/Applications/ParallelWorkbench.app")
    }

    /// 拉取 GitHub Releases 最新版信息
    public static func fetchLatest() async -> Release? {
        try? await fetchLatestRelease()
    }

    /// API 上限 15 秒、临时错误最多重试一次；限流或网络故障时，正式发布索引最多再等待 15 秒。
    public static func fetchLatestRelease() async throws -> Release {
        guard repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.invalidRepository
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ParallelWorkbench/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fallbackURL = URL(string: "https://github.com/\(repo)/releases/latest/download/update.json")!
        return try await fetchLatestReleaseWithFallback(session: session, request: req, fallbackURL: fallbackURL)
    }

    static func fetchLatestReleaseWithFallback(session: URLSession, request: URLRequest, fallbackURL: URL) async throws -> Release {
        do { return try await fetchLatestRelease(session: session, request: request) }
        catch {
            let primaryError = error
            guard shouldUseFallback(after: error) else { throw error }
            do {
                return try await withThrowingTaskGroup(of: Release.self) { group in
                    group.addTask {
                        var request = URLRequest(url: fallbackURL, cachePolicy: .reloadIgnoringLocalCacheData)
                        request.timeoutInterval = 15
                        request.setValue("ParallelWorkbench/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await session.data(for: request)
                        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                            throw UpdateError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
                        }
                        return try parseUpdateIndex(data)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw UpdateError.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let release = try await group.next() else { throw UpdateError.invalidRelease }
                    return release
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                // 旧发布可能没有备用索引；保留主要错误，不能把索引 404 误报成“没有更新”。
                throw primaryError
            }
        }
    }

    private static func shouldUseFallback(after error: Error) -> Bool {
        guard let error = error as? UpdateError else { return false }
        switch error {
        case .httpStatus(let status): return status == 403 || status == 429 || (500...599).contains(status)
        case .timedOut, .network: return true
        default: return false
        }
    }

    /// 与 DMG 一同发布的免 API 限流索引；仅接受本仓库正式版本的 HTTPS 资产和有效 SHA。
    static func parseUpdateIndex(_ data: Data) throws -> Release {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] as? Int == 1,
              let version = json["version"] as? String, versionComponents(version) != nil else {
            throw UpdateError.invalidRelease
        }
        guard let value = json["dmgURL"] as? String, let url = validAssetURL(value),
              url.lastPathComponent == "ParallelWorkbench-\(version).dmg",
              [version, "v\(version)"].contains(url.deletingLastPathComponent().lastPathComponent) else {
            throw UpdateError.missingAsset
        }
        guard let digest = normalizedSHA256(json["dmgSHA256"] as? String) else { throw UpdateError.invalidChecksum }
        return Release(version: version, dmgURL: value, notes: json["notes"] as? String, dmgSHA256: digest)
    }

    static func fetchLatestRelease(session: URLSession, request: URLRequest) async throws -> Release {
        try await withThrowingTaskGroup(of: Release.self) { group in
            group.addTask { try await fetchLatestWithRetries(session: session, request: request) }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw UpdateError.timedOut
            }
            defer { group.cancelAll() }
            guard let release = try await group.next() else { throw UpdateError.invalidRelease }
            return release
        }
    }

    private static func fetchLatestWithRetries(session: URLSession, request: URLRequest) async throws -> Release {
        let deadline = Date().addingTimeInterval(15)
        for attempt in 0..<2 {
            do {
                var request = request
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw UpdateError.timedOut }
                request.timeoutInterval = remaining
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidRelease }
                guard (200...299).contains(response.statusCode) else {
                    throw UpdateError.httpStatus(response.statusCode)
                }
                return try parseLatestRelease(data)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if attempt == 0 && deadline.timeIntervalSinceNow > 0 && isRetryable(error) { continue }
                if let error = error as? UpdateError { throw error }
                if (error as? URLError)?.code == .timedOut { throw UpdateError.timedOut }
                throw UpdateError.network(error.localizedDescription)
            }
        }
        throw UpdateError.timedOut
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case UpdateError.httpStatus(let status) = error { return status == 408 || (500...599).contains(status) }
        guard let code = (error as? URLError)?.code else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(code)
    }

    static func parseLatestRelease(_ data: Data) throws -> Release {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw UpdateError.invalidRelease }
        guard json["draft"] as? Bool == false, json["prerelease"] as? Bool == false else {
            throw UpdateError.unsupportedRelease
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard versionComponents(version) != nil else { throw UpdateError.invalidRelease }
        let notes = json["body"] as? String
        let assets = json["assets"] as? [[String: Any]] ?? []
        let expectedName = "ParallelWorkbench-\(version).dmg"
        let dmgAsset = assets.first(where: { ($0["name"] as? String) == expectedName })
        guard let dmg = dmgAsset?["browser_download_url"] as? String,
              let url = validAssetURL(dmg), url.lastPathComponent == expectedName else { throw UpdateError.missingAsset }
        let rawDigest = dmgAsset?["digest"] as? String
        let apiDigest = rawDigest?.hasPrefix("sha256:") == true ? String(rawDigest!.dropFirst(7)) : nil
        let digest = normalizedSHA256(apiDigest) ?? normalizedSHA256(expectedSHA256(assetName: expectedName, notes: notes))
        guard digest != nil else { throw UpdateError.invalidChecksum }
        return Release(version: version, dmgURL: dmg, notes: notes, dmgSHA256: digest)
    }

    static func validAssetURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/\(repo)/releases/download/"),
              url.pathComponents.count == 7,
              versionFromDMGAssetName(url.lastPathComponent) != nil else { return nil }
        return url
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return nil }
        let values = parts.compactMap { Int($0) }
        return values.count == 3 ? values : nil
    }

    /// 简单语义版本比较：latest 是否高于 current
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let a = versionComponents(latest), let b = versionComponents(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    /// 从 Release Notes 提取某资产名的 SHA256（格式：`SHA256 <文件名> <hex>`，可多行）
    static func expectedSHA256(assetName: String, notes: String?) -> String? {
        guard let notes else { return nil }
        for line in notes.split(separator: "\n") {
            let parts = String(line).split(separator: " ").map(String.init)
            if parts.count >= 3, parts[0].caseInsensitiveCompare("SHA256") == .orderedSame, parts[1] == assetName {
                return parts[2]
            }
        }
        return nil
    }

    static func normalizedSHA256(_ value: String?) -> String? {
        guard let value else { return nil }
        let digest = value.lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        return digest
    }

    static func versionFromDMGAssetName(_ name: String) -> String? {
        let prefix = "ParallelWorkbench-"
        let suffix = ".dmg"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let version = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard versionComponents(version) != nil else { return nil }
        return version
    }

    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 下载 DMG → 校验 → 挂载 → 原子替换 /Applications → 去隔离 → 卸载镜像。
    /// 全程校验退出码；失败即回滚并返回 false。
    public static func install(dmgURL: String, expectedSHA256: String?, notes: String? = nil,
                               progress: @escaping (String) -> Void) async -> Bool {
        progress("正在下载新版本…")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pwb-update-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let url = validAssetURL(dmgURL) else {
            progress("更新失败：安装包下载地址无效")
            return false
        }
        let assetName = url.lastPathComponent
        guard let expected = normalizedSHA256(expectedSHA256) ??
                normalizedSHA256(Self.expectedSHA256(assetName: assetName, notes: notes)) else {
            progress("校验失败：Release 未提供有效 SHA-256，已中止")
            return false
        }
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 180
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (download, resp) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: download) }
            guard let response = resp as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw UpdateError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let data = try Data(contentsOf: download, options: .mappedIfSafe)
            let actual = sha256Hex(of: data)
            guard actual.lowercased() == expected else {
                progress("校验失败：下载文件哈希不匹配，已中止")
                return false
            }
            try data.write(to: tmp)
        } catch {
            let detail = (error as? URLError)?.code == .timedOut ? UpdateError.timedOut.localizedDescription : error.localizedDescription
            progress("下载失败：\(detail)，旧版本保留")
            return false
        }

        progress("正在安装…")
        // 1) 挂载
        guard let mountOutput = run("/usr/bin/hdiutil", ["attach", tmp.path, "-readonly", "-nobrowse"]),
              let mount = mountOutput.split(separator: "\n")
                .compactMap({ line -> String? in
                    let s = String(line)
                    guard s.contains("/Volumes/") else { return nil }
                    return s.components(separatedBy: "\t").last?.trimmingCharacters(in: .whitespaces)
                }).first else {
            progress("安装失败：无法打开安装镜像，旧版本保留")
            return false
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount]) }

        // 2) 定位镜像内应用
        let srcs = [mount + "/ParallelWorkbench.app", mount + "/平行工作台.app"]
        guard let src = srcs.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            progress("安装失败：镜像内未找到应用，旧版本保留")
            return false
        }

        // 3) 校验新应用身份（Bundle ID 必须一致，防止装错包）
        let newInfoPlist = src + "/Contents/Info.plist"
        guard let newInfo = NSDictionary(contentsOfFile: newInfoPlist) as? [String: Any],
              let newBundleID = newInfo["CFBundleIdentifier"] as? String,
              newBundleID == "ParallelWorkbench" else {
            progress("校验失败：安装包 Bundle ID 不符，已中止")
            return false
        }
        guard let expectedVersion = versionFromDMGAssetName(assetName),
              let newVersion = newInfo["CFBundleShortVersionString"] as? String else {
            progress("校验失败：无法确认安装包版本，已中止")
            return false
        }
        if newVersion != expectedVersion {
            progress("校验失败：安装包版本与资产名不符，已中止")
            return false
        }

        // 4) 原子替换：先复制到同卷临时名（保留复制失败时旧版完好）
        let dest = installDestination
        let parent = (dest as NSString).deletingLastPathComponent
        let appName = (dest as NSString).lastPathComponent
        guard !parent.isEmpty,
              run("/bin/mkdir", ["-p", parent]) != nil else {
            progress("安装失败：无法准备目标目录")
            return false
        }
        let transaction = UUID().uuidString
        let staged = parent + "/.\(appName).new-\(transaction)"
        let backup = parent + "/.\(appName).old-\(transaction)"
        let hadOld = FileManager.default.fileExists(atPath: dest)

        _ = run("/bin/rm", ["-rf", staged])
        guard run("/bin/cp", ["-R", src, staged]) != nil,
              FileManager.default.isExecutableFile(atPath: staged + "/Contents/MacOS/ParallelWorkbench") else {
            progress("安装失败：新版本复制未完成，旧版本保留")
            _ = run("/bin/rm", ["-rf", staged])
            return false
        }
        // 替换前完成启动准备，失败时绝不触碰现有应用。
        guard run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged]) != nil else {
            _ = run("/bin/rm", ["-rf", staged])
            progress("安装失败：无法准备新版本启动，旧版本保留")
            return false
        }
        // 同卷 replaceItemAt：替换失败时系统保留原目标，并生成可回滚备份。
        if hadOld {
            _ = run("/bin/rm", ["-rf", backup])
            do {
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: dest),
                    withItemAt: URL(fileURLWithPath: staged),
                    backupItemName: URL(fileURLWithPath: backup).lastPathComponent,
                    options: [.withoutDeletingBackupItem]
                )
            } catch {
                _ = run("/bin/rm", ["-rf", staged])
                if !FileManager.default.fileExists(atPath: dest), FileManager.default.fileExists(atPath: backup) {
                    guard run("/bin/mv", [backup, dest]) != nil else {
                        progress("安装失败：旧版本保留在 \(backup)")
                        return false
                    }
                }
                progress("安装失败：旧版本保留")
                return false
            }
        } else {
            guard run("/bin/mv", [staged, dest]) != nil else {
                _ = run("/bin/rm", ["-rf", staged])
                progress("安装失败：新版本未安装")
                return false
            }
        }
        if hadOld { _ = run("/bin/rm", ["-rf", backup]) }

        progress("更新完成")
        return true
    }

    /// 执行子进程：退出码非零视为失败（返回 nil）
    private static func run(_ bin: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return nil
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }
}
