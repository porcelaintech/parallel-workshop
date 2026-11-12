[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [Parameter(Mandatory = $true)][string]$Evidence
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$started = [DateTime]::UtcNow
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$Evidence = [IO.Path]::GetFullPath($Evidence)
New-Item -ItemType Directory -Path $Evidence -Force | Out-Null
$report = [ordered]@{
  startedAt = $started.ToString('o')
  mode = 'downloaded-installer-observation-only'
  status = 'observation-incomplete'
  installerSha256 = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
  installerBytes = (Get-Item -LiteralPath $Installer).Length
  observations = @()
  limitations = @('Observation only: no prompt or installer button is invoked, and no file is unblocked.', 'A missing window or blocked ShellExecute does not by itself prove SmartScreen caused the delay.', 'The actual installer may remain open for VM teardown; only helper-owned PowerShell children are stopped.')
}
$children = New-Object System.Collections.Generic.List[object]
$childOutput = @{}
$work = Join-Path $env:TEMP ('braintrust-observe-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$launchResult = Join-Path $work 'launch.json'
$signatureResult = Join-Path $work 'signature.json'
$sampleResult = Join-Path $work 'samples.json'

function Quote-PS([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }

function Start-ObserverChild([string]$Script, [string]$Name) {
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
  $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $info
  if (-not $process.Start()) { throw 'Cannot start bounded observation child' }
  $children.Add($process)
  $childOutput[$process.Id] = @{ name=$Name; stdout=$process.StandardOutput.ReadToEndAsync(); stderr=$process.StandardError.ReadToEndAsync() }
  return $process
}

function Read-ChildJson([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
  }
  return $null
}

try {
  if ($env:CI -ne 'true') { throw 'Run this observer only on an ephemeral CI Windows VM (CI=true)' }
  try {
    $zone = Get-Content -LiteralPath $Installer -Stream Zone.Identifier -Raw -ErrorAction Stop
    # Preserve zone fields while excluding signed URL query strings from evidence.
    $zone = [regex]::Replace($zone, '(?im)^(HostUrl|ReferrerUrl)=(.+)$', {
      param($match)
      try { $url = [Uri]$match.Groups[2].Value.Trim(); return $match.Groups[1].Value + '=' + $url.GetLeftPart([UriPartial]::Path) }
      catch { return $match.Groups[1].Value + '=[unparsed URL omitted]' }
    })
    $report.zoneIdentifier = $zone.Substring(0, [Math]::Min(4096, $zone.Length))
    $report.zoneIdentifierPresent = $true
  } catch { $report.zoneIdentifierPresent = $false; $report.zoneIdentifierReadError = $_.Exception.Message }

  $signatureScript = @'
$ErrorActionPreference='Stop'
try {
  $signature=Get-AuthenticodeSignature -LiteralPath __INSTALLER__
  @{ status=[string]$signature.Status; message=[string]$signature.StatusMessage } | ConvertTo-Json | Set-Content -LiteralPath __SIGNATURE_RESULT__ -Encoding UTF8
} catch { @{ error=$_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath __SIGNATURE_RESULT__ -Encoding UTF8 }
'@
  $signatureScript = $signatureScript.Replace('__INSTALLER__', (Quote-PS $Installer)).Replace('__SIGNATURE_RESULT__', (Quote-PS $signatureResult))
  $signatureChild = Start-ObserverChild $signatureScript 'signature'

  $launchScript = @'
$ErrorActionPreference='Stop'
try {
  $process=Start-Process -FilePath __INSTALLER__ -PassThru
  @{ returned=$true; pid=$process.Id; returnedAt=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath __LAUNCH_RESULT__ -Encoding UTF8
} catch { @{ returned=$true; error=$_.Exception.Message; returnedAt=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath __LAUNCH_RESULT__ -Encoding UTF8 }
'@
  $launchScript = $launchScript.Replace('__INSTALLER__', (Quote-PS $Installer)).Replace('__LAUNCH_RESULT__', (Quote-PS $launchResult))
  $launchChild = Start-ObserverChild $launchScript 'installer-launch'
  $report.launchHelperPid = $launchChild.Id

  # Independent screen and UIA children ensure a failed/hung UI provider cannot
  # prevent screenshots or make the parent exceed the observation deadline.
  $screenScript = @'
$ErrorActionPreference='Stop'
$sampleStart=[DateTime]::UtcNow
$screens=New-Object System.Collections.Generic.List[object]
try {
  Add-Type -AssemblyName System.Windows.Forms,System.Drawing
  foreach($second in @(3,10)) {
    while(([DateTime]::UtcNow-$sampleStart).TotalSeconds -lt $second) { Start-Sleep -Milliseconds 100 }
    $sample=[ordered]@{ at=[DateTime]::UtcNow.ToString('o');elapsedSeconds=([DateTime]::UtcNow-$sampleStart).TotalSeconds;userInteractive=[Environment]::UserInteractive }
    try {
      $bounds=[System.Windows.Forms.SystemInformation]::VirtualScreen
      $bitmap=[System.Drawing.Bitmap]::new([int]$bounds.Width,[int]$bounds.Height)
      $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size)
        $name='desktop-'+$second+'s.png'
        $bitmap.Save((Join-Path __EVIDENCE__ $name),[System.Drawing.Imaging.ImageFormat]::Png)
        $sample.screenshot=$name
      } finally { $graphics.Dispose();$bitmap.Dispose() }
    } catch { $sample.error=$_.Exception.Message;$sample.scriptStackTrace=$_.ScriptStackTrace }
    $screens.Add($sample)
    @{samples=$screens.ToArray()} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath __SCREEN_RESULT__ -Encoding UTF8
  }
} catch {
  @{error=$_.Exception.Message;scriptStackTrace=$_.ScriptStackTrace;samples=$screens.ToArray()} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath __SCREEN_RESULT__ -Encoding UTF8
  [Console]::Error.WriteLine($_.ToString())
  exit 1
}
'@
  $screenResult = Join-Path $work 'screens.json'
  $screenScript = $screenScript.Replace('__SCREEN_RESULT__', (Quote-PS $screenResult)).Replace('__EVIDENCE__', (Quote-PS $Evidence))
  $screenChild = Start-ObserverChild $screenScript 'desktop-screenshots'

  $sampleScript = @'
$ErrorActionPreference='Stop'
$sampleStart=[DateTime]::UtcNow
$samples=New-Object System.Collections.Generic.List[object]
try {
  Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
  foreach($second in @(3,10)) {
    while(([DateTime]::UtcNow-$sampleStart).TotalSeconds -lt $second) { Start-Sleep -Milliseconds 100 }
    $sample=[ordered]@{at=[DateTime]::UtcNow.ToString('o');elapsedSeconds=([DateTime]::UtcNow-$sampleStart).TotalSeconds;userInteractive=[Environment]::UserInteractive;windows=@()}
    # Persist before querying UIA, so a provider hang leaves a partial observation.
    $samples.Add($sample)
    @{supported=$true;samples=$samples.ToArray()} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath __SAMPLE_RESULT__ -Encoding UTF8
    try {
      $root=[System.Windows.Automation.AutomationElement]::RootElement
      $windows=$root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
      $matched=New-Object System.Collections.Generic.List[object]
      $knownPid=0
      if(Test-Path -LiteralPath __LAUNCH_RESULT__) { try { $knownPid=[int](Get-Content -LiteralPath __LAUNCH_RESULT__ -Raw | ConvertFrom-Json).pid } catch {} }
      foreach($window in $windows) {
        try {
          if($window.Current.IsOffscreen) { continue }
          $ownerId=[int]$window.Current.ProcessId
          $owner=Get-Process -Id $ownerId -ErrorAction SilentlyContinue
          if(-not $owner) { continue }
          $title=[string]$window.Current.Name
          $isInstaller=($ownerId -eq $knownPid -and $knownPid -gt 0) -or $owner.ProcessName -ieq __INSTALLER_NAME__
          $isSafety=$owner.ProcessName -match '^(smartscreen|consent)$' -or $title -match '(?i)SmartScreen|Windows protected|Windows 已保护|Windows已经保护|Microsoft Defender|Security Warning|安全警告|无法验证发布者'
          if(-not $isInstaller -and -not $isSafety) { continue }
          $texts=New-Object System.Collections.Generic.List[object]
          $controls=$window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
          foreach($control in $controls) {
            if($texts.Count -ge 100) { break }
            try {
              if($control.Current.IsOffscreen) { continue }
              $kind=$control.Current.ControlType.ProgrammaticName
              if($kind -notin @('ControlType.Text','ControlType.Button')) { continue }
              $text=[string]$control.Current.Name
              if($text) { $texts.Add(@{kind=$kind;text=$text.Substring(0,[Math]::Min(400,$text.Length));enabled=$control.Current.IsEnabled}) }
            } catch {}
          }
          $matched.Add(@{processId=$ownerId;processName=$owner.ProcessName;title=$title;classification=$(if($isSafety){'security-prompt'}else{'installer-wizard'});controls=$texts.ToArray()})
        } catch { [Console]::Error.WriteLine('Window read: '+$_.Exception.Message) }
      }
      $sample.windows=$matched.ToArray()
      $sample.uiQueryCompleted=$true
    } catch { $sample.uiAutomationError=$_.Exception.Message;$sample.scriptStackTrace=$_.ScriptStackTrace }
    @{supported=$true;samples=$samples.ToArray()} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath __SAMPLE_RESULT__ -Encoding UTF8
  }
} catch {
  @{supported=$false;error=$_.Exception.Message;scriptStackTrace=$_.ScriptStackTrace;samples=$samples.ToArray()} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath __SAMPLE_RESULT__ -Encoding UTF8
  [Console]::Error.WriteLine($_.ToString())
  exit 1
}
'@
  $sampleScript = $sampleScript.Replace('__SAMPLE_RESULT__', (Quote-PS $sampleResult)).Replace('__LAUNCH_RESULT__', (Quote-PS $launchResult)).Replace('__INSTALLER_NAME__', (Quote-PS ([IO.Path]::GetFileNameWithoutExtension($Installer))))
  $sampleChild = Start-ObserverChild $sampleScript 'ui-automation'
  $deadline = $started.AddSeconds(28)
  do {
    $sampleChild.Refresh()
    $screenChild.Refresh()
    # A failed UI child must not end observation before both screenshot deadlines.
    if (([DateTime]::UtcNow-$started).TotalSeconds -ge 12 -and $sampleChild.HasExited -and $screenChild.HasExited) { break }
    Start-Sleep -Milliseconds 150
  } while ([DateTime]::UtcNow -lt $deadline)

  $report.launch = Read-ChildJson $launchResult
  if ($null -eq $report.launch) { $report.launch = @{ returned=$false; observation='Start-Process did not return during the bounded observation window' } }
  $report.authenticode = Read-ChildJson $signatureResult
  if ($null -eq $report.authenticode) { $report.authenticode = @{ status='unavailable-within-deadline' } }
  $report.screenshots = Read-ChildJson $screenResult
  $samples = Read-ChildJson $sampleResult
  if ($null -ne $samples) {
    $report.observations = @($samples.samples)
    $report.uiAutomationSupported = $samples.supported
    if ($samples.PSObject.Properties.Name -contains 'error') { $report.uiAutomationError = $samples.error; $report.uiAutomationStackTrace = $samples.scriptStackTrace }
    $classes = @($report.observations | ForEach-Object { $_.windows } | ForEach-Object { $_.classification })
    if ($classes -contains 'security-prompt') { $report.status = 'security-prompt-observed' }
    elseif ($classes -contains 'installer-wizard') { $report.status = 'installer-wizard-observed' }
    elseif (-not $samples.supported -or -not [Environment]::UserInteractive) { $report.status = 'unsupported-desktop' }
    elseif (@($report.observations | Where-Object { -not ($_.PSObject.Properties.Name -contains 'uiQueryCompleted') -or -not $_.uiQueryCompleted }).Count -gt 0) { $report.status = 'ui-observation-incomplete-within-deadline' }
    else { $report.status = 'no-ui-observed' }
  } else { $report.status = 'ui-observation-incomplete-within-deadline' }
} catch {
  $report.error = $_.Exception.Message
  $report.status = 'observation-error'
} finally {
  $diagnostics = New-Object System.Collections.Generic.List[object]
  foreach ($child in $children) {
    $diagnostic = [ordered]@{pid=$child.Id;name=$childOutput[$child.Id].name}
    try {
      $child.Refresh()
      $diagnostic.runningAtDeadline = -not $child.HasExited
      if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(500)}
      $child.Refresh()
      if($child.HasExited){$diagnostic.exitCode=$child.ExitCode}
      foreach($stream in @('stdout','stderr')) {
        $task=$childOutput[$child.Id][$stream]
        if($task.IsCompleted -and -not $task.IsFaulted -and -not $task.IsCanceled) {
          $value=[string]$task.Result
          $diagnostic[$stream]=$value.Substring(0,[Math]::Min(12000,$value.Length))
        } else { $diagnostic[$stream]='[stream not complete within bounded cleanup]' }
      }
    } catch { $diagnostic.error=$_.Exception.Message }
    $diagnostics.Add($diagnostic)
    try { $child.Dispose() } catch {}
  }
  $report.childDiagnostics=$diagnostics.ToArray()
  $report.finishedAt = [DateTime]::UtcNow.ToString('o')
  $report.elapsedSeconds = ([DateTime]::UtcNow - $started).TotalSeconds
  $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Evidence 'downloaded-installer-observation.json') -Encoding UTF8
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ('OBSERVED '+$report.status)
if ($report.status -eq 'observation-error') { exit 1 }
exit 0
