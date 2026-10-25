[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms | Out-Null

function Show-Error([string]$Message) {
  [System.Windows.Forms.MessageBox]::Show($Message, '智囊', 'OK', 'Error') | Out-Null
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

function Get-ServicePort([string]$FilePath) {
  try { return [int](Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json).port } catch { return 0 }
}

function Get-ServiceToken([string]$FilePath) {
  try { return [string](Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json).token } catch { return '' }
}

function Test-Service([int]$Port) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/api/health" -TimeoutSec 1 -ErrorAction Stop
    return ($response.StatusCode -eq 200)
  } catch {
    if ($_.Exception.Response) { return ([int]$_.Exception.Response.StatusCode -eq 401) }
    return $false
  }
}

try {
  $InstallRoot = $PSScriptRoot
  $Server = Join-Path $InstallRoot 'server.mjs'
  if (-not (Test-Path -LiteralPath $Server)) { throw "程序文件缺失：$Server。请重新运行安装器。" }

  $Data = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\data'
  $LogDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\logs'
  New-Item -ItemType Directory -Path $Data -Force | Out-Null
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  $Log = Join-Path $LogDir 'service.log'
  $OutLog = Join-Path $LogDir 'service.out.log'
  $ErrLog = Join-Path $LogDir 'service.err.log'
  $ServiceJson = Join-Path $Data 'service.json'

  $node = ''
  foreach ($candidate in @((Join-Path $InstallRoot 'runtime\node-win-x64\node.exe'))) {
    if (Test-Path -LiteralPath $candidate) { $node = $candidate; break }
  }
  if (-not $node) {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($command) { $node = $command.Source }
  }
  if (-not $node -or -not (Test-Path -LiteralPath $node)) {
    throw '没有找到 Node 运行时。请重新安装智囊，或安装 Node.js 22+ 后重试。'
  }

  $browser = $env:BRAINTRUST_BROWSER_PATH
  if (-not $browser -or -not (Test-Path -LiteralPath $browser)) {
    $browser = ''
    $candidates = New-Object System.Collections.Generic.List[string]
    if (${env:ProgramFiles(x86)}) {
      $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'))
      $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'))
    }
    if ($env:ProgramFiles) {
      $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))
      $candidates.Add((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'))
    }
    if ($env:LOCALAPPDATA) {
      $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'))
      $candidates.Add((Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))
    }
    foreach ($candidate in $candidates) {
      if (Test-Path -LiteralPath $candidate) { $browser = $candidate; break }
    }
  }
  if (-not $browser) {
    throw '没有找到 Microsoft Edge 或 Google Chrome。请先安装其中一个浏览器，再打开智囊。'
  }
  $env:BRAINTRUST_BROWSER_PATH = $browser

  # 1) 已有服务：直接把工作台窗口带到前台。
  if (Test-Path -LiteralPath $ServiceJson) {
    $port = Get-ServicePort $ServiceJson
    $token = Get-ServiceToken $ServiceJson
    if ($port -gt 0 -and $token -and (Test-Service $port)) {
      try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/browser/open" -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body '{}' -TimeoutSec 45 | Out-Null
        return
      } catch {
        throw "智囊服务在运行，但无法打开工作台。请查看日志：$Log"
      }
    }
  }

  # 2) 没有服务：选一个空闲端口，启动服务，再打开工作台。
  $port = 47821
  for ($p = 47821; $p -le 47830; $p++) {
    if (-not (Test-TcpPort $p)) { $port = $p; break }
  }

  Add-Content -LiteralPath $Log -Value ("[{0}] 启动智囊服务 port={1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $port) -Encoding UTF8
  $argLine = '"{0}" --data-dir "{1}" --no-browser --port {2}' -f $Server, $Data, $port
  Start-Process -FilePath $node -ArgumentList $argLine -WorkingDirectory $InstallRoot -WindowStyle Hidden -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog | Out-Null

  $token = ''
  for ($i = 0; $i -lt 100; $i++) {
    if (Test-Path -LiteralPath $ServiceJson) {
      $foundPort = Get-ServicePort $ServiceJson
      $foundToken = Get-ServiceToken $ServiceJson
      if ($foundPort -gt 0 -and $foundToken -and (Test-Service $foundPort)) {
        $port = $foundPort; $token = $foundToken; break
      }
    }
    Start-Sleep -Milliseconds 200
  }
  if (-not $token) { throw "智囊服务没有启动成功。请查看日志：$Log" }

  try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/browser/open" -Method Post -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body '{}' -TimeoutSec 45 | Out-Null
  } catch {
    throw "服务已启动，但工作台窗口没有打开。请查看日志：$Log"
  }
} catch {
  Show-Error $_.Exception.Message
  exit 1
}
