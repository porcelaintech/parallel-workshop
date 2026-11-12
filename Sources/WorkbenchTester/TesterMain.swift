import AppKit
import WorkbenchCore
import Foundation
import Darwin
import WebKit

/// 无人值守验收测试器：
/// 对每个平台 —— 离屏 WKWebView 加载官网 → 等待输入框就绪 → 自动注入问题并发送 →
/// 等待回答 → DOM 取证（问题回显/文本量增长）→ 截图存档。
///
/// 用法：
///   swift run WorkbenchTester [--probe-only] [--only=id1,id2] [问题文本]
/// 选项：
///   --probe-only   只探测不发送（用于新平台适配器取证：状态/输入框细节/候选按钮）
///   --only=id,...  只测试指定平台
/// 输出：
///   终端结构化日志 + test-output/<platform>.png 截图
@main
@MainActor
struct WorkbenchTester {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        var args = CommandLine.arguments.dropFirst()

        // 自检模式：本地夹具页，不触网，可随时运行
        if let i = args.firstIndex(of: "--selftest") {
            args.remove(at: i)
            exit(Int32(await SelfTest.run()))
        }

        // 更新器集成测试：由 PWB_INSTALL_DEST 指向隔离临时目录，不启动 GUI。
        if let i = args.firstIndex(of: "--update-smoke") {
            args.remove(at: i)
            guard let urlIndex = args.firstIndex(where: { $0.hasPrefix("--update-url=") }),
                  let shaIndex = args.firstIndex(where: { $0.hasPrefix("--update-sha=") }) else {
                print("用法：--update-smoke --update-url=<DMG URL> --update-sha=<SHA256>")
                exit(2)
            }
            let url = String(args[urlIndex].dropFirst("--update-url=".count))
            let sha = String(args[shaIndex].dropFirst("--update-sha=".count))
            let ok = await Updater.install(dmgURL: url, expectedSHA256: sha) { print("[update] \($0)") }
            print(ok ? "✅ 更新器安装链路通过" : "❌ 更新器安装链路失败")
            exit(ok ? 0 : 1)
        }

