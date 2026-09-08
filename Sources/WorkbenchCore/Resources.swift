import Foundation

private final class ResourceBundleMarker {}

/// 资源根目录定位。
/// 裸可执行文件的 Bundle.module 定位不可靠（SPM 对 executable 的资源访问器有已知坑），
/// 按优先级回退：可执行文件旁 → SPM 资源 bundle → 源码树（开发模式）。
public enum Resources {
    public static func root() -> URL {
        let fm = FileManager.default
        #if SWIFT_PACKAGE
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        #endif
        var candidates: [URL?] = [
            Bundle(for: ResourceBundleMarker.self).resourceURL,
            Bundle.main.resourceURL
        ]
        #if SWIFT_PACKAGE
        candidates += [
            Bundle.module.resourceURL,
            exeDir,
            exeDir.appendingPathComponent("ParallelWorkbench_WorkbenchCore.bundle"),
            exeDir.appendingPathComponent("WorkbenchCore_WorkbenchCore.bundle"),
            exeDir.appendingPathComponent("ParallelWorkbench_ParallelWorkbench.bundle"),
            // 打包 .app 形态：Contents/MacOS/二进制 + Contents/Resources/资源bundle
            exeDir.deletingLastPathComponent().appendingPathComponent("Resources/ParallelWorkbench_WorkbenchCore.bundle"),
            cwd.appendingPathComponent("Sources/WorkbenchCore/Resources"),
            cwd.appendingPathComponent("Sources/ParallelWorkbench/Resources")
        ]
        #endif
        for c in candidates {
            if let c = c, fm.fileExists(atPath: c.appendingPathComponent("adapters").path) {
                return c
            }
        }
        // Store builds only use packaged resources, never a source-tree fallback.
        #if SWIFT_PACKAGE
        return Bundle.module.resourceURL ?? cwd
        #else
        return Bundle(for: ResourceBundleMarker.self).resourceURL ?? Bundle.main.bundleURL
        #endif
    }
}
