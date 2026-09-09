using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using ParallelWorkbench.Controls;
using ParallelWorkbench.Models;
using ParallelWorkbench.Services;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace ParallelWorkbench;

/// <summary>
/// 主窗口：顶部统一输入框 + 平台勾选 + 分页，下方平行排布 WebView2 窗格。
/// 对齐 macOS 版 ContentView.swift 的交互（最多 3 窗格、⌘↩/Ctrl+Enter 发送、附件 chips）。
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly WorkbenchModel _model = new();
    private readonly VoiceInput _voice = new();
    private readonly List<PaneView> _paneViews = new();
    private readonly List<CheckBox> _platformChecks = new();
    private readonly List<UIElement> _attachChips = new();
    private string _voiceBaseline = "";
    private bool _sending;

    public MainWindow()
    {
        InitializeComponent();
        Title = "智囊 · Braintrust";
        try { AppWindow.Resize(new Windows.Graphics.SizeInt32(1440, 860)); } catch { }

        _model.Load();
        _model.StateChanged += OnModelStateChanged;

        BuildPanes();
        RebuildControlRow();
        RebuildAttachBar();
        RefreshPaneVisibility();
    }

    // MARK: - 窗格

    private void BuildPanes()
    {
        foreach (var pane in _model.Panes)
        {
            var view = new PaneView(pane);
            view.FocusRequested += OnPaneFocusRequested;
            _paneViews.Add(view);
            PaneHost.Children.Add(view);
            _ = view.InitAsync();
        }
    }

    private void OnPaneFocusRequested(PaneView view)
    {
        _model.ToggleFocus(view.Controller.Adapter.Id);
        // 放大状态同步到每个窗格标题栏
        foreach (var pv in _paneViews) pv.SetFocused(_model.FocusedId == pv.Controller.Adapter.Id);
        RefreshPaneVisibility();
    }

    private void RefreshPaneVisibility()
    {
        var visible = _model.VisiblePanes.ToHashSet();
        var count = Math.Max(visible.Count, 1);
        var hostWidth = PaneScroller.ViewportWidth > 0 ? PaneScroller.ViewportWidth : 1200;
        var width = Math.Max(hostWidth / count, 420.0);
        foreach (var view in _paneViews)
        {
            var show = visible.Contains(view.Controller);
            view.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            if (show) view.Width = width;
        }
    }

    private void PaneScroller_SizeChanged(object sender, SizeChangedEventArgs e) => RefreshPaneVisibility();

    // MARK: - 顶部控制行（平台勾选 + 分页 + 状态）

    private void RebuildControlRow()
    {
        // 平台勾选框只建一次；后续仅同步 IsChecked
        if (_platformChecks.Count == 0)
        {
            foreach (var pane in _model.Panes)
            {
                var cb = new CheckBox { Content = pane.Adapter.Name, MinWidth = 0, IsChecked = true };
                var id = pane.Adapter.Id;
                cb.Checked += (_, _) => _model.SetEnabled(id, true);
                cb.Unchecked += (_, _) => _model.SetEnabled(id, false);
                _platformChecks.Add(cb);
                ControlRow.Children.Add(cb);
            }
        }
        else
        {
            foreach (var (cb, pane) in _platformChecks.Zip(_model.Panes))
            {
                if (cb.IsChecked != _model.IsEnabled(pane.Adapter.Id)) cb.IsChecked = _model.IsEnabled(pane.Adapter.Id);
            }
        }

        // 清掉动态部分（分页/退出放大/状态文案），重建
        while (ControlRow.Children.Count > _platformChecks.Count)
            ControlRow.Children.RemoveAt(ControlRow.Children.Count - 1);

        if (_model.NeedsPaging)
        {
            var prev = new Button { Content = "\u25C0", FontSize = 11, IsEnabled = _model.WindowStart > 0 };
            prev.Click += (_, _) => _model.PageBackward();
            ControlRow.Children.Add(prev);
            ControlRow.Children.Add(new TextBlock
            {
                Text = _model.PageIndicator,
                FontSize = 11,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
            });
            var next = new Button { Content = "\u25B6", FontSize = 11, IsEnabled = _model.WindowStart < _model.EnabledPanes.Count() - WorkbenchModel.MaxVisiblePanes };
            next.Click += (_, _) => _model.PageForward();
            ControlRow.Children.Add(next);
        }

        if (_model.FocusedId != null)
        {
            var exit = new Button { Content = "退出放大", FontSize = 11 };
            exit.Click += (_, _) =>
            {
                _model.ToggleFocus(_model.FocusedId);
                foreach (var pv in _paneViews) pv.SetFocused(false);
                RefreshPaneVisibility();
            };
            ControlRow.Children.Add(exit);
        }

        if (!string.IsNullOrEmpty(_model.LoginProgress))
            ControlRow.Children.Add(new TextBlock
            {
                Text = _model.LoginProgress, FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
                Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(255, 230, 126, 34))
            });

        if (!string.IsNullOrEmpty(_model.StatusText))
            ControlRow.Children.Add(new TextBlock
            {
                Text = _model.StatusText, FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
            });
    }

    private void OnModelStateChanged()
    {
        if (!DispatcherQueue.HasThreadAccess) { DispatcherQueue.TryEnqueue(OnModelStateChanged); return; }
        RebuildControlRow();
        RefreshPaneVisibility();
    }

    // MARK: - 发送

    private async Task SendAsync()
    {
        if (_sending) return;
        var text = QuestionBox.Text.Trim();
        if (string.IsNullOrEmpty(text) && _model.Attachments.Count == 0) return;

        _model.Question = text;
        var payloads = _model.Attachments
            .Select(a => new AttachmentPayload(a.Name, a.Mime, a.Data))
            .ToList();

        _sending = true;
        SendButton.IsEnabled = false;
        try { await _model.SendAllAsync(text, payloads); }
        finally
        {
            _sending = false;
            SendButton.IsEnabled = true;
        }
        QuestionBox.Text = _model.Question;   // 成功后为空；全部失败时模型未清空
        RebuildAttachBar();
    }

    private async void SendButton_Click(object sender, RoutedEventArgs e) => await SendAsync();

    private void QuestionBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        var ctrl = false;
        try
        {
            ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        }
        catch { }
        if (ctrl)
        {
            e.Handled = true;
            _ = SendAsync();
        }
    }

    // MARK: - 附件

    private void RebuildAttachBar()
    {
        foreach (var chip in _attachChips) AttachBar.Children.Remove(chip);
        _attachChips.Clear();
        if (_model.Attachments.Count == 0)
        {
            AttachBar.Visibility = Visibility.Collapsed;
            return;
        }
        AttachBar.Visibility = Visibility.Visible;
        var addButton = new Button { Content = "\uD83D\uDCCE 附件", FontSize = 11 };
        addButton.Click += AttachButton_Click;
        AttachBar.Children.Add(addButton);
        _attachChips.Add(addButton);

        foreach (var att in _model.Attachments)
        {
            var chip = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 4,
                Padding = new Thickness(8, 3, 8, 3),
                Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["ControlFillColorDefaultBrush"],
                CornerRadius = new CornerRadius(10),
                VerticalAlignment = VerticalAlignment.Center
            };
            chip.Children.Add(new TextBlock { Text = "\uD83D\uDCC4", FontSize = 11 });
            chip.Children.Add(new TextBlock { Text = att.Name, FontSize = 11, MaxWidth = 180, TextTrimming = TextTrimming.CharacterEllipsis });
            chip.Children.Add(new TextBlock
            {
                Text = FormatBytes(att.Size), FontSize = 10, VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
            });
            var remove = new Button
            {
                Content = "\u2715", FontSize = 10, Padding = new Thickness(4, 0, 4, 0),
                Background = null, BorderThickness = new Thickness(0)
            };
            var name = att.Name;
            remove.Click += (_, _) =>
            {
                _model.Attachments.RemoveAll(a => a.Name == name);
                RebuildAttachBar();
            };
            chip.Children.Add(remove);
            AttachBar.Children.Add(chip);
            _attachChips.Add(chip);
        }
    }

    private async void AttachButton_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        picker.FileTypeFilter.Add("*");
        picker.SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary;
        var files = await picker.PickMultipleFilesAsync();
        if (files == null) return;
        foreach (var file in files) AddAttachment(file.Path);
    }

    private void RootGrid_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = DataPackageOperation.Copy;
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
            e.DragUIOverride.Caption = "添加为附件";
    }

    private async void RootGrid_Drop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        foreach (var file in items.OfType<Windows.Storage.StorageFile>())
            AddAttachment(file.Path);
    }

    private void AddAttachment(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length == 0 || info.Length > 25 * 1024 * 1024) return;
            var data = File.ReadAllBytes(path);
            _model.Attachments.Add(new WorkbenchModel.AttachmentItem(
                info.Name, MimeFor(info.Extension), Convert.ToBase64String(data), info.Length));
            RebuildAttachBar();
        }
        catch { }
    }

    private static string MimeFor(string ext) => ext.ToLowerInvariant() switch
    {
        ".png" => "image/png",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".pdf" => "application/pdf",
        ".txt" or ".md" => "text/plain",
        ".doc" or ".docx" => "application/msword",
        ".xls" or ".xlsx" => "application/vnd.ms-excel",
        ".ppt" or ".pptx" => "application/vnd.ms-powerpoint",
        ".zip" => "application/zip",
        _ => "application/octet-stream"
    };

    private static string FormatBytes(long n)
    {
        if (n < 1024) return $"{n}B";
        if (n < 1024 * 1024) return $"{n / 1024.0:F1}KB";
        return $"{n / 1024.0 / 1024.0:F1}MB";
    }

    // MARK: - 语音输入

    private async void MicButton_Click(object sender, RoutedEventArgs e)
    {
        if (_voice.IsRecording)
        {
            await _voice.StopAsync();
            if (!string.IsNullOrWhiteSpace(_voice.Transcript))
            {
                var baseText = _voiceBaseline.Trim();
                QuestionBox.Text = baseText.Length == 0
                    ? _voice.Transcript
                    : baseText + " " + _voice.Transcript;
            }
            VoiceStatusText.Visibility = Visibility.Collapsed;
            MicButton.Content = "\uD83C\uDFA4";
            return;
        }

        _voice.Transcript = "";
        _voiceBaseline = QuestionBox.Text;
        var ok = await _voice.StartAsync();
        if (!ok)
        {
            VoiceStatusText.Text = _voice.Error ?? "语音识别不可用";
            VoiceStatusText.Visibility = Visibility.Visible;
            return;
        }
        MicButton.Content = "\u23F9";
        VoiceStatusText.Text = "录音中，再次点击结束…";
        VoiceStatusText.Visibility = Visibility.Visible;
    }

    // MARK: - 登录态备份/恢复

    private async void BackupAuth_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileSavePicker();
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        picker.SuggestedFileName = $"ParallelWorkbench-auth-{DateTime.Now:yyyyMMdd-HHmm}";
        picker.FileTypeChoices.Add("ZIP 压缩包", new List<string> { ".zip" });
        var file = await picker.PickSaveFileAsync();
        if (file == null) return;
        var ok = await AuthBackup.BackupAsync(file.Path);
        await ShowInfoAsync("备份登录态", ok
            ? $"已备份到：\n{file.Path}"
            : "备份失败，请稍后重试");
    }

    private async void RestoreAuth_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        picker.FileTypeFilter.Add(".zip");
        var file = await picker.PickSingleFileAsync();
        if (file == null) return;

        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = "恢复登录态",
            Content = "恢复会覆盖当前登录态并重启应用，确定继续？",
            PrimaryButtonText = "恢复并重启",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            AuthBackup.ScheduleRestore(file.Path);
    }

    private async void About_Click(object sender, RoutedEventArgs e)
    {
        await ShowInfoAsync("关于 智囊 · Braintrust",
            $"版本：v{AuthBackup.CurrentVersion()}\n\n多模型平行问答工作台：一次提问，ChatGPT / DeepSeek / 豆包 / Kimi / 通义 / 文心并排回答。\n登录态、对话数据全部保存在本机。");
    }

    private async Task ShowInfoAsync(string title, string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = title,
            Content = message,
            CloseButtonText = "确定"
        };
        await dialog.ShowAsync();
    }
}
