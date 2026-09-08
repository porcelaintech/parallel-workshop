#if APP_STORE
import Foundation
import AppKit
import Combine

/// The Store target excludes the direct-download updater at the source-list level.
/// This coordinator only opens the configured App Store listing on user request.
@MainActor public final class UpdateCoordinator: ObservableObject {
    public enum Phase: Equatable { case idle, failed }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var message: String
    public let currentVersion: String
    public var availableVersion: String? { nil }
    public var isBusy: Bool { false }
    public var buttonTitle: String { "App Store 更新" }
    public var menuTitle: String { "在 App Store 中查看更新…" }
    public var helpText: String { "此版本由 Mac App Store 提供更新" }

    private let listingURL: URL?
    private let openListing: (URL) -> Bool

    public init(
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
        storeID: String? = Bundle.main.infoDictionary?["PWBAppStoreID"] as? String,
        openListing: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.currentVersion = currentVersion
        self.openListing = openListing
        self.listingURL = Self.listingURL(for: storeID)
        self.message = self.listingURL == nil
            ? "商店发行准备版：尚未配置 App Store 页面；正式版由商店提供更新。"
            : "此版本由 Mac App Store 提供更新。"
    }

    public static func listingURL(for storeID: String?) -> URL? {
        guard let storeID, let first = storeID.utf8.first,
              (49...57).contains(first), storeID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "macappstore://apps.apple.com/app/id\(storeID)")
    }

    // App Store owns background update checks. Activation never opens another app.
    public func startAutomaticChecks() {}
    public func checkOnActivation() {}

    public func manualCheck() { primaryAction() }

    public func primaryAction() {
        guard let listingURL else {
            phase = .idle
            message = "尚未配置 App Store 页面，当前不能前往商店更新。"
            return
        }
        if openListing(listingURL) {
            phase = .idle
            message = "已打开 App Store 页面，请在商店中查看是否有可用更新。"
        } else {
            phase = .failed
            message = "无法打开 App Store，请稍后重试。"
        }
    }
}
#endif
