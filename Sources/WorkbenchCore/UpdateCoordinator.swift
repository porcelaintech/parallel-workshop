import Foundation
import Combine

/// One shared update state for every window and the application menu.
@MainActor public final class UpdateCoordinator: ObservableObject {
    public enum Phase: Equatable {
        case idle, checking, current, available, installing, installed, restarting, failed
    }

    public typealias FetchRelease = () async throws -> Updater.Release
    public typealias InstallRelease = (Updater.Release, @escaping (String) -> Void) async -> Bool

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var message = ""
    @Published public private(set) var availableVersion: String?
    @Published public private(set) var lastCheckedAt: Date?
    public let currentVersion: String

    private let fetchRelease: FetchRelease
    private let installRelease: InstallRelease
    private let relaunch: () throws -> Void
    private let now: () -> Date
    private let foregroundInterval: TimeInterval
    private var release: Updater.Release?
    private var installed = false
    private var lastAttemptAt: Date?
    private var pollingTask: Task<Void, Never>?

    public init(
        currentVersion: String = Updater.currentVersion,
        foregroundInterval: TimeInterval = 300,
        now: @escaping () -> Date = Date.init,
        fetchRelease: @escaping FetchRelease = { try await Updater.fetchLatestRelease() },
        installRelease: @escaping InstallRelease = { rel, progress in
            guard let dmg = rel.dmgURL else { return false }
            return await Updater.install(dmgURL: dmg, expectedSHA256: rel.dmgSHA256,
                                         notes: rel.notes, progress: progress)
        },
        relaunch: @escaping () throws -> Void
    ) {
        self.currentVersion = currentVersion
        self.foregroundInterval = foregroundInterval
        self.now = now
        self.fetchRelease = fetchRelease
        self.installRelease = installRelease
        self.relaunch = relaunch
    }

    deinit { pollingTask?.cancel() }

    public var isBusy: Bool {
        phase == .checking || phase == .installing || phase == .restarting
    }

    public var menuTitle: String { "检查更新…" }
    public var helpText: String { "检查 GitHub 最新版本；发现新版后点击即可安装并重启" }

    public var buttonTitle: String {
        switch phase {
        case .checking: return "检查中…"
        case .installing: return "更新中…"
        case .restarting: return "正在重启…"
        default:
            if installed { return "重启更新" }
            if let availableVersion { return "Update · v\(availableVersion)" }
            return "Update / 检查更新"
        }
    }

    public func startAutomaticChecks() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(force: false)
                do { try await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000) }
                catch { return }
            }
        }
    }

    public func checkOnActivation() {
        Task { await check(force: false) }
    }

    public func primaryAction() {
        guard !isBusy else { return }
        Task {
            if release != nil || installed { await installAvailableUpdate() }
            else { await check(force: true) }
        }
    }

    public func manualCheck() {
        Task { await check(force: true) }
    }

    public func check(force: Bool) async {
        guard !isBusy, !installed else { return }
        let instant = now()
        if !force, let lastAttemptAt, instant.timeIntervalSince(lastAttemptAt) < foregroundInterval { return }
        lastAttemptAt = instant
        phase = .checking
        message = "正在检查 GitHub 最新版本…"
        do {
            let latest = try await fetchRelease()
            lastCheckedAt = now()
            if Updater.isNewer(latest.version, than: currentVersion) {
                guard latest.dmgURL != nil, latest.dmgSHA256 != nil else {
                    throw NSError(domain: "ParallelWorkbench.Update", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "新版安装包或校验信息尚未就绪，请稍后重试"])
                }
                release = latest
                availableVersion = latest.version
                phase = .available
                message = "发现 v\(latest.version)，点击 Update 安装并重启"
            } else {
                release = nil
                availableVersion = nil
                phase = .current
                message = "已是最新版本 v\(currentVersion)"
            }
        } catch {
            phase = .failed
            message = "检查失败：\(error.localizedDescription)"
        }
    }

    public func installAvailableUpdate() async {
        guard !isBusy else { return }
        if !installed {
            guard let release else { await check(force: true); return }
            phase = .installing
            message = "正在下载 v\(release.version)…"
            let ok = await installRelease(release) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.phase == .installing else { return }
                    self.message = progress
                }
            }
            guard ok else {
                phase = .failed
                message = "更新未完成，点击 Update 重试；当前版本可继续使用"
                return
            }
            installed = true
        }
        phase = .installed
        do {
            try relaunch()
            phase = .restarting
            message = "更新完成，正在重启…"
        } catch {
            phase = .failed
            message = "新版已安装，重启失败：\(error.localizedDescription)"
        }
    }
}
