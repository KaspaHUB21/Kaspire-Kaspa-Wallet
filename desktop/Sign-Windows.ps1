param(
    [Parameter(Mandatory=$true)][string[]]$Path,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CertificateThumbprint
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Authenticode signing requires Windows.' }
$Certificate = Get-Item "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction Stop
if (-not $Certificate.HasPrivateKey -or $Certificate.NotAfter -le (Get-Date) -or $Certificate.NotBefore -gt (Get-Date)) { throw 'A valid code-signing certificate with an accessible private key is required.' }
$Usage = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | Select-Object -First 1
if (-not $Usage -or -not ($Usage.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' })) { throw 'Certificate does not have the code-signing EKU.' }
$Tool = Get-Command signtool.exe -ErrorAction Stop
foreach ($Item in $Path) {
    $File = (Resolve-Path -LiteralPath $Item).Path
    if ([IO.Path]::GetExtension($File) -notin @('.exe', '.dll')) { throw 'Only explicitly selected EXE/DLL files may be signed.' }
    & $Tool.Source sign /sha1 $CertificateThumbprint /fd SHA256 /tr https://timestamp.digicert.com /td SHA256 $File
    if ($LASTEXITCODE -ne 0) { throw "Authenticode signing failed: $File" }
    & $Tool.Source verify /pa /all /tw $File
    if ($LASTEXITCODE -ne 0) { throw "Authenticode verification failed: $File" }
    $Signature = Get-AuthenticodeSignature -LiteralPath $File
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Thumbprint -ne $CertificateThumbprint) { throw "Unexpected or untrusted publisher signature: $File" }
}
