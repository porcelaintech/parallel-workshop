import SwiftUI
import AppKit
import Darwin
import WorkbenchCore

@main
struct ParallelWorkbenchApp: App {
    @StateObject private var updates = UpdateCoordinator(relaunch: {
        try Updater.scheduleRelaunch(afterProcessID: ProcessInfo.processInfo.processIdentifier,
                                    applicationURL: URL(fileURLWithPath: Updater.installDestination))
        NSApp.terminate(nil)
    })
    init() {
        // 关闭 stdout/stderr 缓冲，注入日志实时可见
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
    }

    var body: some Scene {
        WindowGroup("智囊") {
            ContentView()
                .environmentObject(updates)
                .frame(minWidth: 1280, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
        // 参考画布 2048×1325（含标题栏）；屏幕放不下时 macOS 自动收敛到可见区域
        .defaultSize(width: 2048, height: 1325)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updates.manualCheck() }
                    .disabled(updates.isBusy)
                if updates.availableVersion != nil {
                    Button(updates.buttonTitle) { updates.primaryAction() }
                        .disabled(updates.isBusy)
                }
            }
        }
    }
}
