[CmdletBinding()]
param(
    [string]$SourceDir = $PSScriptRoot,
    [string]$TargetRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ParallelWorkbench'),
    [switch]$NoLaunch,
    [switch]$NoShortcuts,
    [switch]$NoClipboard,
    [switch]$VerifyOnly
)

# 智囊安装器（v0.4.1 起的新分发模型）：
#   - 版本化目录 edge-extension-<version> + current.txt 指针：更新不再受 Windows 文件锁影响；
#   - 桌面/开始菜单快捷方式调用 launch.ps1（每次启动自动检查更新，用独立 Edge 配置档 +
#     --load-extension 加载扩展）：不再需要开发者模式，不再有任何反复授权/骚扰条。
#   - 旧版（开发者模式加载解压缩扩展）的注册项会在首次启动说明中引导清理。
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$timer = [Diagnostics.Stopwatch]::StartNew()
$expectedExtensionID = 'mklpdfdkbchlahfahofajchfjphlpkek'

function Write-Step([string]$Message) {
    Write-Host ('[{0,6:N1}s] {1}' -f $timer.Elapsed.TotalSeconds, $Message)
}

function Get-EdgePath {
    $command = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $registryKeys = @(
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )
    foreach ($key in $registryKeys) {
        if (Test-Path -LiteralPath $key) {
            $value = (Get-Item -LiteralPath $key).GetValue('')
            if ($value -and (Test-Path -LiteralPath $value)) { return [string]$value }
        }
    }
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
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

function Assert-ExtensionSource([string]$Path) {
    foreach ($required in @(
        'manifest.json', 'distribution.json', 'background.js', 'content.js', 'workbench.html', 'workbench.js',
        'workbench.css', 'launch.html', 'launch.js', 'launch.css', 'start.html', 'start.js', 'lib\model-preference.js', 'lib\adapters\index.json', 'install.ps1', 'launch.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $required))) {
            throw "安装源缺少 $required"
        }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $Path 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest.version -or -not $manifest.key) { throw 'manifest.json 缺少版本或固定扩展 ID 公钥' }
    if ([string]$manifest.version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw 'manifest.json 版本号格式无效' }
    if ((Get-DerivedExtensionID (Join-Path $Path 'manifest.json')) -ne $expectedExtensionID) { throw 'manifest.json 固定公钥与启动器扩展 ID 不一致' }
    return [string]$manifest.version
}

function Move-WithRetry([string]$From, [string]$To, [string]$Description) {
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Milliseconds (200 * $attempt) }
        }
    }
    throw "$Description 失败：$($lastError.Exception.Message)"
}

