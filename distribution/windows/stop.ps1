$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Braintrust\service'
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$root*server.mjs*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
