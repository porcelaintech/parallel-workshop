[CmdletBinding()]
param([switch]$PrintOnly)

# 智囊启动器（v0.4.1 起）：
#   1) 每次启动前自动检查更新（发布索引 update.json → 下载校验 → 版本化目录落地），
#      不依赖开发者模式，不需要任何反复授权；
#   2) 用独立 Edge 配置档 + --load-extension 启动（Edge 全平台保留该命令行能力；
#      仅 Google 品牌 Chrome 移除了它），因此扩展每次必被加载、无启动骚扰条。
# 版本化目录（edge-extension-<version>）保证运行中的旧版文件不被覆盖（Windows 文件锁）。
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$extensionID = 'mklpdfdkbchlahfahofajchfjphlpkek'
$updateRepos = @('porcelaintech/parallel-workshop', 'HanchengQiao/parallel-workshop')
$productRoot = Split-Path -Parent $PSScriptRoot
if (-not $productRoot) { $productRoot = $PSScriptRoot }

function Get-EdgePath {
    $command = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($key in @(
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )) {
        if (Test-Path -LiteralPath $key) {
            $value = (Get-Item -LiteralPath $key).GetValue('')
            if ($value -and (Test-Path -LiteralPath $value)) { return [string]$value }
        }
    }
    foreach ($candidate in @(
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe' }),
        $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe' })
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw '未找到 Microsoft Edge（msedge.exe）'
}

function Get-DerivedExtensionID([string]$ManifestPath) {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest.key) { throw 'manifest.json 缺少 key 公钥' }
    $keyBytes = [Convert]::FromBase64String([string]$manifest.key)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $keyHash = $sha.ComputeHash($keyBytes) } finally { $sha.Dispose() }
    $hexPrefix = -join @($keyHash[0..15] | ForEach-Object { $_.ToString('x2') })
    return -join @($hexPrefix.ToCharArray() | ForEach-Object { [char](([int][char]'a') + [Convert]::ToInt32([string]$_, 16)) })
}

function Assert-InstalledExtension([string]$Path) {
    foreach ($required in @(
        'manifest.json', 'distribution.json', 'background.js', 'content.js', 'workbench.html', 'workbench.js',
        'workbench.css', 'launch.html', 'launch.js', 'launch.css', 'start.html', 'start.js', 'lib\model-preference.js', 'lib\adapters\index.json'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $required))) { throw "安装目录缺少 $required" }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $Path 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw 'manifest.json 版本号格式无效' }
    if ((Get-DerivedExtensionID (Join-Path $Path 'manifest.json')) -ne $extensionID) { throw 'manifest.json 公钥与扩展 ID 不一致' }
    return [string]$manifest.version
}

function Get-CurrentExtensionDir {
    $pointer = Join-Path $productRoot 'current.txt'
    if (Test-Path -LiteralPath $pointer) {
        $current = (Get-Content -LiteralPath $pointer -Raw -Encoding UTF8).Trim()
        if ($current) {
            $dir = Join-Path $productRoot ('edge-extension-' + $current)
            if (Test-Path -LiteralPath (Join-Path $dir 'manifest.json')) { return $dir }
        }
    }
    # 兼容旧版未版本化目录
    $legacy = Join-Path $productRoot 'edge-extension'
    if (Test-Path -LiteralPath (Join-Path $legacy 'manifest.json')) { return $legacy }
    return $null
}

