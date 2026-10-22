[CmdletBinding()]
param(
  [string]$ServiceRoot = (Join-Path (Get-Location) 'local-service'),
  [string]$DataDir = (Join-Path $env:TEMP ('braintrust-service-smoke-' + [Guid]::NewGuid().ToString('N')))
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$node = Join-Path $ServiceRoot 'runtime\node-win-x64\node.exe'
if (-not (Test-Path -LiteralPath $node)) { $node = (Get-Command node.exe -ErrorAction Stop).Source }
$server = Join-Path $ServiceRoot 'server.mjs'
if (-not (Test-Path -LiteralPath $server)) { throw '服务入口缺失' }
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$stdout = Join-Path $DataDir 'stdout.log'
$stderr = Join-Path $DataDir 'stderr.log'
$process = Start-Process -FilePath $node -ArgumentList @($server, '--no-browser', '--print-ready', '--data-dir', $DataDir, '--port', '0') -WorkingDirectory $ServiceRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
try {
  $ready = $null
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline -and $null -eq $ready) {
    if ($process.HasExited) { throw "服务提前退出：$($process.ExitCode)" }
    if (Test-Path -LiteralPath $stdout) {
      foreach ($line in @(Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue)) {
        if ($line.StartsWith('{"ok":true')) { $ready = $line | ConvertFrom-Json; break }
      }
    }
    if ($null -eq $ready) { Start-Sleep -Milliseconds 100 }
  }
  if ($null -eq $ready) { throw "服务未启动：$(Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue)" }
  $unauthorizedStatus = 0
  try { Invoke-WebRequest -Uri ($ready.url + 'api/health') -UseBasicParsing -ErrorAction Stop | Out-Null }
  catch { if ($_.Exception.Response) { $unauthorizedStatus = [int]$_.Exception.Response.StatusCode } else { throw } }
  if ($unauthorizedStatus -ne 401) { throw "API 未拒绝未授权请求：$unauthorizedStatus" }
  $headers = @{ Authorization = "Bearer $($ready.token)" }
  $platforms = Invoke-RestMethod -Uri ($ready.url + 'api/platforms') -Headers $headers
  if (@($platforms.platforms).Count -ne 6) { throw "适配器数量错误：$(@($platforms.platforms).Count)" }
  Write-Host '✅ Windows 本地服务 smoke test 通过（启动、令牌保护、六平台适配器）'
} finally {
  if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
