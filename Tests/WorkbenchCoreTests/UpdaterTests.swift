import XCTest
@testable import WorkbenchCore

final class UpdaterTests: XCTestCase {
    func testReleaseNotesDigestExtraction() {
        let digest = String(repeating: "a", count: 64)
        let notes = """
        Release notes
        SHA256 ParallelWorkbench-0.2.1.dmg \(digest)
        """
        XCTAssertEqual(
            Updater.expectedSHA256(assetName: "ParallelWorkbench-0.2.1.dmg", notes: notes),
            digest
        )
    }

    func testDigestNormalizationFailsClosed() {
        XCTAssertNil(Updater.normalizedSHA256(nil))
        XCTAssertNil(Updater.normalizedSHA256("abc"))
        XCTAssertNil(Updater.normalizedSHA256(String(repeating: "z", count: 64)))
        XCTAssertEqual(
            Updater.normalizedSHA256(String(repeating: "A", count: 64)),
            String(repeating: "a", count: 64)
        )
    }

    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("0.2.1", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("0.1.9", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("1.2.beta", than: "0.2.0"))
        XCTAssertFalse(Updater.isNewer("1.2.3.4", than: "0.2.0"))
    }

    func testDMGAssetVersionParsingFailsClosed() {
        XCTAssertEqual(Updater.versionFromDMGAssetName("ParallelWorkbench-1.2.3.dmg"), "1.2.3")
        XCTAssertNil(Updater.versionFromDMGAssetName("ParallelWorkbench-latest.dmg"))
        XCTAssertNil(Updater.versionFromDMGAssetName("edge-extension.zip"))
        XCTAssertNil(Updater.versionFromDMGAssetName("ParallelWorkbench-1.2.dmg"))
        XCTAssertNil(Updater.versionFromDMGAssetName("ParallelWorkbench-1.-2.3.dmg"))
        XCTAssertNil(Updater.versionFromDMGAssetName("ParallelWorkbench-1..3.dmg"))
    }

    private func releaseData(changes: [String: Any] = [:], assetChanges: [String: Any] = [:]) throws -> Data {
        var asset: [String: Any] = [
            "name": "ParallelWorkbench-1.2.3.dmg",
            "browser_download_url": "https://github.com/porcelaintech/parallel-workshop/releases/download/v1.2.3/ParallelWorkbench-1.2.3.dmg",
            "digest": "sha256:" + String(repeating: "a", count: 64)
        ]
        asset.merge(assetChanges) { _, new in new }
        var json: [String: Any] = ["tag_name": "v1.2.3", "draft": false, "prerelease": false, "assets": [asset]]
        json.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testReleaseMetadataIsValidatedBeforeOfferingUpdate() throws {
        let release = try Updater.parseLatestRelease(releaseData())
        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(release.dmgSHA256, String(repeating: "a", count: 64))
        for change: [String: Any] in [["draft": true], ["prerelease": true], ["tag_name": "v1.2.3-beta"], ["tag_name": "v1.-2.3"], ["assets": []]] {
            XCTAssertThrowsError(try Updater.parseLatestRelease(releaseData(changes: change)))
        }
        XCTAssertThrowsError(try Updater.parseLatestRelease(releaseData(assetChanges: ["digest": "sha256:invalid"]))) {
            XCTAssertEqual($0 as? Updater.UpdateError, .invalidChecksum)
        }
        let notes = "SHA256 ParallelWorkbench-1.2.3.dmg " + String(repeating: "b", count: 64)
        XCTAssertEqual(try Updater.parseLatestRelease(releaseData(changes: ["body": notes], assetChanges: ["digest": NSNull()])).dmgSHA256,
                       String(repeating: "b", count: 64))
    }

    func testAssetURLFailsClosedForUntrustedOrMalformedURL() {
        let prefix = "https://github.com/porcelaintech/parallel-workshop/releases/download/v1.2.3/ParallelWorkbench-1.2.3.dmg"
        XCTAssertNotNil(Updater.validAssetURL(prefix))
        for invalid in [prefix.replacingOccurrences(of: "https:", with: "http:"),
                        prefix.replacingOccurrences(of: "github.com", with: "github.com.attacker.example"),
                        prefix.replacingOccurrences(of: "porcelaintech", with: "other-owner"),
                        prefix + "?redirect=elsewhere", prefix + "#fragment", "file:///tmp/update.dmg"] {
            XCTAssertNil(Updater.validAssetURL(invalid))
        }
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testTransientServerErrorRetriesOnceAndReturnsRelease() async throws {
        let data = try releaseData()
        UpdateURLProtocol.configure([(503, Data()), (200, data)])
        let session = session()
        defer { session.invalidateAndCancel() }
        let release = try await Updater.fetchLatestRelease(session: session, request: URLRequest(url: URL(string: "https://update.test/latest")!))
        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(UpdateURLProtocol.requestCount, 2)
    }

    func testMissingReleaseIsFailureNotCurrentVersionAndDoesNotRetry() async throws {
        UpdateURLProtocol.configure([(404, Data())])
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await Updater.fetchLatestRelease(session: session, request: URLRequest(url: URL(string: "https://update.test/latest")!))
            XCTFail("HTTP 404 must not be interpreted as up-to-date")
        } catch { XCTAssertEqual(error as? Updater.UpdateError, .httpStatus(404)) }
        XCTAssertEqual(UpdateURLProtocol.requestCount, 1)
    }

    func testNetworkTimeoutIsDistinctAndRetriesAreBounded() async throws {
        UpdateURLProtocol.configure([], error: URLError(.timedOut))
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await Updater.fetchLatestRelease(session: session, request: URLRequest(url: URL(string: "https://update.test/latest")!))
            XCTFail("Timeout must be surfaced")
        } catch { XCTAssertEqual(error as? Updater.UpdateError, .timedOut) }
        XCTAssertEqual(UpdateURLProtocol.requestCount, 2)
    }

