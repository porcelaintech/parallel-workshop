[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [Parameter(Mandatory = $true)][string]$Evidence,
  [string]$ExpectedVersion = '',
  [string]$InstallDirectory = '',
  [string]$UiTest = (Join-Path $PSScriptRoot 'windows-installed-ui-test.mjs'),
  [switch]$LiveProbe,
  [switch]$PublicBaseline
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$Evidence = [IO.Path]::GetFullPath($Evidence)
New-Item -ItemType Directory -Path $Evidence -Force | Out-Null
$installRoot = if ($InstallDirectory) { [IO.Path]::GetFullPath($InstallDirectory) } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust' }
$serviceRoot = Join-Path $installRoot 'service'
$dataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\data'
$infoPath = Join-Path $dataRoot 'service.json'
$profilePath = Join-Path $dataRoot 'browser-profile'
$serverPath = Join-Path $serviceRoot 'server.mjs'
$nodePath = Join-Path $serviceRoot 'runtime\node-win-x64\node.exe'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Braintrust.lnk'
$startShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Braintrust\Braintrust.lnk'
$uninstallRegistry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust'
$sentinel = Join-Path $dataRoot 'acceptance-preserve.txt'
$sentinelText = 'Braintrust lifecycle acceptance ' + [Guid]::NewGuid().ToString('N')
$report = [ordered]@{
  startedAt = [DateTime]::UtcNow.ToString('o')
  mode = $(if ($PublicBaseline) { 'published-baseline' } else { 'source-candidate' })
  installerSha256 = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
  installerBytes = (Get-Item -LiteralPath $Installer).Length
  installDirectory = $installRoot
  os = [Environment]::OSVersion.VersionString
  browserMode = $(if ($env:BRAINTRUST_BROWSER_HEADLESS -eq '1') { 'headless' } else { 'headed' })
  checks = (New-Object System.Collections.Generic.List[object])
  observations = (New-Object System.Collections.Generic.List[object])
  limitations = @('A hosted Windows VM does not establish SmartScreen reputation or physical-device behavior.', 'Installer execution is automated; third-party account login and real AI responses require separate validation.')
}
$script:currentInfo = $null
$script:testFailed = $false
$script:completedUninstall = $false
$script:ownsTestInstallation = $false

function Write-Check([string]$Name, [bool]$Passed, [string]$Detail = '') {
  $report.checks.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail })
  if ($Passed) { Write-Host "PASS $Name $Detail" } else { Write-Host "FAIL $Name $Detail"; $script:testFailed = $true }
}

function Require([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Wait-Until([scriptblock]$Test, [string]$Description, [int]$Seconds = 45) {
  $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
  do {
    $result = & $Test
    if ($result) { return $result }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Timed out: $Description"
}

function Get-OwnedServers {
  $escaped = [regex]::Escape([IO.Path]::GetFullPath($serverPath))
  $argument = '(?i)(?:^|\s)(?:"' + $escaped + '"|' + $escaped + ')(?=\s|$)'
  @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    $_.Name -ieq 'node.exe' -and $_.CommandLine -and $_.CommandLine -match $argument
  })
}

function Get-ProfileBrowsers {
  $escaped = [regex]::Escape([IO.Path]::GetFullPath($profilePath))
  $argument = '(?i)(?:^|\s)(?:"--user-data-dir=' + $escaped + '"|--user-data-dir="' + $escaped + '"|--user-data-dir=' + $escaped + ')(?=\s|$)'
  @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    ($_.Name -ieq 'msedge.exe' -or $_.Name -ieq 'chrome.exe') -and $_.CommandLine -and $_.CommandLine -match $argument
  })
}

function Get-ProductLaunchers {
  $escaped = [regex]::Escape((Join-Path $serviceRoot 'launcher.ps1'))
  $argument = '(?i)(?:^|\s)(?:"' + $escaped + '"|' + $escaped + ')(?=\s|$)'
  @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    $_.Name -ieq 'powershell.exe' -and $_.CommandLine -and $_.CommandLine -match $argument
  })
}

function Get-WorkbenchTargetCount($Health) {
  $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$($Health.browser.port)/json/list" -TimeoutSec 5)
  $prefix = "http://127.0.0.1:$($script:currentInfo.port)/"
  return @($targets | Where-Object { $_.type -eq 'page' -and ([string]$_.url).StartsWith($prefix) }).Count
}

