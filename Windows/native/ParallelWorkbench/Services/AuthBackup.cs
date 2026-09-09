using Microsoft.Windows.AppLifecycle;
using System;
using System.IO;
using System.IO.Compression;
using System.Threading.Tasks;

namespace ParallelWorkbench.Services;

/// <summary>
/// 登录态备份/恢复：WebView2 用户数据目录（%LOCALAPPDATA%\ParallelWorkbench\WebView2）
/// 的 zip 备份与恢复，防应用存储损坏/系统重装导致全部登录失效（对齐 macOS --backup-auth/--restore-auth）。
/// 恢复需要重启应用：先写待办标记 → AppInstance.Restart → 启动时 ApplyPendingRestore 替换目录。
/// </summary>
public static class AuthBackup
{
    public static string RootDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ParallelWorkbench");

    /// <summary>WebView2 真实用户数据目录：首次启动后由 PaneController 记录到 profile-path.txt，
    /// 未记录时回退到约定路径（幂等，仅影响备份/恢复的目标选择）。</summary>
    public static string ProfileDir
    {
        get
        {
            try
            {
                var marker = Path.Combine(RootDir, "profile-path.txt");
                if (File.Exists(marker))
                {
                    var p = File.ReadAllText(marker).Trim();
                    if (Directory.Exists(p)) return p;
                }
            }
            catch { }
            return Path.Combine(RootDir, "WebView2");
        }
    }

    private static string PendingMarker => Path.Combine(RootDir, "restore-pending.txt");

    /// <summary>把 WebView2 数据目录压缩到 zipPath（运行中锁定的文件跳过）。</summary>
    public static async Task<bool> BackupAsync(string zipPath)
    {
        if (!Directory.Exists(ProfileDir)) return false;
        return await Task.Run(() =>
        {
            try
            {
                if (File.Exists(zipPath)) File.Delete(zipPath);
                using var zip = ZipFile.Open(zipPath, ZipArchiveMode.Create);
                foreach (var file in Directory.EnumerateFiles(ProfileDir, "*", SearchOption.AllDirectories))
                {
                    try
                    {
                        var rel = Path.GetRelativePath(ProfileDir, file).Replace('\\', '/');
                        using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                        var entry = zip.CreateEntry(rel, CompressionLevel.Fastest);
                        using var es = entry.Open();
                        fs.CopyTo(es);
                    }
                    catch (Exception ex)
                    {
                        System.Diagnostics.Debug.WriteLine($"[PWB] 备份跳过锁定文件 {file}: {ex.Message}");
                    }
                }
                return true;
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[PWB] 备份失败: {ex.Message}");
                return false;
            }
        });
    }

    /// <summary>预约恢复：记录 zip 路径并重启应用。</summary>
    public static void ScheduleRestore(string zipPath)
    {
        Directory.CreateDirectory(RootDir);
        File.WriteAllText(PendingMarker, zipPath);
        AppInstance.Restart("");
    }

    /// <summary>启动时执行：若存在恢复待办，先替换 WebView2 数据目录（必须在首个 WebView2 环境创建前调用）。</summary>
    public static void ApplyPendingRestore()
    {
        try
        {
            if (!File.Exists(PendingMarker)) return;
            var zip = File.ReadAllText(PendingMarker).Trim();
            if (!File.Exists(zip))
            {
                File.Delete(PendingMarker);
                return;
            }
            if (Directory.Exists(ProfileDir))
            {
                var old = ProfileDir + ".old-" + Guid.NewGuid().ToString("N")[..8];
                Directory.Move(ProfileDir, old);
                try { Directory.Delete(old, true); } catch { }
            }
            Directory.CreateDirectory(ProfileDir);
            ZipFile.ExtractToDirectory(zip, ProfileDir);
            File.Delete(PendingMarker);
        }
        catch (Exception ex)
        {
            // 恢复失败不阻塞启动；标记保留，下次启动重试
            System.Diagnostics.Debug.WriteLine($"[PWB] 恢复登录态失败: {ex.Message}");
        }
    }

    /// <summary>当前版本（打包形态取 MSIX 包版本，开发形态取程序集版本）。</summary>
    public static string CurrentVersion()
    {
        try
        {
            var v = Windows.ApplicationModel.Package.Current.Id.Version;
            return $"{v.Major}.{v.Minor}.{v.Build}.{v.Revision}";
        }
        catch
        {
            var v = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
            return v?.ToString() ?? "?";
        }
    }
}
