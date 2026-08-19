# ============================================================
#  sign-wgtray.ps1 - sign the PS1 edition of WgTray
#
#  Purpose: Authenticode-sign wgtray-ps1\WgTray.ps1 so it is
#  trusted under AllSigned/RemoteSigned ExecutionPolicies and is
#  treated as a trusted-publisher script by AV/SmartScreen.
#
#  Defaults to a SELF-SIGNED code-signing certificate created in
#  the CurrentUser store (no admin needed) and installs it into the
#  CurrentUser Trusted Publishers + Root, so THIS machine trusts the
#  signature immediately. For other machines, export the cert and
#  install it into their Trusted Publishers (see README).
#
#  Usage:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File sign-wgtray.ps1
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File sign-wgtray.ps1 -CertThumbprint <tp>
#
#  NOTE: ASCII-only script (Windows PS 5.1 reads .ps1 as ANSI).
# ============================================================
param(
    [string]$Path = (Join-Path $PSScriptRoot 'wgtray-ps1\WgTray.ps1'),
    [string]$CertThumbprint = '',
    [switch]$SkipInstall
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Path)) { throw "not found: $Path (run build-wgtray-ps1.ps1 first)" }

# ---- 1) pick or create a code-signing certificate (CurrentUser store) ----
$cert = $null
if ($CertThumbprint) {
    $cert = Get-Item ("Cert:\CurrentUser\My\" + $CertThumbprint) -ErrorAction Stop
}
if (-not $cert) {
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=WgTray Local' `
            -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable `
            -NotAfter (Get-Date).AddYears(3) -KeyAlgorithm RSA -KeyLength 2048
    Write-Output ("created self-signed code-signing cert: " + $cert.Thumbprint)
} else {
    Write-Output ("using existing code-signing cert: " + $cert.Thumbprint)
}

# ---- 2) trust it on this machine (CurrentUser stores, no admin) ----
if (-not $SkipInstall) {
    $srcStore = "Cert:\CurrentUser\My\" + $cert.Thumbprint
    if (-not (Get-Item ("Cert:\CurrentUser\Root\" + $cert.Thumbprint) -ErrorAction SilentlyContinue)) {
        Copy-Item $srcStore "Cert:\CurrentUser\Root" -ErrorAction Stop
    }
    if (-not (Get-Item ("Cert:\CurrentUser\TrustedPublisher\" + $cert.Thumbprint) -ErrorAction SilentlyContinue)) {
        Copy-Item $srcStore "Cert:\CurrentUser\TrustedPublisher" -ErrorAction Stop
    }
    Write-Output "cert installed to CurrentUser Trusted Publishers + Root (this machine now trusts it)"
}

# ---- 3) sign ----
$sig = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert -HashAlgorithm SHA256
if ($sig.Status -ne 'Valid') { throw ("signing failed: " + $sig.StatusMessage) }
Write-Output ("signed: " + $Path + "  status=" + $sig.Status + "  signer=" + $sig.SignerCertificate.Subject)

# ---- 4) verify ----
$check = Get-AuthenticodeSignature $Path
Write-Output ("verify: " + $check.Status + " (" + $check.StatusMessage + ")")

Write-Output ""
Write-Output ("For other machines, export the cert and install it into their Trusted Publishers:")
Write-Output ('  Export-PfxCertificate -Cert "Cert:\CurrentUser\My\' + $cert.Thumbprint + '" -FilePath wgtray-signing-cert.pfx -ProtectTo $env:USERNAME')
Write-Output "  then on the target machine: Import-PfxCertificate into Cert:\CurrentUser\TrustedPublisher"
Write-Output ("(thumbprint: " + $cert.Thumbprint + ")")
