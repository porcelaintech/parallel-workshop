[CmdletBinding()]
param(
  [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\service'),
  [int]$Port = 0,
  [switch]$NoBrowser
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$node = $env:BRAINTRUST_NODE
$data = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\data'
$runtimeRoot = Join-Path $data 'runtime'
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
if (-not $node) {
  $bundled = Join-Path $InstallRoot 'runtime\node-win-x64\node.exe'
  if (Test-Path -LiteralPath $bundled) { $node = $bundled }
}
if (-not $node) {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($command) { $node = $command.Source }
}
if ($node -and -not (Test-Path -LiteralPath $node)) {
  $command = Get-Command $node -ErrorAction SilentlyContinue
  if ($command) { $node = $command.Source }
}
if (-not $node -or -not (Test-Path -LiteralPath $node)) {
  $nodeVersion = '22.23.4'
  $archiveName = "node-v$nodeVersion-win-x64.zip"
  $archive = Join-Path $runtimeRoot $archiveName
  $expected = 'cbc74b5e0982c9dbb41525fd8fb5dcd32fbee237863f7829072f4639a1ce5f20'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest -UseBasicParsing -Uri "https://nodejs.org/dist/v$nodeVersion/$archiveName" -OutFile $archive
  }
  if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    throw 'Node 运行时校验失败，请重试。'
  }
  $extract = Join-Path $runtimeRoot "node-v$nodeVersion-win-x64"
  if (-not (Test-Path -LiteralPath (Join-Path $extract 'node.exe'))) { Expand-Archive -LiteralPath $archive -DestinationPath $runtimeRoot -Force }
  $node = Join-Path $extract 'node.exe'
}
if (-not (Test-Path -LiteralPath $node)) {
  throw '无法准备 Node 运行时，请检查网络或设置 BRAINTRUST_NODE。'
}
$server = Join-Path $InstallRoot 'server.mjs'
if (-not (Test-Path -LiteralPath $server)) { throw '智囊服务文件缺失，请重新安装。' }
$arguments = @($server, '--data-dir', $data, '--port', [string]$Port)
if ($NoBrowser) { $arguments += '--no-browser' }
Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $InstallRoot -WindowStyle Hidden
