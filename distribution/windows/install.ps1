[CmdletBinding()]
param(
  [switch]$NoLaunch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms | Out-Null

function Show-Error([string]$Message) {
  [Console]::Error.WriteLine($Message)
  if ($env:CI -eq 'true' -or $env:BRAINTRUST_NO_DIALOG -eq '1') { return }
  try { [System.Windows.Forms.MessageBox]::Show($Message, '智囊 · 安装失败', 'OK', 'Error') | Out-Null } catch {}
}

function Test-TcpPort([int]$Port) {
  $client = New-Object Net.Sockets.TcpClient
  try {
    $pending = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    if (-not $pending.AsyncWaitHandle.WaitOne(150)) { return $false }
    $client.EndConnect($pending)
    return $true
  } catch { return $false } finally { $client.Close() }
}

try {
  $Source = Join-Path $PSScriptRoot 'local-service'
  if (-not (Test-Path -LiteralPath (Join-Path $Source 'server.mjs'))) { throw '安装包不完整：找不到 local-service\server.mjs。请重新下载完整 zip。' }
  if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'launcher.ps1'))) { throw '安装包不完整：launcher.ps1 缺失。' }
  if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'assets\AppIcon.ico'))) { throw '安装包不完整：assets\AppIcon.ico 缺失。' }

  $InstallRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\service'
  $Data = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\data'
  $LogDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\logs'
  New-Item -ItemType Directory -Path (Split-Path -Parent $InstallRoot) -Force | Out-Null
  New-Item -ItemType Directory -Path $Data -Force | Out-Null
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

  Write-Host "==> 安装智囊"
  Write-Host "    服务：$InstallRoot"
  Write-Host "    数据：$Data"

  # 停掉旧服务，避免覆盖正在运行的 server.mjs。
  try {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -like "*$InstallRoot*server.mjs*" } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
  } catch {}

  Write-Host "==> 复制程序文件"
  $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
  & $robocopy $Source $InstallRoot /MIR /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  if ($LASTEXITCODE -gt 7) { throw "复制失败（robocopy 退出码 $LASTEXITCODE）" }

  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'launcher.ps1') -Destination (Join-Path $InstallRoot 'launcher.ps1') -Force
  $icons = Join-Path $InstallRoot 'assets'
  New-Item -ItemType Directory -Path $icons -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'assets\AppIcon.ico') -Destination (Join-Path $icons 'AppIcon.ico') -Force

  Write-Host "==> 创建桌面和开始菜单快捷方式"
  $shell = New-Object -ComObject WScript.Shell
  $launcher = Join-Path $InstallRoot 'launcher.ps1'
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $shortcutArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
  $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) | Where-Object { $_ }
  foreach ($dir in $dirs) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $ascii = Join-Path $dir 'Braintrust.lnk'
    try {
      $shortcut = $shell.CreateShortcut($ascii)
      $shortcut.TargetPath = $powershell
      $shortcut.Arguments = $shortcutArgs
      $shortcut.WorkingDirectory = $InstallRoot
      $shortcut.IconLocation = (Join-Path $icons 'AppIcon.ico') + ',0'
      $shortcut.Description = '智囊 · Braintrust 本地工作台'
      $shortcut.Save()
    } catch {
      throw "无法在 $dir 创建快捷方式：$($_.Exception.Message)"
    }
    # WScript.Shell 在部分非中文系统上无法直接用中文路径保存 .lnk；
    # 先用 ASCII 名保存，再用 .NET 文件 API 改名，尽量保留「智囊」。
    try {
      Rename-Item -LiteralPath $ascii -NewName '智囊.lnk' -Force -ErrorAction Stop
      Write-Host "    快捷方式：$dir\智囊.lnk"
    } catch {
      Write-Warning "中文快捷方式改名失败，保留 Braintrust.lnk：$($_.Exception.Message)"
    }
  }

  if ($NoLaunch) {
    Write-Host "==> 已跳过启动（-NoLaunch）"
  } else {
    Write-Host "==> 启动智囊"
    & $launcher
  }
  Write-Host "✅ 安装完成。以后双击桌面或开始菜单里的「智囊」即可打开。"
  Start-Sleep -Milliseconds 400
} catch {
  Show-Error $_.Exception.Message
  Write-Error $_.Exception.Message
  exit 1
}
