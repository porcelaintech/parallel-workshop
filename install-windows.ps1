[CmdletBinding()]
param(
    [string]$Repository = 'porcelaintech/parallel-workshop',
    [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ParallelWorkbench'),
    [string]$ArchivePath = '',
    [switch]$NoLaunch,
    [switch]$NoShortcuts,
    [switch]$NoClipboard,
    [switch]$VerifyOnly,
    [switch]$Enterprise
)

# -Enterprise：企业模式（仅限已加入 Active Directory / Microsoft Entra 域的 Windows）。
# 安装后把 Edge 策略 ExtensionSettings 写入 HKLM（需要一次 UAC 管理员授权 = 用户的一次性弹窗授权），
# Edge 将自动安装并持续自动更新官方签名的 .crx（不再需要任何交互，用户也无法再被反复索权）。
# 注意：按 Microsoft 官方文档，商店外扩展的强制安装仅支持已加域的 Windows；普通个人电脑请用默认模式。

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$timer = [Diagnostics.Stopwatch]::StartNew()
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ParallelWorkbench-install-' + [Guid]::NewGuid().ToString('N'))

function Write-Step([string]$Message) {
    Write-Host ('[{0,6:N1}s] {1}' -f $timer.Elapsed.TotalSeconds, $Message)
}

function Invoke-WithRetry([scriptblock]$Operation, [string]$Description) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try { return & $Operation } catch {
            $lastError = $_
            if ($attempt -lt 2) { Start-Sleep -Seconds 1 }
        }
    }
    throw "$Description 失败（共尝试 2 次）：$($lastError.Exception.Message)"
}

function Get-LatestPackage([string]$Repo) {
    if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw '仓库名称格式无效' }
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Braintrust-Windows-Installer' }
    # 固定 Release 索引不消耗 GitHub API 配额，也不要求 Agent 预先配置账户或令牌。
    try {
        $index = Invoke-RestMethod -Uri "https://github.com/$Repo/releases/latest/download/update.json" -Headers $headers -TimeoutSec 12
        $version = [string]$index.version
        if ($index.schemaVersion -ne 1 -or $version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw '更新索引格式无效' }
        $url = "https://github.com/$Repo/releases/download/v$version/edge-extension.zip"
        if ([string]$index.edgeURL -cne $url -or [string]$index.edgeSHA256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw '更新索引未提供匹配版本的官方安装包与 SHA-256'
        }
        return [pscustomobject]@{ Version = $version; URL = $url; SHA256 = [string]$index.edgeSHA256 }
    } catch { $indexError = $_.Exception.Message }

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec 12
        if ($release.draft -or $release.prerelease) { throw '最新 Release 不是稳定版本' }
        $asset = @($release.assets | Where-Object { $_.name -eq 'edge-extension.zip' }) | Select-Object -First 1
        if (-not $asset) { throw 'Release 缺少 edge-extension.zip' }
        $version = ([string]$release.tag_name).TrimStart('v')
        if ($version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw 'Release 版本号格式无效' }
        $url = "https://github.com/$Repo/releases/download/v$version/edge-extension.zip"
        if ([string]$asset.browser_download_url -cne $url) { throw 'Release 安装包下载地址无效' }
        $digest = ''
        if ($asset.PSObject.Properties.Name -contains 'digest') { $digest = ([string]$asset.digest) -replace '^sha256:', '' }
        if ($digest -notmatch '^[0-9a-fA-F]{64}$') {
            $match = [regex]::Match([string]$release.body, '(?im)^SHA256\s+edge-extension\.zip\s+([0-9a-f]{64})\s*$')
            if ($match.Success) { $digest = $match.Groups[1].Value }
        }
        if ($digest -notmatch '^[0-9a-fA-F]{64}$') { throw 'Release 未提供有效 SHA-256' }
        return [pscustomobject]@{ Version = $version; URL = $url; SHA256 = $digest }
    } catch {
        throw "无法获取最新安装包。下载索引：$indexError；版本服务：$($_.Exception.Message)"
    }
}

