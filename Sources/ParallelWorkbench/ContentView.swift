import SwiftUI
import AppKit
import WorkbenchCore

enum WorkbenchPalette {
    static let warmWhite = Color(red: 247.0 / 255.0, green: 245.0 / 255.0, blue: 240.0 / 255.0)
    static let graphite = Color(red: 37.0 / 255.0, green: 42.0 / 255.0, blue: 46.0 / 255.0)
    static let sage = Color(red: 126.0 / 255.0, green: 146.0 / 255.0, blue: 131.0 / 255.0)
}

private typealias ContentPalette = WorkbenchPalette

struct ContentView: View {
    @StateObject private var model = WorkbenchModel()
    @EnvironmentObject private var updates: UpdateCoordinator
    @StateObject private var voice = VoiceInput()
    @FocusState private var inputFocused: Bool
    @State private var showFilePicker = false
    @State private var questionBaseline = ""

    var body: some View {
        ZStack {
            ContentPalette.warmWhite
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                paneRow
            }
        }
        .frame(minWidth: 1280, minHeight: 760)
        .foregroundStyle(ContentPalette.graphite)
        .tint(ContentPalette.sage)
        .onAppear {
            // 裸可执行文件启动的 GUI 应用：显式常规激活策略 + 激活，否则窗口收不到键盘输入
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // 稍后把焦点钉到输入框（等窗口先成为 key window）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                inputFocused = true
            }
            updates.startAutomaticChecks()
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
        // 拖入文件 → 附件；粘贴图片 → 附件
        .dropDestination(for: URL.self) { urls, _ in
            model.addAttachment(urls: urls)
            return true
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

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("智囊")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(3)
                    Text("BRAINTRUST")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.7)
                        .foregroundStyle(ContentPalette.graphite.opacity(0.58))
                }

                Spacer()

                Text("v\(updates.currentVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ContentPalette.graphite.opacity(0.62))
                Button(action: { updates.primaryAction() }) {
                    Label(updates.buttonTitle, systemImage: "arrow.down.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(WorkbenchSoftButtonStyle(tint: ContentPalette.sage,
                                                     emphasized: updates.availableVersion != nil))
                .disabled(updates.isBusy || model.sending)
                .fixedSize()
                .accessibilityIdentifier("workbench.update")
                .help(updates.helpText)

                Label("⌘↩ 发送", systemImage: "command")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ContentPalette.graphite.opacity(0.62))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(ContentPalette.graphite.opacity(0.035), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(ContentPalette.graphite.opacity(0.12))
                            .allowsHitTesting(false)
                    )
            }

            if !updates.message.isEmpty {
                HStack {
                    Text(updates.message)
                        .font(.caption)
                        .foregroundStyle(ContentPalette.graphite.opacity(0.75))
                        .accessibilityIdentifier("workbench.update.status")
                    Spacer(minLength: 0)
                    if updates.phase == .failed {
                        Button("重试") { updates.primaryAction() }
                            .buttonStyle(WorkbenchTextButtonStyle())
                    }
                }
            }

            // 主战场：大输入框 + 大发送按钮
            HStack(spacing: 10) {
                TextField("输入问题（Enter 换行，⌘↩ 或点「发送」同步到所有勾选的模型）", text: $model.question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(ContentPalette.graphite)
                    .lineLimit(2...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(ContentPalette.warmWhite)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                inputFocused ? ContentPalette.sage.opacity(0.82) : ContentPalette.graphite.opacity(0.18),
                                lineWidth: inputFocused ? 1.5 : 1
                            )
                            .allowsHitTesting(false)
                    )
                    .shadow(
                        color: inputFocused ? ContentPalette.sage.opacity(0.13) : ContentPalette.graphite.opacity(0),
                        radius: inputFocused ? 5 : 0
                    )
                    .focused($inputFocused)
                    .animation(.easeOut(duration: 0.16), value: inputFocused)

                Button(action: { voice.toggle() }) {
                    Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(WorkbenchIconButtonStyle(tint: ContentPalette.sage, selected: voice.isRecording))
                .help(voice.isRecording ? "停止录音" : "语音输入（点击开始，再次点击结束）")

                Button(action: { model.send() }) {
                    Label("发送", systemImage: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(WorkbenchPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
                .help("发送到所有勾选的模型（⌘↩）")
                .disabled(model.sending ||
                          (model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty))
            }

            // 语音状态提示
            if !voice.statusText.isEmpty {
                HStack {
                    statusPill(
                        voice.statusText,
                        color: voice.isRecording ? ContentPalette.sage : ContentPalette.graphite,
                        systemImage: voice.isRecording ? "waveform" : "mic"
                    )
                    Spacer()
                }
            }

            // 附件栏：已选附件 chips + 添加/拖放/粘贴
            if !model.attachments.isEmpty || true {
                HStack(spacing: 8) {
                    Button(action: { showFilePicker = true }) {
                        Label("附件", systemImage: "paperclip")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(WorkbenchSoftButtonStyle(tint: ContentPalette.sage))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.attachments) { att in
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.fill")
                                        .font(.caption2)
                                        .foregroundStyle(ContentPalette.sage)
                                    Text(att.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(formatBytes(att.size))
                                        .font(.caption2)
                                        .foregroundStyle(ContentPalette.graphite.opacity(0.58))
                                    Button(action: { model.removeAttachment(id: att.id) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(ContentPalette.graphite.opacity(0.55))
                                    .help("移除 \(att.name)")
                                }
                                .padding(.leading, 9)
                                .padding(.trailing, 6)
                                .padding(.vertical, 5)
                                .background(ContentPalette.sage.opacity(0.09), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(ContentPalette.sage.opacity(0.2))
                                        .allowsHitTesting(false)
                                )
                            }
                        }
                    }

                    Spacer(minLength: 6)

                    Text("可拖入文件 / 图片，或 ⌘V 粘贴图片")
                        .font(.caption2)
                        .foregroundStyle(ContentPalette.graphite.opacity(0.5))
                        .fixedSize()
                }
            }

            // 控制行：平台勾选（= 参与显示与发送）+ 分页 + 状态
            HStack(spacing: 9) {
                ForEach(model.panes, id: \.adapter.id) { pane in
                    Toggle(pane.adapter.name, isOn: model.binding(for: pane.adapter.id))
                        .toggleStyle(WorkbenchPlatformToggleStyle())
                        .fixedSize()
                }

                if model.needsPaging {
                    HStack(spacing: 3) {
                        Button(action: { model.pageBackward() }) {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(WorkbenchMiniIconButtonStyle())
                        .disabled(model.windowStart == 0)
                        .help("上一页窗格")

                        Text(model.pageIndicator)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ContentPalette.graphite.opacity(0.62))
                            .monospacedDigit()
                            .frame(minWidth: 30)

                        Button(action: { model.pageForward() }) {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(WorkbenchMiniIconButtonStyle())
                        .disabled(model.windowStart >= model.enabledPanes.count - WorkbenchModel.maxVisiblePanes)
                        .help("下一页窗格")
                    }
                    .padding(3)
                    .background(ContentPalette.graphite.opacity(0.035), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(ContentPalette.graphite.opacity(0.12))
                            .allowsHitTesting(false)
                    )
                }

                if let f = model.focusedID {
                    Button(action: { model.toggleFocus(f) }) {
                        Label("退出放大", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(WorkbenchSoftButtonStyle(tint: ContentPalette.sage))
                }

                Spacer(minLength: 8)

                if !model.loginProgress.isEmpty {
                    statusPill(model.loginProgress, color: ContentPalette.sage, systemImage: "person.crop.circle.badge.clock")
                }
                if !model.statusText.isEmpty {
                    statusPill(model.statusText, color: ContentPalette.graphite, systemImage: "info.circle")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .background(ContentPalette.warmWhite.opacity(0.98))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ContentPalette.graphite.opacity(0.13))
                .frame(height: 1)
                .allowsHitTesting(false)
        }
        .zIndex(1)
    }

    private var paneRow: some View {
        GeometryReader { geo in
            if model.visiblePanes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(ContentPalette.sage.opacity(0.76))
                    Text("尚未选择模型")
                        .font(.title3.weight(.semibold))
                    Text("在上方选择要参与显示和发送的平台")
                        .font(.callout)
                        .foregroundStyle(ContentPalette.graphite.opacity(0.58))
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .background(ContentPalette.warmWhite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(ContentPalette.graphite.opacity(0.14))
                        .allowsHitTesting(false)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                // 每 pane 最小 420px（更窄会触发平台响应式布局、输入框消失）
                let count = CGFloat(model.visiblePanes.count)
                let paneSpacing: CGFloat = 10
                let paneInset: CGFloat = 12
                let availableWidth = geo.size.width - paneInset * 2 - paneSpacing * max(count - 1, 0)
                let paneWidth = max(availableWidth / count, 420)
                ScrollView(.horizontal) {
                    HStack(spacing: paneSpacing) {
                        ForEach(model.visiblePanes, id: \.adapter.id) { pane in
                            PaneView(
                                controller: pane,
                                focused: model.focusedID == pane.adapter.id,
                                onToggleFocus: { model.toggleFocus(pane.adapter.id) }
                            )
                            .frame(width: paneWidth)
                        }
                    }
                    .padding(.horizontal, paneInset)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func statusPill(_ text: String, color: Color, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.09), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.16))
                    .allowsHitTesting(false)
            )
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n)B" }
        if n < 1024 * 1024 { return String(format: "%.1fKB", Double(n) / 1024) }
        return String(format: "%.1fMB", Double(n) / 1024 / 1024)
    }
}

private struct WorkbenchPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchPrimaryButtonBody(configuration: configuration)
    }
}

private struct WorkbenchPrimaryButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(ContentPalette.warmWhite)
            .padding(.horizontal, 23)
            .frame(height: 46)
            .background(
                ContentPalette.sage.opacity(isHovered ? 1 : 0.92),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(ContentPalette.graphite.opacity(isHovered ? 0.18 : 0.1))
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.975 : (isHovered ? 1.01 : 1))
            .opacity(isEnabled ? 1 : 0.48)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct WorkbenchIconButtonStyle: ButtonStyle {
    let tint: Color
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        WorkbenchIconButtonBody(configuration: configuration, tint: tint, selected: selected)
    }
}

private struct WorkbenchIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(tint)
            .frame(width: 46, height: 46)
            .background(
                (selected ? tint.opacity(0.16) : ContentPalette.graphite.opacity(isHovered ? 0.07 : 0.035)),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke((selected || isHovered) ? tint.opacity(0.34) : ContentPalette.graphite.opacity(0.14))
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : (isHovered ? 1.015 : 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct WorkbenchSoftButtonStyle: ButtonStyle {
    let tint: Color
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        WorkbenchSoftButtonBody(configuration: configuration, tint: tint, emphasized: emphasized)
    }
}

private struct WorkbenchSoftButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let emphasized: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(emphasized ? ContentPalette.warmWhite : tint)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                emphasized ? tint : tint.opacity(isHovered ? 0.13 : 0.075),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(emphasized ? ContentPalette.graphite.opacity(0.12) : tint.opacity(isHovered ? 0.3 : 0.18))
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct WorkbenchTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(ContentPalette.graphite.opacity(0.62))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(ContentPalette.graphite.opacity(configuration.isPressed ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct WorkbenchMiniIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(ContentPalette.graphite.opacity(0.62))
            .frame(width: 24, height: 24)
            .background(ContentPalette.graphite.opacity(configuration.isPressed ? 0.09 : 0), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct WorkbenchPlatformToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchPlatformToggleBody(configuration: configuration)
    }
}

private struct WorkbenchPlatformToggleBody: View {
    let configuration: ToggleStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                configuration.label
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(configuration.isOn ? ContentPalette.sage : ContentPalette.graphite.opacity(0.62))
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(
                configuration.isOn ? ContentPalette.sage.opacity(isHovered ? 0.16 : 0.11) : ContentPalette.graphite.opacity(isHovered ? 0.07 : 0.035),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    configuration.isOn ? ContentPalette.sage.opacity(isHovered ? 0.38 : 0.25) : ContentPalette.graphite.opacity(0.14)
                )
                .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
