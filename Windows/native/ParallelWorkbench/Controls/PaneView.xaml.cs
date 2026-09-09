using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using ParallelWorkbench.Models;
using System;
using System.Threading.Tasks;

namespace ParallelWorkbench.Controls;

/// <summary>
/// 单个模型窗格视图：标题栏（平台名+状态+操作）+ WebView2 + 发送反馈提示。
/// 对齐 macOS 版 PaneView.swift。
/// </summary>
public sealed partial class PaneView : UserControl
{
    public PaneController Controller { get; }
    private readonly DispatcherTimer _toastTimer = new();

    public PaneView(PaneController controller)
    {
        InitializeComponent();
        Controller = controller;
        NameText.Text = controller.Adapter.Name;
        WebHost.Children.Add(controller.WebView);

        controller.StatusChanged += OnStatusChanged;
        controller.LogChanged += OnLogChanged;

        _toastTimer.Interval = TimeSpan.FromSeconds(5);
        _toastTimer.Tick += (_, _) =>
        {
            _toastTimer.Stop();
            ToastBorder.Visibility = Visibility.Collapsed;
        };

        ApplyStatus();
    }

    /// <summary>创建底层 WebView2 并加载平台官网（MainWindow 在加入视觉树后调用）。</summary>
    public Task InitAsync() => Controller.InitAsync();

    private void OnStatusChanged(PaneController _)
    {
        if (DispatcherQueue.HasThreadAccess) ApplyStatus();
        else DispatcherQueue.TryEnqueue(ApplyStatus);
    }

    private void ApplyStatus()
    {
        StatusText.Text = Controller.StatusLabel();
        StatusBadge.Background = new SolidColorBrush(BadgeColor(Controller.Status));
        GoHomeButton.Visibility = Controller.IsDrifted ? Visibility.Visible : Visibility.Collapsed;
        LoggedOutHint.Visibility = Controller.Status == PaneStatus.LoggedOut ? Visibility.Visible : Visibility.Collapsed;
        ReloadButton.Visibility = Controller.Status != PaneStatus.Ready ? Visibility.Visible : Visibility.Collapsed;
        FocusButton.Content = _focused ? "\u2198" : "\u2197";
        UpdateZoomText();
    }

    private bool _focused;
    public void SetFocused(bool focused)
    {
        _focused = focused;
        FocusButton.Content = focused ? "\u2198" : "\u2197";
        ToolTipService.SetToolTip(FocusButton, focused ? "退出放大" : "放大此窗口（登录/阅读）");
    }

    private void OnLogChanged(PaneController _)
    {
        if (DispatcherQueue.HasThreadAccess) ShowLog();
        else DispatcherQueue.TryEnqueue(ShowLog);
    }

    private void ShowLog()
    {
        if (string.IsNullOrEmpty(Controller.LastLog))
        {
            ToastBorder.Visibility = Visibility.Collapsed;
            return;
        }
        ToastText.Text = Controller.LastLog;
        ToastBorder.Visibility = Visibility.Visible;
        _toastTimer.Stop();
        _toastTimer.Start();
    }

    private void UpdateZoomText()
    {
        ZoomText.Content = $"{(int)Math.Round(Controller.Zoom * 100)}%";
    }

    private static Windows.UI.Color BadgeColor(PaneStatus status) => status switch
    {
        PaneStatus.Loading => Windows.UI.Color.FromArgb(255, 128, 128, 128),
        PaneStatus.Ready => Windows.UI.Color.FromArgb(255, 46, 160, 67),
        PaneStatus.LoggedOut => Windows.UI.Color.FromArgb(255, 214, 132, 24),
        PaneStatus.Challenge => Windows.UI.Color.FromArgb(255, 209, 52, 56),
        PaneStatus.InputMissing => Windows.UI.Color.FromArgb(255, 128, 88, 200),
        PaneStatus.Unreachable => Windows.UI.Color.FromArgb(255, 209, 52, 56),
        _ => Windows.UI.Color.FromArgb(255, 128, 128, 128)
    };

    private void ZoomIn_Click(object sender, RoutedEventArgs e)
    {
        Controller.ZoomIn();
        UpdateZoomText();
    }

    private void ZoomOut_Click(object sender, RoutedEventArgs e)
    {
        Controller.ZoomOut();
        UpdateZoomText();
    }

    private void ZoomReset_Click(object sender, RoutedEventArgs e)
    {
        Controller.ResetZoom();
        UpdateZoomText();
    }

    private void Focus_Click(object sender, RoutedEventArgs e) => FocusRequested?.Invoke(this);
    private void Reload_Click(object sender, RoutedEventArgs e) => Controller.Reload();
    private void GoHome_Click(object sender, RoutedEventArgs e) => Controller.GoHome();

    /// <summary>放大/退出放大请求（MainWindow 处理）。</summary>
    public event Action<PaneView>? FocusRequested;
}
