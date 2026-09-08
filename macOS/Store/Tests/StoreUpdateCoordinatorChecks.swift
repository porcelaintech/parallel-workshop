import Foundation
import WorkbenchCore

@main
struct StoreUpdateCoordinatorChecks {
    @MainActor static func main() {
        var opened: [URL] = []
        let preview = UpdateCoordinator(currentVersion: "3.0.0", storeID: nil, openListing: { opened.append($0); return true })
        preview.startAutomaticChecks()
        preview.checkOnActivation()
        preview.manualCheck()
        precondition(opened.isEmpty, "Preview must not invent a Store URL")
        precondition(preview.message.contains("尚未配置"))
        for invalid in ["", "0", "-1", "12/other", "123?redirect=x", "$(PWB_APP_STORE_ID)", " 123", "123\n"] {
            precondition(UpdateCoordinator.listingURL(for: invalid) == nil)
        }
        let configured = UpdateCoordinator(currentVersion: "3.0.0", storeID: "123456789", openListing: { opened.append($0); return true })
        configured.startAutomaticChecks()
        configured.checkOnActivation()
        precondition(opened.isEmpty, "Background checks must not open the Store")
        configured.primaryAction()
        precondition(opened.map(\.absoluteString) == ["macappstore://apps.apple.com/app/id123456789"])
        precondition(configured.availableVersion == nil)
        precondition(configured.message.contains("查看是否"), "Opening a listing does not establish update availability")
        let failure = UpdateCoordinator(storeID: "123456789", openListing: { _ in false })
        failure.primaryAction()
        precondition(failure.phase == .failed)
        precondition(failure.message.contains("无法打开"))
        precondition(Resources.root().path.contains("WorkbenchCore.framework"))
        precondition(Adapter.loadAll().count >= 6)
        precondition(!InjectionScripts.injectJS.isEmpty && !InjectionScripts.probeJS.isEmpty && !InjectionScripts.modelPreferenceJS.isEmpty)
        print("Store behavior checks passed: missing/malformed ID, explicit open, open failure, no background launch, bundled resources.")
    }
}
