[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [Parameter(Mandatory = $true)][string]$Evidence,
  [string]$InstallDirectory = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$Evidence = [IO.Path]::GetFullPath($Evidence)
New-Item -ItemType Directory -Path $Evidence -Force | Out-Null
$installRoot = if ($InstallDirectory) { [IO.Path]::GetFullPath($InstallDirectory) } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust' }
$server = Join-Path $installRoot 'service\server.mjs'
$report = [ordered]@{
  startedAt = [DateTime]::UtcNow.ToString('o')
  mode = 'interactive-installer-wizard'
  status = 'failed'
  passed = $false
  installerSha256 = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
  installDirectory = $installRoot
  userInteractive = [Environment]::UserInteractive
  actions = (New-Object System.Collections.Generic.List[object])
  screenshots = (New-Object System.Collections.Generic.List[string])
  limitations = @('This checks NSIS wizard buttons on a hosted Windows desktop, not SmartScreen reputation or physical consumer Windows.', 'No security dialog is accepted or bypassed. Installation auto-launch may open the product, but this helper sends no AI messages.')
}
$process = $null
$exitCode = 1
$script:screenshotNumber = 0

function Save-Desktop([string]$Label) {
  try {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($bounds.Width -le 0 -or $bounds.Height -le 0) { return }
    $bitmap = [System.Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
      $script:screenshotNumber++
      $name = '{0:D2}-{1}.png' -f $script:screenshotNumber, $Label
      $bitmap.Save((Join-Path $Evidence $name), [System.Drawing.Imaging.ImageFormat]::Png)
      $report.screenshots.Add($name)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
  } catch { $report.screenshotError = $_.Exception.Message }
}

function Get-InstallerWindow {
  # Never select a window by title alone: browsers and security dialogs are excluded.
  $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$process.Id)
  $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
  foreach ($window in $windows) {
    if (-not $window.Current.IsOffscreen -and $window.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window) { return $window }
  }
  return $null
}

function Get-WizardButtons($Window) {
  $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
  $buttons = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
  foreach ($button in $buttons) {
    try {
      if ($button.Current.IsEnabled -and -not $button.Current.IsOffscreen) { $button }
    } catch {}
  }
}

try {
  if ($env:CI -ne 'true') { throw 'Run this helper only on an ephemeral CI Windows VM (CI=true)' }
  if (Test-Path -LiteralPath $server) { throw 'Test installation already exists; refusing to overwrite it' }
  if (Test-Path -LiteralPath 'HKCU:\Software\Braintrust') { throw 'An existing Braintrust installation is registered; use a fresh VM' }
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
  if (-not [Environment]::UserInteractive) {
    $report.status = 'unsupported'
    $exitCode = 2
    throw 'No interactive user desktop is available; the wizard was not tested'
  }
  $arguments = if ($InstallDirectory) { '/D=' + $installRoot } else { '' }
  if ($arguments) { $process = Start-Process -FilePath $Installer -ArgumentList $arguments -PassThru }
  else { $process = Start-Process -FilePath $Installer -PassThru }
  $report.installerPid = $process.Id
  $deadline = [DateTime]::UtcNow.AddSeconds(150)
  $windowDeadline = [DateTime]::UtcNow.AddSeconds(25)
  $sawWindow = $false
  $sawForward = $false
  $sawFinish = $false
  $lastClick = [DateTime]::MinValue
  $lastName = ''
  while ([DateTime]::UtcNow -lt $deadline) {
    $process.Refresh()
    if ($process.HasExited) { break }
    $window = Get-InstallerWindow
    if (-not $window) {
      if (-not $sawWindow -and [DateTime]::UtcNow -ge $windowDeadline) {
        $report.status = 'unsupported'
        $exitCode = 2
        throw 'No process-owned interactive installer window appeared; no buttons were invoked'
      }
      Start-Sleep -Milliseconds 200
      continue
    }
    if (-not $sawWindow) { $sawWindow = $true; Save-Desktop 'welcome' }
    $buttons = @(Get-WizardButtons $window)
    $report.lastWindow = [ordered]@{ name = $window.Current.Name; buttons = @($buttons | ForEach-Object { $_.Current.Name }) }
    $chosen = $null
    $kind = ''
    foreach ($button in $buttons) {
      $name = ([string]$button.Current.Name).Replace('&', '').Trim()
      if ($name -match '^(Finish|完成|Close|关闭)(?:\s|\(|（|$)' -and $sawForward -and (Test-Path -LiteralPath $server)) {
        $chosen = $button; $kind = 'finish'; break
      }
      if ($name -match '^(Next|下一步|Install|安装)(?:\s|\(|（|>|$)') {
        $chosen = $button; $kind = 'forward'
      }
    }
    if ($chosen) {
      $name = [string]$chosen.Current.Name
      # Wait for page transitions rather than double-invoking a still-visible button.
      if ($name -ne $lastName -or ([DateTime]::UtcNow - $lastClick).TotalSeconds -ge 2) {
        if ($report.actions.Count -ge 8) { throw 'Unexpected installer page loop; refusing additional clicks' }
        Save-Desktop $kind
        $pattern = $null
        if (-not $chosen.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { throw "Wizard button does not support InvokePattern: $name" }
        $report.actions.Add([ordered]@{ at = [DateTime]::UtcNow.ToString('o'); kind = $kind; button = $name; processId = $process.Id })
        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        if ($kind -eq 'finish') { $sawFinish = $true } else { $sawForward = $true }
        $lastName = $name; $lastClick = [DateTime]::UtcNow
      }
    }
    Start-Sleep -Milliseconds 200
  }
  $process.Refresh()
  if (-not $process.HasExited) { throw 'Installer wizard exceeded 150 seconds' }
  $process.WaitForExit()
  $process.Refresh()
  $report.installerExitCode = $process.ExitCode
  if ($process.ExitCode -ne 0) { throw "Installer exited $($process.ExitCode)" }
  if (-not $sawWindow -or -not $sawForward -or -not $sawFinish) { throw 'Installer did not complete the observed welcome/install/finish interaction' }
  if (-not (Test-Path -LiteralPath $server)) { throw 'Installer closed without creating the expected product files' }
  foreach ($relative in @('Uninstall.exe', 'service\launcher.vbs', 'service\runtime\node-win-x64\node.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot $relative))) { throw "Installed file missing: $relative" }
  }
  Save-Desktop 'completed'
  $report.passed = $true
  $report.status = 'passed'
  $exitCode = 0
  Write-Host 'PASS interactive NSIS welcome/install/finish wizard'
} catch {
  $report.error = $_.Exception.Message
  $report.scriptStackTrace = $_.ScriptStackTrace
  if ($report.status -ne 'unsupported') { $report.status = 'failed' }
  if ($env:CI -eq 'true') { Save-Desktop 'failure' }
  Write-Host ("{0}: {1}" -f $report.status.ToUpperInvariant(), $_.Exception.Message)
} finally {
  # Only the installer process started by this helper may be stopped on failure.
  # Installed app/data are left for the caller's explicit lifecycle cleanup.
  if ($null -ne $process) {
    try { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } } catch {}
  }
  $report.finishedAt = [DateTime]::UtcNow.ToString('o')
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Evidence 'installer-wizard.json') -Encoding UTF8
}
exit $exitCode