function Get-ReadyService {
  if (-not (Test-Path -LiteralPath $infoPath)) { return $null }
  try {
    $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $headers = @{ Authorization = "Bearer $($info.token)" }
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$($info.port)/api/health" -Headers $headers -TimeoutSec 2
    if (-not $health.ok -or -not $health.browser.running) { return $null }
    # Browser process creation precedes its CDP version endpoint becoming ready.
    $browserVersion = $health.browser.version
    if ($null -eq $browserVersion -or -not $browserVersion.PSObject.Properties['Browser'] -or -not ([string]$browserVersion.Browser)) { return $null }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$info.pid)" -ErrorAction Stop
    if (-not $process -or $process.ExecutablePath -ine $nodePath) { return $null }
    $script:currentInfo = $info
    return $health
  } catch { return $null }
}

function Invoke-BoundedProcess([string]$FilePath, [string]$Arguments, [int]$Seconds = 90) {
  $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
  if (-not $process.WaitForExit($Seconds * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Process exceeded ${Seconds}s: $([IO.Path]::GetFileName($FilePath))"
  }
  $process.Refresh()
  Require ($process.ExitCode -eq 0) "Process exited $($process.ExitCode): $([IO.Path]::GetFileName($FilePath))"
}

function Install-Product {
  # NSIS /D must be the final argument and is parsed as the remaining path, including spaces.
  $arguments = '/S'
  if ($InstallDirectory) { $arguments += ' /D=' + $installRoot }
  Invoke-BoundedProcess $Installer $arguments
}

function Start-DesktopProduct {
  Remove-Item Env:\BRAINTRUST_BROWSER_PATH -ErrorAction SilentlyContinue
  $wrapper = Start-Process -FilePath $desktopShortcut -PassThru
  # WSH returns after creating launcher.ps1; wait for that exact launcher too so
  # repeat-open assertions cannot pass merely by reading the previous health.
  if ($wrapper -and -not $wrapper.WaitForExit(10000)) { throw 'Desktop shortcut wrapper did not finish' }
  $health = Wait-Until { Get-ReadyService } 'desktop shortcut -> bundled Node -> auto-discovered browser' 60
  Wait-Until { @(Get-ProductLaunchers).Count -eq 0 } 'desktop launcher completion' 60 | Out-Null
  return (Wait-Until { Get-ReadyService } 'healthy service after launcher completion' 15)
}

function Quit-Product {
  $info = $script:currentInfo
  Require ($null -ne $info) 'No current service for quit'
  Invoke-RestMethod -Uri "http://127.0.0.1:$($info.port)/api/quit" -Method Post -Headers @{ Authorization = "Bearer $($info.token)" } -ContentType 'application/json' -Body '{}' -TimeoutSec 5 | Out-Null
  Wait-Until { -not (Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue) } 'service exit after quit' 20 | Out-Null
  Wait-Until { @(Get-ProfileBrowsers).Count -eq 0 } 'product browser exit after quit' 15 | Out-Null
}

function Test-InstalledUi([string]$Subdirectory, [switch]$Persistence) {
  if (-not $UiTest) { return }
  Require (Test-Path -LiteralPath $UiTest) 'Installed UI helper missing'
  $uiEvidence = Join-Path $Evidence $Subdirectory
  New-Item -ItemType Directory -Path $uiEvidence -Force | Out-Null
  $arguments = @($UiTest, '--service-info', $infoPath, '--evidence', $uiEvidence)
  if ($Persistence) { $arguments += '--verify-persistence' }
  & $nodePath @arguments
  Require ($LASTEXITCODE -eq 0) "Installed UI helper failed in $Subdirectory"
}

function Record-LiveProbes {
  if (-not $LiveProbe -or -not $UiTest) { return }
  $liveEvidence = Join-Path $Evidence 'unauthenticated-live'
  New-Item -ItemType Directory -Path $liveEvidence -Force | Out-Null
  try {
    & $nodePath $UiTest --service-info $infoPath --evidence $liveEvidence --live-probe
    $report.observations.Add([pscustomobject]@{ name = 'unauthenticated live platform probes'; helperExitCode = $LASTEXITCODE; affectsLifecycleVerdict = $false })
  } catch {
    $report.observations.Add([pscustomobject]@{ name = 'unauthenticated live platform probes'; error = $_.Exception.Message; affectsLifecycleVerdict = $false })
  }
}

function Save-FailureDiagnostics {
  $logRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\logs'
  foreach ($name in @('service.log', 'service.out.log', 'service.err.log')) {
    $source = Join-Path $logRoot $name
    if (-not (Test-Path -LiteralPath $source)) { continue }
    try {
      $content = (Get-Content -LiteralPath $source -Tail 600 -Encoding UTF8) -join "`r`n"
      if ($script:currentInfo -and ([string]$script:currentInfo.token).Length -ge 8) { $content = $content.Replace([string]$script:currentInfo.token, '[REDACTED]') }
      $content = $content -replace '(?i)(Bearer\s+)[A-Za-z0-9._~-]+', '$1[REDACTED]'
      $content = $content -replace '(?i)("token"\s*:\s*")[^"]+("|$)', '$1[REDACTED]$2'
      $content = $content -replace '[a-fA-F0-9]{48}', '[REDACTED]'
      Set-Content -LiteralPath (Join-Path $Evidence ('diagnostic-' + $name)) -Value $content -Encoding UTF8
    } catch {}
  }
}

function Uninstall-Product {
  $uninstaller = Join-Path $installRoot 'Uninstall.exe'
  Require (Test-Path -LiteralPath $uninstaller) 'Uninstaller missing'
  # A copied uninstaller with _?= runs synchronously and can delete its installed original.
  $copy = Join-Path $env:TEMP ('braintrust-uninstall-' + [Guid]::NewGuid().ToString('N') + '.exe')
  Copy-Item -LiteralPath $uninstaller -Destination $copy -Force
  try { Invoke-BoundedProcess $copy ('/S _?=' + $installRoot) 90 } finally { Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue }
}

function Cleanup-Product {
  # This helper is for ephemeral CI VMs only and targets the installation used in this run.
  if (Test-Path -LiteralPath (Join-Path $serviceRoot 'stop.ps1')) {
    try { & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $serviceRoot 'stop.ps1') -ServiceRoot $serviceRoot 2>$null | Out-Null } catch {}
  }
  try {
    foreach ($process in @(Get-OwnedServers)) {
      & taskkill.exe /PID ([string]$process.ProcessId) /T /F 2>$null | Out-Null
    }
  } catch {}
  if (-not $script:completedUninstall -and (Test-Path -LiteralPath (Join-Path $installRoot 'Uninstall.exe'))) {
    try { Uninstall-Product } catch {}
  }
}

