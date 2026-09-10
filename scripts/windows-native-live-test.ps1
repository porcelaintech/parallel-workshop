[CmdletBinding()]
param(
    [string]$MsixPath,
    [int]$Port = 9222,
    [int]$TimeoutSeconds = 240
)

# Windows 原生 MSIX 真机 live 测试（在 windows-latest 上运行）：
#   安装测试签名包 → 带 WebView2 调试端口启动 → 断言六个平台窗格全部加载到官方域名 →
#   稳定性观察 → 截图与目标清单存档。
# 语音/附件/登录备份受 CI 无麦克风/无交互限制，属于人工验收清单（见 STORE_LISTING.md）。
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$packageName = 'PorcelainTech.Braintrust'
$evidenceDir = Join-Path (Split-Path -Parent $MsixPath) 'live-evidence'
New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null

function Write-Step([string]$Message) { Write-Host ('[live] {0}' -f $Message) }

# —— 1. 导入并信任测试证书（与构建 job 使用同一份 pfx）——
$pfx = Join-Path (Split-Path -Parent $MsixPath) 'pwb-ci-dev.pfx'
if (-not (Test-Path -LiteralPath $pfx)) { throw "缺少测试签名证书: $pfx" }
$pfxPassword = ConvertTo-SecureString -String 'pwb-ci-dev' -Force -AsPlainText
# 导入到本机信任库（runner 为管理员）：
# CurrentUser 信任库在交互会话会弹「证书信任」确认框导致 CI 挂起；LocalMachine 无对话框。
Write-Step '导入测试证书到本机信任库'
Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\My' -Password $pfxPassword | Out-Null
Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' -Password $pfxPassword | Out-Null
# 自签证书本身即根：必须同时进入「受信任的根证书颁发机构」，否则 MSIX 签名链校验报 0x800B0109
Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\Root' -Password $pfxPassword | Out-Null
Write-Step '测试证书已导入并信任'

# —— 2. 安装 MSIX ——
Write-Step "安装 $MsixPath"
Add-AppxPackage -Path $MsixPath -ForceApplicationShutdown
$pkg = Get-AppxPackage | Where-Object { $_.Name -eq $packageName } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pkg) { throw '安装后未找到应用包' }
Write-Step "已安装: $($pkg.PackageFamilyName) v$($pkg.Version)"

# —— 3. 启动（携带 WebView2 调试端口，供六窗格取证）——
# 应用内的测试钩子读取 %TEMP%\pwb-test-cdp-port.txt 启用调试端口（不依赖环境变量传递，
# 打包应用的激活链不受 explorer/ShellExecute 环境继承影响）。
Set-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'pwb-test-cdp-port.txt') -Value "$Port" -Encoding ASCII
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port"
Start-Process -FilePath "shell:AppsFolder\$($pkg.PackageFamilyName)!App" | Out-Null
Write-Step '已发起启动（应用内调试端口钩子已就绪）'

# —— 4. 轮询进程与调试端口 ——
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$targets = $null
$procAlive = $false
while ((Get-Date) -lt $deadline) {
    $procAlive = [bool](Get-Process -Name 'ParallelWorkbench' -ErrorAction SilentlyContinue)
    if ($procAlive) {
        try {
            $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec 3)
            if ($targets.Count -gt 0) { break }
        } catch { Start-Sleep -Seconds 2 }
    }
    Start-Sleep -Seconds 2
}
if (-not $procAlive) { throw '应用进程未出现（启动失败或立即崩溃）' }
if (-not $targets -or $targets.Count -eq 0) {
    # 失败前存档诊断（进程信息 + 端口监听），便于远端排查
    $diag = @{
        processes = @(Get-Process -Name 'ParallelWorkbench' -ErrorAction SilentlyContinue |
            Select-Object Id, StartTime, Responding, MainWindowTitle)
        portLines = @(netstat -ano | Select-String ":$Port\s")
    }
    $diag | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $evidenceDir 'diagnostics.json') -Encoding UTF8
    throw 'WebView2 调试端口不可达（窗格未创建）；诊断已存档 diagnostics.json'
}
Write-Step "应用已启动，WebView2 目标 $($targets.Count) 个"

# —— 5. 断言六个平台窗格 ——
# 每平台一个可接受主机集合（重定向：tongyi→qianwen、yiyan→wenxin）
$expected = @{
    chatgpt  = @('chatgpt.com')
    deepseek = @('chat.deepseek.com')
    doubao   = @('www.doubao.com')
    kimi     = @('www.kimi.com')
    tongyi   = @('www.tongyi.com', 'tongyi.com', 'www.qianwen.com', 'qianwen.com')
    yiyan    = @('yiyan.baidu.com', 'wenxin.baidu.com')
}
$pages = @($targets | Where-Object { $_.type -eq 'page' })
$hosts = @($pages | ForEach-Object {
    try { ([uri]$_.url).Host } catch { '' }
} | Where-Object { $_ })
$missing = @()
foreach ($pair in $expected.GetEnumerator()) {
    $hit = @($hosts | Where-Object { $pair.Value -contains $_ })
    if ($hit.Count -eq 0) { $missing += $pair.Key }
}
if ($missing.Count -gt 0) {
    throw "缺少平台窗格: $($missing -join ', ')。当前目标: $($hosts -join ', ')"
}
Write-Step "六窗格全部加载: $($hosts -join ', ')"

# —— 6. 稳定性观察（15 秒无崩溃）——
Start-Sleep -Seconds 15
if (-not (Get-Process -Name 'ParallelWorkbench' -ErrorAction SilentlyContinue)) {
    throw '应用在观察期内退出'
}
Write-Step '15 秒稳定性观察通过'

# —— 7. 证据存档（目标清单 + 屏幕截图）——
$targets | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $evidenceDir 'targets.json') -Encoding UTF8
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size) }
    finally { $graphics.Dispose() }
    $bitmap.Save((Join-Path $evidenceDir 'screenshot.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    Write-Step "截图已保存: $evidenceDir\screenshot.png"
} catch {
    Write-Warning "截图失败（不阻断测试）: $($_.Exception.Message)"
}

Write-Host 'PASS: Windows 原生 MSIX 真机 live 测试（安装/启动/六窗格/稳定性）'