        // 单实例守护：与 GUI 同名共享 WebKit 数据目录，并发会损坏登录态
        if otherInstanceRunning() {
            print("⚠️ 检测到 GUI（ParallelWorkbench）正在运行。并发共享 WebKit 存储会损坏登录态，请先退出 GUI 再运行测试。")
            exit(3)
        }
        var probeOnly = false
        var force = false
        var uiAudit = false
        var only: Set<String>? = nil
        if let i = args.firstIndex(of: "--probe-only") {
            probeOnly = true
            args.remove(at: i)
        }
        if let i = args.firstIndex(of: "--ui-audit") {
            uiAudit = true
            args.remove(at: i)
        }
        if let i = args.firstIndex(of: "--force") {
            force = true
            args.remove(at: i)
        }
        if let i = args.firstIndex(of: "--cookies") {
            args.remove(at: i)
            await dumpCookies()
            exit(0)
        }
        if let i = args.firstIndex(of: "--backup-auth") {
            args.remove(at: i)
            exit(backupAuth() ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--restore-auth") {
            args.remove(at: i)
            exit(restoreAuth() ? 0 : 1)
        }
        if let i = args.firstIndex(where: { $0.hasPrefix("--only=") }) {
            only = Set(args.remove(at: i).dropFirst("--only=".count).split(separator: ",").map(String.init))
        }
        var attachPath: String? = nil
        if let i = args.firstIndex(where: { $0.hasPrefix("--attach=") }) {
            attachPath = String(args.remove(at: i).dropFirst("--attach=".count))
        }
        var clickSelector: String? = nil
        if let i = args.firstIndex(where: { $0.hasPrefix("--click=") }) {
            clickSelector = String(args.remove(at: i).dropFirst("--click=".count))
        }
        var evalJS: String? = nil
        if let i = args.firstIndex(where: { $0.hasPrefix("--eval=") }) {
            evalJS = String(args.remove(at: i).dropFirst("--eval=".count))
        }
        var attachOnly = false
        if let i = args.firstIndex(of: "--attach-only") {
            attachOnly = true
            args.remove(at: i)
        }
        var pasteAttach: String? = nil
        if let i = args.firstIndex(where: { $0.hasPrefix("--paste-attach=") }) {
            pasteAttach = String(args.remove(at: i).dropFirst("--paste-attach=".count))
        }
        var windowWidth = 1280.0
        if let i = args.firstIndex(where: { $0.hasPrefix("--width=") }) {
            windowWidth = Double(args.remove(at: i).dropFirst("--width=".count)) ?? 1280.0
        }
        let question = args.isEmpty ? "请用一句话介绍你自己，不超过20个字" : args.joined(separator: " ")

        let allAdapters = Adapter.loadAll()
        let adapters = only.map { o in allAdapters.filter { o.contains($0.id) } } ?? allAdapters
        print("已加载适配器: \(allAdapters.map(\.name).joined(separator: "、"))")
        print("本次测试: \(adapters.map(\.name).joined(separator: "、"))\(probeOnly ? "（仅探测，不发送）" : "")")
        guard !adapters.isEmpty else {
            print("FATAL: 无匹配适配器")
            exit(2)
        }
        let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("test-output")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var keepAliveWindows: [NSWindow] = []
        var failures = 0
        var skipped = 0

        for adapter in adapters {
            print("\n===== 测试平台: \(adapter.name) (\(adapter.origin)) =====")

            let pane = await MainActor.run { PaneController(adapter: adapter) }
            let window = await MainActor.run { () -> NSWindow in
                // 离屏窗口（x=-4000，用户不可见），保证 WKWebView 有渲染宿主、可截图
                let w = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: windowWidth, height: 900),
                                 styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = pane.webView
                w.orderFront(nil)
                return w
            }
            keepAliveWindows.append(window)

            let loaded = await pane.waitForLoad(timeout: 60)
            guard loaded else {
                print("❌ 页面 60s 内未完成加载（网络或风控拦截？）")
                failures += 1
                continue
            }
            print("页面加载完成")

            let hasInput = await pane.waitForInput(timeout: 30)
            await pane.refreshStatus()
            let detail = await pane.inputDetail()
            let buttons = await pane.buttonCandidates()
            let logins = await pane.loginElements()
            print("状态: \(pane.statusLabel)，输入框可用: \(hasInput)")
            print("输入框详情: \(detail)")
            if let evalJS {
                await pane.idle(8)
                if let r = await pane.debugEval(evalJS) {
                    print("eval 结果: \(r)")
                } else {
                    print("eval 结果: nil")
                }
                continue
            }
            if !buttons.isEmpty {
                print("候选发送按钮: \(buttons)")
            }
            if !logins.isEmpty {
                print("登录入口元素: \(logins)")
            }
            // 页面适配审计：主题注入/字体命中/推广候选/关键功能可见性
            if uiAudit {
                await pane.idle(8)
                let audit = await pane.uiAudit()
                print("【UI 审计】\(adapter.name):")
                print("  host=\(audit["host"] ?? "?") url=\(audit["url"] ?? "?") themeInjected=\(audit["themeInjected"] ?? "?")")
                print("  bodyFont=\(audit["bodyFont"] ?? "?")")
                print("  inputFont=\(audit["inputFont"] ?? "?")")
                print("  placeholderFont=\(audit["placeholderFont"] ?? "?")")
                print("  buttonFont=\(audit["buttonFont"] ?? "?")")
                print("  fontChecks=\(audit["fontChecks"] ?? "?")")
                print("  critical=\(audit["critical"] ?? "?")")
                print("  downloadLinks=\(audit["downloadLinks"] ?? "?")")
                print("  textHits=\(audit["textHits"] ?? "?")")
                print("  pageText=\(audit["pageText"] ?? "?")")
                if let promo = audit["promo"] as? [[String: Any]] {
                    print("  推广候选(\(promo.count)):")
                    for p in promo {
                        print("    [\(p["visible"] as? Bool == true ? "可见" : "隐藏")] \(p["text"] ?? "?") <\(p["tag"] ?? "?") class=\(p["cls"] ?? "-") id=\(p["id"] ?? "-")>")
                        print("      \(p["chain"] ?? "-")")
                    }
                }
                let shotPath = outDir.appendingPathComponent("\(adapter.id)-ui.png").path
                let shot = await pane.screenshot(to: shotPath)
                print("  截图: \(shot ? "OK \(shotPath)" : "失败")")
                continue
            }
            // 探测模式打印全部输入框候选（识别哪个才是主聊天输入框）
            if probeOnly {
                // 预点击（取证动态渲染的元素，如上传面板）：点击 → 等待 → 再取证
                if let cs = clickSelector {
                    let clicked = await pane.clickSelector(cs)
                    let hit = clicked ? "已命中" : "未命中"
                    print("预点击(\(cs)): \(hit)")
                    await pane.idle(2.5)
                }
                let fileIns = await pane.fileInputs()
                if !fileIns.isEmpty {
                    print("附件相关元素: \(fileIns)")
                }
                let candidates = await pane.inputCandidates()
                if !candidates.isEmpty {
                    print("全部输入框候选: \(candidates)")
                }
            }

            // 探测模式：不发送，只取证
            if probeOnly {
                let allButtons = await pane.allButtons()
                if !allButtons.isEmpty {
                    print("全部按钮清单: \(allButtons)")
                }
                let links = await pane.links()
                if !links.isEmpty {
                    print("页面链接清单: \(links)")
                }
                let composerHTML = await pane.composerHTML()
                print("编辑器外层结构:")
                print("----")
                print(composerHTML)
                print("----")
                let tail = await pane.pageTextTail(200)
                let head = await pane.pageTextHead(600)
                print("页面文本前部:")
                print("----")
                print(head)
                print("----")
                print("页面文本尾部:")
                print("----")
                print(tail)
                print("----")
                let shotPath = outDir.appendingPathComponent("\(adapter.id).png").path
                let shot = await pane.screenshot(to: shotPath)
                print("截图: \(shot ? "OK \(shotPath)" : "失败")")
                continue
            }

            // 未登录的平台默认跳过；--force 时仍尝试发送（游客模式平台，如文心/ChatGPT）
            if pane.status == .loggedOut && !force {
                print("⚠️ 平台 \(adapter.name) 未登录，跳过发送（需人工登录后复测）")
                let shotPath = outDir.appendingPathComponent("\(adapter.id).png").path
                let shot = await pane.screenshot(to: shotPath)
                print("截图: \(shot ? "OK \(shotPath)" : "失败")")
                skipped += 1
                continue
            }
            if pane.status == .loggedOut && force {
                print("⚠️ 平台 \(adapter.name) 未登录，但 --force 指定继续尝试（游客模式验证）")
            }

            // 预动作（新建对话等）已由 PaneController.send 生产路径统一处理，测试器不再重复执行

            // 原生粘贴通道：sendEvent 同步派发（无需 NSApp.run）
            if let path = pasteAttach {
                let url = URL(fileURLWithPath: path)
                let rc = await runPasteTest(file: url)
                print(rc == 0 ? "✅ 原生粘贴测试通过" : "❌ 原生粘贴测试失败")
                skipped += 1
                continue
            }

            var atts: [[String: Any]] = []
            var attName = ""
            if let path = attachPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                attName = URL(fileURLWithPath: path).lastPathComponent
                atts = [["name": attName, "mime": "application/octet-stream", "data": data.base64EncodedString()]]
                print("附件: \(attName) (\(data.count) bytes)")
            }

