using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.System;

namespace Braintrust.NativePreview;

public sealed class PlatformPane : Grid, IDisposable
{
    private readonly PlatformDefinition _platform;
    private readonly CoreWebView2Environment _environment;
    private readonly bool _isPopup;
    private readonly WebView2 _web = new();
    private readonly TextBlock _origin = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button _external = new() { Content = "在浏览器查看已拦截链接", Visibility = Visibility.Collapsed };
    private readonly List<Window> _popups = [];
    private Task<CoreWebView2>? _initialization;
    private Uri? _blockedLink;
    private bool _disposed;
    private bool _requiresRestart;
    public event Action? CloseRequested;

    public PlatformPane(PlatformDefinition platform, CoreWebView2Environment environment, bool isPopup = false)
    {
        _platform = platform;
        _environment = environment;
        _isPopup = isPopup;
        RowSpacing = 6;
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        var header = new StackPanel { Spacing = 5 };
        header.Children.Add(new TextBlock { Text = isPopup ? $"{platform.Name} · 站点弹窗" : platform.Name, FontSize = 18 });
        _origin.Text = PlatformPolicy.DisplayOrigin(platform.Origin);
        header.Children.Add(_origin);
        _status.Text = "正在初始化；登录与附件权限未检测";
        header.Children.Add(_status);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var home = new Button { Content = "首页" };
        home.Click += (_, _) => NavigateHome();
        var reload = new Button { Content = "重新加载" };
        reload.Click += (_, _) => {
            if (_requiresRestart) { _status.Text = "浏览器进程已退出，请关闭并重新打开验证版以恢复全部会话。"; return; }
            try { _web.CoreWebView2?.Reload(); }
            catch (Exception ex) { ShowError("重新加载失败", ex); }
        };
        actions.Children.Add(home);
        actions.Children.Add(reload);
        header.Children.Add(actions);
        _external.Click += OpenBlockedLink;
        header.Children.Add(_external);
        Children.Add(header);
        Grid.SetRow(_web, 1);
        Children.Add(_web);
        Loaded += OnLoaded;
        _environment.BrowserProcessExited += OnBrowserExited;
    }

    private async void OnLoaded(object sender, RoutedEventArgs args)
    {
        Loaded -= OnLoaded;
        try { await EnsureReadyAsync(); if (!_isPopup && !_disposed) NavigateHome(); }
        catch (Exception ex) { if (!_disposed) ShowError("浏览器初始化失败，请重开验证版", ex); }
    }

    public Task<CoreWebView2> EnsureReadyAsync() => _initialization ??= InitializeCoreAsync();

    private async Task<CoreWebView2> InitializeCoreAsync()
    {
        var options = _environment.CreateCoreWebView2ControllerOptions();
        options.ProfileName = _platform.ProfileName;
        options.IsInPrivateModeEnabled = false;
        await _web.EnsureCoreWebView2Async(_environment, options);
        if (_disposed) { _web.Close(); throw new ObjectDisposedException(nameof(PlatformPane)); }
        var core = _web.CoreWebView2;
        // The website never receives a native bridge or app-selected file paths.
        core.Settings.AreHostObjectsAllowed = false;
        core.Settings.IsWebMessageEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.NavigationStarting += (_, args) => {
            if (args.Uri == "about:blank") return;
            if (!PlatformPolicy.IsAllowed(_platform, args.Uri)) { args.Cancel = true; Block(args.Uri); }
            else { _status.Text = "正在加载；登录与附件权限未检测"; ClearBlockedLink(); }
        };
        core.SourceChanged += (_, _) => _origin.Text = PlatformPolicy.DisplayOrigin(core.Source);
        core.NavigationCompleted += (_, args) => {
            if (!args.IsSuccess)
            {
                if (args.WebErrorStatus != CoreWebView2WebErrorStatus.OperationCanceled)
                    _status.Text = $"加载失败：{args.WebErrorStatus}。可重试或检查网络。";
                return;
            }
            _status.Text = "页面已加载；登录与附件权限请以站点显示为准";
        };
        core.NewWindowRequested += OnNewWindowRequested;
        // Also cover custom protocol launches originating in site subframes.
        core.LaunchingExternalUriScheme += (_, args) => {
            args.Cancel = true;
            ClearBlockedLink();
            _status.Text = "已阻止网页唤起外部应用。此验证版只允许显式确认后的 HTTPS 浏览器链接。";
        };
        core.WindowCloseRequested += (_, _) => { if (_isPopup) CloseRequested?.Invoke(); };
        core.PermissionRequested += (_, args) => {
            if (!args.IsUserInitiated || !PlatformPolicy.IsAllowed(_platform, args.Uri))
                args.State = CoreWebView2PermissionState.Deny;
            // Trusted, user-initiated requests keep the runtime's permission prompt; never auto-grant.
        };
        core.ProcessFailed += (_, args) => {
            if (args.ProcessFailedKind == CoreWebView2ProcessFailedKind.BrowserProcessExited)
            {
                _requiresRestart = true;
                _status.Text = "浏览器进程退出。请关闭并重开验证版；持久会话目录保留。";
            }
            else _status.Text = $"页面进程异常：{args.ProcessFailedKind}。可点击重新加载；未自动重发任何内容。";
        };
        return core;
    }

