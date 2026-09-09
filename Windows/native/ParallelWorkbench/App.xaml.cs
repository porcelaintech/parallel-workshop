using Microsoft.UI.Xaml;
using System;

namespace ParallelWorkbench;

/// <summary>
/// 应用入口。启动时先处理「恢复登录态」待办（必须在任何 WebView2 创建之前），再打开主窗口。
/// </summary>
public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            System.Diagnostics.Debug.WriteLine("[PWB] 未处理异常: " + e.Exception);
            try { e.Handled = true; } catch { }
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // 恢复登录态：替换 WebView2 数据目录，必须在首个 WebView2 环境创建前完成
        Services.AuthBackup.ApplyPendingRestore();

        _window = new MainWindow();
        _window.Activate();
    }
}