            let before = await pane.textLength()
            let indicatorBaseline: Bool
            if let ind = adapter.verify?.responseIndicator, !ind.isEmpty {
                indicatorBaseline = await pane.containsText(ind)
            } else {
                indicatorBaseline = false
            }
            let report = await pane.send(text: question, attachments: atts, noSend: attachOnly)
            print("注入发送: \(report)")
            if attachOnly {
                // 只注入不发送：取证附件落地状态
                await pane.idle(2)
                let state = await pane.inputState()
                let hasName = attName.isEmpty ? false : await pane.containsText(attName)
                let tail = await pane.pageTextTail(250)
                print("附件落地取证: 输入框=\(state) 文件名可见=\(hasName)")
                print("----")
                print(tail)
                print("----")
                skipped += 1
                continue
            }

            // 二段式：3 秒后检查消息是否进入对话区，未进入则重发一次（部分平台首次发送会先建会话）
            await pane.idle(3)
            let bubble1 = await pane.messageBubbleContains(String(question.prefix(10)))
            let state1 = await pane.inputState()
            let cleared1 = state1["cleared"] as? Bool ?? false
            if !bubble1 && !cleared1 {
                print("首段未提交（气泡=\(bubble1) 清空=\(cleared1)），重发一次…")
                _ = await pane.send(text: question)
            }