function Test-IsSameOrChildPath([string]$Candidate, [string]$Parent) {
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd($separators)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd($separators)
    if ($candidateFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $candidateFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

$source = (Resolve-Path -LiteralPath $SourceDir).Path
$version = Assert-ExtensionSource $source
if ($VerifyOnly) {
    Write-Step "安装源验证通过：v$version"
    exit 0
}

$targetRootFull = [IO.Path]::GetFullPath($TargetRoot)
$target = Join-Path $targetRootFull ('edge-extension-' + $version)
$operationID = [Guid]::NewGuid().ToString('N')
$stage = Join-Path $targetRootFull ('.edge-extension.new-' + $operationID)
$backup = Join-Path $targetRootFull ('.edge-extension.old-' + $operationID)

if ($source.Equals($targetRootFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SourceDir 不能与 TargetRoot 相同'
}

Write-Step "正在安装智囊 v$version（新分发模式：免开发者模式、免反复授权）"
New-Item -ItemType Directory -Path $targetRootFull -Force | Out-Null
foreach ($path in @($stage, $backup)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$originalLocation = (Get-Location).Path
$locationWasMoved = $false
$oldWasMoved = $false
try {
    if (Test-IsSameOrChildPath $originalLocation $targetRootFull) {
        Set-Location -LiteralPath $targetRootFull
        $locationWasMoved = $true
    }

    Write-Step '复制并校验扩展文件'
    Get-ChildItem -LiteralPath $source -Force |
        Where-Object { $_.Name -ne '_metadata' -and $_.Name -ne '.DS_Store' } |
        Copy-Item -Destination $stage -Recurse -Force
    $stagedVersion = Assert-ExtensionSource $stage
    if ($stagedVersion -ne $version) { throw '复制后的扩展版本不一致' }

    # 版本化目录原地激活：同版本重装时先备份旧目录，失败即回滚；版本化设计使运行中的旧版本不受影响
    if (Test-Path -LiteralPath $target) {
        Move-WithRetry $target $backup '备份旧版本'
        $oldWasMoved = $true
    }
    Move-WithRetry $stage $target '启用新版本'
} catch {
    $installError = $_
    if ($oldWasMoved -and (-not (Test-Path -LiteralPath $target)) -and (Test-Path -LiteralPath $backup)) {
        try {
            Move-WithRetry $backup $target '恢复旧版本'
            $oldWasMoved = $false
        } catch {
            throw "安装失败且旧版本自动恢复失败；旧版备份位于 $backup。原错误：$($installError.Exception.Message)"
        }
    }
    throw "安装失败，已保留原版本：$($installError.Exception.Message)"
} finally {
    if ($locationWasMoved) {
        if (Test-Path -LiteralPath $originalLocation) { Set-Location -LiteralPath $originalLocation }
        else { Set-Location -LiteralPath $targetRootFull }
    }
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path -LiteralPath $backup) {
    try { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop }
    catch { Write-Warning "新版已安装，但旧版备份未能删除：$backup" }
}

Set-Content -LiteralPath (Join-Path $targetRootFull 'current.txt') -Value $version -Encoding UTF8

# —— 迁移：移除旧版未版本化目录与临时残留（旧版靠开发者模式注册，新模型不再使用）——
foreach ($legacy in @((Join-Path $targetRootFull 'edge-extension'))) {
    if (Test-Path -LiteralPath $legacy) {
        try { Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction Stop; Write-Step '已移除旧版未版本化安装目录' }
        catch { Write-Warning "旧版目录清理失败（可稍后手动删除）：$legacy" }
    }
}
Get-ChildItem -LiteralPath $targetRootFull -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '.edge-extension.*' } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

# —— 清理非当前版本目录（运行中被锁定的跳过，下次启动再清理）——
Get-ChildItem -LiteralPath $targetRootFull -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^edge-extension-\d+\.\d+\.\d+(\.\d+)?$' -and $_.FullName -ne $target } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

$launcherPath = Join-Path $target 'launch.ps1'
$powershellPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
if (-not (Test-Path -LiteralPath $powershellPath)) { $powershellPath = 'powershell.exe' }
$launcherArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcherPath + '"'

function Test-ProductShortcut($Shortcut, [string]$ProductRoot) {
    # 新模型：快捷方式指向本产品的 launch.ps1（powershell.exe 目标）
    foreach ($relative in @('launch.bat', 'launch.ps1', 'edge-extension\launch.bat', 'edge-extension\launch.ps1')) {
        if ([string]$Shortcut.TargetPath -eq (Join-Path $ProductRoot $relative)) { return $true }
        if ([string]$Shortcut.Arguments).Contains('"' + (Join-Path $ProductRoot $relative) + '"') { return $true }
    }
    # 旧版快捷方式形态（v0.4.0 及更早）
    if ([string]$Shortcut.Arguments -match 'chrome-extension://mklpdfdkbchlahfahofajchfjphlpkek/(workbench|launch)\.html(?:["\s]|$)') { return $true }
    if ([string]$Shortcut.Arguments -match 'chrome-extension://eeppnjgcjioaohaaoaknkkafhodccmmf/(workbench|launch)\.html(?:["\s]|$)') { return $true }
    $startURL = [Uri]::new((Join-Path $ProductRoot 'edge-extension\start.html'), [UriKind]::Absolute).AbsoluteUri
    if (([string]$Shortcut.Arguments).Contains('--app="' + $startURL + '"')) { return $true }
    return $false
}

if (-not $NoShortcuts) {
    Write-Step '创建桌面与开始菜单快捷方式'
    $shell = New-Object -ComObject WScript.Shell
    $shortcutDirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('Programs')
    ) | Where-Object { $_ }
    foreach ($dir in $shortcutDirs) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $newShortcutPath = Join-Path $dir '智囊.lnk'
            $shortcut = $shell.CreateShortcut($newShortcutPath)
            if ((Test-Path -LiteralPath $newShortcutPath) -and (-not (Test-ProductShortcut $shortcut $targetRootFull))) {
                throw '已有同名快捷方式属于其他程序，已保留；可运行安装目录中的 launch.bat'
            }
            $shortcut.TargetPath = $powershellPath
            $shortcut.Arguments = $launcherArgs
            $shortcut.WorkingDirectory = $targetRootFull
            $shortcut.IconLocation = (Join-Path $target 'icons\128.png')
            $shortcut.Description = '智囊 Braintrust · 多模型并行工作台'
            $shortcut.Save()
            foreach ($legacyName in @('平行工作台.lnk', 'Parallel Workbench.lnk', 'ParallelWorkbench.lnk')) {
                $legacyPath = Join-Path $dir $legacyName
                if (Test-Path -LiteralPath $legacyPath) {
                    $legacy = $shell.CreateShortcut($legacyPath)
                    if (Test-ProductShortcut $legacy $targetRootFull) {
                        # 保留用户原有入口，同时让它启动新版；不触碰任何其他应用快捷方式。
                        $legacy.TargetPath = $powershellPath
                        $legacy.Arguments = $launcherArgs
                        $legacy.WorkingDirectory = $targetRootFull
                        $legacy.Description = $shortcut.Description
                        $legacy.Save()
                    }
                }
            }
        } catch {
            Write-Warning "快捷方式创建失败（$dir）：$($_.Exception.Message)"
        }
    }
}

$pathNote = Join-Path $targetRootFull 'EXTENSION_PATH.txt'
Set-Content -LiteralPath $pathNote -Value $target -Encoding UTF8
if (-not $NoClipboard) {
    try {
        if (Get-Command 'Set-Clipboard' -ErrorAction SilentlyContinue) { Set-Clipboard -Value $target }
        elseif (Get-Command 'clip.exe' -ErrorAction SilentlyContinue) { $target | clip.exe }
    } catch {}
}

if (-not $NoLaunch) {
    Write-Step '打开智囊（独立配置档 + 命令行加载扩展，无需开发者模式）'
    & $launcherPath
}

Write-Step "安装文件已就绪：$target"
Write-Host '以后双击桌面或开始菜单中的「智囊」即可打开，每次启动自动检查并安装更新。'
Write-Host '若此前用过旧版（开发者模式加载）：打开 Edge 的 edge://extensions，删除旧「智囊」条目即可（仅一次）。'
Write-Host 'AI 平台登录状态保存在智囊窗口自己的配置里，首次使用请重新登录一次。'
Write-Host ('完成用时：{0:N1} 秒' -f $timer.Elapsed.TotalSeconds)
