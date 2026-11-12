import SwiftUI
import AppKit
import CoreText

/// 智囊工作台 2026 UI 改版主题：低强调色板 + Helvetica/宋体组合字体。
///
/// 颜色规范（见交付规格）：
/// 页面背景 #F5F6F7 · 卡片/输入框 #FFFFFF · 主文字 #272D33 · 辅助文字 #626B75
/// 输入框边线 #CBD1D8 · 窗口轮廓/分隔线 #E2E5E9 · 可发送按钮 #343A40
/// 禁用发送 #E7E9EC · 勾选选中 #647C6C · 悬停 #EBEDF0
enum WorkbenchPalette {
    static let pageBackground = Color(red: 245.0 / 255.0, green: 246.0 / 255.0, blue: 247.0 / 255.0)   // #F5F6F7
    static let surface = Color(red: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0)          // #FFFFFF
    static let textPrimary = Color(red: 39.0 / 255.0, green: 45.0 / 255.0, blue: 51.0 / 255.0)         // #272D33
    static let textSecondary = Color(red: 98.0 / 255.0, green: 107.0 / 255.0, blue: 117.0 / 255.0)     // #626B75
    static let inputBorder = Color(red: 203.0 / 255.0, green: 209.0 / 255.0, blue: 216.0 / 255.0)      // #CBD1D8
    static let hairline = Color(red: 226.0 / 255.0, green: 229.0 / 255.0, blue: 233.0 / 255.0)         // #E2E5E9
    static let sendEnabled = Color(red: 52.0 / 255.0, green: 58.0 / 255.0, blue: 64.0 / 255.0)         // #343A40
    static let sendDisabled = Color(red: 231.0 / 255.0, green: 233.0 / 255.0, blue: 236.0 / 255.0)     // #E7E9EC
    static let checkboxSelected = Color(red: 100.0 / 255.0, green: 124.0 / 255.0, blue: 108.0 / 255.0) // #647C6C
    static let hoverFill = Color(red: 235.0 / 255.0, green: 237.0 / 255.0, blue: 240.0 / 255.0)        // #EBEDF0
    static let sendHover = Color(red: 42.0 / 255.0, green: 47.0 / 255.0, blue: 52.0 / 255.0)           // #2A2F34（发送按钮悬停加深）
}

/// 组合字体：英文字母 / 数字 / ASCII 标点 / 英文快捷键使用 Helvetica；
/// 中文汉字与全角标点使用宋体（SimSun）。
///
/// 实现方式：NSFont 级联（cascadeList）——Helvetica 作为基字体，缺少的字形
/// 依次回退到 SimSun → Songti SC（macOS 内置宋体-简）→ 系统默认。
/// 注意不能简单声明 `SimSun, Helvetica`：SimSun 自带拉丁字形，顺序颠倒会让英文也变宋体。
///
/// 字体资源状态由 `WorkbenchFont` 提供查询：
/// - Helvetica：macOS 系统字体，始终存在。
/// - SimSun（宋体）：微软字体，本机未安装时中文回退渲染为 Songti SC（宋体-简），
///   交付说明中如实报告；安装 SimSun.ttf 后无需改代码即自动生效。
enum WorkbenchFont {
    /// 中文宋体首选家族，按序回退。
    static let cjkFamilies = ["SimSun", "Songti SC"]

    static var simSunAvailable: Bool { NSFont(name: "SimSun", size: 13) != nil }
    static var helveticaAvailable: Bool { NSFont(name: "Helvetica", size: 13) != nil }
    static var songtiSCAvailable: Bool { NSFont(name: "Songti SC", size: 13) != nil }

    /// 实际渲染中文时命中的字体族（用于验收报告）。
    static var effectiveCJKFamily: String {
        if simSunAvailable { return "SimSun" }
        if songtiSCAvailable { return "Songti SC" }
        return NSFont.systemFont(ofSize: 13).familyName ?? "System"
    }

    /// 构建 Helvetica（拉丁/数字/ASCII）→ 宋体（中文/全角）级联字体。
    static func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // 中文级联带同样的字重特征（宋体缺失 semibold 字面时由 CoreText 选择最近字重），
        // 避免“英文加粗、中文常规”导致混排视觉大小不一。
        var cjkAttrs: [NSFontDescriptor.AttributeName: Any] = [:]
        if weight >= .semibold {
            cjkAttrs[.traits] = [NSFontDescriptor.TraitKey.weight: weight]
        }
        let cascades = cjkFamilies.map { family -> NSFontDescriptor in
            var attrs = cjkAttrs
            attrs[.family] = family
            return NSFontDescriptor(fontAttributes: attrs)
        }
        guard let base = NSFont(name: "Helvetica", size: size) else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        // Helvetica 无 semibold 字面，semibold 及以上统一落到 Helvetica-Bold（600 视觉等重）
        let weighted: NSFont
        switch weight {
        case .semibold, .bold, .heavy, .black:
            weighted = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        default:
            weighted = base
        }
        let descriptor = weighted.fontDescriptor.addingAttributes([.cascadeList: cascades])
        return NSFont(descriptor: descriptor, size: size) ?? weighted
    }

    /// SwiftUI Font 包装：所有 UI 文字统一走这个入口，保证混排逐字命中对应字体。
    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight) as CTFont)
    }

    /// 当前机器上的字体资源报告（多行文本，供启动日志与验收输出）。
    static var availabilityReport: String {
        "Helvetica=\(helveticaAvailable ? "✓" : "✗") SimSun(宋体)=\(simSunAvailable ? "✓" : "✗，回退 Songti SC=\(songtiSCAvailable ? "✓" : "✗")") 中文实际字体=\(effectiveCJKFamily)"
    }
}

/// 布局常量（pt；参考画布 2048×1325 上的验收尺寸）。
enum WorkbenchLayout {
    static let pageMargin: CGFloat = 24
    static let paneGap: CGFloat = 16
    static let controlGap: CGFloat = 8
    static let groupGap: CGFloat = 16

    /// 模型选项点击区域宽度（参考画布：24 + 16 复选框 + 8 间距 + 文字）。
    static func modelOptionWidth(for id: String) -> CGFloat {
        switch id {
        case "chatgpt": return 104
        case "deepseek": return 112
        case "doubao": return 64
        case "kimi": return 64
        case "tongyi": return 96
        case "yiyan": return 96
        default: return 96
        }
    }
}
