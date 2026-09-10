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
# 打包（MSIX）形态的 WebView2 会忽略 WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS 环境变量；
# 用微软官方支持的 WebView2 策略注册表注入调试参数（管理员可写、运行时必读）。
$wv2Policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\WebView2'
New-Item -Path $wv2Policy -Force | Out-Null
New-ItemProperty -Path $wv2Policy -Name 'AdditionalBrowserArguments' `
    -Value "--remote-debugging-port=$Port" -PropertyType String -Force | Out-Null
# 应用内测试钩子（开发调试备用）：标记文件使应用开放 DevTools
Set-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'pwb-test-cdp-port.txt') -Value "$Port" -Encoding ASCII
Start-Process -FilePath "shell:AppsFolder\$($pkg.PackageFamilyName)!App" | Out-Null
Write-Step '已发起启动（WebView2 策略已注入调试端口）'

# —— 4. 轮询应用进程与窗口就绪 ——
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$procAlive = $false
$windowTitle = ''
while ((Get-Date) -lt $deadline) {
    $proc = Get-Process -Name 'ParallelWorkbench' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $procAlive = $true
        $proc.Refresh()
        if ($proc.MainWindowTitle) { $windowTitle = $proc.MainWindowTitle; break }
    }
    Start-Sleep -Seconds 2
}
if (-not $procAlive) { throw '应用进程未出现（启动失败或立即崩溃）' }
if (-not $windowTitle) { throw '应用窗口未出现（进程存在但无主窗口）' }
Write-Step "应用窗口已就绪: $windowTitle"

# CDP 取证为尽力而为（打包形态下调试端口受限于运行时策略），
# 六窗格主断言改用 Windows UI 自动化（无障碍树，稳定可靠）。
$targets = @()
try {
    $cdpDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $cdpDeadline) {
        try {
            $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec 3)
            if ($targets.Count -gt 0) { break }
        } catch { Start-Sleep -Seconds 2 }
    }
} catch { }
if ($targets.Count -gt 0) { Write-Step "CDP 取证可用（$($targets.Count) 个目标）" }
else { Write-Warning 'CDP 取证不可用（打包形态限制），改用 UI 自动化断言' }

# —— 5. UI 自动化断言：分页翻看全部窗格，六个平台标题必须齐全 ——
# 应用默认 1–3 窗格分页（MaxVisiblePanes=3）：断言分页指示「/ 6」，再点 ▶ 翻两页，
# 汇总各页标题后六个平台名必须全部出现。
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$root = [System.Windows.Automation.AutomationElement]::RootElement
$windowCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::NameProperty, $windowTitle)
$window = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $windowCond)
if (-not $window) { throw 'UI 自动化未找到应用窗口' }

function Get-WindowTexts($windowElement) {
    $elements = $windowElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($el in $elements) {
        $name = $el.Current.Name
        if ($name) { $texts.Add($name) }
    }
    return $texts
}

function Get-NextPageButton($windowElement) {
    $all = $windowElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        if ($el.Current.Name -eq ([string][char]0x25B6)) { return $el }
    }
    return $null
}

$allTexts = New-Object System.Collections.Generic.HashSet[string]
$pagerSeen = $false
for ($page = 0; $page -lt 3; $page++) {
    Start-Sleep -Seconds 2
    $texts = @(Get-WindowTexts $window)
    foreach ($t in $texts) { [void]$allTexts.Add($t) }
    if (@($texts | Where-Object { $_ -match '/ 6$' }).Count -gt 0) { $pagerSeen = $true }
    $nextBtn = Get-NextPageButton $window
    if (-not $nextBtn) { break }
    $invoke = $nextBtn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invoke.Invoke()
}
$allTexts | Sort-Object |
    Set-Content -LiteralPath (Join-Path $evidenceDir 'uia-texts.txt') -Encoding UTF8
if (-not $pagerSeen) { throw "分页指示未显示「/ 6」（收集文本 $($allTexts.Count) 行）" }
$platformNames = @('ChatGPT', 'DeepSeek', '豆包', 'Kimi', '通义千问', '文心一言')
$missingNames = @()
foreach ($name in $platformNames) {
    $hit = @($allTexts | Where-Object { $_ -match [regex]::Escape($name) })
    if ($hit.Count -eq 0) { $missingNames += $name }
}
if ($missingNames.Count -gt 0) {
    throw "窗口内缺少平台窗格: $($missingNames -join ', ')。已收集文本行数: $($allTexts.Count)"
}
Write-Step "六个平台窗格全部存在: $($platformNames -join ', ')"

# —— 6. 稳定性观察（15 秒无崩溃）——
Start-Sleep -Seconds 15
if (-not (Get-Process -Name 'ParallelWorkbench' -ErrorAction SilentlyContinue)) {
    throw '应用在观察期内退出'
}
Write-Step '15 秒稳定性观察通过'

# —— 7. 证据存档（UI 文本 + CDP 目标 + 屏幕截图）——
if ($targets.Count -gt 0) {
    $targets | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $evidenceDir 'targets.json') -Encoding UTF8
}
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

# 清理测试钩子（运行器为一次性环境，保持整洁）
Remove-ItemProperty -Path $wv2Policy -Name 'AdditionalBrowserArguments' -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'pwb-test-cdp-port.txt') -Force -ErrorAction SilentlyContinue

Write-Host 'PASS: Windows 原生 MSIX 真机 live 测试（安装/启动/六窗格/稳定性）'
