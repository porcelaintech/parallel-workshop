using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace ParallelWorkbench.Models;

/// <summary>
/// 工作台模型：加载适配器、管理窗格（勾选 = 参与显示与发送）、分页、附件与发送。
/// 对齐 macOS 版 WorkbenchModel.swift 的行为（最多显示 3 窗格、全部失败回填等）。
/// </summary>
public sealed class WorkbenchModel
{
    public const int MaxVisiblePanes = 3;

    public List<PaneController> Panes { get; } = new();
    private readonly HashSet<string> _enabled = new();
    public string Question { get; set; } = "";
    public string StatusText { get; private set; } = "";
    public string LoginProgress { get; private set; } = "";
    public string? FocusedId { get; private set; }
    public int WindowStart { get; private set; }

    /// <summary>附件（base64 数据 + 元信息），随问题一并发送给所有勾选平台。</summary>
    public sealed class AttachmentItem
    {
        public string Name { get; }
        public string Mime { get; }
        public string Data { get; }
        public long Size { get; }

        public AttachmentItem(string name, string mime, string data, long size)
        {
            Name = name; Mime = mime; Data = data; Size = size;
        }
    }

    public List<AttachmentItem> Attachments { get; } = new();

    /// <summary>任何 UI 相关状态变化时触发（勾选/分页/放大/状态文案/附件）。</summary>
    public event Action? StateChanged;

    public void RaiseStateChanged() => StateChanged?.Invoke();

    public void Load()
    {
        foreach (var adapter in Adapter.LoadAll())
        {
            Panes.Add(new PaneController(adapter));
            _enabled.Add(adapter.Id);
        }
        System.Diagnostics.Debug.WriteLine($"[PWB] 已加载适配器: {string.Join("、", Panes.Select(p => p.Adapter.Name))}");
        if (Panes.Count == 0) StatusText = "未加载到适配器配置（资源缺失，请查看日志）";
        UpdateLoginProgress();
    }

    public bool IsEnabled(string id) => _enabled.Contains(id);

    public void SetEnabled(string id, bool on)
    {
        if (on) _enabled.Add(id);
        else
        {
            _enabled.Remove(id);
            // 取消勾选后修正分页窗口，避免空窗
            var list = EnabledPanes.ToList();
            WindowStart = Math.Min(WindowStart, Math.Max(list.Count - MaxVisiblePanes, 0));
        }
        RaiseStateChanged();
    }

    public IEnumerable<PaneController> EnabledPanes => Panes.Where(p => _enabled.Contains(p.Adapter.Id));

    /// <summary>可见窗格：放大模式显示单个；否则显示勾选列表的当前分页窗口（最多 3 个）。</summary>
    public IEnumerable<PaneController> VisiblePanes
    {
        get
        {
            if (FocusedId != null)
            {
                var focused = Panes.FirstOrDefault(p => p.Adapter.Id == FocusedId);
                if (focused != null) return new[] { focused };
            }
            var list = EnabledPanes.ToList();
            if (list.Count == 0) return Array.Empty<PaneController>();
            var start = Math.Min(WindowStart, Math.Max(list.Count - MaxVisiblePanes, 0));
            return list.Skip(start).Take(MaxVisiblePanes).ToList();
        }
    }

    public bool NeedsPaging => EnabledPanes.Count() > MaxVisiblePanes;

    public string PageIndicator
    {
        get
        {
            var list = EnabledPanes.ToList();
            if (!NeedsPaging) return "";
            var start = Math.Min(WindowStart, Math.Max(list.Count - MaxVisiblePanes, 0));
            return $"{start + 1}-{Math.Min(start + MaxVisiblePanes, list.Count)} / {list.Count}";
        }
    }

    public void PageBackward()
    {
        WindowStart = Math.Max(0, WindowStart - 1);
        RaiseStateChanged();
    }

    public void PageForward()
    {
        var list = EnabledPanes.ToList();
        WindowStart = Math.Min(Math.Max(list.Count - MaxVisiblePanes, 0), WindowStart + 1);
        RaiseStateChanged();
    }

    public void ToggleFocus(string id)
    {
        FocusedId = FocusedId == id ? null : id;
        RaiseStateChanged();
    }

    public void UpdateLoginProgress()
    {
        var ready = Panes.Count(p => p.Status == PaneStatus.Ready);
        LoginProgress = (Panes.Count == 0 || ready == Panes.Count) ? "" : $"已登录 {ready}/{Panes.Count}";
    }

    /// <summary>发送到全部勾选窗格；状态机：全部失败则回填，有成功才清空（防数据丢失）。</summary>
    public async Task SendAllAsync(string text, IReadOnlyList<AttachmentPayload> payloads)
    {
        var targets = EnabledPanes.ToList();
        if (targets.Count == 0)
        {
            StatusText = "没有勾选的模型窗口";
            RaiseStateChanged();
            return;
        }
        StatusText = $"已向 {targets.Count} 个窗口提交";
        RaiseStateChanged();

        var okCount = 0;
        var failCount = 0;
        foreach (var pane in targets)
        {
            _ = await pane.SendAsync(text, payloads);
            if (pane.LastResultOK == true) okCount++; else failCount++;
        }
        if (okCount > 0)
        {
            Question = "";
            Attachments.Clear();
            StatusText = $"已提交 {okCount}/{targets.Count} 个窗口";
        }
        else
        {
            StatusText = "全部窗口发送失败，问题与附件已回填";
        }
        RaiseStateChanged();
    }
}
