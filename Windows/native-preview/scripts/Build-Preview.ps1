#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^0\.1\.[0-9]{1,5}\.0$')]
    [string]$PackageVersion = '0.1.0.0'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'WinUI/MSIX build requires a Windows host.' }
if ([Version]$PackageVersion -gt [Version]'0.1.65535.0') { throw 'Package version exceeds MSIX bounds.' }
$previewRoot = Split-Path $PSScriptRoot -Parent
$stageRoot = Join-Path $previewRoot "artifacts\stage\$PackageVersion"
$packageRoot = Join-Path $previewRoot "artifacts\packages\$PackageVersion"
$logRoot = Join-Path $previewRoot 'artifacts\logs'
foreach ($path in @($stageRoot, $packageRoot)) {
    # Both paths are derived strictly from this preview directory and a validated version.
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
foreach ($name in @('Braintrust.NativePreview.csproj', 'global.json', 'App.xaml', 'App.xaml.cs',
    'MainWindow.cs', 'PlatformPane.cs', 'PlatformPolicy.cs', 'Package.appxmanifest', 'app.manifest', 'Assets', 'Config')) {
    Copy-Item -LiteralPath (Join-Path $previewRoot $name) -Destination $stageRoot -Recurse
}
$manifestPath = Join-Path $stageRoot 'Package.appxmanifest'
[xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
if ($manifest.Package.Identity.Name -ne 'Braintrust.NativePreview.Development' -or
    $manifest.Package.Identity.Publisher -ne 'CN=Braintrust Native Preview Development') {
    throw 'This script only builds the local preview identity. Store packaging needs a separate reviewed configuration.'
}
$manifest.Package.Identity.Version = $PackageVersion
$manifest.Save($manifestPath)
Push-Location $stageRoot
try {
    & dotnet build '.\Braintrust.NativePreview.csproj' --configuration Release `
        '-p:Platform=x64' '-p:RuntimeIdentifier=win-x64' '-p:GenerateAppxPackageOnBuild=true' `
        '-p:UapAppxPackageBuildMode=SideloadOnly' '-p:AppxBundle=Never' '-p:AppxPackageSigningEnabled=false' `
        "-p:AppxPackageDir=$packageRoot\" "-bl:$(Join-Path $logRoot "$PackageVersion.binlog")"
    if ($LASTEXITCODE -ne 0) { throw "Windows build failed with exit code $LASTEXITCODE." }
} finally { Pop-Location }
$packages = @(Get-ChildItem -LiteralPath $packageRoot -Filter '*.msix' -Recurse)
if ($packages.Count -ne 1) { throw "Expected one unsigned MSIX; found $($packages.Count)." }
# Confirm the actual package version/identity, rather than trusting build-property substitution.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($packages[0].FullName)
try {
    $entry = $archive.GetEntry('AppxManifest.xml')
    if ($null -eq $entry) { throw 'Packaged manifest is missing.' }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { [xml]$packagedManifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($packagedManifest.Package.Identity.Version -ne $PackageVersion -or
        $packagedManifest.Package.Identity.Name -ne 'Braintrust.NativePreview.Development') {
        throw 'Actual MSIX identity/version differs from the preview request.'
    }
} finally { $archive.Dispose() }
$evidence = [ordered]@{
    package = $packages[0].Name; version = $PackageVersion; architecture = 'x64'
    sha256 = (Get-FileHash -LiteralPath $packages[0].FullName -Algorithm SHA256).Hash
    signed = $false; storeIdentity = $false; windowsCompilation = 'passed'
    installation = 'pending'; login = 'pending'; upgrade = 'pending'; storeDelivery = 'pending'
}
$evidence | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $packageRoot 'build-evidence.json') -Encoding utf8
Write-Host "Created unsigned local preview MSIX: $($packages[0].FullName)"
Write-Host 'Installation requires a locally trusted development signature. No account, login, install or Store update was tested.'
