[CmdletBinding()]
param(
  [string]$ServiceRoot = $PSScriptRoot,
  [string]$DataDir = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\data'),
  [ValidateRange(0, 15)][int]$GraceSeconds = 8
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# The installed launcher invokes node.exe followed immediately by this server script.
# A different Node tool merely receiving server.mjs as an input is not ours to stop.
$server = [IO.Path]::GetFullPath((Join-Path $ServiceRoot 'server.mjs'))
$escapedServer = [regex]::Escape($server)
$serverArgument = '(?i)^\s*(?:"[^"]+"|[^\s"]+)\s+(?:"' + $escapedServer + '"|' + $escapedServer + ')(?=\s|$)'

function Test-ProcessIdentity($Original, $Current) {
  return ($null -ne $Current -and $null -ne $Original.CreationDate -and
    $Current.CreationDate -eq $Original.CreationDate -and
    $Current.Name -eq $Original.Name -and
    [string]$Current.CommandLine -ceq [string]$Original.CommandLine)
}

function Get-LiveOwnedProcesses($Owned) {
  $current = @{}
  foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
    $current[[int]$process.ProcessId] = $process
  }
  foreach ($entry in $Owned) {
    $original = $entry.Process
    $processId = [int]$original.ProcessId
    if (-not $current.ContainsKey($processId)) { continue }
    $process = $current[$processId]
    # A recycled PID must never authorize terminating a different process.
    if (Test-ProcessIdentity $original $process) { $entry }
  }
}

try {
  $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
  $servers = @($processes | Where-Object {
    $_.Name -ieq 'node.exe' -and $_.CommandLine -and $_.CommandLine -match $serverArgument
  })
  if ($servers.Count -eq 0) { exit 0 }

  # Capture descendants before graceful exit reparents any remaining browser processes.
  $owned = New-Object System.Collections.Generic.List[object]
  $depths = @{}
  $captured = @{}
  foreach ($process in $servers) {
    $depths[[int]$process.ProcessId] = 0
    $captured[[int]$process.ProcessId] = $process
    $owned.Add([pscustomobject]@{ Process = $process; Depth = 0 })
  }
  do {
    $added = $false
    foreach ($process in $processes) {
      $processId = [int]$process.ProcessId
      $parentId = [int]$process.ParentProcessId
      if ($depths.ContainsKey($processId) -or -not $depths.ContainsKey($parentId)) { continue }
      # Old orphan processes may retain a parent PID now reused by this service.
      if ($null -eq $process.CreationDate -or $process.CreationDate -lt $captured[$parentId].CreationDate) { continue }
      $captured[$processId] = $process
      $depth = [int]$depths[$parentId] + 1
      $depths[$processId] = $depth
      $owned.Add([pscustomobject]@{ Process = $process; Depth = $depth })
      $added = $true
    }
  } while ($added)

  # Only contact a service whose recorded PID belongs to this exact installation.
  $serviceJson = Join-Path $DataDir 'service.json'
  if (Test-Path -LiteralPath $serviceJson) {
    try {
      $info = Get-Content -LiteralPath $serviceJson -Raw -Encoding UTF8 | ConvertFrom-Json
      $port = [int]$info.port
      $token = [string]$info.token
      $serverIds = @($servers | ForEach-Object { [int]$_.ProcessId })
      if ($serverIds -contains [int]$info.pid -and $port -gt 0 -and $port -le 65535 -and $token -match '^[a-fA-F0-9]{48}$') {
        Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/quit" -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body '{}' -TimeoutSec 3 | Out-Null
      }
    } catch {
      Write-Verbose 'Graceful shutdown unavailable; checking only the installed service process tree.'
    }
  }

  $deadline = [DateTime]::UtcNow.AddSeconds($GraceSeconds)
  do {
    $remaining = @(Get-LiveOwnedProcesses $owned)
    if ($remaining.Count -eq 0) { exit 0 }
    if ([DateTime]::UtcNow -ge $deadline) { break }
    Start-Sleep -Milliseconds 200
  } while ($true)

  # Fallback is limited to the captured installation tree, with PID reuse checks.
  foreach ($entry in @($remaining | Sort-Object Depth -Descending)) {
    $processId = [int]$entry.Process.ProcessId
    $current = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
    if (Test-ProcessIdentity $entry.Process $current) {
      Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(4)
  do {
    $remaining = @(Get-LiveOwnedProcesses $owned)
    if ($remaining.Count -eq 0) { exit 0 }
    Start-Sleep -Milliseconds 200
  } while ([DateTime]::UtcNow -lt $deadline)
  throw 'The installed Braintrust service did not stop. Close Braintrust and retry.'
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
