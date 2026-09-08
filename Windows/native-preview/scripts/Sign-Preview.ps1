#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Existing')]
param(
    [Parameter(Mandatory)] [string[]]$PackagePaths,
    [Parameter(Mandatory, ParameterSetName = 'Existing')] [string]$CertificateThumbprint,
    [Parameter(Mandatory, ParameterSetName = 'Create')] [switch]$CreateDevelopmentCertificate
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Local preview signing requires Windows.' }
$subject = 'CN=Braintrust Native Preview Development'
$resolvedPackages = @($PackagePaths | ForEach-Object {
    $item = Get-Item -LiteralPath $_
    if ($item.Extension -ne '.msix') { throw 'Only .msix preview packages can be signed.' }
    $item
})
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($package in $resolvedPackages) {
    $archive = [IO.Compression.ZipFile]::OpenRead($package.FullName)
    try {
        $reader = [IO.StreamReader]::new($archive.GetEntry('AppxManifest.xml').Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($manifest.Package.Identity.Name -ne 'Braintrust.NativePreview.Development' -or
            $manifest.Package.Identity.Publisher -ne $subject) {
            throw 'Refusing to development-sign an identity outside this local preview.'
        }
    } finally { $archive.Dispose() }
}
$toolsRoot = Join-Path $env:USERPROFILE '.nuget\packages\microsoft.windows.sdk.buildtools\10.0.26100.9169\bin'
$signTool = Get-ChildItem -LiteralPath $toolsRoot -Filter 'signtool.exe' -Recurse |
    Where-Object { $_.Directory.Name -eq 'x64' } | Select-Object -First 1
if ($null -eq $signTool) { throw 'Pinned Windows SDK SignTool was not restored. Build the preview first.' }
if ($CreateDevelopmentCertificate) {
    # This explicit switch creates a local key. It neither trusts it nor exports its private key.
    $certificate = New-SelfSignedCertificate -Type Custom -Subject $subject -KeyUsage DigitalSignature `
        -FriendlyName 'Braintrust local preview only' -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddMonths(3) -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
} else {
    if ($CertificateThumbprint -notmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid certificate thumbprint.' }
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$CertificateThumbprint"
}
if ($certificate.Subject -ne $subject -or -not $certificate.HasPrivateKey -or $certificate.NotAfter -lt (Get-Date)) {
    throw 'Expected a valid local preview certificate with private key and matching Publisher.'
}
foreach ($package in $resolvedPackages) {
    & $signTool.FullName sign /fd SHA256 /s My /sha1 $certificate.Thumbprint $package.FullName
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $($package.Name)." }
    $certificatePath = Join-Path $package.Directory.FullName 'PreviewDevelopmentCertificate.cer'
    Export-Certificate -Cert $certificate -FilePath $certificatePath -Force | Out-Null
    [ordered]@{
        package = $package.Name; sha256 = (Get-FileHash $package.FullName -Algorithm SHA256).Hash
        developmentSigned = $true; certificateThumbprint = $certificate.Thumbprint
        trustedOnOtherDevices = $false; storeSigned = $false; installation = 'pending'
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $package.Directory.FullName 'signing-evidence.json') -Encoding utf8
}
Write-Host "Development signing complete. Reuse this certificate for subsequent builds: $($certificate.Thumbprint)"
Write-Host 'No certificate trust was added, no app was installed, and no private key was exported.'
