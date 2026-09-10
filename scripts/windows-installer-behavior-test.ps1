Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Braintrust-installer-test-' + [Guid]::NewGuid().ToString('N'))

# 只载入被测函数；不执行安装器主流程、不读取真实 Edge 配置、不启动浏览器。
foreach ($relative in @('install-windows.ps1', 'Windows/edge-extension/launch.ps1', 'Windows/edge-extension/install.ps1')) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $relative), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell parse failed: $relative" }
    $definitions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$script:httpCalls = @()
$script:indexResponse = $null
$script:apiResponse = $null
$script:webDownloadSource = $null
function Invoke-RestMethod([string]$Uri, $Headers, [int]$TimeoutSec) {
    $script:httpCalls += [pscustomobject]@{ URL = $Uri; Timeout = $TimeoutSec }
    if ($Uri.EndsWith('/update.json')) {
        if ($null -eq $script:indexResponse) { throw 'index network unavailable' }
        return $script:indexResponse
    }
    if ($null -eq $script:apiResponse) { throw 'API unavailable' }
    return $script:apiResponse
}
function Invoke-WebRequest([string]$Uri, $Headers, [string]$OutFile, [int]$TimeoutSec) {
    $script:httpCalls += [pscustomobject]@{ URL = $Uri; Download = $true }
    Copy-Item -LiteralPath $script:webDownloadSource -Destination $OutFile -Force
}