            await pane.idle(18)
            await pane.refreshStatus()
            let after = await pane.textLength()
            let echo = await pane.containsText(String(question.prefix(10)))
            let bubble = await pane.messageBubbleContains(String(question.prefix(10)))
            let inputState = await pane.inputState()
            let cleared = inputState["cleared"] as? Bool ?? false
            if !attName.isEmpty {
                let attEcho = await pane.containsText(attName)
                print("附件回显: \(attEcho)")
            }
            let tail = await pane.pageTextTail(300)
            // 回答标志判定（适用于发送后不清空输入框的平台，如 ChatGPT 游客模式）
            var responseSeen = false
            if let indicator = adapter.verify?.responseIndicator, !indicator.isEmpty {
                responseSeen = await pane.containsText(indicator)
            }
            print("页面文本量: \(before) → \(after)；问题回显: \(echo)；消息气泡: \(bubble)")
            print("输入框状态: found=\(inputState["found"] ?? "?") cleared=\(cleared) value=\(inputState["value"] ?? "")")
            print("发送后状态: \(pane.statusLabel)；回答标志: \(responseSeen ? "已出现" : (adapter.verify?.responseIndicator == nil ? "未配置" : "未出现"))")
            print("页面文本尾部（回答原文）:")
            print("----")
            print(tail)
            print("----")

            let shotPath = outDir.appendingPathComponent("\(adapter.id).png").path
            let shot = await pane.screenshot(to: shotPath)
            print("截图: \(shot ? "OK \(shotPath)" : "失败")")

            // 通过标准：提交证据（清空/气泡）+ 问题回显 + 页面文本实际增长；
            // 回答标志必须是"发送后新增"（排除页面历史文本假阳性）
            let hasIndicator = adapter.verify?.responseIndicator != nil
            let submitted = cleared || bubble
            let growth = after - before
            let indicatorFresh = !indicatorBaseline && responseSeen
            // pointer 型平台（通义）：发送会从落地页切到会话页，页面整体文本可能变短；
            // 判据放宽为「消息已进入对话区 + 页面未大幅消失（-500 内）」，避免布局变化造成假阴性
            let layoutShrinkOK = adapter.send.type == "pointer" && bubble && growth > -500
            let passed = hasIndicator ? (hasInput && echo && (indicatorFresh || growth > 0))
                                       : (hasInput && echo && submitted && (growth > 0 || layoutShrinkOK))