try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $zip = Join-Path $temp 'edge-extension.zip'
    $expectedDigest = ''
    $releaseVersion = ''

    if ($Enterprise) {
        # 前置校验：Microsoft 官方约束——商店外扩展的强制安装仅支持已加入 Active Directory 域的 Windows。
        $isDomainJoined = $false
        try { $isDomainJoined = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch {}
        if (-not $isDomainJoined) {
            throw '企业模式仅支持已加入 Active Directory 域的 Windows（Microsoft 官方约束）。请改用默认安装模式。'
        }
    }

function Register-EnterprisePolicy([string]$Version) {
    # Microsoft 官方约束：商店外扩展的强制/自动安装仅支持已加入 AD 域或 Entra(AAD) 域的 Windows。
    $isDomainJoined = $false
    try { $isDomainJoined = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch {}
    if (-not $isDomainJoined) {
        throw '企业模式仅支持已加入 Active Directory 域的 Windows（Microsoft 官方约束）。请改用默认安装模式。'
    }
    $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $extensionID = 'mklpdfdkbchlahfahofajchfjphlpkek'
    $updateURL = "https://github.com/$Repository/releases/latest/download/updates.xml"
    $policy = @{ $extensionID = @{
        installation_mode = 'force_installed'
        update_url = $updateURL
        override_update_url = $true
    } } | ConvertTo-Json -Compress

    $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isElevated) {
        # 一次性管理员授权（UAC 弹窗）：用户明确同意后由提权进程写入策略，之后不再需要任何授权。
        Write-Step '请求一次性管理员授权（写入 Edge 策略，之后永久生效）'
        $scriptPath = $MyInvocation.MyCommand.Path
        $elevatedArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
            '-Repository', $Repository, '-InstallRoot', $InstallRoot, '-NoLaunch', '-NoShortcuts', '-NoClipboard', '-Enterprise')
        if ($ArchivePath) { $elevatedArgs += @('-ArchivePath', $ArchivePath) }
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $elevatedArgs -Verb RunAs -PassThru -Wait
        if ($process.ExitCode -ne 0) { throw "企业策略注册失败（退出码 $($process.ExitCode)）" }
        return
    }

    New-Item -Path $policyKey -Force | Out-Null
    New-ItemProperty -Path $policyKey -Name 'ExtensionSettings' -Value $policy -PropertyType String -Force | Out-Null
    Write-Step 'Edge 策略已写入：智囊将由 Edge 自动安装并持续自动更新（无需开发者模式）'
    Write-Host 'Edge 会在下一次启动/策略刷新时自动安装。可在 edge://policy 查看；edge://extensions 中显示「由组织管理」。'
}

    if ($ArchivePath) {
        Write-Step '使用本地候选包'
        Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ArchivePath).Path -Destination $zip
    } else {
        Write-Step '正在获取并安装最新版智囊'
        $package = Get-LatestPackage $Repository
        $releaseVersion = $package.Version
        $expectedDigest = $package.SHA256
        Write-Step "下载 v$releaseVersion"
        Invoke-WithRetry {
            Invoke-WebRequest -UseBasicParsing -Uri $package.URL -Headers @{ 'User-Agent' = 'Braintrust-Windows-Installer' } -OutFile $zip -TimeoutSec 45
        } '下载安装包' | Out-Null
        $actualDigest = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualDigest -ne $expectedDigest.ToLowerInvariant()) { throw 'SHA-256 校验失败' }
        Write-Step 'SHA-256 校验通过'
    }

    Write-Step '解压安装包'
    $expanded = Join-Path $temp 'expanded'
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
    $source = Join-Path $expanded 'edge-extension'
    if (-not (Test-Path -LiteralPath (Join-Path $source 'manifest.json'))) {
        if (Test-Path -LiteralPath (Join-Path $expanded 'manifest.json')) { $source = $expanded }
        else { throw '压缩包目录结构无效' }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $source 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($releaseVersion -and ([string]$manifest.version -ne $releaseVersion)) { throw 'Release 与 manifest 版本不一致' }
    if (-not (Test-Path -LiteralPath (Join-Path $source 'install.ps1'))) { throw '安装包缺少 install.ps1' }

    if ($VerifyOnly) {
        Write-Step "下载、校验和解压通过：v$($manifest.version)"
        exit 0
    }

    $parameters = @{
        SourceDir = $source
        TargetRoot = $InstallRoot
        NoLaunch = [bool]$NoLaunch
        NoShortcuts = [bool]$NoShortcuts
        NoClipboard = [bool]$NoClipboard
    }
    & (Join-Path $source 'install.ps1') @parameters
    Write-Step "安装完成：v$($manifest.version)"

    if ($Enterprise) {
        Write-Step '企业模式：注册 Edge 扩展策略（一次性管理员授权）'
        Register-EnterprisePolicy -Version $manifest.version
    }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

