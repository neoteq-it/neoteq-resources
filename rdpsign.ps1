# ==============================================================================
# SIGN RDP CONNECTION FILES YOU CREATE ON THE MACHINE USING A SELF-SIGNED CERTIFICATE TO SUPRESS APRIL 2026 RDP SECURITY UPDATE WARNINGS WHEN OPENING REMOTE DESKTOP FILES
# https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/remotepc/understanding-security-warnings#:~:text=When%20an%20RDP%20file%20is,as%20the%20following%20image%20shows.
# https://msrc.microsoft.com/update-guide/vulnerability/CVE-2026-26151
# NOTE!! THIS WILL NO LONGER SHOW THE "Remote Desktop Connection security warning" FOR ANY SIGNED FILES AND ENSURES THESE FILES CAN'T BE MODIFIED AFTER SIGNING WITHOUT INVALIDATING THE SIGNATURE, WHICH WILL MAKE THE WARNING REAPPAER
# NOTE!! ANY GPO THAT MODIFIES "Specify SHA1 thumbprints of certificates that represent trusted .rdp publishers" WILL OVERWRITE THE SETTINGS CREATED BY THIS SCRIPT CAUSING THE SIGNED RDP FILE TO SHOW A WARNING AGAIN
# IF YOU ARE IMPLEMENTING A GPO SOLUTION KEEP THIS IN MIND OR TRY TO ENSURE THAT THE GPO COMMA APPENDS TO THE EXISTING VALUES OF THE KEY ALREADY EXISTS (NOT STANDARD BEHAVIOUR)
# "THE SCRIPT IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND..."
# ==============================================================================

# 1. Configuration
$rdpFile = "C:\Users\Desktop\RDPFILENAME.rdp"
$certSubjectName = "NEOTEQ IT GmbH"
$certSubject = "CN=$certSubjectName"

# 2. Check for existing certificate
Write-Host "Searching for existing certificate: $certSubjectName..." -ForegroundColor Cyan
$existingCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $certSubject } | Select-Object -First 1

if ($existingCert) {
    Write-Host "Found existing certificate with Thumbprint: $($existingCert.Thumbprint)" -ForegroundColor Green
    $thumbprint = $existingCert.Thumbprint
} else {
    Write-Host "No existing certificate found. Creating new one..." -ForegroundColor Yellow

    # Create the Self-Signed Certificate
    $cert = New-SelfSignedCertificate -Subject $certSubject `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -Type CodeSigningCert `
        -KeyExportPolicy None `
        -NotAfter (Get-Date).AddYears(5)

    $thumbprint = $cert.Thumbprint

    # Add to Trusted Root
    $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $rootStore.Open("ReadWrite")
    $rootStore.Add($cert)
    $rootStore.Close()

    # Add to Trusted Publishers
    $pubStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
    $pubStore.Open("ReadWrite")
    $pubStore.Add($cert)
    $pubStore.Close()

    # --- Updated GPO Registry Key Logic ---
    # Per your screenshot, path is Terminal Services (not Client) and key is TrustedCertThumbprints
    $gpoPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    $keyName = "TrustedCertThumbprints"

    if (!(Test-Path $gpoPath)) { New-Item -Path $gpoPath -Force | Out-Null }

    $currentRegistry = Get-ItemProperty -Path $gpoPath -Name $keyName -ErrorAction SilentlyContinue
    $currentValues = if ($currentRegistry) { $currentRegistry.$keyName } else { "" }

    if ($currentValues -notlike "*$thumbprint*") {
        Write-Host "Updating registry trust list at $gpoPath..." -ForegroundColor Cyan
        $newValue = if ([string]::IsNullOrWhiteSpace($currentValues)) { $thumbprint } else { "$currentValues,$thumbprint" }

        # Using Set-ItemProperty with string type to match your screenshot
        Set-ItemProperty -Path $gpoPath -Name $keyName -Value $newValue -Type String
    } else {
        Write-Host "Thumbprint already exists in registry. Skipping update." -ForegroundColor Yellow
    }

    Write-Host "New certificate created and trusted." -ForegroundColor Green
}

# 3. Sign the RDP File
if (Test-Path $rdpFile) {
    Write-Host "Signing RDP file: $rdpFile" -ForegroundColor Cyan
    # Signing with /sha256 to match modern security standards
    rdpsign.exe /sha256 $thumbprint "$rdpFile"
    Write-Host "Success! RDP file is ready for use." -ForegroundColor Green
} else {
    Write-Error "Target RDP file not found at $rdpFile"
}
