[CmdletBinding(DefaultParameterSetName = 'Archive')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Archive')]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Url')]
    [Uri]$ArchiveUrl,

    [string]$ExpectedSHA256 = '',
    [string]$BootstrapPath = '',
    [string]$TrustedExtensionSource = '',
    [string]$TemporaryBase = ([IO.Path]::GetTempPath()),
    [int]$StepTimeoutSeconds = 180,
    [switch]$KeepArtifacts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent $scriptDirectory
if (-not $BootstrapPath) { $BootstrapPath = Join-Path $repositoryRoot 'install-windows.ps1' }
if (-not $TrustedExtensionSource) { $TrustedExtensionSource = Join-Path $repositoryRoot 'Windows\edge-extension' }
$timer = [Diagnostics.Stopwatch]::StartNew()
$stages = New-Object 'System.Collections.Generic.List[object]'
$testRoot = Join-Path ([IO.Path]::GetFullPath($TemporaryBase)) ('ParallelWorkbench-device-test-' + [Guid]::NewGuid().ToString('N'))
$sentinel = Join-Path $testRoot '.pwb-device-test-sentinel'
$candidate = Join-Path $testRoot '候选包 edge-extension.zip'
$installRoot = Join-Path $testRoot '测试 用户\Parallel Workbench'
$verifyOnlyTarget = Join-Path $testRoot 'VerifyOnly must stay absent'
$powerShellPath = $null
$failure = $null
$cleanedUp = $false
$actualSHA256 = $null
$manifestVersion = $null
$launchProbe = $null
$trustedScriptsMatched = $false
$edgeProcessIdsBefore = @()
$edgeProcessIdsAfter = @()
$newEdgeProcessIdsObserved = @()
$edgeSnapshotCaptured = $false

function ConvertTo-ProcessArgument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-BoundedPowerShell([string]$ScriptPath, [string[]]$Arguments, [string]$StageName) {
    $allArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($Arguments)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = (($allArguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $stageTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw "无法启动 $StageName" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit([Math]::Max(1, $StepTimeoutSeconds) * 1000)) {
            try { $process.Kill() } catch {}
            $process.WaitForExit()
            throw "$StageName 超过 $StepTimeoutSeconds 秒，已终止测试子进程"
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $result = [pscustomobject][ordered]@{
            name = $StageName
            success = $process.ExitCode -eq 0
            exitCode = $process.ExitCode
            durationSeconds = [Math]::Round($stageTimer.Elapsed.TotalSeconds, 3)
            stdout = $stdout.Trim()
            stderr = $stderr.Trim()
        }
        $stages.Add($result) | Out-Null
        if ($process.ExitCode -ne 0) {
            $details = @($stderr.Trim(), $stdout.Trim()) | Where-Object { $_ } | Select-Object -First 1
            throw "$StageName 失败（退出码 $($process.ExitCode)）：$details"
        }
        return $result
    } finally {
        $process.Dispose()
    }
}

function Invoke-DownloadWithRetry([Uri]$Uri, [string]$Destination) {
    if ($Uri.Scheme -ne 'https') { throw 'ArchiveUrl 必须使用 HTTPS' }
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri.AbsoluteUri -OutFile $Destination -TimeoutSec 60
            return
        } catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Seconds $attempt }
        }
    }
    throw "候选包下载失败（已重试 3 次）：$($lastError.Exception.Message)"
}

