import SwiftUI
import AppKit
import Darwin
import WorkbenchCore

@main
struct ParallelWorkbenchApp: App {
    #if APP_STORE
    @StateObject private var updates = UpdateCoordinator()
    #else
    @StateObject private var updates = UpdateCoordinator(relaunch: {
        try Updater.scheduleRelaunch(afterProcessID: ProcessInfo.processInfo.processIdentifier,
                                    applicationURL: URL(fileURLWithPath: Updater.installDestination))
        NSApp.terminate(nil)
    })
    #endif
    init() {
        // 关闭 stdout/stderr 缓冲，注入日志实时可见
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
    }

    var body: some Scene {
        WindowGroup("智囊 · Braintrust") {
            ContentView()
                .environmentObject(updates)
                .frame(minWidth: 1280, minHeight: 780)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1520, height: 900)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updates.menuTitle) { updates.manualCheck() }
                    .disabled(updates.isBusy)
                if updates.availableVersion != nil {
                    Button(updates.buttonTitle) { updates.primaryAction() }
                        .disabled(updates.isBusy)
                }
            }
        }
    }
}