try {
  Require ($env:CI -eq 'true') 'Run this installation acceptance script only on an ephemeral CI Windows VM (CI=true)'
  Require (-not (Test-Path -LiteralPath $serverPath)) 'Test installation already exists; refusing to overwrite unrelated work'
  Require (@(Get-OwnedServers).Count -eq 0) 'A service for this installation is already running'
  $script:ownsTestInstallation = $true
  Remove-Item Env:\BRAINTRUST_BROWSER_PATH -ErrorAction SilentlyContinue
  $env:BRAINTRUST_NO_DIALOG = '1'
  Install-Product
  foreach ($relative in @('server.mjs', 'package.json', 'launcher.ps1', 'launcher.vbs', 'stop.ps1', 'runtime\node-win-x64\node.exe', 'assets\AppIcon.ico', 'public\workbench-local.js')) {
    Require (Test-Path -LiteralPath (Join-Path $serviceRoot $relative)) "Missing installed file: $relative"
  }
  $shell = New-Object -ComObject WScript.Shell
  foreach ($path in @($desktopShortcut, $startShortcut)) {
    Require (Test-Path -LiteralPath $path) "Missing shortcut: $path"
    $shortcut = $shell.CreateShortcut($path)
    Require ($shortcut.TargetPath -like '*\wscript.exe') 'Shortcut does not use no-console VBS entry'
    Require ($shortcut.Arguments -eq ('"' + (Join-Path $serviceRoot 'launcher.vbs') + '"')) 'Shortcut has incorrect launcher arguments'
    Require ($shortcut.IconLocation -like ('*' + (Join-Path $serviceRoot 'assets\AppIcon.ico') + '*')) 'Shortcut icon missing'
  }
  $registry = Get-ItemProperty -LiteralPath $uninstallRegistry
  if ($ExpectedVersion) { Require ($registry.DisplayVersion -eq $ExpectedVersion) 'Uninstall registry version differs from expected candidate' }
  Write-Check 'silent per-user install and both shortcuts' $true

  $health = Start-DesktopProduct
  Require ([string]$health.browser.version.Browser -like 'Edg/*') 'Standard Edge was not automatically discovered'
  if ($ExpectedVersion) { Require ($health.version -eq $ExpectedVersion) 'Running version differs from expected candidate' }
  Write-Check 'desktop shortcut and bundled runtime with automatic Edge discovery' $true ([string]$health.browser.version.Browser)
  Record-LiveProbes
  Test-InstalledUi 'first-start'
  Write-Check 'installed workbench interaction and deterministic send' $true

  $firstPid = [int]$script:currentInfo.pid
  $workbenchCount = Get-WorkbenchTargetCount $health
  $health = Start-DesktopProduct
  Require ([int]$script:currentInfo.pid -eq $firstPid) 'Second shortcut invocation created another service'
  Require (@(Get-OwnedServers).Count -eq 1) 'Multiple installed service processes exist'
  Require ((Get-WorkbenchTargetCount $health) -eq $workbenchCount) 'Repeat shortcut opened duplicate workbench tabs'
  Write-Check 'reopen uses existing service' $true

  Quit-Product
  $health = Start-DesktopProduct
  Test-InstalledUi 'restart' -Persistence
  Write-Check 'quit restart and stored preferences' $true
  [IO.File]::WriteAllText($sentinel, $sentinelText)
  Require (Test-Path -LiteralPath (Join-Path $dataRoot 'browser-profile')) 'Persistent browser profile missing'

  $beforeUpgradePid = [int]$script:currentInfo.pid
  try {
    Install-Product
    Require (-not (Get-Process -Id $beforeUpgradePid -ErrorAction SilentlyContinue)) 'Running service survived installer upgrade'
    Wait-Until { @(Get-ProfileBrowsers).Count -eq 0 } 'product browser exit during upgrade' 15 | Out-Null
    Require ((Get-Content -LiteralPath $sentinel -Raw) -eq $sentinelText) 'Upgrade changed user data sentinel'
    $health = Start-DesktopProduct
    Test-InstalledUi 'upgrade' -Persistence
    Write-Check 'upgrade while running retains data and preferences' $true
  } catch {
    Write-Check 'upgrade while running retains data and preferences' $false $_.Exception.Message
    if (-not $PublicBaseline) { throw }
  }

  # No pre-quit here: this is deliberately the case omitted by the historical smoke test.
  $beforeUninstall = @(Get-OwnedServers | ForEach-Object { [int]$_.ProcessId })
  Uninstall-Product
  $script:completedUninstall = $true
  Wait-Until { -not (Test-Path -LiteralPath $serverPath) -and -not (Test-Path -LiteralPath $nodePath) } 'uninstaller removes program payload' 10 | Out-Null
  foreach ($processId in $beforeUninstall) { Require (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) 'Installed service survived uninstall' }
  Wait-Until { @(Get-ProfileBrowsers).Count -eq 0 } 'product browser exit during uninstall' 15 | Out-Null
  Require (-not (Test-Path -LiteralPath $desktopShortcut)) 'Desktop shortcut survived uninstall'
  Require (-not (Test-Path -LiteralPath $startShortcut)) 'Start Menu shortcut survived uninstall'
  Require (-not (Test-Path -LiteralPath $uninstallRegistry)) 'Uninstall registry entry survived uninstall'
  Require (-not (Test-Path -LiteralPath 'HKCU:\Software\Braintrust')) 'Installation registry entry survived uninstall'
  Require ((Test-Path -LiteralPath $sentinel) -and (Get-Content -LiteralPath $sentinel -Raw) -eq $sentinelText) 'Uninstall removed user data'
  Require (Test-Path -LiteralPath (Join-Path $dataRoot 'browser-profile')) 'Uninstall removed browser profile'
  Write-Check 'uninstall while running removes app and preserves user data' $true
} catch {
  Write-Check 'lifecycle completion' $false $_.Exception.Message
  $report.failure = $_.Exception.Message
  $report.failureStack = $_.ScriptStackTrace
  Save-FailureDiagnostics
} finally {
  if ($script:ownsTestInstallation) { Cleanup-Product }
  $report.finishedAt = [DateTime]::UtcNow.ToString('o')
  $report.passed = -not $script:testFailed
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Evidence 'lifecycle.json') -Encoding UTF8
}
if ($script:testFailed) { exit 1 }
exit 0
