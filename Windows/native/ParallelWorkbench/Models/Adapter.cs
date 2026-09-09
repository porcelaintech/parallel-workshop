using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ParallelWorkbench.Models;

/// <summary>
/// 每个平台的适配器配置（与 macOS/Edge 扩展共享同一份 JSON schema，
/// 源文件由 scripts/sync-windows-native.sh 从 Sources/WorkbenchCore/Resources/adapters 同步）。
/// </summary>
public sealed class Adapter
{
    public sealed class InputSpec
    {
        public List<string> Selectors { get; set; } = new();
    }

    public sealed class SendSpec
    {
        public string Type { get; set; } = "enter";
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public string? Selector { get; set; }
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public List<string>? Selectors { get; set; }
    }

    public sealed class ProbeSpec
    {
        public List<string>? LoggedOut { get; set; }
        public List<string>? Challenge { get; set; }
        public List<string>? LoginModal { get; set; }
    }

    public sealed class PrepareSpec
    {
        public string? ClickSelector { get; set; }
        public double? WaitSeconds { get; set; }
    }

    public sealed class AttachmentSpec
    {
        public List<string>? Selectors { get; set; }
        public List<string>? OpenSelectors { get; set; }
        public bool? ForceDrop { get; set; }
    }

    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Origin { get; set; } = "";
    public InputSpec Input { get; set; } = new();
    public SendSpec Send { get; set; } = new();
    public ProbeSpec? Probe { get; set; }
    public PrepareSpec? Prepare { get; set; }
    public AttachmentSpec? Attachment { get; set; }
    public List<string>? HomeHosts { get; set; }
    public bool? International { get; set; }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    /// <summary>从 Resources/adapters/*.json 加载全部适配器（与 macOS 一致，无 index.json）。</summary>
    public static List<Adapter> LoadAll()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "Resources", "adapters");
        var result = new List<Adapter>();
        if (!Directory.Exists(dir)) return result;
        foreach (var file in Directory.EnumerateFiles(dir, "*.json").OrderBy(f => f, StringComparer.Ordinal))
        {
            try
            {
                var adapter = JsonSerializer.Deserialize<Adapter>(File.ReadAllText(file), JsonOpts);
                if (adapter != null) result.Add(adapter);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[PWB] 适配器解析失败 {Path.GetFileName(file)}: {ex.Message}");
            }
        }
        return result;
    }

    /// <summary>注入脚本用的配置对象（含问题文本与附件），序列化后替换 inject.js 里的 __CFG__。</summary>
    public Dictionary<string, object?> InjectionConfig(string text, IReadOnlyList<AttachmentPayload> attachments, bool noSend, string reqId)
    {
        var cfg = new Dictionary<string, object?>
        {
            ["input"] = new Dictionary<string, object?> { ["selectors"] = Input.Selectors },
            ["send"] = JsonSerializer.SerializeToElement(Send, JsonOpts),
            ["text"] = text,
            ["attachments"] = attachments.Select(a => (object)new Dictionary<string, object?>
            {
                ["name"] = a.Name, ["mime"] = a.Mime, ["data"] = a.Data
            }).ToList(),
            ["reqId"] = reqId
        };
        if (Probe != null) cfg["probe"] = JsonSerializer.SerializeToElement(Probe, JsonOpts);
        if (Attachment != null) cfg["attachment"] = JsonSerializer.SerializeToElement(Attachment, JsonOpts);
        cfg["noSend"] = noSend;
        return cfg;
    }

    /// <summary>状态探测脚本用的配置对象。</summary>
    public Dictionary<string, object?> ProbeConfig() => InjectionConfig("", Array.Empty<AttachmentPayload>(), false, "");
}

/// <summary>附件负载（base64 数据 + 元信息），随问题一并发送给所有勾选平台。</summary>
public sealed record AttachmentPayload(string Name, string Mime, string Data);