    private func updateIndexData(changes: [String: Any] = [:]) throws -> Data {
        var index: [String: Any] = [
            "schemaVersion": 1, "version": "1.2.3",
            "dmgURL": "https://github.com/porcelaintech/parallel-workshop/releases/download/v1.2.3/ParallelWorkbench-1.2.3.dmg",
            "dmgSHA256": String(repeating: "a", count: 64), "notes": "A stable release"
        ]
        index.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: index)
    }

    func testRateLimitedAPIUsesPublishedIndexAndValidatesIt() async throws {
        UpdateURLProtocol.configure([(403, Data()), (200, try updateIndexData())])
        let session = session()
        defer { session.invalidateAndCancel() }
        let release = try await Updater.fetchLatestReleaseWithFallback(session: session,
            request: URLRequest(url: URL(string: "https://update.test/latest")!),
            fallbackURL: URL(string: "https://update.test/update.json")!)
        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(UpdateURLProtocol.requestCount, 2)
        for change: [String: Any] in [["schemaVersion": 2], ["version": "1.2.3-beta"], ["version": "9.9.9"],
                                      ["dmgSHA256": "missing"], ["dmgURL": "https://attacker.example/update.dmg"]] {
            XCTAssertThrowsError(try Updater.parseUpdateIndex(updateIndexData(changes: change)))
        }
    }

    func testUnavailableFallbackPreservesRateLimitFailure() async throws {
        UpdateURLProtocol.configure([(403, Data()), (404, Data())])
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await Updater.fetchLatestReleaseWithFallback(session: session,
                request: URLRequest(url: URL(string: "https://update.test/latest")!),
                fallbackURL: URL(string: "https://update.test/update.json")!)
            XCTFail("Missing fallback must not be interpreted as current")
        } catch { XCTAssertEqual(error as? Updater.UpdateError, .httpStatus(403)) }
    }

    func testRelaunchUsesPositionalArgumentsAndValidatesApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pwb-relaunch-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("平行 工作台 ' $(touch SHOULD_NOT_RUN).app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/ParallelWorkbench")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "ParallelWorkbench", "CFBundleExecutable": "ParallelWorkbench", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let args = try Updater.relaunchArguments(afterProcessID: 12345, applicationURL: app)
        XCTAssertEqual(args.suffix(2), ["12345", app.path])
        XCTAssertFalse(args[1].contains(app.path))
        XCTAssertTrue(args[1].contains("while /bin/kill -0"))
        XCTAssertTrue(args[1].contains("exec /usr/bin/open -n"))
        XCTAssertThrowsError(try Updater.relaunchArguments(afterProcessID: 1, applicationURL: app))
        XCTAssertThrowsError(try Updater.relaunchArguments(afterProcessID: 12345, applicationURL: URL(fileURLWithPath: "/tmp")))
    }

    func testPublicLatestLiveWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["PWB_TEST_LIVE_UPDATE"] == "1" else { throw XCTSkip("Explicit live probe only") }
        let release = try await Updater.fetchLatestRelease()
        XCTAssertNotNil(release.dmgURL)
        XCTAssertNotNil(release.dmgSHA256)
        print("PUBLIC_LATEST_VERSION=\(release.version)")
    }

    // —— 2026-09-09 仓库更名后新增：旧仓库名资产 URL 必须继续通过校验 ——

    func testLegacyRepoAssetURLsAreAcceptedButOtherOwnersRejected() {
        let current = "https://github.com/porcelaintech/parallel-workshop/releases/download/v1.2.3/ParallelWorkbench-1.2.3.dmg"
        let legacy = "https://github.com/HanchengQiao/parallel-workshop/releases/download/v1.2.3/ParallelWorkbench-1.2.3.dmg"
        XCTAssertNotNil(Updater.validAssetURL(current))
        XCTAssertNotNil(Updater.validAssetURL(legacy))
        XCTAssertNil(Updater.validAssetURL(legacy.replacingOccurrences(of: "HanchengQiao", with: "attacker")))
        XCTAssertNil(Updater.validAssetURL("https://github.com/porcelaintech/evil-repo/releases/download/v1.2.3/ParallelWorkbench-1.2.3.dmg"))
    }

    func testOrchestratorFallsThroughAPI404ToPublishedIndex() async throws {
        let index = try updateIndexData()
        UpdateURLProtocol.configure([(404, Data()), (200, index)])
        let session = session()
        defer { session.invalidateAndCancel() }
        let release = try await Updater.fetchLatestRelease(session: session)
        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(UpdateURLProtocol.requestCount, 2)
    }

    func testOrchestratorFallsThroughToMirrorAndLegacyIndexes() async throws {
        let index = try updateIndexData()
        // API 404 → 官方索引 404 → jsDelivr 镜像 404 → 历史仓库名索引 200
        UpdateURLProtocol.configure([(404, Data()), (404, Data()), (404, Data()), (200, index)])
        let session = session()
        defer { session.invalidateAndCancel() }
        let release = try await Updater.fetchLatestRelease(session: session)
        XCTAssertEqual(release.version, "1.2.3")
        XCTAssertEqual(UpdateURLProtocol.requestCount, 4)
    }

    func testOrchestratorPreservesPrimaryErrorWhenEverySourceFails() async throws {
        // 全部 4 个来源 404：必须报错（保留首个错误），绝不允许静默。
        UpdateURLProtocol.configure([(404, Data()), (404, Data()), (404, Data()), (404, Data())])
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await Updater.fetchLatestRelease(session: session)
            XCTFail("All sources failing must surface an error")
        } catch { XCTAssertEqual(error as? Updater.UpdateError, .httpStatus(404)) }
        XCTAssertEqual(UpdateURLProtocol.requestCount, 4)
    }
}

private final class UpdateURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [(Int, Data)] = []
    private static var failure: Error?
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    static func configure(_ responses: [(Int, Data)], error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.responses = responses
        failure = error
        count = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let failure = Self.failure
        let response = Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        Self.lock.unlock()
        if let failure { client?.urlProtocol(self, didFailWithError: failure); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