$extensionID = 'mklpdfdkbchlahfahofajchfjphlpkek'
$expectedExtensionID = 'mklpdfdkbchlahfahofajchfjphlpkek'
$updateRepos = @('porcelaintech/parallel-workshop', 'HanchengQiao/parallel-workshop')
$productRoot = $testRoot
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    # —— 身份推导与安装源校验 ——
    $derived = Get-DerivedExtensionID (Join-Path $repoRoot 'Windows/edge-extension/manifest.json')
    Assert-True ($derived -eq $extensionID) "Derived ID must match launcher ID (got $derived)"
    $validVersion = Assert-InstalledExtension (Join-Path $repoRoot 'Windows/edge-extension')
    Assert-True ($validVersion -match '^\d+\.\d+\.\d+$') 'Repo extension source must validate'
    $badDir = Join-Path $testRoot 'bad-ext'
    New-Item -ItemType Directory -Path $badDir -Force | Out-Null
    @{ version = '0.4.1'; key = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqf16kba9ozEJ1v9PsGG5MUEj3650Y4b/L7asL+77UF2oFQjpyyFmrE7M+PrlukH68QMS31VYSrKqQzv6ZASga+qghEmySj1NfXaGja+PJuYZJ4Utf8O71GS/Fty5nBAiZp9foh+7Eeo5SeE7TZXODTgUvs0zxefMdV6XJa5YXLlU6gRDlh4p4ic826BV8c2qsfl1kVya8WTc7v1Nt1fnOAk+N3p56UW5TH8PcxPnl7c/7ehA6imhTSkfC5OJw7HeX9AwUJ9sFmDfiIUl0L2m4+U2bsdnrg+slHAE2UzLgVsfnDzoHTV+LWv1z9JFCXF+B3QU+ExCymQ+ZJD0ymygJQIDAQAB' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $badDir 'manifest.json') -Encoding UTF8
    $rejected = $false
    try { Assert-InstalledExtension $badDir | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Incomplete extension directory must fail closed'

    # —— 快捷方式识别（新模型 + 旧版迁移）——
    $launcherShortcut = [pscustomobject]@{ TargetPath = 'powershell.exe'; Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $testRoot 'edge-extension-0.4.1\launch.ps1') + '"' }
    $legacyShortcut = [pscustomobject]@{ TargetPath = 'msedge.exe'; Arguments = '--app=chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/workbench.html' }
    $newShortcut = [pscustomobject]@{ TargetPath = 'msedge.exe'; Arguments = '--app=chrome-extension://mklpdfdkbchlahfahofajchfjphlpkek/workbench.html' }
    $unrelatedShortcut = [pscustomobject]@{ TargetPath = 'other.exe'; Arguments = '' }
    Assert-True (Test-ProductShortcut $launcherShortcut $testRoot) 'New launcher shortcut must be recognized'
    Assert-True (Test-ProductShortcut $legacyShortcut $testRoot) 'Legacy extension shortcut should migrate'
    Assert-True (Test-ProductShortcut $newShortcut $testRoot) 'Current extension shortcut should migrate'
    Assert-True (-not (Test-ProductShortcut $unrelatedShortcut $testRoot)) 'Same-name unrelated shortcut must be preserved'

    # —— 外层安装器：官方索引 → API 回退 → 恶意/缺失校验 ——
    $digest = 'a' * 64
    $url = 'https://github.com/porcelaintech/parallel-workshop/releases/download/v9.8.7/edge-extension.zip'
    $script:indexResponse = [pscustomobject]@{ schemaVersion = 1; version = '9.8.7'; edgeURL = $url; edgeSHA256 = $digest }
    $package = Get-LatestPackage 'porcelaintech/parallel-workshop'
    Assert-True ($package.URL -eq $url -and $package.SHA256 -eq $digest) 'Official index must select the expected archive and digest'
    Assert-True ($script:httpCalls.Count -eq 1 -and $script:httpCalls[0].Timeout -eq 12) 'Successful index must avoid all API requests'

    $script:httpCalls = @()
    $script:indexResponse = $null
    $script:apiResponse = [pscustomobject]@{
        draft = $false; prerelease = $false; tag_name = 'v9.8.7'; body = ''
        assets = @(
            [pscustomobject]@{ name = 'edge-extension-store.zip'; digest = 'sha256:' + $digest; browser_download_url = 'https://example.invalid/store.zip' },
            [pscustomobject]@{ name = 'edge-extension.zip'; digest = 'sha256:' + $digest; browser_download_url = $url }
        )
    }
    $fallback = Get-LatestPackage 'porcelaintech/parallel-workshop'
    Assert-True ($fallback.URL -eq $url -and $script:httpCalls.Count -eq 2) 'Index outage must use one bounded API fallback and select the user ZIP'
    Assert-True ($script:httpCalls[1].Timeout -eq 12) 'API fallback must retain a short request deadline'

    $script:indexResponse = [pscustomobject]@{ schemaVersion = 1; version = '9.8.7'; edgeURL = 'https://example.invalid/edge-extension.zip'; edgeSHA256 = $digest }
    $script:apiResponse = $null
    $rejected = $false
    try { Get-LatestPackage 'porcelaintech/parallel-workshop' | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Untrusted archive URL must not be returned for downloading'
    $script:indexResponse = [pscustomobject]@{ schemaVersion = 1; version = '9.8.7'; edgeURL = $url; edgeSHA256 = '' }
    $rejected = $false
    try { Get-LatestPackage 'porcelaintech/parallel-workshop' | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Missing digest must fail closed'

    # —— 内层安装器：版本化目录 + current.txt + 旧版目录迁移 ——
    $sourceDir = Join-Path $repoRoot 'Windows/edge-extension'
    $installRoot = Join-Path $testRoot '安装 中文 空格'
    $version = Assert-ExtensionSource $sourceDir
    $installedDir = Join-Path $installRoot ('edge-extension-' + $version)
    & (Join-Path $sourceDir 'install.ps1') -TargetRoot $installRoot -NoLaunch -NoShortcuts -NoClipboard
    Assert-True (Test-Path -LiteralPath (Join-Path $installedDir 'manifest.json')) 'Versioned install directory must exist'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw -Encoding UTF8).Trim() -eq $version) 'current.txt must point at the installed version'

    # 旧版未版本化目录必须被迁移清理
    New-Item -ItemType Directory -Path (Join-Path $installRoot 'edge-extension') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installRoot 'edge-extension\old-marker') -Value 'legacy'
    & (Join-Path $sourceDir 'install.ps1') -TargetRoot $installRoot -NoLaunch -NoShortcuts -NoClipboard
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot 'edge-extension'))) 'Legacy unversioned directory must be removed during migration'

    # 同版本重装：删除的过时文件必须消失，_metadata 残留必须清理
    Set-Content -LiteralPath (Join-Path $installedDir 'obsolete-old-release.js') -Value 'obsolete'
    New-Item -ItemType Directory -Path (Join-Path $installedDir '_metadata') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $installedDir '_metadata/stale-cache') -Value 'stale'
    & (Join-Path $sourceDir 'install.ps1') -TargetRoot $installRoot -NoLaunch -NoShortcuts -NoClipboard
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedDir 'obsolete-old-release.js'))) 'Replacing from a fresh package must remove files deleted by the new release'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedDir '_metadata'))) 'Replacing the product must discard stale product metadata'

    # 激活失败必须回滚（保留原版本，无临时残留）
    $script:simulateStageFailure = $true
    function Move-Item {
        [CmdletBinding()]
        param([string]$LiteralPath, [string]$Destination)
        if ($script:simulateStageFailure -and (Split-Path -Leaf $LiteralPath) -like '.edge-extension.new-*') { throw 'simulated Windows file lock during activation' }
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }
    Set-Content -LiteralPath (Join-Path $installedDir 'previous-version-marker') -Value 'preserve on rollback'
    $rolledBack = $false
    try { & (Join-Path $sourceDir 'install.ps1') -TargetRoot $installRoot -NoLaunch -NoShortcuts -NoClipboard }
    catch { $rolledBack = $true }
    $script:simulateStageFailure = $false
    Assert-True $rolledBack 'A failed activation must report failure'
    Assert-True (Test-Path -LiteralPath (Join-Path $installedDir 'previous-version-marker')) 'A failed activation must restore the original complete installation'
    Assert-True (@(Get-ChildItem -LiteralPath $installRoot -Force | Where-Object { $_.Name -like '.edge-extension.*' }).Count -eq 0) 'Successful rollback must remove staging and backup directories'

    # —— 启动器：current.txt 解析 + 启动参数形态 ——
    # launch.ps1 的 productRoot = 包含 edge-extension-<version> 的目录（即 InstallRoot）
    $productRoot = $installRoot
    $currentDir = Get-CurrentExtensionDir
    Assert-True ($currentDir -eq $installedDir) 'Launcher must resolve the current versioned directory'
    $args = Get-LaunchArguments $currentDir
    Assert-True ($args.Contains('--load-extension="' + $installedDir + '"')) 'Launch args must load the extension without developer mode'
    Assert-True ($args.Contains('--user-data-dir=')) 'Launch args must use a dedicated Edge profile'
    Assert-True ($args.Contains('chrome-extension://mklpdfdkbchlahfahofajchfjphlpkek/launch.html')) 'Launch args must open the launcher page'

    # 启动器自动更新：索引版本与当前一致 → 不下载；更高版本 → 下载校验并激活版本化目录
    $script:httpCalls = @()
    $script:indexResponse = [pscustomobject]@{ schemaVersion = 1; version = $version; edgeURL = "https://github.com/porcelaintech/parallel-workshop/releases/download/v$version/edge-extension.zip"; edgeSHA256 = $digest }
    Update-IfAvailable $currentDir
    Assert-True (@($script:httpCalls | Where-Object { $_.Download }).Count -eq 0) 'Same-version index must not trigger a download'

    $nextVersion = '9.8.7'
    $nextURL = "https://github.com/porcelaintech/parallel-workshop/releases/download/v$nextVersion/edge-extension.zip"
    $zipSource = Join-Path $testRoot 'edge-extension.zip'
    $zipStageDir = Join-Path $testRoot 'zip-stage'
    New-Item -ItemType Directory -Path $zipStageDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceDir '*') -Destination $zipStageDir -Recurse -Force
    $manifestPath = Join-Path $zipStageDir 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.version = $nextVersion
    $manifest | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Compress-Archive -Path (Join-Path $zipStageDir '*') -DestinationPath $zipSource
    $nextDigest = (Get-FileHash -LiteralPath $zipSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:webDownloadSource = $zipSource
    $script:indexResponse = [pscustomobject]@{ schemaVersion = 1; version = $nextVersion; edgeURL = $nextURL; edgeSHA256 = $nextDigest }
    Update-IfAvailable $currentDir
    $newCurrent = Get-CurrentExtensionDir
    Assert-True ($newCurrent -eq (Join-Path $installRoot ('edge-extension-' + $nextVersion))) 'Launcher update must activate the new versioned directory'
    Assert-True ((Assert-InstalledExtension $newCurrent) -eq $nextVersion) 'Activated update must pass identity and completeness checks'

    Write-Host 'PASS: Windows installer behavior (identity, shortcuts, index+fallback, versioned install, migration, rollback, launcher auto-update)'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
