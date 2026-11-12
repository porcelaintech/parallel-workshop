import AppKit
import WebKit
import Combine

/// 单个模型窗格的状态。
public enum PaneStatus: Equatable {
    case loading
    case ready
    case loggedOut
    case challenge
    case inputMissing
    case unreachable(String)
}

/// 一个模型窗格：WKWebView 加载平台官网 + 注入引擎 + 状态探测。
/// 使用本应用自己的 WKWebsiteDataStore.default()，登录态在应用内持久化，不继承 Safari。
@MainActor public final class PaneController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    public let adapter: Adapter
    public let webView: WKWebView

    @Published public var status: PaneStatus = .loading
    @Published public private(set) var lastLog: String = ""
    @Published public private(set) var currentURL: String = ""
    var isLoaded = false

    public init(adapter: Adapter) {
        self.adapter = adapter
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 本应用独立的持久 WebKit 数据存储
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if adapter.id == "deepseek", !InjectionScripts.modelPreferenceJS.isEmpty {
            config.userContentController.addUserScript(WKUserScript(
                source: InjectionScripts.modelPreferenceJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        // 页面适配（字体统一 + 推广精简）：全部平台的主框架注入
        if !InjectionScripts.pageThemeJS.isEmpty {
            config.userContentController.addUserScript(WKUserScript(
                source: InjectionScripts.pageThemeJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 不做 UA 伪装，保持 Safari 系 UA
        webView.load(URLRequest(url: URL(string: adapter.origin)!))
    }

    public var statusLabel: String {
        switch status {
        case .loading: return "加载中"
        case .ready: return "就绪"
        case .loggedOut: return "未登录"
        case .challenge: return "需人工验证"
        case .inputMissing: return "未找到输入框"
        case .unreachable: return "网络不可达"
        }
    }

    // MARK: - 注入

    /// 最近一次 send 的结果是否成功（供上层状态机判断清空/回填）
    public private(set) var lastResultOK: Bool? = nil

    @discardableResult
    public func send(text: String, attachments: [[String: Any]] = [], noSend: Bool = false) async -> String {
        lastResultOK = false
        guard isLoaded else {
            lastLog = "页面未加载完成，跳过"
            lastResultOK = false
            print("[\(adapter.id)] ⏭ 页面未加载完成，跳过发送")
            return lastLog
        }
        // 输入框缺失时执行预动作（如通义「新建对话」进入对话视图后再注入）
        if let prep = adapter.prepare, let prepSelector = prep.clickSelector, !prepSelector.isEmpty {
            let hasInput = await waitForInput(timeout: 3)
            if !hasInput {
                _ = await clickSelector(prepSelector)
                let wait = prep.waitSeconds ?? 3
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            }
        }
        let reqId = UUID().uuidString
        let js = InjectionScripts.build(InjectionScripts.injectJS, cfg: adapter.injectionConfig(text: text, attachments: attachments, noSend: noSend, reqId: reqId))
        do {
            // 脚本异步执行、结果写入 window.__wb_result，这里轮询取回（WebKit 不自动等待 Promise）；
            // 只接受与本轮 reqId 匹配的结果，避免快速连续发送串读旧结果
            _ = try await eval(js)
            var dict: [String: Any] = [:]
            for _ in 0..<50 {
                if let r = try? await eval("window.__wb_result || null"),
                   let d = r as? [String: Any], !d.isEmpty,
                   (d["reqId"] as? String) == reqId {
                    dict = d
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if dict.isEmpty {
                lastLog = "注入超时（脚本未返回结果）"
                lastResultOK = false
                print("[\(adapter.id)] ❌ 注入超时（5s 内未取回 window.__wb_result）")
                return lastLog
            }
            lastResultOK = dict["ok"] as? Bool
            if dict["ok"] as? Bool == true {
                let sent = dict["sent"] as? String ?? "?"
                let attInfo = dict["attInfo"] as? String ?? ""
                if attInfo.hasPrefix("fileInput:") && attInfo != "fileInput:0" {
                    lastLog = "已发送（含附件 \(attInfo)）"
                } else if attInfo.hasPrefix("drop:") && attInfo != "drop:0" {
                    lastLog = "已发送（附件走拖放）"
                } else if !attInfo.isEmpty && attInfo != "none" {
                    lastLog = "已发送（附件未能自动注入，请在该窗格手动添加）"
                } else {
                    lastLog = "已注入并发送(\(sent))"
                }
                print("[\(adapter.id)] ✅ 注入成功，发送方式: \(sent)")
                if let bs = dict["buttonState"] as? [String: Any], !bs.isEmpty {
                    print("[\(adapter.id)]    按钮状态: disabled=\(bs["disabled"] ?? "?") aria-disabled=\(bs["ariaDisabled"] ?? "null")，命中数=\(dict["matchedCount"] ?? "?")")
                }
                if let matches = dict["matches"] as? [[String: Any]], !matches.isEmpty {
                    print("[\(adapter.id)]    按钮命中清单: \(matches)")
                }
                if let att = dict["attInfo"] as? String, !att.isEmpty {
                    print("[\(adapter.id)]    附件结果: \(att)")
                }
                if let html = dict["editorHTML"] as? String, !html.isEmpty {
                    print("[\(adapter.id)]    编辑器HTML: \(html)")
                }
            } else {
                let error = dict["error"] as? String ?? "UNKNOWN"
                lastLog = "注入失败: \(error)"
                print("[\(adapter.id)] ❌ 注入失败: \(error)")
                if error == "NO_INPUT" {
                    status = .inputMissing
                    if let candidates = dict["candidates"] as? [[String: Any]] {
                        print("[\(adapter.id)] 页面内候选输入框:")
                        for c in candidates.prefix(8) {
                            print("    tag=\(c["tag"] ?? "?") id=\(c["id"] ?? "-") class=\(c["cls"] ?? "-") placeholder=\(c["ph"] ?? "-")")
                        }
                    }
                }
            }
        } catch {
            lastResultOK = false
            lastLog = "注入异常: \(error.localizedDescription)"
            print("[\(adapter.id)] ❌ 注入异常: \(error)")
        }
        // 反馈提示 5 秒后自动消失
        let final = lastLog
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.lastLog == final { self.lastLog = "" }
        }
        return final
    }

    // MARK: - 状态探测

    public func refreshStatus() async {
        guard isLoaded else { return }
        let js = InjectionScripts.build(InjectionScripts.probeJS, cfg: adapter.probeConfig())
        guard let result = try? await eval(js), let dict = result as? [String: Any] else {
            status = .unreachable("状态探测失败")
            return
        }
        let hasInput = dict["input"] as? Bool ?? false
        let challenge = dict["challenge"] as? Bool ?? false
        let loggedOut = dict["loggedOut"] as? Bool ?? false
        let loginModal = dict["loginModal"] as? Bool ?? false
        currentURL = dict["url"] as? String ?? ""
        if challenge {
            status = .challenge
        } else if loggedOut || loginModal {
            status = .loggedOut
        } else if !hasInput {
            status = .inputMissing
        } else {
            status = .ready
        }
        print("[\(adapter.id)] 状态: \(statusLabel) (input=\(hasInput) challenge=\(challenge) loggedOut=\(loggedOut) loginModal=\(loginModal))")
    }

    /// 当前 URL 是否漂移出归属域名（登录跳转后未回到对话页）
    public var isDrifted: Bool {
        guard !currentURL.isEmpty,
              let host = URL(string: currentURL)?.host?.lowercased() else { return false }
        let homes = (adapter.homeHosts ?? []).map { $0.lowercased() }
        if homes.isEmpty {
            if let originHost = URL(string: adapter.origin)?.host?.lowercased() {
                return host != originHost && !host.hasSuffix("." + originHost)
            }
            return false
        }
        return !homes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    /// 回到平台对话主页
    public func goHome() {
        status = .loading
        webView.load(URLRequest(url: URL(string: adapter.origin)!))
    }

    // MARK: - 原生粘贴附件（可信通道：NSPasteboard + 真实 NSEvent Cmd+V，经应用事件管线被 WebKit 视为可信）

    /// 把文件写入剪贴板（富格式：文件内容 + URL + 图片数据）并对当前窗格发送真实 Cmd+V
    public func pasteFiles(fileURLs: [URL]) async -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardItem] = []
        for url in fileURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            let item = NSPasteboardItem()
            item.setData(data, forType: .fileContents)
            item.setString(url.path, forType: .fileURL)
            // 图片类文件附带位图数据，页面能按图片粘贴处理
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp"].contains(ext) {
                if let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) {
                    if let png = rep.representation(using: .png, properties: [:]) {
                        item.setData(png, forType: .png)
                    }
                }
            }
            items.append(item)
        }
        guard !items.isEmpty, pb.writeObjects(items) else {
            print("[\(adapter.id)] ❌ 剪贴板写入失败")
            return false
        }
        await MainActor.run {
            webView.window?.makeKeyAndOrderFront(nil)
            webView.window?.makeFirstResponder(webView)
        }
        // makeFirstResponder 会把页面内焦点从编辑器移走，重新聚焦编辑器（粘贴目标）
        if let sel = adapter.input.selectors.first {
            let escaped = sel.replacingOccurrences(of: "'", with: "\\'")
            _ = try? await eval("(function(){ var el = document.querySelector('" + escaped + "'); if (el) { el.focus(); return true; } return false; })()")
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await MainActor.run {
            guard let window = webView.window else { return false }
            // 先发合成 Cmd+V 按键（让 WebKit 键盘处理与页面监听器可见）
            let keyDown = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                           timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: "v", charactersIgnoringModifiers: "v",
                                           isARepeat: false, keyCode: 9)
            if let keyDown { NSApp.sendEvent(keyDown) }
            // 再对第一响应者执行标准粘贴动作（AppKit 正统路径，触发 WebKit 的粘贴处理）
            let acted = NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            return acted
        }
    }

    /// 附件发送（可信通道）：注入文本 → 原生粘贴文件 → 等待上传 → 触发发送
    @discardableResult
    public func sendWithPaste(text: String, fileURLs: [URL]) async -> String {
        guard isLoaded else {
            lastLog = "页面未加载完成，跳过"
            return lastLog
        }
        // 1) 注入文本（不发送）
        let js1 = InjectionScripts.build(InjectionScripts.injectJS,
                                         cfg: adapter.injectionConfig(text: text, noSend: true))
        _ = try? await eval(js1)
        try? await Task.sleep(nanoseconds: 500_000_000)
        // 2) 原生粘贴文件（可信事件）
        let pasted = await pasteFiles(fileURLs: fileURLs)
        print("[\(adapter.id)] 粘贴文件: \(pasted ? "已触发" : "失败")")
        // 3) 等平台上传
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        // 4) 触发发送（不动输入框）；inject 是异步约定，轮询 window.__wb_result
        var cfg = adapter.injectionConfig(text: "", noSend: false)
        cfg["skipText"] = true
        let js2 = InjectionScripts.build(InjectionScripts.injectJS, cfg: cfg)
        _ = try? await eval(js2)
        var result: [String: Any] = [:]
        for _ in 0..<50 {
            if let r = try? await eval("window.__wb_result || null"), let d = r as? [String: Any], !d.isEmpty {
                result = d
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if result["ok"] as? Bool == true {
            lastLog = "已注入文本+粘贴附件并发送(\(result["sent"] as? String ?? "?"))"
            print("[\(adapter.id)] ✅ \(lastLog)")
        } else {
            lastLog = "附件发送失败: \(result["error"] as? String ?? "UNKNOWN")"
            print("[\(adapter.id)] ❌ \(lastLog)")
        }
        let final = lastLog
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self.lastLog == final { self.lastLog = "" }
        }
        return final
    }

    // MARK: - 缩放（解决平台界面宽于窗格时的裁切问题）

    public static let minimumZoom = WorkbenchZoom.minimum
    public static let maximumZoom = WorkbenchZoom.maximum

    @Published public private(set) var zoom: Double = 1.0

    public func zoomIn() {
        setZoom(zoom + 0.1)
    }

    public func zoomOut() {
        setZoom(zoom - 0.1)
    }

    public func resetZoom() {
        setZoom(1.0)
    }

    /// 从持久化偏好恢复缩放。非有限值回退 100%，其余值严格钳制在安全范围内。
    public func restoreZoom(_ storedZoom: Double?) {
        setZoom(Self.normalizedZoom(storedZoom))
    }

    public static func normalizedZoom(_ value: Double?) -> Double {
        WorkbenchZoom.normalized(value)
    }

    private func setZoom(_ z: Double) {
        let normalized = Self.normalizedZoom(z)
        zoom = normalized
        webView.pageZoom = normalized
    }

    public func hasInput() async -> Bool {
        let js = InjectionScripts.build(InjectionScripts.probeJS, cfg: adapter.probeConfig())
        guard let result = try? await eval(js), let dict = result as? [String: Any] else { return false }
        return dict["input"] as? Bool ?? false
    }

    public func reload() {
        isLoaded = false
        status = .loading
        webView.reload()
    }

    // MARK: - CLI 测试辅助（无 UI 场景下泵动 RunLoop 让 WebKit 回调送达）

    public func waitForLoad(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isLoaded && Date() < deadline {
            await pumpRunLoop(0.1)
        }
        return isLoaded
    }

    public func waitForInput(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await hasInput() { return true }
            await pumpRunLoop(0.5)
        }
        return false
    }

    public func idle(_ seconds: TimeInterval) async {
        await pumpRunLoop(seconds)
    }

    /// 输入框当前状态：是否存在、是否已清空（清空 = 平台已提交消息）
    public func inputState() async -> [String: Any] {
        let sels = adapter.input.selectors
            .map { "'" + $0.replacingOccurrences(of: "'", with: "\\'") + "'" }
            .joined(separator: ",")
        let js = """
        (function(){
          const sels = [\(sels)];
          for (const s of sels) {
            try {
              const el = document.querySelector(s);
              if (el) {
                const v = (el.value !== undefined ? el.value : (el.textContent || '')).trim();
                return { found: true, cleared: v.length === 0, value: v.slice(0, 60) };
              }
            } catch {}
          }
          return { found: false, cleared: false, value: '' };
        })()
        """
        guard let result = try? await eval(js), let dict = result as? [String: Any] else { return [:] }
        return dict
    }

    /// 页面文本尾部（用于审阅模型回答原文）
    public func pageTextTail(_ length: Int) async -> String {
        guard let r = try? await eval("document.body ? document.body.innerText.slice(-\(length)) : ''") as? String else { return "" }
        return r
    }

    /// 页面文本前部（对话区常在页面中部，尾部取证看不到）
    public func pageTextHead(_ length: Int) async -> String {
        guard let r = try? await eval("document.body ? document.body.innerText.slice(0, \(length)) : ''") as? String else { return "" }
        return r
    }

    /// 命中输入框的细节（tag/class/是否 contenteditable/当前值），用于适配器调试取证
    public func inputDetail() async -> [String: Any] {
        let sels = adapter.input.selectors
            .map { "'" + $0.replacingOccurrences(of: "'", with: "\\'") + "'" }
            .joined(separator: ",")
        let js = """
        (function(){
          const sels = [\(sels)];
          for (const s of sels) {
            try {
              const el = document.querySelector(s);
              if (el) {
                return {
                  tag: el.tagName,
                  id: el.id || null,
                  cls: (typeof el.className === 'string' ? el.className : '').slice(0, 120),
                  ce: el.getAttribute('contenteditable') || null,
                  value: (el.value !== undefined ? String(el.value) : (el.textContent || '')).slice(0, 80),
                  placeholder: el.getAttribute('placeholder') || null
                };
              }
            } catch {}
          }
          return { tag: 'NONE' };
        })()
        """
        guard let result = try? await eval(js), let dict = result as? [String: Any] else { return [:] }
        return dict
    }

    /// 调试用：对已加载页面执行任意 JS 并取回结果（--eval 选项）。
    public func debugEval(_ js: String) async -> Any? {
        try? await eval(js)
    }

    /// 页面适配审计（--ui-audit）：主题注入状态、字体实际命中、推广候选元素、关键功能可见性。
    public func uiAudit() async -> [String: Any] {
        let js = """
        (function(){
          const out = {};
          out.host = location.hostname;
          out.url = location.href;
          out.themeInjected = !!document.getElementById('__wb_theme_style__');
          const fam = (el) => el ? getComputedStyle(el).fontFamily : null;
          out.bodyFont = fam(document.body);
          const inp = document.querySelector('textarea, [contenteditable="true"], input[type="text"]');
          out.inputFont = fam(inp);
          out.placeholderFont = inp ? getComputedStyle(inp, '::placeholder').fontFamily : null;
          let btn = null;
          document.querySelectorAll('button').forEach((b) => { if (!btn && (b.textContent || '').trim()) btn = b; });
          out.buttonFont = fam(btn);
          try {
            out.fontChecks = {
              helveticaLatin: document.fonts.check('14px Helvetica', 'ChatGPT'),
              helveticaDigit: document.fonts.check('14px Helvetica', '100%'),
              simsunCJK: document.fonts.check('14px SimSun', '智囊'),
              songtiCJK: document.fonts.check('14px "Songti SC"', '智囊')
            };
          } catch (e) { out.fontChecks = { error: String(e) }; }
          // 推广候选取证：短文本且命中关键词的元素 + 4 层祖先链
          const pats = ['下载电脑版','Download for Desktop','下载App','下载 App','App 下载','推荐问题','为你推荐','新任务','新工作','电脑版','安装桌面版','desktop app','Desktop App','下载客户端'];
          out.promo = [];
          document.querySelectorAll('a, button, div, span, section, aside, li').forEach((e) => {
            const t = (e.textContent || '').trim();
            if (t.length > 0 && t.length <= 40) {
              for (const p of pats) {
                if (t.includes(p)) {
                  let chain = ''; let n = e;
                  for (let i = 0; i < 4 && n; i++) {
                    chain = n.tagName.toLowerCase() + (typeof n.className === 'string' && n.className ? '.' + n.className.trim().split(/\\s+/).join('.') : '') + (n.id ? '#' + n.id : '') + ' > ' + chain;
                    n = n.parentElement;
                  }
                  const r = e.getBoundingClientRect();
                  out.promo.push({
                    text: t.slice(0, 30), tag: e.tagName,
                    cls: (typeof e.className === 'string' ? e.className : '').slice(0, 100),
                    id: (e.id || '').slice(0, 60),
                    visible: !!(r && r.width > 0 && r.height > 0),
                    chain: chain.slice(0, 320)
                  });
                  break;
                }
              }
            }
            if (out.promo.length >= 20) return;
          });
          // 关键功能可见性（登录入口、对话输入、发送按钮）
          const vis = (el) => { if (!el) return false; const r = el.getBoundingClientRect ? el.getBoundingClientRect() : null; return !!(r && r.width > 0 && r.height > 0); };
          out.critical = {
            input: vis(document.querySelector('textarea, [contenteditable="true"]')),
            login: (() => {
              let hit = false;
              document.querySelectorAll('a, button, [role="button"]').forEach((e) => {
                if (hit) return;
                const t = (e.textContent || '').trim();
                if (t && t.length < 24 && /登录|Log in|Sign in/.test(t) && vis(e)) hit = true;
              });
              return hit;
            })()
          };
          // 下载/推广相关链接
          out.downloadLinks = [];
          document.querySelectorAll('a[href]').forEach((a) => {
            const h = a.getAttribute('href') || '';
            const t = (a.textContent || '').trim();
            if ((/download|app|desktop|client/i.test(h) || /下载|电脑版|桌面版/i.test(t)) && t.length <= 30) {
              if (out.downloadLinks.length < 10) {
                out.downloadLinks.push({ text: t.slice(0, 24), href: h.slice(0, 120),
                  cls: (typeof a.className === 'string' ? a.className : '').slice(0, 80), visible: vis(a) });
              }
            }
          });
          // 页面文本片段（辅助识别推荐区）
          const bodyText = (document.body ? document.body.innerText : '');
          out.textHits = {
            hasNewWork: bodyText.includes('新工作'),
            hasRecommend: bodyText.includes('推荐'),
            hasDownload: bodyText.includes('下载电脑版') || bodyText.includes('Download for Desktop'),
            length: bodyText.length
          };
          out.pageText = bodyText.slice(0, 800);
          return out;
        })()
        """
        guard let result = try? await eval(js), let dict = result as? [String: Any] else { return [:] }
        return dict
    }

    /// 页面内全部输入框候选（textarea/contenteditable），含可见性与父级上下文，用于识别正确的聊天输入框
    public func inputCandidates() async -> [[String: Any]] {
        let js = """
        (function(){
          const out = [];
          document.querySelectorAll('textarea, [contenteditable="true"]').forEach((e) => {
            const r = e.getBoundingClientRect ? e.getBoundingClientRect() : null;
            let ctx = '';
            let p = e.parentElement;
            for (let i = 0; i < 3 && p; i++) {
              ctx = (typeof p.className === 'string' ? p.className.slice(0, 40) : '') + ' / ' + ctx;
              p = p.parentElement;
            }
            out.push({
              tag: e.tagName,
              id: e.id || null,
              cls: (typeof e.className === 'string' ? e.className : '').slice(0, 90),
              ph: (e.getAttribute('placeholder') || e.getAttribute('aria-label') || e.textContent || '').slice(0, 20),
              visible: !!(r && r.width > 0 && r.height > 0),
              rect: r ? [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)] : null,
              context: ctx.slice(0, 140)
            });
          });
          return out;
        })()
        """
        guard let result = try? await eval(js), let arr = result as? [[String: Any]] else { return [] }
        return arr
    }

    /// 页面内疑似发送按钮（class/aria/文本含 send/发送/submit），用于适配器调试取证
    public func buttonCandidates() async -> [[String: Any]] {
        let js = """
        (function(){
          const out = [];
          document.querySelectorAll('button, [role="button"]').forEach((b) => {
            const cls = typeof b.className === 'string' ? b.className : '';
            const aria = b.getAttribute('aria-label') || '';
            const t = (b.textContent || '').trim().slice(0, 20);
            if (/send|发送|submit/i.test(cls + aria + t) && out.length < 10) {
              out.push({ tag: b.tagName, cls: cls.slice(0, 80), aria: aria, text: t });
            }
          });
          return out;
        })()
        """
        guard let result = try? await eval(js), let arr = result as? [[String: Any]] else { return [] }
        return arr
    }

    /// 全部按钮清单（含图标按钮），用于定位没有文字的发送按钮
    public func allButtons() async -> [[String: Any]] {
        let js = """
        (function(){
          const out = [];
          document.querySelectorAll('button').forEach((b) => {
            const cls = typeof b.className === 'string' ? b.className : '';
            const aria = b.getAttribute('aria-label') || '';
            const title = b.getAttribute('title') || '';
            const testid = b.getAttribute('data-testid') || '';
            const t = (b.textContent || '').trim().slice(0, 16);
            if (out.length < 25 && (cls || aria || title || testid || t)) {
              out.push({ cls: cls.slice(0, 90), aria, title, testid, text: t, disabled: !!b.disabled });
            }
          });
          return out;
        })()
        """
        guard let result = try? await eval(js), let arr = result as? [[String: Any]] else { return [] }
        return arr
    }

    /// 附件相关元素：全部 file input（含隐藏）与疑似上传按钮，用于逐平台附件适配
    public func fileInputs() async -> [[String: Any]] {
        let js = """
        (function(){
          const out = [];
          document.querySelectorAll('input[type=file]').forEach((i) => {
            const r = i.getBoundingClientRect ? i.getBoundingClientRect() : null;
            let ctx = '';
            let p = i.parentElement;
            for (let k = 0; k < 3 && p; k++) {
              ctx = (typeof p.className === 'string' ? p.className.slice(0, 40) : '') + ' / ' + ctx;
              p = p.parentElement;
            }
            // 所在工具项的可见文本（识别是哪个上传项）
            const item = i.closest('.toolkit-item');
            const itemText = item ? (item.innerText || '').trim().slice(0, 20) : '';
            out.push({ kind: 'file', visible: !!(r && r.width > 0), cls: (typeof i.className === 'string' ? i.className : '').slice(0, 60), itemText: itemText, context: ctx.slice(0, 160) });
          });
          document.querySelectorAll('button, [role=\"button\"]').forEach((b) => {
            const cls = typeof b.className === 'string' ? b.className : '';
            const aria = b.getAttribute('aria-label') || '';
            const t = (b.textContent || '').trim().slice(0, 12);
            if (/upload|attach|附件|上传|文件|file|image|图片|paperclip|plus|添加/i.test(cls + aria + t)) {
              if (out.length < 16) out.push({ kind: 'button', cls: cls.slice(0, 70), aria, text: t });
            }
          });
          return out;
        })()
        """
        guard let result = try? await eval(js), let arr = result as? [[String: Any]] else { return [] }
        return arr
    }

    /// 页面链接清单（文本 + href），用于找到对话/聊天的正确入口路由
    public func links() async -> [[String: Any]] {
        let js = """
        (function(){
          const out = [];
          document.querySelectorAll('a[href]').forEach((a) => {
            const t = (a.textContent || '').trim().slice(0, 20);
            const h = (a.getAttribute('href') || '').slice(0, 100);
            if (out.length < 40 && t) {
              out.push({ text: t, href: h });
            }
          });
          return out;
        })()
        """
        guard let result = try? await eval(js), let arr = result as? [[String: Any]] else { return [] }
        return arr
    }

    /// 输入元素向上 3 层的外层结构（outerHTML 截断），用于理解编辑器/发送按钮布局
    public func composerHTML() async -> String {
        let sels = adapter.input.selectors
            .map { "'" + $0.replacingOccurrences(of: "'", with: "\\'") + "'" }
            .joined(separator: ",")
        let js = """
        (function(){
          const sels = [\(sels)];
          let el = null;
          for (const s of sels) { try { const e = document.querySelector(s); if (e) { el = e; break; } } catch {} }
          if (!el) return 'NO_INPUT';
          let node = el;
          for (let i = 0; i < 3 && node.parentElement; i++) { node = node.parentElement; }
          return node.outerHTML.slice(0, 4000);
        })()
        """
        guard let r = try? await eval(js) as? String else { return "" }
        return r
    }

    /// 页面内所有疑似登录入口元素（文本含 登录/Log in/Sign in），用于完善未登录探针
    public func loginElements() async -> [[String: Any]] {
        let js = """
        (function(){
          const out = [];
          document.querySelectorAll('a, button, [role="button"], span, div').forEach((e) => {
            const t = (e.textContent || '').trim();
            if (t.length > 0 && t.length < 24 && /登录|登 录|Log in|Log In|Sign in|Sign In|立即登录|请登录/.test(t)) {
              if (out.length < 12) {
                out.push({
                  tag: e.tagName,
                  cls: (typeof e.className === 'string' ? e.className : '').slice(0, 100),
                  href: e.getAttribute('href') || null,
                  text: t
                });
              }
            }
          });
          return out;
        })()
        """
        guard let result = try? await eval(js), let arr = result as? [[String: Any]] else { return [] }
        return arr
    }

    /// 点击指定选择器（支持 xpath: 前缀），返回是否命中并点击
    public func clickSelector(_ sel: String) async -> Bool {
        let escaped = sel
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
          const s = '\(escaped)';
          let el = null;
          if (s.startsWith('xpath:')) {
            try {
              el = document.evaluate(s.slice(6), document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
            } catch {}
          } else {
            try { el = document.querySelector(s); } catch {}
          }
          if (el) { el.click(); return true; }
          return false;
        })()
        """
        guard let r = try? await eval(js) as? NSNumber else { return false }
        return r.boolValue
    }

    /// 问题文本是否出现在输入框之外的区域（= 真实的消息气泡）
    public func messageBubbleContains(_ text: String) async -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
          const q = '\(escaped)';
          const composer = document.querySelector('[contenteditable="true"], textarea');
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          let n;
          while ((n = walker.nextNode())) {
            if (n.textContent.includes(q)) {
              if (composer && composer.contains(n)) continue;
              return true;
            }
          }
          return false;
        })()
        """
        guard let r = try? await eval(js) as? NSNumber else { return false }
        return r.boolValue
    }

    public func textLength() async -> Int {
        guard let r = try? await eval("document.body ? document.body.innerText.length : -1") as? NSNumber else { return -1 }
        return r.intValue
    }

    public func containsText(_ text: String) async -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        guard let r = try? await eval("document.body ? document.body.innerText.includes('\(escaped)') : false") as? NSNumber else { return false }
        return r.boolValue
    }

    public func screenshot(to path: String) async -> Bool {
        await withCheckedContinuation { cont in
            webView.takeSnapshot(with: nil) { image, error in
                guard let image = image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    print("    截图失败: \(error?.localizedDescription ?? "图像为空")")
                    cont.resume(returning: false)
                    return
                }
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    cont.resume(returning: true)
                } catch {
                    print("    截图写入失败: \(error)")
                    cont.resume(returning: false)
                }
            }
        }
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        // SPA 渲染是异步的：多级延迟重探，让状态收敛到真实值
        Task { await self.refreshStatus() }
        for delay in [2.0, 6.0, 15.0, 30.0] {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await self.refreshStatus()
            }
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoaded = false
        status = .unreachable(error.localizedDescription)
        print("[\(adapter.id)] ❌ 加载失败: \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[\(adapter.id)] ⚠️ 导航失败: \(error.localizedDescription)")
    }

    // target=_blank 的新窗口统一在当前窗格内打开（登录跳转等场景）
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: - 内部

    private func eval(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(js) { result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: result)
                }
            }
        }
    }

    private func pumpRunLoop(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}