function Get-DirectoryFingerprint([string]$Directory) {
    $root = [IO.Path]::GetFullPath($Directory).TrimEnd([char[]]@('\', '/'))
    $records = @(
        Get-ChildItem -LiteralPath $root -File -Recurse -Force |
            Sort-Object -Property FullName |
            ForEach-Object {
                $relative = $_.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/'))
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                '{0}|{1}' -f ($relative -replace '\\', '/'), $hash
            }
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($records -join "`n"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-EdgeProcessIDs {
    try { return @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
    catch { return @() }
}

function Test-SafeCleanupRoot([string]$Path, [string]$Base, [string]$SentinelPath) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    $fullBase = [IO.Path]::GetFullPath($Base).TrimEnd([char[]]@('\', '/'))
    if (-not ([IO.Path]::GetDirectoryName($fullPath)).Equals($fullBase, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ([IO.Path]::GetFileName($fullPath) -notmatch '^ParallelWorkbench-device-test-[0-9a-f]{32}$') { return $false }
    if (-not (Test-Path -LiteralPath $SentinelPath -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $fullPath -Force
    return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
}

try {
    if ($StepTimeoutSeconds -lt 1 -or $StepTimeoutSeconds -gt 900) { throw 'StepTimeoutSeconds 必须介于 1 到 900 秒' }
    if ($PSCmdlet.ParameterSetName -eq 'Url' -and -not $ExpectedSHA256) {
        throw '使用 ArchiveUrl 时必须同时提供 ExpectedSHA256'
    }
    $bootstrap = (Resolve-Path -LiteralPath $BootstrapPath).Path
    $trustedSource = (Resolve-Path -LiteralPath $TrustedExtensionSource).Path
    $powerShellCommand = Get-Command 'powershell.exe' -ErrorAction Stop
    $powerShellPath = [string]$powerShellCommand.Source

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Set-Content -LiteralPath $sentinel -Value 'ParallelWorkbench isolated device test' -Encoding ASCII
    $edgeProcessIdsBefore = Get-EdgeProcessIDs
    $edgeSnapshotCaptured = $true
    if ($PSCmdlet.ParameterSetName -eq 'Archive') {
        $resolvedArchive = (Resolve-Path -LiteralPath $ArchivePath).Path
        Copy-Item -LiteralPath $resolvedArchive -Destination $candidate
    } else {
        Invoke-DownloadWithRetry $ArchiveUrl $candidate
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw '候选 ZIP 不存在' }

    $actualSHA256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ExpectedSHA256) {
        if ($ExpectedSHA256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'ExpectedSHA256 格式无效' }
        if ($actualSHA256 -ne $ExpectedSHA256.ToLowerInvariant()) { throw '候选 ZIP 的 SHA-256 与 ExpectedSHA256 不一致' }
    }

    $inspectionRoot = Join-Path $testRoot '只读脚本比对'
    Expand-Archive -LiteralPath $candidate -DestinationPath $inspectionRoot -Force
    $candidateSource = Join-Path $inspectionRoot 'edge-extension'
    if (-not (Test-Path -LiteralPath (Join-Path $candidateSource 'manifest.json'))) {
        if (Test-Path -LiteralPath (Join-Path $inspectionRoot 'manifest.json')) { $candidateSource = $inspectionRoot }
        else { throw '候选 ZIP 目录结构无效' }
    }
    foreach ($scriptName in @('install.ps1', 'launch.ps1')) {
        $candidateScript = Join-Path $candidateSource $scriptName
        $trustedScript = Join-Path $trustedSource $scriptName
        if (-not (Test-Path -LiteralPath $candidateScript -PathType Leaf) -or
            -not (Test-Path -LiteralPath $trustedScript -PathType Leaf)) {
            throw "无法比对受信任的 $scriptName"
        }
        $candidateScriptHash = (Get-FileHash -LiteralPath $candidateScript -Algorithm SHA256).Hash
        $trustedScriptHash = (Get-FileHash -LiteralPath $trustedScript -Algorithm SHA256).Hash
        if ($candidateScriptHash -ne $trustedScriptHash) {
            throw "候选包中的 $scriptName 与当前受信任源码不一致，拒绝执行"
        }
    }
    $trustedScriptsMatched = $true

    $verify = Invoke-BoundedPowerShell $bootstrap @(
        '-ArchivePath', $candidate,
        '-InstallRoot', $verifyOnlyTarget,
        '-NoLaunch', '-NoShortcuts', '-NoClipboard', '-VerifyOnly'
    ) 'bootstrap.verifyOnly'
    if (Test-Path -LiteralPath $verifyOnlyTarget) { throw 'VerifyOnly 意外写入了 InstallRoot' }

    $firstInstall = Invoke-BoundedPowerShell $bootstrap @(
        '-ArchivePath', $candidate,
        '-InstallRoot', $installRoot,
        '-NoLaunch', '-NoShortcuts', '-NoClipboard'
    ) 'bootstrap.install.first'
    $currentFile = Join-Path $installRoot 'current.txt'
    if (-not (Test-Path -LiteralPath $currentFile -PathType Leaf)) { throw '首次安装后 current.txt 不存在' }
    $installed = Join-Path $installRoot ('edge-extension-' + ((Get-Content -LiteralPath $currentFile -Raw -Encoding UTF8).Trim()))
    $manifestPath = Join-Path $installed 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw '首次安装后版本化目录 manifest.json 不存在' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifestVersion = [string]$manifest.version
    if ($manifestVersion -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { throw '安装后的 manifest 版本无效' }
    if (Test-Path -LiteralPath (Join-Path $installed '_metadata')) { throw '安装结果保留了陈旧的 _metadata' }
    $firstInstallFingerprint = Get-DirectoryFingerprint $installed

    $secondInstall = Invoke-BoundedPowerShell $bootstrap @(
        '-ArchivePath', $candidate,
        '-InstallRoot', $installRoot,
        '-NoLaunch', '-NoShortcuts', '-NoClipboard'
    ) 'bootstrap.install.idempotent'
    $secondInstallFingerprint = Get-DirectoryFingerprint $installed
    if ($firstInstallFingerprint -ne $secondInstallFingerprint) { throw '重复安装后扩展文件树发生变化' }
    $leftovers = @(
        Get-ChildItem -LiteralPath $installRoot -Force -ErrorAction Stop |
            Where-Object { $_.Name -like '.edge-extension.new-*' -or $_.Name -like '.edge-extension.old-*' }
    )
    if ($leftovers.Count -ne 0) { throw '重复安装留下了暂存或备份目录' }

    $launchScript = Join-Path $installed 'launch.ps1'
    if (-not (Test-Path -LiteralPath $launchScript -PathType Leaf)) { throw '安装结果缺少 launch.ps1' }
    $launch = Invoke-BoundedPowerShell $launchScript @('-PrintOnly') 'launcher.printOnly'
    $launchLine = @($launch.stdout -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($launchLine.Count -ne 1) { throw 'launch -PrintOnly 未返回 JSON' }
    $launchProbe = $launchLine[0] | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath ([string]$launchProbe.EdgePath) -PathType Leaf)) { throw 'launch -PrintOnly 返回的 Edge 路径无效' }
    if ([string]$launchProbe.WorkbenchURL -ne 'chrome-extension://mklpdfdkbchlahfahofajchfjphlpkek/launch.html') {
        throw 'launch -PrintOnly 返回的工作台 URL 无效'
    }
    if (-not ([string]$launchProbe.Arguments).Contains('--load-extension="' + $installed + '"')) {
        throw 'launch -PrintOnly 未用命令行加载本次安装的扩展'
    }
    if (-not ([string]$launchProbe.Arguments).Contains('--user-data-dir=')) {
        throw 'launch -PrintOnly 未使用独立 Edge 配置档（已运行 Edge 场景下命令行参数会失效）'
    }
    if ([string]$launchProbe.Arguments -match 'about:blank') {
        throw '启动参数触碰 blank 预热'
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    if ($edgeSnapshotCaptured) {
        $edgeProcessIdsAfter = Get-EdgeProcessIDs
        $newEdgeProcessIdsObserved = @($edgeProcessIdsAfter | Where-Object { $edgeProcessIdsBefore -notcontains $_ })
    }
    $timer.Stop()
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $testRoot)) {
        try {
            if (-not (Test-SafeCleanupRoot $testRoot $TemporaryBase $sentinel)) {
                throw '隔离目录未通过清理安全校验，已拒绝递归删除'
            }
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
            $cleanedUp = -not (Test-Path -LiteralPath $testRoot)
        } catch {
            if (-not $failure) { $failure = "测试通过，但隔离目录清理失败：$($_.Exception.Message)" }
        }
    }
}

$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    success = -not [bool]$failure
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    durationSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
    candidate = [pscustomobject][ordered]@{
        source = $(if ($PSCmdlet.ParameterSetName -eq 'Archive') { $ArchivePath } else { $ArchiveUrl.AbsoluteUri })
        sha256 = $actualSHA256
        expectedSHA256Checked = [bool]$ExpectedSHA256
        trustedInstallerScriptsMatched = $trustedScriptsMatched
    }
    isolation = [pscustomobject][ordered]@{
        testRoot = $testRoot
        installRoot = $installRoot
        usesUniqueTemporaryDirectory = $true
        requestedNoLaunch = $true
        requestedNoShortcuts = $true
        requestedNoClipboard = $true
        launchValidationMode = 'PrintOnly'
        shortcutsCreated = $false
        edgeProcessObservationAvailable = $edgeSnapshotCaptured
        edgeProcessIdsBefore = @($edgeProcessIdsBefore)
        edgeProcessIdsAfter = @($edgeProcessIdsAfter)
        newEdgeProcessIdsObserved = @($newEdgeProcessIdsObserved)
        profileIsolation = 'Candidate install/launch scripts matched trusted local source; no Edge launch command was issued. This is not an OS sandbox.'
        artifactsKept = [bool]$KeepArtifacts
        cleanedUp = $cleanedUp
    }
    installedVersion = $manifestVersion
    launchProbe = $launchProbe
    stages = $stages.ToArray()
    error = $failure
}
$summary | ConvertTo-Json -Depth 8
if ($failure) { exit 1 }
exit 0
