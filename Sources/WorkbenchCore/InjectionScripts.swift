import Foundation

/// 共享注入核心：inject.js / probe.js 是纯 JS 文件，
/// 未来 Windows/Edge 扩展直接复用同一份资源。
public enum InjectionScripts {
    public static let injectJS: String = load("inject")
    public static let probeJS: String = load("probe")
    public static let modelPreferenceJS: String = load("model-preference")
    public static let pageThemeJS: String = load("theme")

    private static func load(_ name: String) -> String {
        let url = Resources.root().appendingPathComponent("injection/\(name).js")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 把配置 JSON 注入脚本模板，替换 __CFG__ 占位符。
    public static func build(_ template: String, cfg: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: cfg, options: [])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return template.replacingOccurrences(of: "__CFG__", with: json)
    }
}
