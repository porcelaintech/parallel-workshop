using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ParallelWorkbench.Models;

public enum PaneStatus
{
    Loading,
    Ready,
    LoggedOut,
    Challenge,
    InputMissing,
    Unreachable
}

/// <summary>
/// 一个模型窗格：WebView2 加载平台官网 + 注入引擎 + 状态探测。
/// 使用应用专属用户数据目录（%LOCALAPPDATA%\ParallelWorkbench\WebView2）持久化登录态。
/// 与 macOS 版 PaneController.swift 行为对齐：同一份 inject.js / probe.js / adapters。
/// </summary>
public sealed class PaneController
{
    private static CoreWebView2Environment? _env;
    private static string? _injectJs;
    private static string? _probeJs;

    public Adapter Adapter { get; }
    public WebView2 WebView { get; } = new();
    public PaneStatus Status { get; private set; } = PaneStatus.Loading;
    public string LastLog { get; private set; } = "";
    public string CurrentUrl { get; private set; } = "";
    public bool IsLoaded { get; private set; }
    public bool? LastResultOK { get; private set; }
    public double Zoom { get; private set; } = 1.0;

    public event Action<PaneController>? StatusChanged;
    public event Action<PaneController>? LogChanged;

    public PaneController(Adapter adapter)
    {
        Adapter = adapter;
    }

    // MARK: - 环境（应用级共享：登录态持久目录）

    public static async Task<CoreWebView2Environment> EnsureEnvironmentAsync()
    {
        if (_env == null)
        {
            // WinUI 3 投影只提供无参 CreateAsync：默认用户数据目录即可
            // （打包形态下 WebView2 自动落到可写的包数据目录），真实路径由环境报告，
            // 记录到 profile-path.txt 供登录态备份/恢复使用。
            // 测试钩子（仅内部真机测试）：标记文件存在时在本进程内设置调试参数，
            // WebView2 运行时读取的是本进程环境变量，不受打包应用激活链影响。
            var cdpPort = CdpTestPort();
            if (cdpPort != null)
            {
                Environment.SetEnvironmentVariable(
                    "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", $"--remote-debugging-port={cdpPort}");
            }
            _env = await CoreWebView2Environment.CreateAsync();
            try
            {
                var udf = _env.UserDataFolder;
                if (!string.IsNullOrEmpty(udf))
                {
                    var root = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ParallelWorkbench");
                    Directory.CreateDirectory(root);
                    File.WriteAllText(Path.Combine(root, "profile-path.txt"), udf);
                }
            }
            catch { }
        }
        return _env;
    }

    /// <summary>
    /// 内部真机测试钩子：%TEMP%\pwb-test-cdp-port.txt 存在时启用 WebView2 调试端口。
    /// 生产环境无此文件，行为与之前完全一致；仅用于 CI 六窗格取证。
    /// </summary>
    private static string? CdpTestPort()
    {
        try
        {
            var marker = Path.Combine(Path.GetTempPath(), "pwb-test-cdp-port.txt");
            if (!File.Exists(marker)) return null;
            var port = File.ReadAllText(marker).Trim();
            return int.TryParse(port, out _) ? port : null;
        }
        catch { return null; }
    }

    /// <summary>创建底层 WebView2 并加载平台官网。必须在 UI 线程调用。</summary>
    public async Task InitAsync()
    {
        var env = await EnsureEnvironmentAsync();
        await WebView.EnsureCoreWebView2Async(env);
        var cv = WebView.CoreWebView2;
        cv.Settings.AreDefaultContextMenusEnabled = true;
        cv.Settings.IsStatusBarEnabled = false;
        // 生产环境关闭 DevTools；仅内部真机测试（调试端口标记文件存在）时开放，供六窗格取证
        cv.Settings.AreDevToolsEnabled = CdpTestPort() != null;
        cv.NavigationCompleted += OnNavigationCompleted;
        cv.NavigationStarting += OnNavigationStarting;
        cv.NewWindowRequested += OnNewWindowRequested;
        cv.PermissionRequested += OnPermissionRequested;
        cv.ProcessFailed += (_, e) =>
        {
            if (!IsLoaded)
            {
                Status = PaneStatus.Unreachable;
                StatusChanged?.Invoke(this);
            }
        };
        // DeepSeek 模型偏好记忆（与 macOS 版一致：文档起点注入，新会话重置后恢复上次模型）
        if (Adapter.Id == "deepseek")
        {
            var modelPref = LoadScript("model-preference");
            if (!string.IsNullOrEmpty(modelPref))
            {
                await cv.AddScriptToExecuteOnDocumentCreatedAsync(modelPref);
            }
        }
        cv.Navigate(Adapter.Origin);
    }

