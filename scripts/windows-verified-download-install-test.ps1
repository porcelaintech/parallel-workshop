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
$expectedHash = '5b25f75d70ce9c20c5aa11513048e47af475258b488f8cab5be6463229a5ac65'
$expectedName = 'public-setup.exe'
$children = New-Object System.Collections.Generic.List[object]
$childTasks = @{}
$work = Join-Path $env:TEMP ('braintrust-verified-install-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$launchResult = Join-Path $work 'launch.json'
$report = [ordered]@{
  startedAt = $started.ToString('o')
  mode = 'verified-browser-download-install'
  passed = $false
  status = 'failed'
  expectedSha256 = $expectedHash
  runAcknowledged = $false
  warningObservations = (New-Object System.Collections.Generic.List[object])
  limitations = @('Only the ordinary Run button for this exact SHA-verified installer is acknowledged.', 'No checkbox, security setting, file download mark, SmartScreen window, or UAC prompt is changed.', 'This hosted Windows desktop test does not establish consumer Windows SmartScreen reputation.')
}
$exitCode = 1

function Quote-PS([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
function Get-VerifiedHash { return (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant() }
function Read-Result([string]$Path) {
  if (Test-Path -LiteralPath $Path) { try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }
  return $null
}
function Start-OwnedChild([string]$Script, [string]$Name) {
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $child = New-Object System.Diagnostics.Process
  $child.StartInfo = $info
  if (-not $child.Start()) { throw 'Cannot start controlled installation helper' }
  $children.Add($child)
  $childTasks[$child.Id] = @{name=$Name;stdout=$child.StandardOutput.ReadToEndAsync();stderr=$child.StandardError.ReadToEndAsync()}
  return $child
}
function Save-Screen([string]$Name) {
  try {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = [System.Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$bitmap.Size);$bitmap.Save((Join-Path $Evidence $Name),[System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $graphics.Dispose();$bitmap.Dispose() }
  } catch { $report.screenshotError=$_.Exception.Message }
}

try {
  if ($env:CI -ne 'true') { throw 'Run only on a fresh ephemeral CI Windows VM (CI=true)' }
  if ([IO.Path]::GetFileName($Installer) -ine $expectedName) { throw 'This test only acknowledges the expected public-setup.exe browser download' }
  $report.installerSha256 = Get-VerifiedHash
  if ($report.installerSha256 -ne $expectedHash) { throw 'Browser download does not match the exact known installer SHA-256' }
  $zoneBefore = Get-Content -LiteralPath $Installer -Stream Zone.Identifier -Raw -ErrorAction Stop
  if ($zoneBefore -notmatch '(?m)^ZoneId=3\s*$') { throw 'Expected retained Internet download mark ZoneId=3 is missing' }
  $report.zoneId = 3
  if (Test-Path -LiteralPath 'HKCU:\Software\Braintrust') { throw 'An existing product installation is registered; use a fresh VM' }
  $wizard = Join-Path $PSScriptRoot 'windows-installer-wizard-test.ps1'
  if (-not (Test-Path -LiteralPath $wizard)) { throw 'Installer wizard helper missing' }
  Add-Type -AssemblyName System.Windows.Forms,System.Drawing
  if (-not [Environment]::UserInteractive) { throw 'Interactive desktop unavailable; no warning can be acknowledged' }
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public sealed class BraintrustDialogControl {
  public IntPtr Handle; public string Text; public string ClassName; public bool Enabled;
}
public sealed class BraintrustOwnedDialog {
  public IntPtr Handle; public string Title; public BraintrustDialogControl[] Controls;
}
public static class BraintrustVerifiedDialog {
  private delegate bool EnumProc(IntPtr window, IntPtr state);
  [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr state);
  [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr state);
  [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window,StringBuilder value,int size);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window,StringBuilder value,int size);
  [DllImport("user32.dll",CharSet=CharSet.Unicode,ExactSpelling=true,EntryPoint="SendMessageTimeoutW")] private static extern IntPtr TextMessage(IntPtr window,uint message,UIntPtr count,StringBuilder value,uint flags,uint timeout,out UIntPtr result);
  [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",ExactSpelling=true)] private static extern IntPtr ValueMessage(IntPtr window,uint message,UIntPtr wParam,IntPtr lParam,uint flags,uint timeout,out UIntPtr result);
  private static string Text(IntPtr window) {
    StringBuilder value=new StringBuilder(8192);UIntPtr result;
    if(TextMessage(window,0x000D,new UIntPtr(8192),value,3,100,out result)==IntPtr.Zero) return "";
    return value.ToString();
  }
  public static BraintrustOwnedDialog[] Windows(uint processId) {
    List<BraintrustOwnedDialog> found=new List<BraintrustOwnedDialog>();
    EnumWindows(delegate(IntPtr window,IntPtr state) {
      uint owner;GetWindowThreadProcessId(window,out owner);
      if(owner!=processId||!IsWindowVisible(window))return true;
      StringBuilder title=new StringBuilder(512);GetWindowText(window,title,title.Capacity);
      List<BraintrustDialogControl> controls=new List<BraintrustDialogControl>();
      EnumChildWindows(window,delegate(IntPtr control,IntPtr unused) {
        if(controls.Count>=50||!IsWindowVisible(control))return true;
        StringBuilder kind=new StringBuilder(256);GetClassName(control,kind,kind.Capacity);
        controls.Add(new BraintrustDialogControl{Handle=control,Text=Text(control),ClassName=kind.ToString(),Enabled=IsWindowEnabled(control)});
        return true;
      },IntPtr.Zero);
      found.Add(new BraintrustOwnedDialog{Handle=window,Title=title.ToString(),Controls=controls.ToArray()});return true;
    },IntPtr.Zero);
    return found.ToArray();
  }
  public static bool RunOnce(IntPtr window,uint ownerId,string expectedName) {
    foreach(BraintrustOwnedDialog dialog in Windows(ownerId)) {
      if(dialog.Handle!=window||dialog.Title!="Open File - Security Warning")continue;
      bool nameMatches=false;BraintrustDialogControl run=null;
      foreach(BraintrustDialogControl control in dialog.Controls) {
        if(control.Text.IndexOf(expectedName,StringComparison.OrdinalIgnoreCase)>=0)nameMatches=true;
        if(control.ClassName=="Button"&&control.Enabled&&control.Text.Replace("&","").Trim()=="Run")run=control;
      }
      if(!nameMatches||run==null)return false;
      UIntPtr result;
      // BM_CLICK, with a bounded wait; no checkbox or alternate prompt is touched.
      return ValueMessage(run.Handle,0x00F5,UIntPtr.Zero,IntPtr.Zero,3,3000,out result)!=IntPtr.Zero;
    }
    return false;
  }
}
'@
  $launchScript = @'
$ErrorActionPreference='Stop'
try {
  $process=Start-Process -FilePath __INSTALLER__ -PassThru
  @{pid=$process.Id;returnedAt=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath __RESULT__ -Encoding UTF8
} catch { @{error=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath __RESULT__ -Encoding UTF8;exit 1 }
'@
  $launchScript=$launchScript.Replace('__INSTALLER__',(Quote-PS $Installer)).Replace('__RESULT__',(Quote-PS $launchResult))
  $launcher=Start-OwnedChild $launchScript 'download-launch'
  $report.launcherPid=$launcher.Id
  $launchDeadline=$started.AddSeconds(45)
  $launched=$null
  while([DateTime]::UtcNow -lt $launchDeadline) {
    $launched=Read-Result $launchResult
    if($launched) { break }
    $dialogs=[BraintrustVerifiedDialog]::Windows([uint32]$launcher.Id)
    foreach($dialog in $dialogs) {
      $details=[ordered]@{title=$dialog.Title;ownerPid=$launcher.Id;controls=@($dialog.Controls | ForEach-Object { @{text=$_.Text;className=$_.ClassName;enabled=$_.Enabled} })}
      if($report.warningObservations.Count -lt 3){$report.warningObservations.Add($details)}
      if($dialog.Title -cne 'Open File - Security Warning') { throw 'Unrecognized launcher-owned dialog; no button acknowledged' }
      $texts=($dialog.Controls | ForEach-Object {$_.Text}) -join "`n"
      if($texts.IndexOf($expectedName,[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'Warning text does not identify the exact expected downloaded filename' }
      $run=@($dialog.Controls | Where-Object {$_.ClassName -ceq 'Button' -and $_.Enabled -and $_.Text.Replace('&','').Trim() -ceq 'Run'})
      if($run.Count -ne 1) { throw 'Exact Run button is absent or ambiguous; no button acknowledged' }
      if($report.runAcknowledged) { continue }
      if((Get-VerifiedHash) -ne $expectedHash) { throw 'Installer SHA changed before acknowledgment' }
      Save-Screen 'download-warning-before-run.png'
      $report.runAcknowledgmentAttempted=$true
      if(-not [BraintrustVerifiedDialog]::RunOnce($dialog.Handle,[uint32]$launcher.Id,$expectedName)) { throw 'Run acknowledgment did not complete within the bounded native message' }
      $report.runAcknowledged=$true
      $report.runAcknowledgedAt=[DateTime]::UtcNow.ToString('o')
    }
    Start-Sleep -Milliseconds 200
  }
  if(-not $launched) { throw 'Verified installer launch did not return within 45 seconds' }
  if($launched.PSObject.Properties.Name -contains 'error') { throw ('Installer launch failed: '+$launched.error) }
  $installerPid=[int]$launched.pid
  if($installerPid -le 0) { throw 'Installer process ID missing after launch' }
  $report.installerPid=$installerPid
  $zoneAfter=Get-Content -LiteralPath $Installer -Stream Zone.Identifier -Raw -ErrorAction Stop
  if($zoneAfter -cne $zoneBefore) { throw 'Download mark changed unexpectedly; test requires it to remain unchanged' }
  $report.downloadMarkUnchanged=$true
  Save-Screen 'installer-after-run.png'
  $wizardEvidence=Join-Path $Evidence 'wizard'
  $wizardScript='& '+(Quote-PS $wizard)+' -Installer '+(Quote-PS $Installer)+' -Evidence '+(Quote-PS $wizardEvidence)+' -ExistingInstallerProcessId '+$installerPid+' -TimeoutSeconds 110; exit $LASTEXITCODE'
  $wizardChild=Start-OwnedChild $wizardScript 'existing-installer-wizard'
  $remaining=[Math]::Max(1000,[int]($started.AddSeconds(175)-[DateTime]::UtcNow).TotalMilliseconds)
  if(-not $wizardChild.WaitForExit($remaining)) { throw 'Whole verified download/install flow exceeded its bounded deadline' }
  $wizardChild.Refresh()
  $report.wizardHelperExitCode=$wizardChild.ExitCode
  $wizardResult=Read-Result (Join-Path $wizardEvidence 'installer-wizard.json')
  $report.wizard=$wizardResult
  if($wizardChild.ExitCode -ne 0 -or -not $wizardResult -or -not $wizardResult.passed) { throw 'Existing verified installer wizard did not complete successfully' }
  $report.passed=$true
  $report.status='passed'
  $exitCode=0
  Write-Host 'PASS actual browser download -> retained security warning -> exact Run acknowledgment -> installer wizard'
} catch {
  $report.error=$_.Exception.Message
  $report.scriptStackTrace=$_.ScriptStackTrace
  if($env:CI -eq 'true') { Save-Screen 'verified-install-failure.png' }
  Write-Host ('FAIL '+$_.Exception.Message)
} finally {
  $diagnostics=New-Object System.Collections.Generic.List[object]
  foreach($child in $children) {
    $entry=[ordered]@{pid=$child.Id;name=$childTasks[$child.Id].name}
    try {
      $child.Refresh();$entry.runningAtDeadline=-not $child.HasExited
      if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(500)}
      $child.Refresh();if($child.HasExited){$entry.exitCode=$child.ExitCode}
      foreach($stream in @('stdout','stderr')) {
        $task=$childTasks[$child.Id][$stream]
        if($task.IsCompleted -and -not $task.IsFaulted -and -not $task.IsCanceled){$value=[string]$task.Result;$entry[$stream]=$value.Substring(0,[Math]::Min(12000,$value.Length))}
        else{$entry[$stream]='[stream not complete within bounded cleanup]'}
      }
    } catch {$entry.error=$_.Exception.Message}
    $diagnostics.Add($entry);try{$child.Dispose()}catch{}
  }
  $report.childDiagnostics=$diagnostics.ToArray()
  $report.warningObservations=$report.warningObservations.ToArray()
  $report.finishedAt=[DateTime]::UtcNow.ToString('o')
  $report.elapsedSeconds=([DateTime]::UtcNow-$started).TotalSeconds
  $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $Evidence 'verified-download-install.json') -Encoding UTF8
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exitCode
