[CmdletBinding()]
param(
  [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\service'),
  [int]$Port = 0,
  [switch]$NoBrowser
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$node = $env:BRAINTRUST_NODE
if (-not $node) {
  $bundled = Join-Path $InstallRoot 'runtime\node-win-x64\node.exe'
  if (Test-Path -LiteralPath $bundled) { $node = $bundled }
}
if (-not $node) {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($command) { $node = $command.Source }
}
if (-not $node -or -not (Test-Path -LiteralPath $node)) {
  throw '未找到随包 Node 运行时。请重新安装智囊服务包，或设置 BRAINTRUST_NODE。'
}
$server = Join-Path $InstallRoot 'server.mjs'
if (-not (Test-Path -LiteralPath $server)) { throw '智囊服务文件缺失，请重新安装。' }
$data = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\data'
$arguments = @($server, '--data-dir', $data, '--port', [string]$Port)
if ($NoBrowser) { $arguments += '--no-browser' }
Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $InstallRoot -WindowStyle Hidden