    // MARK: - 注入（对齐 macOS PaneController.send）

    public async Task<(bool ok, string log)> SendAsync(string text, IReadOnlyList<AttachmentPayload> attachments, bool noSend = false)
    {
        if (!IsLoaded)
        {
            SetLog("页面未加载完成，跳过");
            LastResultOK = false;
            return (false, LastLog);
        }

        // 输入框缺失时执行预动作（如通义「新建对话」进入对话视图后再注入）
        if (Adapter.Prepare is { ClickSelector: not null and not "" } prep)
        {
            var hasInput = await WaitForInputAsync(timeoutSeconds: 3);
            if (!hasInput)
            {
                await ClickSelectorAsync(prep.ClickSelector);
                await Task.Delay((int)((prep.WaitSeconds ?? 3) * 1000));
            }
        }

        var reqId = Guid.NewGuid().ToString();
        var cfg = Adapter.InjectionConfig(text, attachments, noSend, reqId);
        var js = BuildScript(InjectJs, cfg);
        await EvalAsync(js);

        // inject.js 异步执行、结果写入 window.__wb_result，这里轮询取回；
        // 只接受与本轮 reqId 匹配的结果，避免快速连续发送串读旧结果
        JsonElement? result = null;
        for (var i = 0; i < 50; i++)
        {
            var r = await EvalAsync("window.__wb_result || null");
            if (r is { ValueKind: JsonValueKind.Object } d
                && d.TryGetProperty("reqId", out var rid)
                && rid.GetString() == reqId)
            {
                result = d;
                break;
            }
            await Task.Delay(100);
        }

        if (result is not { ValueKind: JsonValueKind.Object } dict)
        {
            SetLog("注入超时（脚本未返回结果）");
            LastResultOK = false;
            System.Diagnostics.Debug.WriteLine($"[{Adapter.Id}] ❌ 注入超时（5s 内未取回 window.__wb_result）");
            return (false, LastLog);
        }

        var ok = dict.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.True;
        LastResultOK = ok;
        if (ok)
        {
            var sent = dict.TryGetProperty("sent", out var sEl) ? sEl.GetString() ?? "?" : "?";
            var attInfo = dict.TryGetProperty("attInfo", out var aEl) ? aEl.GetString() ?? "" : "";
            if (attInfo.StartsWith("fileInput:") && attInfo != "fileInput:0") SetLog($"已发送（含附件 {attInfo}）");
            else if (attInfo.StartsWith("drop:") && attInfo != "drop:0") SetLog("已发送（附件走拖放）");
            else if (!string.IsNullOrEmpty(attInfo) && attInfo != "none") SetLog("已发送（附件未能自动注入，请在该窗格手动添加）");
            else SetLog($"已注入并发送({sent})");
            System.Diagnostics.Debug.WriteLine($"[{Adapter.Id}] ✅ 注入成功，发送方式: {sent}");
        }
        else
        {
            var error = dict.TryGetProperty("error", out var eEl) ? eEl.GetString() ?? "UNKNOWN" : "UNKNOWN";
            SetLog($"注入失败: {error}");
            System.Diagnostics.Debug.WriteLine($"[{Adapter.Id}] ❌ 注入失败: {error}");
            if (error == "NO_INPUT")
            {
                Status = PaneStatus.InputMissing;
                StatusChanged?.Invoke(this);
            }
        }
        return (ok, LastLog);
    }

