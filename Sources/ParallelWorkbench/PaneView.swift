import SwiftUI
import WebKit
import WorkbenchCore

/// 单个模型窗格视图（2026 改版）：
/// 40px 标题区（16 左边距 → 88 名称列 → 8 间距 → 状态文字 → 右侧「…」菜单）
/// + 1px 分隔线 + 原生网页视口。
/// 窗口 12px 圆角、1px 浅灰轮廓、无阴影；缩放/刷新/回到对话/放大收进「…」菜单。
struct PaneView: View {
    @ObservedObject var controller: PaneController
    var focused: Bool
    var onToggleFocus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle()
                .fill(WorkbenchPalette.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
            ZStack(alignment: .topTrailing) {
                // 保持 WKWebView 原始渲染树，不加 blur / scale / transition；仅裁下角圆角
                WebViewRepresentable(webView: controller.webView)
                    .clipShape(BottomRoundedRectangle(cornerRadius: 12))

                if !controller.lastLog.isEmpty {
                    Label(controller.lastLog, systemImage: "checkmark.circle.fill")
                        .font(WorkbenchFont.font(12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(WorkbenchPalette.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(WorkbenchPalette.hairline)
                                .allowsHitTesting(false)
                        )
                        .foregroundStyle(WorkbenchPalette.textPrimary)
                        .padding(10)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // URL 漂移治理：登录跳转后未回到对话页时提供「回到对话」
                if controller.isDrifted {
                    Button(action: { controller.goHome() }) {
                        Label("回到对话", systemImage: "house.fill")
                            .font(WorkbenchFont.font(12, weight: .semibold))
                    }
                    .buttonStyle(PaneSoftButtonStyle())
                    .padding(10)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WorkbenchPalette.surface)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WorkbenchPalette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text(controller.adapter.name)
                .font(WorkbenchFont.font(14, weight: .semibold))
                .foregroundStyle(WorkbenchPalette.textPrimary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
                .accessibilityIdentifier("pane.name")

            Text(controller.statusLabel)
                .font(WorkbenchFont.font(12))
                .foregroundStyle(WorkbenchPalette.textSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("pane.status")

            Spacer(minLength: 0)

            paneMenu
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(WorkbenchPalette.surface)
    }

    /// 各列「…」菜单：独立缩放 / 恢复 100% / 放大窗口 / 重新加载 / 回到对话。
    private var paneMenu: some View {
        Menu {
            Text("缩放 \(Int((controller.zoom * 100).rounded()))%")
                .font(WorkbenchFont.font(13))
            Button {
                controller.zoomOut()
            } label: {
                Label("缩小", systemImage: "minus.magnifyingglass")
            }
            Button {
                controller.zoomIn()
            } label: {
                Label("放大", systemImage: "plus.magnifyingglass")
            }
            Button {
                controller.resetZoom()
            } label: {
                Text("恢复 100%")
            }
            .disabled(abs(controller.zoom - 1.0) < 0.001)
            Divider()
            Button {
                onToggleFocus()
            } label: {
                Label(focused ? "退出放大" : "放大此窗口",
                      systemImage: focused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            Divider()
            Button {
                controller.reload()
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
            }
            if controller.isDrifted {
                Button {
                    controller.goHome()
                } label: {
                    Label("回到对话", systemImage: "house.fill")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(WorkbenchPalette.textPrimary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .accessibilityIdentifier("pane.menu")
        .help("缩放、放大与更多操作")
    }
}

/// 仅下角圆角（标题区为直角，网页视口贴合 12px 窗口圆角，不产生双圆角）。
private struct BottomRoundedRectangle: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = cornerRadius
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// 窗格内软按钮（「回到对话」）：白底 + 1px 发丝线，低强调。
private struct PaneSoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaneSoftButtonBody(configuration: configuration)
    }
}

private struct PaneSoftButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(WorkbenchPalette.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(WorkbenchPalette.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hovered ? WorkbenchPalette.inputBorder : WorkbenchPalette.hairline)
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
