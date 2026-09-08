using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.ApplicationModel;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;

namespace Braintrust.NativePreview;

public sealed class MainWindow : Window
{
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Grid _panes = new() { ColumnSpacing = 8 };
    private readonly List<PlatformPane> _views = [];
    private bool _closed;

    public MainWindow()
    {
        Title = "智囊 · Windows 原生验证版";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1440, 920));
        var root = new Grid { Padding = new Thickness(16), RowSpacing = 10 };
        root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        var header = new StackPanel { Spacing = 6 };
        header.Children.Add(new TextBlock { Text = "智囊 · 原生发行验证", FontSize = 24 });
        header.Children.Add(new TextBlock {
            Text = "在各平台页面中手动登录和操作。当前工程用于验证安装、独立会话、文件选择与升级。",
            TextWrapping = TextWrapping.Wrap });
        header.Children.Add(new TextBlock {
            Text = "登录状态与附件权限尚未自动检测；此处没有统一输入或附件分发。",
            TextWrapping = TextWrapping.Wrap });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var picker = new Button { Content = "验证本地文件选择" };
        picker.Click += PickLocalFile;
        var runtime = new Button { Content = "WebView2 官方下载说明" };
        runtime.Click += async (_, _) => {
            try { await Launcher.LaunchUriAsync(new Uri("https://developer.microsoft.com/microsoft-edge/webview2/")); }
            catch (Exception ex) { _status.Text = $"无法打开浏览器（0x{ex.HResult:X8}）。"; }
        };
        actions.Children.Add(picker);
        actions.Children.Add(runtime);
        header.Children.Add(actions);
        root.Children.Add(header);
        Grid.SetRow(_status, 1);
        root.Children.Add(_status);
        Grid.SetRow(_panes, 2);
        root.Children.Add(_panes);
        Content = root;
        root.Loaded += Initialize;
        Closed += (_, _) => { _closed = true; foreach (var pane in _views) pane.Dispose(); };
    }

    private async void Initialize(object sender, RoutedEventArgs args)
    {
        ((FrameworkElement)sender).Loaded -= Initialize;
        try
        {
            var version = Package.Current.Id.Version;
            var profiles = PlatformPolicy.Load(Path.Combine(AppContext.BaseDirectory, "Config", "platforms.json"));
            var dataFolder = Path.Combine(ApplicationData.Current.LocalFolder.Path, "WebView2");
            Directory.CreateDirectory(dataFolder);
            _status.Text = $"本地开发包 {version.Major}.{version.Minor}.{version.Build}.{version.Revision} · 正在初始化浏览器";
            // WinUI uses the WinRT WebView2 projection, whose custom-environment API is CreateWithOptionsAsync.
            var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, dataFolder, new CoreWebView2EnvironmentOptions());
            if (_closed) return;
            _status.Text = $"本地开发包 {version.Major}.{version.Minor}.{version.Build}.{version.Revision} · WebView2 {environment.BrowserVersionString} · 三个独立持久会话";
            environment.NewBrowserVersionAvailable += (_, _) => DispatcherQueue.TryEnqueue(() => {
                _status.Text = "WebView2 已有新运行时。完成当前操作后，请关闭并重新打开验证版。";
            });
            for (var index = 0; index < profiles.Count; index++)
            {
                _panes.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
                var pane = new PlatformPane(profiles[index], environment);
                _views.Add(pane);
                Grid.SetColumn(pane, index);
                _panes.Children.Add(pane);
            }
        }
        catch (Exception ex)
        {
            if (_closed) return;
            var missingRuntime = ex.HResult == unchecked((int)0x80070002);
            _status.Text = missingRuntime
                ? "未找到 WebView2 Runtime。请通过上方微软官方入口安装 Evergreen Runtime，然后重新打开验证版。"
                : $"启动失败（0x{ex.HResult:X8}）。请确认 MSIX 已安装、WebView2 Runtime 可用，且应用数据目录可写；本次未验证平台登录。";
        }
    }

    private async void PickLocalFile(object sender, RoutedEventArgs args)
    {
        var button = (Button)sender;
        button.IsEnabled = false;
        try
        {
            var picker = new FileOpenPicker();
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            picker.FileTypeFilter.Add("*");
            var file = await picker.PickSingleFileAsync();
            if (!_closed) _status.Text = file is null ? "已取消文件选择。" : $"本地选择成功：{file.Name}。文件未上传，也未交给任何平台。";
        }
        catch (Exception ex) { if (!_closed) _status.Text = $"文件选择失败（0x{ex.HResult:X8}）。"; }
        finally { if (!_closed) button.IsEnabled = true; }
    }
}