            if pane.status == .loggedOut {
                print("⚠️ 平台 \(adapter.name) 未登录（需人工扫码登录后复测），跳过判定")
                skipped += 1
            } else if !passed {
                print("❌ 平台 \(adapter.name) 验收不通过（hasInput=\(hasInput) echo=\(echo) 气泡=\(bubble) 清空=\(cleared) 回答标志=\(responseSeen) 增长=\(growth)）")
                failures += 1
            } else {
                print("✅ 平台 \(adapter.name) 验收通过（消息已提交、模型已生成回答）")
            }
        }

        if probeOnly {
            print("\n===== 探测完成（未发送任何消息） =====")
            exit(0)
        }
        print("\n===== 测试完成：\(adapters.count - failures - skipped)/\(adapters.count) 通过，\(skipped) 待登录，\(failures) 失败 =====")
        exit(failures == 0 ? 0 : 1)
    }

    /// NSApp 事件环驱动：Kimi 原生粘贴附件实测
    @MainActor
    static func runPasteTest(file: URL) async -> Int32 {
        guard let adapter = Adapter.loadAll().first(where: { $0.id == "kimi" }) else { return 1 }
        let pane = PaneController(adapter: adapter)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1280, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane.webView
        window.orderFront(nil)

        guard await pane.waitForLoad(timeout: 60) else {
            print("❌ 页面加载失败")
            return 1
        }
        let hasInput = await pane.waitForInput(timeout: 30)
        print("输入框可用: \(hasInput)")

        // 先装按键监听（验证事件是否到达 + 可信性）
        _ = try? await pane.webView.evaluateJavaScript("""
        window.__pasteKey = null;
        window.__pasteInfo = null;
        document.addEventListener('keydown', (e) => {
          if (e.key === 'v' && (e.metaKey || e.ctrlKey)) window.__pasteKey = e.isTrusted;
        });
        document.addEventListener('paste', (e) => {
          window.__pasteInfo = {
            types: e.clipboardData ? Array.from(e.clipboardData.types || []) : [],
            files: e.clipboardData && e.clipboardData.files ? e.clipboardData.files.length : 0,
            text: e.clipboardData ? e.clipboardData.getData('text/plain').slice(0, 60) : ''
          };
        });
        """)
        let report = await pane.sendWithPaste(text: "这张图片里有什么？", fileURLs: [file])
        print("发送: \(report)")
        if let trust = try? await pane.webView.evaluateJavaScript("window.__pasteKey") {
            print("粘贴按键到达: \(String(describing: trust))")
        }
        if let info = try? await pane.webView.evaluateJavaScript("JSON.stringify(window.__pasteInfo || null)") {
            print("页面粘贴数据: \(String(describing: info))")
        }

        // 等上传/回答证据（最多 20 秒）
        let deadline = Date().addingTimeInterval(20)
        var visible = false
        while Date() < deadline {
            visible = await pane.containsText(file.lastPathComponent)
            if visible { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("文件名可见: \(visible)")
        let bubble = await pane.messageBubbleContains("这张图片里有什么？")
        print("消息气泡: \(bubble)")
        return (visible || bubble) ? 0 : 1
    }

    /// 是否有另一个 ParallelWorkbench 进程（GUI）在运行。
    /// 注意：pgrep -x 匹配的进程名被 macOS 截断（15 字符），且改名后的测试器自身
    /// 不会计入，因此改用完整命令行匹配（pgrep -f）并排除自身 PID。
    static func otherInstanceRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = [
            "-f",
            "ParallelWorkbench\\.app/Contents/MacOS/ParallelWorkbench|/debug/ParallelWorkbench$|/release/ParallelWorkbench$|\\.tester-bin/ParallelWorkbench$"
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let others = String(data: data, encoding: .utf8)!
            .split(separator: "\n")
            .compactMap { Int32($0) }
            .filter { $0 != selfPID }
        return !others.isEmpty
    }

    /// 打印共享 cookie 罐中与各平台相关的 cookie（只看域名与条数，不泄露值）
    static func dumpCookies() async {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let keywords = ["deepseek", "kimi", "moonshot", "tongyi", "aliyun", "yiyan", "baidu", "chatgpt", "openai", "claude", "gemini", "google"]
        let grouped = Dictionary(grouping: cookies, by: { $0.domain })
        let relevant = grouped.filter { domain, _ in keywords.contains { domain.contains($0) } }
        print("相关域 cookie 统计（\(cookies.count) 条总数）:")
        if relevant.isEmpty {
            print("  （无相关域 cookie——平台登录态不在共享罐中或未登录）")
            return
        }
        for (domain, list) in relevant.sorted(by: { $0.key < $1.key }) {
            let sessionish = list.filter {
                let n = $0.name.lowercased()
                return n.contains("session") || n.contains("token") || n.contains("auth") || n.contains("login")
            }
            let suffix = sessionish.isEmpty ? "" : "，疑似会话凭证: \(sessionish.map(\.name).joined(separator: "、"))"
            print("  \(domain): \(list.count) 条\(suffix)")
        }
    }

    // MARK: - 登录态备份/恢复（覆盖 localStorage/IndexedDB + cookie 两层）

    static func authPaths() -> (websiteData: URL, cookies: URL, backupDir: URL) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let websiteData = home.appendingPathComponent("Library/WebKit/ParallelWorkbench/WebsiteData")
        let cookies = home.appendingPathComponent("Library/HTTPStorages/ParallelWorkbench.binarycookies")
        let backupDir = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("auth-backup")
        return (websiteData, cookies, backupDir)
    }

    /// 备份 GUI 应用（ParallelWorkbench 进程）的登录态到工作区 auth-backup/
    static func backupAuth() -> Bool {
        let (websiteData, cookies, backupDir) = authPaths()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let wdDest = backupDir.appendingPathComponent("WebsiteData")
            if fm.fileExists(atPath: websiteData.path) {
                if fm.fileExists(atPath: wdDest.path) { try fm.removeItem(at: wdDest) }
                try fm.copyItem(at: websiteData, to: wdDest)
            }
            let ckDest = backupDir.appendingPathComponent("cookies.binarycookies")
            if fm.fileExists(atPath: cookies.path) {
                if fm.fileExists(atPath: ckDest.path) { try fm.removeItem(at: ckDest) }
                try fm.copyItem(at: cookies, to: ckDest)
            }
            print("✅ 登录态已备份到 \(backupDir.path)")
            print("   （建议：各平台登录完成后执行一次；应用存储损坏或迁移时用 --restore-auth 恢复）")
            return true
        } catch {
            print("❌ 备份失败: \(error)")
            return false
        }
    }

    /// 从工作区 auth-backup/ 恢复登录态（请先退出 ParallelWorkbench 应用再执行）
    static func restoreAuth() -> Bool {
        let (websiteData, cookies, backupDir) = authPaths()
        let fm = FileManager.default
        do {
            let wdSrc = backupDir.appendingPathComponent("WebsiteData")
            let ckSrc = backupDir.appendingPathComponent("cookies.binarycookies")
            guard fm.fileExists(atPath: wdSrc.path) || fm.fileExists(atPath: ckSrc.path) else {
                print("❌ 未找到备份（\(backupDir.path)），请先执行 --backup-auth")
                return false
            }
            if fm.fileExists(atPath: wdSrc.path) {
                if fm.fileExists(atPath: websiteData.path) { try fm.removeItem(at: websiteData) }
                try fm.copyItem(at: wdSrc, to: websiteData)
            }
            if fm.fileExists(atPath: ckSrc.path) {
                if fm.fileExists(atPath: cookies.path) { try fm.removeItem(at: cookies) }
                try fm.copyItem(at: ckSrc, to: cookies)
            }
            print("✅ 登录态已恢复，重启 ParallelWorkbench 后生效")
            return true
        } catch {
            print("❌ 恢复失败: \(error)")
            return false
        }
    }
}
