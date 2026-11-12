import SwiftUI
import AppKit
import CoreGraphics
import WorkbenchCore

/// 智囊工作台主界面（2026 改版）：
/// 品牌行（32）→ 统一输入区（默认 96，随多行输入增长至 192）→ 模型勾选与分页行（32）→ 三列窗口。
/// 页面左右边距 24，三列窗口间距 16，底部边距 24；纵向正常流式布局。
struct ContentView: View {
    @StateObject private var model = WorkbenchModel()
    @EnvironmentObject private var updates: UpdateCoordinator
    @StateObject private var voice = VoiceInput()
    @FocusState private var inputFocused: Bool
    @State private var showFilePicker = false
    @State private var questionBaseline = ""
    @State private var dropHover = false

    var body: some View {
        ZStack {
            WorkbenchPalette.pageBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                brandRow
                    .padding(.top, 8)
                    .frame(height: 40)
                inputCard
                    .padding(.top, 8)
                modelRow
                    .padding(.top, 8)
                    .frame(height: 40)
                paneRow
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, WorkbenchLayout.pageMargin)
        }
        .frame(minWidth: 1280, minHeight: 760)
        .foregroundStyle(WorkbenchPalette.textPrimary)
        .tint(WorkbenchPalette.checkboxSelected)
        .onAppear {
            // 裸可执行文件启动的 GUI 应用：显式常规激活策略 + 激活，否则窗口收不到键盘输入
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // 稍后把焦点钉到输入框（等窗口先成为 key window）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                inputFocused = true
            }
            updates.startAutomaticChecks()
            print("字体资源: \(WorkbenchFont.availabilityReport)")
            // 窗口钳制：屏幕小于参考画布（2048×1325）时收敛到可见区域，
            // 避免右侧按钮/分页被切出屏幕造成“没对齐”的观感。
            if let window = NSApp.windows.first, let screen = window.screen ?? NSScreen.main {
                let vf = screen.visibleFrame
                var frame = window.frame
                if frame.width > vf.width || frame.height > vf.height {
                    frame.size.width = min(frame.width, vf.width)
                    frame.size.height = min(frame.height, vf.height)
                    frame.origin = NSPoint(x: vf.minX, y: vf.minY)
                    window.setFrame(frame, display: true)
                }
            }
            // 验收/测试钩子：WB_FRAME="x,y,w,h" 显式设定窗口位置与尺寸（未设置则用默认尺寸）
            if let spec = ProcessInfo.processInfo.environment["WB_FRAME"] {
                let parts = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 4 {
                    let rect = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                    NSApp.windows.first?.setFrame(rect, display: true)
                }
            }
            // 验收/测试钩子：WB_PAGE="N" 定位到第 N 页窗口（用于逐页取证）
            if let pageSpec = ProcessInfo.processInfo.environment["WB_PAGE"],
               let page = Int(pageSpec.trimmingCharacters(in: .whitespaces)), page >= 0 {
                model.windowStart = page
            }
            // 验收/测试钩子：WB_QUESTION 预填多行问题（\\n 换行）、WB_ATTACH 预加附件（验证布局）
            if let q = ProcessInfo.processInfo.environment["WB_QUESTION"] {
                model.question = q.replacingOccurrences(of: "\\n", with: "\n")
            }
            if let attachSpec = ProcessInfo.processInfo.environment["WB_ATTACH"] {
                let urls = attachSpec.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
                model.addAttachment(urls: urls)
            }
            // 验收/测试钩子：WB_SHOT="输出.png" 延迟几秒后抓取本应用窗口（含标题栏）存 PNG
            if let shotPath = ProcessInfo.processInfo.environment["WB_SHOT"] {
                let delay = ProcessInfo.processInfo.environment["WB_SHOT_DELAY"].flatMap(Double.init) ?? 6
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    ContentView.captureWindowShot(to: shotPath)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updates.checkOnActivation()
        }
        .onChange(of: voice.isRecording) { recording in
            // 开始录音时记录基线，结束后把转写追加到输入框
            if recording {
                questionBaseline = model.question
            } else if !voice.transcript.isEmpty {
                let base = questionBaseline.trimmingCharacters(in: .whitespacesAndNewlines)
                model.question = base.isEmpty ? voice.transcript : base + " " + voice.transcript
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image, .pdf, .plainText, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.addAttachment(urls: urls)
            }
        }
        // 拖入文件 → 附件；拖动悬停时显示状态提示（替代常驻说明文字）
        .dropDestination(for: URL.self) { urls, _ in
            dropHover = false
            model.addAttachment(urls: urls)
            return true
        } isTargeted: { targeted in
            dropHover = targeted
        }
        .onPasteCommand(of: [.image]) { providers in
            for provider in providers {
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    if let data {
                        DispatchQueue.main.async {
                            model.addAttachmentImage(data: data, name: "粘贴图片-\(Int(Date().timeIntervalSince1970)).png")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 品牌与全局设置行（高 32，标题左侧与页面主对齐线 x=24 对齐）

    private var brandRow: some View {
        HStack(spacing: 0) {
            Text("智囊")
                .font(WorkbenchFont.font(24, weight: .semibold))
                .foregroundStyle(WorkbenchPalette.textPrimary)
                .frame(height: 28)
                .accessibilityIdentifier("workbench.brand")

            Spacer()

            globalMenu
        }
        .frame(height: 32)
    }

    /// 全局设置「…」菜单：版本号、检查更新、关于全部收进这里。
    private var globalMenu: some View {
        Menu {
            if !updates.message.isEmpty {
                Text(updates.message)
                    .font(WorkbenchFont.font(13))
                    .accessibilityIdentifier("workbench.update.status")
                Divider()
            }
            Text("版本 v\(updates.currentVersion)")
                .font(WorkbenchFont.font(13))
            Divider()
            Button {
                updates.manualCheck()
            } label: {
                Text("检查更新").font(WorkbenchFont.font(13))
            }
            .disabled(updates.isBusy)
            if let version = updates.availableVersion {
                Button {
                    updates.primaryAction()
                } label: {
                    Text("安装 v\(version)").font(WorkbenchFont.font(13))
                }
            }
            if updates.phase == .failed {
                Button {
                    updates.primaryAction()
                } label: {
                    Text("重试").font(WorkbenchFont.font(13))
                }
                Button {
                    NSWorkspace.shared.open(Updater.releasePageURL)
                } label: {
                    Text("前往下载页").font(WorkbenchFont.font(13))
                }
            }
            Divider()
            Button {
                showAbout()
            } label: {
                Text("关于智囊").font(WorkbenchFont.font(13))
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
        .accessibilityIdentifier("workbench.menu")
        .help("版本、检查更新与关于")
    }

    private func showAbout() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "智囊",
            .applicationVersion: updates.currentVersion
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    // MARK: - 统一输入区（默认 96 高，随文字增长最高约 192）

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            inputField
            inputControlsRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(WorkbenchPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(inputFocused ? WorkbenchPalette.checkboxSelected : WorkbenchPalette.inputBorder,
                        lineWidth: inputFocused ? 2 : 1)
                .allowsHitTesting(false)
        )
        .overlay {
            if dropHover { dropOverlay }
        }
        .animation(.easeOut(duration: 0.15), value: inputFocused)
        .animation(.easeOut(duration: 0.12), value: dropHover)
    }

    /// 文字输入：16px/行高 24；默认 32 高，随内容最多增长到 128，更多内容在区域内滚动。
    /// fixedSize(vertical: true) 让高度严格跟随内容（VStack 中不贪婪撑满），由 frame 钳制上下限。
    private var inputField: some View {
        TextField("输入问题…", text: $model.question, axis: .vertical)
            .textFieldStyle(.plain)
            .font(WorkbenchFont.font(16))
            .foregroundStyle(WorkbenchPalette.textPrimary)
            .lineLimit(1...6)
            .frame(minHeight: 32, maxHeight: 128, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .focused($inputFocused)
            .accessibilityIdentifier("workbench.question")
    }

    private var inputControlsRow: some View {
        HStack(spacing: WorkbenchLayout.controlGap) {
            Button(action: { showFilePicker = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .regular))
                    Text("附件")
                        .font(WorkbenchFont.font(14))
                }
                .foregroundStyle(WorkbenchPalette.textPrimary)
                .frame(width: 64, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(WorkbenchFlatButtonStyle())
            .accessibilityIdentifier("workbench.attachment")
            .help("添加附件：点击选择文件，或直接拖入文件 / 图片，也可 ⌘V 粘贴图片")

            Button(action: { voice.toggle() }) {
                Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(voice.isRecording ? WorkbenchPalette.checkboxSelected : WorkbenchPalette.textPrimary)
                    .frame(width: 32, height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(WorkbenchFlatButtonStyle())
            .accessibilityIdentifier("workbench.voice")
            .help(voice.isRecording ? "停止录音" : "语音输入（点击开始，再次点击结束）")

            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.attachments) { att in
                            attachmentChip(att)
                        }
                    }
                }
                .frame(height: 32)
            }

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Text("Ctrl+Enter 发送")
                    .font(WorkbenchFont.font(12))
                    .foregroundStyle(WorkbenchPalette.textSecondary)
                    .frame(width: 140, height: 24)
                    .accessibilityIdentifier("workbench.send.hint")
                sendButton
            }
        }
    }

    private func attachmentChip(_ att: WorkbenchModel.AttachmentItem) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.fill")
                .font(.system(size: 12))
                .foregroundStyle(WorkbenchPalette.textSecondary)
            Text(att.name)
                .font(WorkbenchFont.font(12))
                .foregroundStyle(WorkbenchPalette.textPrimary)
                .lineLimit(1)
            Text(formatBytes(att.size))
                .font(WorkbenchFont.font(11))
                .foregroundStyle(WorkbenchPalette.textSecondary)
            Button(action: { model.removeAttachment(id: att.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(WorkbenchPalette.textSecondary)
            .help("移除 \(att.name)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 24)
        .background(WorkbenchPalette.hoverFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 可发送条件沿用现有业务逻辑：非发送中，且（问题非空 或 有附件）。
    private var canSend: Bool {
        !model.sending &&
        (!model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty)
    }

    /// 文案按实际勾选数量动态变化；数量来自 enabledPanes（包含当前分页不可见的已选模型）。
    private var sendTitle: String {
        let n = model.enabledPanes.count
        return n > 0 ? "发送给 \(n) 个模型" : "发送"
    }

    private var sendButton: some View {
        Button(action: { model.send() }) {
            Text(sendTitle)
                .font(WorkbenchFont.font(14, weight: .semibold))
                .foregroundStyle(canSend ? Color.white : WorkbenchPalette.textSecondary)
                .frame(width: 144, height: 32)
                .background(canSend ? WorkbenchPalette.sendEnabled : WorkbenchPalette.sendDisabled,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(WorkbenchSendButtonStyle())
        .keyboardShortcut(.return, modifiers: [.command])
        .keyboardShortcut(.return, modifiers: [.control])
        .disabled(!canSend)
        .accessibilityIdentifier("workbench.send")
        .help("发送到所有勾选的模型（⌘↩ / Ctrl+Enter）")
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WorkbenchPalette.surface.opacity(0.94))
            VStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .font(.system(size: 18, weight: .medium))
                Text("松开以添加附件")
                    .font(WorkbenchFont.font(14))
            }
            .foregroundStyle(WorkbenchPalette.checkboxSelected)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WorkbenchPalette.checkboxSelected, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .allowsHitTesting(false)
    }

    // MARK: - 模型勾选与窗口分页行（高 32）

    private var modelRow: some View {
        HStack(spacing: WorkbenchLayout.groupGap) {
            ForEach(model.panes, id: \.adapter.id) { pane in
                Toggle(pane.adapter.name, isOn: model.binding(for: pane.adapter.id))
                    .toggleStyle(WorkbenchCheckToggleStyle())
                    .frame(width: WorkbenchLayout.modelOptionWidth(for: pane.adapter.id), height: 32, alignment: .leading)
                    .accessibilityIdentifier("workbench.model.\(pane.adapter.id)")
            }

            Spacer(minLength: 16)

            statusTextGroup

            if model.needsPaging {
                pager
            }
        }
        .frame(height: 32)
    }

    /// 瞬时状态文字（录音 / 就绪进度 / 发送结果），低强调纯文本。
    @ViewBuilder
    private var statusTextGroup: some View {
        HStack(spacing: WorkbenchLayout.groupGap) {
            if !voice.statusText.isEmpty {
                statusText(voice.statusText)
            }
            if !model.loginProgress.isEmpty {
                statusText(model.loginProgress)
            }
            if !model.statusText.isEmpty {
                statusText(model.statusText)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(WorkbenchFont.font(12))
            .foregroundStyle(WorkbenchPalette.textSecondary)
            .monospacedDigit()
            .accessibilityIdentifier("workbench.status")
    }

    /// 窗口分页：范围文字（112，右对齐）+ 两个 32×32 箭头按钮，无外框。
    private var pager: some View {
        HStack(spacing: WorkbenchLayout.controlGap) {
            Text(model.pageIndicator)
                .font(WorkbenchFont.font(12))
                .foregroundStyle(WorkbenchPalette.textSecondary)
                .monospacedDigit()
                .frame(width: 112, alignment: .trailing)
            pagerButton("chevron.left",
                        disabled: model.windowStart == 0,
                        help: "上一页窗口") { model.pageBackward() }
            pagerButton("chevron.right",
                        disabled: model.windowStart >= model.enabledPanes.count - WorkbenchModel.maxVisiblePanes,
                        help: "下一页窗口") { model.pageForward() }
        }
        .frame(height: 32)
    }

    private func pagerButton(_ systemName: String, disabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(WorkbenchPalette.textPrimary)
                .frame(width: 32, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(WorkbenchFlatButtonStyle())
        .disabled(disabled)
        .help(help)
    }

    // MARK: - 三列窗口（间距 16，等宽栅格）

    private var paneRow: some View {
        GeometryReader { geo in
            if model.visiblePanes.isEmpty {
                emptyState
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                let count = CGFloat(model.visiblePanes.count)
                let spacing = WorkbenchLayout.paneGap
                let available = geo.size.width - spacing * (count - 1)
                let width = max(available / count, 420)
                if width * count + spacing * (count - 1) > geo.size.width {
                    // 极窄窗口：保持每列最小 420 可读宽度，横向滚动
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: spacing) {
                            ForEach(model.visiblePanes, id: \.adapter.id) { pane in
                                paneView(pane).frame(width: width)
                            }
                        }
                        .frame(minHeight: geo.size.height)
                    }
                } else {
                    HStack(spacing: spacing) {
                        ForEach(model.visiblePanes, id: \.adapter.id) { pane in
                            paneView(pane).frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: geo.size.height)
                }
            }
        }
    }

    private func paneView(_ pane: PaneController) -> some View {
        PaneView(
            controller: pane,
            focused: model.focusedID == pane.adapter.id,
            onToggleFocus: { model.toggleFocus(pane.adapter.id) }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(WorkbenchPalette.textSecondary.opacity(0.7))
            Text("尚未选择模型")
                .font(WorkbenchFont.font(16, weight: .semibold))
                .foregroundStyle(WorkbenchPalette.textPrimary)
            Text("在上方勾选要参与显示和发送的平台")
                .font(WorkbenchFont.font(13))
                .foregroundStyle(WorkbenchPalette.textSecondary)
        }
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024) }
        return String(format: "%.1fMB", Double(n) / 1024 / 1024)
    }

    /// 抓取本应用窗口（含标题栏）的 PNG。仅用于验收取证（WB_SHOT 钩子）。
    static func captureWindowShot(to path: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let mine = (list ?? []).filter { (($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1) == pid
                                            && ($0[kCGWindowLayer as String] as? Int ?? 99) == 0 }
        // 取面积最大的主窗口（避免抓到菜单/辅助窗口）
        guard let info = mine.max(by: { area($0) < area($1) }),
              let wid = info[kCGWindowNumber as String] as? CGWindowID,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let w = b["Width"], let h = b["Height"],
              let img = CGWindowListCreateImage(CGRect(x: 0, y: 0, width: w, height: h),
                                                .optionIncludingWindow, wid,
                                                [.boundsIgnoreFraming, .bestResolution]) else {
            let owners = (list ?? []).compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue }
            print("[WB_SHOT] ❌ 窗口截图失败 (pid=\(pid), 屏上窗口 owner=\(owners))")
            return
        }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("[WB_SHOT] ❌ PNG 编码失败")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[WB_SHOT] ✅ 已保存 \(path) \(Int(w))×\(Int(h))px")
        } catch {
            print("[WB_SHOT] ❌ 写入失败: \(error)")
        }
    }

    private static func area(_ info: [String: Any]) -> CGFloat {
        guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return 0 }
        return (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
}

// MARK: - 按钮样式

/// 普通扁平按钮：默认无边框无底色，悬停 #EBEDF0，圆角 8。
private struct WorkbenchFlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchFlatButtonBody(configuration: configuration)
    }
}

private struct WorkbenchFlatButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .background(
                WorkbenchPalette.hoverFill.opacity(hovered ? 1 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// 发送按钮：深色底白字为页面唯一高强调；悬停略加深。
private struct WorkbenchSendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchSendButtonBody(configuration: configuration)
    }
}

private struct WorkbenchSendButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(WorkbenchPalette.sendHover.opacity(isEnabled && hovered ? 0.3 : 0))
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}

// MARK: - 模型复选样式（16×16 复选框 + 14px 文字，无胶囊边框）

private struct WorkbenchCheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchCheckToggleBody(configuration: configuration)
    }
}

private struct WorkbenchCheckToggleBody: View {
    let configuration: ToggleStyle.Configuration
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(configuration.isOn ? WorkbenchPalette.checkboxSelected : Color.clear)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(
                            focused ? WorkbenchPalette.checkboxSelected :
                            (configuration.isOn ? WorkbenchPalette.checkboxSelected :
                             (hovered ? WorkbenchPalette.textPrimary.opacity(0.55) : WorkbenchPalette.inputBorder)),
                            lineWidth: focused ? 2 : 1
                        )
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 16, height: 16)
                configuration.label
                    .font(WorkbenchFont.font(14))
                    .foregroundStyle(WorkbenchPalette.textPrimary)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
    }
}
