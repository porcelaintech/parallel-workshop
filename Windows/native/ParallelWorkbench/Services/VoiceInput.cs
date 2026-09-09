using System;
using System.Threading.Tasks;
using Windows.Media.SpeechRecognition;

namespace ParallelWorkbench.Services;

/// <summary>
/// 语音输入：Windows 系统语音识别（Windows.Media.SpeechRecognition），
/// 点击开始 → 实时累积转写 → 再次点击结束（对齐 macOS 版 SFSpeechRecognizer 行为）。
/// 需要麦克风权限（Package.appxmanifest 已声明 microphone 能力）。
/// </summary>
public sealed class VoiceInput : IDisposable
{
    private SpeechRecognizer? _recognizer;

    public bool IsRecording { get; private set; }
    public string Transcript { get; set; } = "";
    public string? Error { get; private set; }

    public async Task<bool> StartAsync()
    {
        if (_recognizer == null)
        {
            try
            {
                try { _recognizer = new SpeechRecognizer(new Windows.Globalization.Language("zh-CN")); }
                catch { _recognizer = new SpeechRecognizer(); }
                _recognizer.ContinuousRecognitionSession.AutoStopSilenceTimeout = TimeSpan.FromSeconds(3);
                _recognizer.ContinuousRecognitionSession.ResultGenerated += (_, e) =>
                {
                    if (!string.IsNullOrEmpty(e.Result?.Text)) Transcript += e.Result.Text;
                };
                _recognizer.ContinuousRecognitionSession.Completed += (_, _) => IsRecording = false;
            }
            catch (Exception ex)
            {
                Error = "语音识别不可用：" + ex.Message;
                return false;
            }
        }
        Error = null;
        try
        {
            await _recognizer.ContinuousRecognitionSession.StartAsync();
            IsRecording = true;
            return true;
        }
        catch (UnauthorizedAccessException)
        {
            Error = "麦克风权限被拒绝（Windows 设置 → 隐私 → 麦克风）";
            return false;
        }
        catch (Exception ex)
        {
            Error = "启动识别失败：" + ex.Message;
            return false;
        }
    }

    public async Task StopAsync()
    {
        if (_recognizer == null || !IsRecording) return;
        try { await _recognizer.ContinuousRecognitionSession.StopAsync(); } catch { }
        IsRecording = false;
    }

    public void Dispose()
    {
        try { _recognizer?.Dispose(); } catch { }
        _recognizer = null;
    }
}