    // MARK: - 状态探测

    public async Task RefreshStatusAsync()
    {
        if (!IsLoaded) return;
        var js = BuildScript(ProbeJs, Adapter.ProbeConfig());
        var result = await EvalAsync(js);
        if (result is not { ValueKind: JsonValueKind.Object } dict)
        {
            Status = PaneStatus.Ready;
            StatusChanged?.Invoke(this);
            return;
        }
        var hasInput = dict.TryGetProperty("input", out var iEl) && iEl.ValueKind == JsonValueKind.True;
        var challenge = dict.TryGetProperty("challenge", out var cEl) && cEl.ValueKind == JsonValueKind.True;
        var loggedOut = dict.TryGetProperty("loggedOut", out var loEl) && loEl.ValueKind == JsonValueKind.True;
        var loginModal = dict.TryGetProperty("loginModal", out var lmEl) && lmEl.ValueKind == JsonValueKind.True;
        if (dict.TryGetProperty("url", out var uEl)) CurrentUrl = uEl.GetString() ?? "";
        Status = challenge ? PaneStatus.Challenge
            : (loggedOut || loginModal) ? PaneStatus.LoggedOut
            : !hasInput ? PaneStatus.InputMissing
            : PaneStatus.Ready;
        StatusChanged?.Invoke(this);
        System.Diagnostics.Debug.WriteLine($"[{Adapter.Id}] 状态: {StatusLabel()} (input={hasInput} challenge={challenge} loggedOut={loggedOut} loginModal={loginModal})");
    }