function Write-Log([string]$Message) {
    Write-Host ('[launch] {0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

# —— 启动前自动更新：仅从官方发布索引获取，SHA-256 + 扩展 ID 双重校验 ——
function Update-IfAvailable([string]$CurrentDir) {
    $currentVersion = '0.0.0'
    if ($CurrentDir) {
        try { $currentVersion = Assert-InstalledExtension $CurrentDir } catch { Write-Log "本地版本不可用：$($_.Exception.Message)" }
    }
    $lastError = $null
    foreach ($repo in $updateRepos) {
        try {
            $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Braintrust-Launcher' }
            $index = Invoke-RestMethod -Uri "https://github.com/$repo/releases/latest/download/update.json" -Headers $headers -TimeoutSec 8
            if ($index.schemaVersion -ne 1) { throw '更新索引 schemaVersion 无效' }
            $version = [string]$index.version
            if ($version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw '更新索引版本号无效' }
            $expectedURL = "https://github.com/$repo/releases/download/v$version/edge-extension.zip"
            if ([string]$index.edgeURL -cne $expectedURL) { throw '更新索引安装包地址无效' }
            if ([string]$index.edgeSHA256 -notmatch '^[0-9a-fA-F]{64}$') { throw '更新索引缺少有效 SHA-256' }

            $installed = [version]($currentVersion -replace '^(\d+\.\d+\.\d+).*', '$1')
            $available = [version]$version
            if ($available -le $installed) { return }
            Write-Log "发现新版本 v$version（当前 v$currentVersion），开始更新…"

            $zip = Join-Path ([IO.Path]::GetTempPath()) ('parallel-workbench-update-' + [Guid]::NewGuid().ToString('N') + '.zip')
            $expanded = Join-Path ([IO.Path]::GetTempPath()) ('parallel-workbench-update-' + [Guid]::NewGuid().ToString('N'))
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $expectedURL -Headers @{ 'User-Agent' = 'Braintrust-Launcher' } -OutFile $zip -TimeoutSec 60
                $actualDigest = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actualDigest -ne [string]$index.edgeSHA256) { throw '下载包 SHA-256 校验失败' }
                Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
                $source = Join-Path $expanded 'edge-extension'
                if (-not (Test-Path -LiteralPath (Join-Path $source 'manifest.json'))) {
                    if (Test-Path -LiteralPath (Join-Path $expanded 'manifest.json')) { $source = $expanded }
                    else { throw '压缩包目录结构无效' }
                }
                $downloadedVersion = Assert-InstalledExtension $source
                if ($downloadedVersion -ne $version) { throw '压缩包版本与索引不一致' }
                $targetDir = Join-Path $productRoot ('edge-extension-' + $version)
                if (Test-Path -LiteralPath $targetDir) { Remove-Item -LiteralPath $targetDir -Recurse -Force }
                Move-Item -LiteralPath $source -Destination $targetDir
                Set-Content -LiteralPath (Join-Path $productRoot 'current.txt') -Value $version -Encoding UTF8
                Write-Log "已更新到 v$version"
            } finally {
                if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $expanded) { Remove-Item -LiteralPath $expanded -Recurse -Force -ErrorAction SilentlyContinue }
            }
            return
        } catch {
            $lastError = $_.Exception.Message
        }
    }
    Write-Log "更新检查未完成（${lastError}），使用已安装版本"
}

function Get-LaunchArguments([string]$ExtensionDir) {
    $profileDir = Join-Path $productRoot 'EdgeProfile'
    # 入口页：本地 start.html（file:// 必然加载成功，避免冷启动首屏/同步弹窗竞争导致
    # chrome-extension:// URL 被 ERR_BLOCKED_BY_CLIENT 拦掉）；页面内轮询扩展就绪后
    # 导航到扩展启动页（launch.html 在 web_accessible_resources 中，跨源导航合法）。
    $startFile = Join-Path $ExtensionDir 'start.html'
    $startURL = [Uri]::new($startFile, [UriKind]::Absolute).AbsoluteUri
    $escapedProfile = $profileDir.Replace('"', '""')
    $escapedExt = $ExtensionDir.Replace('"', '""')
    return '--user-data-dir="' + $escapedProfile + '" --disable-extensions-except="' + $escapedExt + '" --load-extension="' + $escapedExt + '" --no-first-run --no-default-browser-check "' + $startURL + '"'
}

$edge = Get-EdgePath
$currentDir = Get-CurrentExtensionDir
if ($PrintOnly) {
    $extensionDirForArgs = $currentDir
    if (-not $extensionDirForArgs) {
        # 尚未安装时仅输出占位（安装流程中不会用到）
        $extensionDirForArgs = Join-Path $productRoot 'edge-extension-pending'
    }
    [pscustomobject]@{
        EdgePath = $edge
        Arguments = Get-LaunchArguments $extensionDirForArgs
        ExtensionReady = $true
        ProfileDirectory = 'Default'
        WorkbenchURL = "chrome-extension://$extensionID/launch.html"
    } | ConvertTo-Json -Compress
    exit 0
}

if (-not $currentDir) {
    Write-Host '❌ 未找到智囊安装目录，请重新运行官方安装命令（install-windows.ps1）。'
    exit 1
}
Update-IfAvailable $currentDir
$currentDir = Get-CurrentExtensionDir
if (-not $currentDir) { Write-Host '❌ 智囊更新后无法定位安装目录。'; exit 1 }

# 清理不再使用的旧版本目录（运行中被锁定的跳过，下次启动再清理）
Get-ChildItem -LiteralPath $productRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^edge-extension-\d+\.\d+\.\d+(\.\d+)?$' -and $_.FullName -ne $currentDir } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

$args = Get-LaunchArguments $currentDir
Start-Process -FilePath $edge -ArgumentList $args
exit 0