    private void NavigateHome()
    {
        if (_requiresRestart) { _status.Text = "请关闭并重开验证版以恢复浏览器。"; return; }
        try { _web.CoreWebView2?.Navigate(_platform.Origin); }
        catch (Exception ex) { ShowError("打开首页失败", ex); }
    }

    private async void OnNewWindowRequested(CoreWebView2 sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        // Popups share only their originating platform's profile and preserve the opener relationship.
        if (_disposed || _isPopup || _popups.Count >= 2 || !args.IsUserInitiated ||
            !PlatformPolicy.IsAllowed(_platform, sender.Source) ||
            (args.Uri != "about:blank" && !PlatformPolicy.IsAllowed(_platform, args.Uri)))
        {
            Block(args.Uri);
            return;
        }
        var deferral = args.GetDeferral();
        Window? popup = null;
        try
        {
            popup = new Window { Title = $"{_platform.Name} · 站点弹窗（原生验证版）" };
            var pane = new PlatformPane(_platform, _environment, isPopup: true);
            popup.Content = pane;
            popup.AppWindow.Resize(new Windows.Graphics.SizeInt32(620, 780));
            var capturedWindow = popup;
            pane.CloseRequested += capturedWindow.Close;
            popup.Closed += (_, _) => { pane.Dispose(); _popups.Remove(capturedWindow); };
            _popups.Add(popup);
            popup.Activate();
            var core = await pane.EnsureReadyAsync();
            if (_disposed) { popup.Close(); return; }
            args.NewWindow = core;
        }
        catch (Exception ex) { popup?.Close(); if (!_disposed) ShowError("站点弹窗失败", ex); }
        finally { deferral.Complete(); }
    }

    private void OnBrowserExited(CoreWebView2Environment sender, CoreWebView2BrowserProcessExitedEventArgs args)
    {
        if (_disposed) return;
        DispatcherQueue.TryEnqueue(() => {
            if (_disposed) return;
            _requiresRestart = true;
            _status.Text = "浏览器进程已退出。请关闭并重新打开验证版以恢复。";
        });
    }

    private void Block(string? target)
    {
        ClearBlockedLink();
        _status.Text = $"已拦截未批准的跳转或弹窗：{PlatformPolicy.DisplayOrigin(target)}。";
        if (PlatformPolicy.TryHttps(target, out var uri)) { _blockedLink = uri; _external.Visibility = Visibility.Visible; }
    }

    private async void OpenBlockedLink(object sender, RoutedEventArgs args)
    {
        var target = _blockedLink;
        if (target is null) return;
        try
        {
            var dialog = new ContentDialog {
                XamlRoot = XamlRoot, Title = "在系统浏览器打开？",
                Content = $"目标：{PlatformPolicy.DisplayOrigin(target.AbsoluteUri)}\n浏览器会话独立；此操作不会把浏览器登录同步回验证版。",
                PrimaryButtonText = "打开", CloseButtonText = "取消"
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                await Launcher.LaunchUriAsync(target);
        }
        catch (Exception ex) { if (!_disposed) ShowError("无法打开外部链接", ex); }
    }

    private void ClearBlockedLink() { _blockedLink = null; _external.Visibility = Visibility.Collapsed; }
    private void ShowError(string action, Exception ex) => _status.Text = $"{action}（0x{ex.HResult:X8}）。";

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Loaded -= OnLoaded;
        _environment.BrowserProcessExited -= OnBrowserExited;
        foreach (var popup in _popups.ToArray()) popup.Close();
        _popups.Clear();
        _web.Close();
    }
}