    public async Task<bool> WaitForInputAsync(double timeoutSeconds)
    {
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            if (await HasInputAsync()) return true;
            await Task.Delay(500);
        }
        return false;
    }

    public async Task<bool> HasInputAsync()
    {
        var js = BuildScript(ProbeJs, Adapter.ProbeConfig());
        var result = await EvalAsync(js);
        return result is { ValueKind: JsonValueKind.Object } d
            && d.TryGetProperty("input", out var el)
            && el.ValueKind == JsonValueKind.True;
    }

    /// <summary>当前 URL 是否漂移出归属域名（登录跳转后未回到对话页）。</summary>
    public bool IsDrifted
    {
        get
        {
            if (string.IsNullOrEmpty(CurrentUrl)) return false;
            string host;
            try { host = new Uri(CurrentUrl).Host.ToLowerInvariant(); }
            catch { return false; }
            var homes = (Adapter.HomeHosts ?? new List<string>()).Select(h => h.ToLowerInvariant()).ToList();
            if (homes.Count == 0)
            {
                string originHost;
                try { originHost = new Uri(Adapter.Origin).Host.ToLowerInvariant(); }
                catch { return false; }
                return host != originHost && !host.EndsWith("." + originHost, StringComparison.Ordinal);
            }
            return !homes.Any(h => host == h || host.EndsWith("." + h, StringComparison.Ordinal));
        }
    }

    public void GoHome()
    {
        Status = PaneStatus.Loading;
        StatusChanged?.Invoke(this);
        WebView.CoreWebView2?.Navigate(Adapter.Origin);
    }

    public void Reload()
    {
        IsLoaded = false;
        Status = PaneStatus.Loading;
        StatusChanged?.Invoke(this);
        WebView.CoreWebView2?.Reload();
    }

    // MARK: - 缩放

    public void ZoomIn() => SetZoom(Math.Min(Zoom + 0.1, 1.3));
    public void ZoomOut() => SetZoom(Math.Max(Zoom - 0.1, 0.6));
    public void ResetZoom() => SetZoom(1.0);

    private async void SetZoom(double z)
    {
        Zoom = z;
        // WinUI 3 的 WebView2 控件不暴露 ZoomFactor/Controller，缩放用 CSS zoom 注入（Chromium 128+ 支持）
        try
        {
            var v = z.ToString(System.Globalization.CultureInfo.InvariantCulture);
            await WebView.CoreWebView2!.ExecuteScriptAsync($"document.body.style.zoom = '{v}'");
        }
        catch { }
    }

    /// <summary>点击指定选择器（支持 xpath: 前缀），返回是否命中并点击。</summary>
    public async Task<bool> ClickSelectorAsync(string sel)
    {
        var escaped = sel.Replace("\\", "\\\\").Replace("'", "\\'");
        var js = $@"(function(){{
  const s = '{escaped}';
  let el = null;
  if (s.startsWith('xpath:')) {{
    try {{ el = document.evaluate(s.slice(6), document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue; }} catch {{}}
  }} else {{
    try {{ el = document.querySelector(s); }} catch {{}}
  }}
  if (el) {{ el.click(); return true; }}
  return false;
}})()";
        var result = await EvalAsync(js);
        return result is { ValueKind: JsonValueKind.True };
    }

    // MARK: - 事件

    private void OnNavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs args)
    {
        IsLoaded = false;
        Status = PaneStatus.Loading;
        StatusChanged?.Invoke(this);
    }

    private async void OnNavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (!args.IsSuccess)
        {
            IsLoaded = false;
            Status = PaneStatus.Unreachable;
            StatusChanged?.Invoke(this);
            System.Diagnostics.Debug.WriteLine($"[{Adapter.Id}] ❌ 加载失败: {args.WebErrorStatus}");
            return;
        }
        IsLoaded = true;
        await RefreshStatusAsync();
        // SPA 渲染是异步的：多级延迟重探，让状态收敛到真实值
        foreach (var delay in new[] { 2.0, 6.0, 15.0, 30.0 })
        {
            await Task.Delay((int)(delay * 1000));
            if (IsLoaded) await RefreshStatusAsync();
        }
    }

    private void OnNewWindowRequested(CoreWebView2 sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        // target=_blank 的新窗口统一在当前窗格内打开（登录跳转等场景）
        args.Handled = true;
        if (!string.IsNullOrEmpty(args.Uri)) sender.Navigate(args.Uri);
    }

    private void OnPermissionRequested(CoreWebView2 sender, CoreWebView2PermissionRequestedEventArgs args)
    {
        args.Handled = true;
        // 页内语音/定位放行（与 macOS WKWebView 提示后的行为对齐），其余默认拒绝
        args.State = args.PermissionKind is CoreWebView2PermissionKind.Microphone or CoreWebView2PermissionKind.Geolocation
            ? CoreWebView2PermissionState.Allow
            : CoreWebView2PermissionState.Deny;
    }

    // MARK: - 内部

    public string StatusLabel() => Status switch
    {
        PaneStatus.Loading => "加载中",
        PaneStatus.Ready => "就绪",
        PaneStatus.LoggedOut => "未登录",
        PaneStatus.Challenge => "需人工验证",
        PaneStatus.InputMissing => "未找到输入框",
        PaneStatus.Unreachable => "网络不可达",
        _ => ""
    };

    private void SetLog(string log)
    {
        LastLog = log;
        LogChanged?.Invoke(this);
    }

    private static string LoadScript(string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Resources", "injection", name + ".js");
        return File.Exists(path) ? File.ReadAllText(path) : "";
    }

    private static string InjectJs => _injectJs ??= LoadScript("inject");
    private static string ProbeJs => _probeJs ??= LoadScript("probe");

    private static string BuildScript(string template, Dictionary<string, object?> cfg)
        => template.Replace("__CFG__", JsonSerializer.Serialize(cfg));

    /// <summary>执行 JS。WebView2 会把结果序列化为 JSON 字符串返回。</summary>
    private async Task<JsonElement?> EvalAsync(string js)
    {
        try
        {
            var raw = await WebView.CoreWebView2.ExecuteScriptAsync(js);
            if (string.IsNullOrEmpty(raw) || raw == "null") return null;
            using var doc = JsonDocument.Parse(raw);
            return doc.RootElement.Clone();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"[{Adapter.Id}] eval 异常: {ex.Message}");
            return null;
        }
    }
}
