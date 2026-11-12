[CmdletBinding()]
param(
  [string]$SourceDir = (Join-Path (Split-Path -Parent $PSScriptRoot) '..'),
  [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\service'),
  [switch]$NoShortcut
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'server.mjs'))) { throw '安装源缺少 server.mjs' }
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Get-ChildItem -LiteralPath $SourceDir -Force |
  Where-Object { $_.Name -notin @('node_modules', '.git') } |
  Copy-Item -Destination $InstallRoot -Recurse -Force
$launcher = Join-Path $InstallRoot 'launchers\windows\launch.ps1'
if (-not $NoShortcut) {
  $shell = New-Object -ComObject WScript.Shell
  $dirs = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) | Where-Object { $_ }
  foreach ($dir in $dirs) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $shortcut = $shell.CreateShortcut((Join-Path $dir '智囊.lnk'))
    $shortcut.TargetPath = (Get-Command powershell.exe).Source
    $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '"'
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.Description = '智囊 Braintrust · 本地浏览器服务'
    $shortcut.Save()
  }
}
Write-Host "智囊服务已安装：$InstallRoot"
Write-Host '以后双击桌面或开始菜单中的“智囊”即可打开。'
