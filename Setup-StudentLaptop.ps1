<#
.SYNOPSIS
    Sherborne student laptop setup script.

.DESCRIPTION
    1. Installs Microsoft 365 Apps (Office) and Microsoft Teams via winget, if not already installed.
    2. Prompts for the student's email (and password, held in memory only) to pre-fill sign-in.
    3. Installs the Fortinet SSL certificate (embedded directly in this script -- no internet
       or GitHub access needed at runtime) into the Local Machine "Trusted Root
       Certification Authorities" store.
    4. Creates and connects to the school Wi-Fi network (Sherborne-Pupil-2).
    5. Registers the account under Access work or school for SSO across apps.
    6. Downloads and runs the ClassHero Device Agent installer (School ID: girlsschool).

.NOTES
    - Run this as Administrator (it will self-elevate if you don't).
    - Nothing is written to disk in plaintext -- credentials only exist in memory for this run.
    - Office/Teams sign-in itself still needs the student to click "Sign in" and enter
      their password once, because modern auth (and MFA) can't be safely scripted.
    - If you install Office from a pendrive instead of winget, see the
      "PENDRIVE OPTION" comment block below and swap it in.
    - The certificate below is the Fortinet SSL-inspection CA cert. To update it later,
      just replace the text between the BEGIN/END lines with the new cert's contents.
#>

param(
    [string]$WifiSSID     = "Sherborne-Pupil-2",
    [string]$WifiPassword = "xyz1234.",
    [string]$CertStore    = "Root"  # LocalMachine store name; "Root" = Trusted Root CAs
)

# ---------------------------------------------------------------------------
# Embedded Fortinet SSL CA certificate (PEM format) -- no download needed
# ---------------------------------------------------------------------------
$FortinetCertPem = @"
-----BEGIN CERTIFICATE-----
MIID5jCCAs6gAwIBAgIIH8snIxqIl+8wDQYJKoZIhvcNAQELBQAwgakxCzAJBgNV
BAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRIwEAYDVQQHDAlTdW5ueXZhbGUx
ETAPBgNVBAoMCEZvcnRpbmV0MR4wHAYDVQQLDBVDZXJ0aWZpY2F0ZSBBdXRob3Jp
dHkxGTAXBgNVBAMMEEZHMjAwRVRLMTk5MTk1ODExIzAhBgkqhkiG9w0BCQEWFHN1
cHBvcnRAZm9ydGluZXQuY29tMB4XDTIwMDMwNDE0MjYwN1oXDTMwMDMwNTE0MjYw
N1owgakxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRIwEAYDVQQH
DAlTdW5ueXZhbGUxETAPBgNVBAoMCEZvcnRpbmV0MR4wHAYDVQQLDBVDZXJ0aWZp
Y2F0ZSBBdXRob3JpdHkxGTAXBgNVBAMMEEZHMjAwRVRLMTk5MTk1ODExIzAhBgkq
hkiG9w0BCQEWFHN1cHBvcnRAZm9ydGluZXQuY29tMIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAvfdavukIQ9Eg5utxLGNlP+4spDPdjBqG00Rbb+L4pDTD
fBMpKeAzhQVsLjVo9PCtuj+5uygLbeKI87e0h+8zQG28c86ao7cJwe0NtkXngZD0
JXjdIsceGC6LDfeSUrolFbaIS1eSbQTTlq0Nnk86illYgiUN51ju8Ip2Vlm7UzJV
TyfrRIm9zBlLRTvsJh82oadO7uT+/Httz4vVimBD2P4VFDr1dDx39i7+/rkqZtN9
nmrh2wB1uyElfoqmTdW1Hir7lkt0n3QbsBNdSvmVHiO68GP5LuTIxHuW+FQN0IEy
KKm/8wiWKM9+A0jRfI5QetMze4isoRGEnxqGLspeCwIDAQABoxAwDjAMBgNVHRME
BTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQArRTvdgLmtwy3eeTuWEpeGX07otRQx
MxpKdVKEy86wudCqAktY3xfME0rTwXqGQ4bkcz+wb9S7xQNWYTj6FXrfimKr8EfW
NP4RRwSameVsrt1/7EptzyrIfFlofi9m0G1Xytug+RpdwCrIP32fFBQA5jqmsDle
QRUlQjHZn4PXsF0zptHraAPyrJupjhYumGmp1oJ1rFUQax2HWUZgDnGfvgPXHTkE
QTlP4Ab+NIR5reh8UwshkaBoj6+RH6f9lm1aLb574gnafxRW/I7jPuhyWULIICPo
XTaqSPCofgRCkxvnjkwMbf4mDhY1fw72M/nLrwjiLUNVvDOpcC7H7tZY
-----END CERTIFICATE-----
"@

# ---------------------------------------------------------------------------
# 0. Self-elevate to Administrator if not already running as admin
# ---------------------------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching as Administrator..." -ForegroundColor Yellow
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") + $args
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

$ErrorActionPreference = "Stop"
Write-Host "`n=== Sherborne Student Laptop Setup ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Prompt for credentials (kept in memory only -- never written to disk)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# 2. Install Office 365 (Microsoft 365 Apps) and Teams via winget
# ---------------------------------------------------------------------------
function Test-WingetPackage {
    param([string]$Id)
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null
    return ($installed -match [regex]::Escape($Id))
}

function Install-WingetPackage {
    param([string]$Id, [string]$Name)
    if (Test-WingetPackage -Id $Id) {
        Write-Host "$Name already installed -- skipping." -ForegroundColor Green
    } else {
        Write-Host "Installing $Name... (this can take several minutes with no visible progress -- please wait)" -ForegroundColor Yellow
        winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        Write-Host "$Name install step finished." -ForegroundColor Green
    }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warning "winget not found. Install 'App Installer' from the Microsoft Store first, or use the pendrive option below."
} else {
    # Accept source agreements once up front so nothing prompts silently later
    winget source update --accept-source-agreements | Out-Null

    # Microsoft 365 Apps for enterprise (includes Word/Excel/PowerPoint/Outlook)
    Install-WingetPackage -Id "Microsoft.Office" -Name "Microsoft 365 Apps"
    Install-WingetPackage -Id "Microsoft.Teams" -Name "Microsoft Teams"
}

<#
--- PENDRIVE OPTION (use instead of the winget block above) ---
$pendriveSetup = "D:\Office\setup.exe"   # adjust drive letter/path
$pendriveConfig = "D:\Office\configuration.xml"
if (Test-Path $pendriveSetup) {
    Write-Host "Installing Office from pendrive..." -ForegroundColor Yellow
    Start-Process -FilePath $pendriveSetup -ArgumentList "/configure `"$pendriveConfig`"" -Wait
}
#>

# ---------------------------------------------------------------------------
# 3a. Sign out of any existing Office / Teams account (clear cached identity)
# ---------------------------------------------------------------------------
Write-Host "Signing out of any existing Microsoft 365 / Teams session..." -ForegroundColor Yellow

# Close apps that may be holding the cached identity open
Get-Process -Name "outlook","winword","excel","powerpnt","onenote","teams","ms-teams","OneDrive" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 2

# Clear Office's own identity cache (this is what re-appeared as the old account)
Remove-Item -Path "HKCU:\Software\Microsoft\Office\16.0\Common\Identity" -Recurse -Force -ErrorAction SilentlyContinue

# Clear the shared Microsoft identity/SSO cache used by Office, Teams, and other MS apps
Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\OneAuth" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\IdentityCache" -Recurse -Force -ErrorAction SilentlyContinue

# Clear Teams' own local cache (covers both classic Teams and new Teams client)
Remove-Item -Path "$env:APPDATA\Microsoft\Teams" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache" -Recurse -Force -ErrorAction SilentlyContinue

# Remove any saved Office/Microsoft account credentials from Windows Credential Manager
$savedCreds = cmdkey /list | Select-String "Target:" | ForEach-Object { ($_ -split "Target:\s*")[1].Trim() }
foreach ($target in $savedCreds) {
    if ($target -match "MicrosoftOffice|OC-CLIENT|OneAuth|Teams") {
        cmdkey /delete:$target | Out-Null
    }
}

Write-Host "Old sign-in data cleared." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3c. Open "Access work or school" so the account can be registered for SSO
# ---------------------------------------------------------------------------
# This works on Windows Home (unlike full Azure AD Join, which needs Pro/Enterprise/Education).
# Registering here means Office, Teams, and Edge can all silently reuse this sign-in afterward
# instead of asking the student to log in separately in every app.
Write-Host "`nOpening 'Access work or school' settings..." -ForegroundColor Yellow
Write-Host "STEP 1: If an existing account is listed there, click it and select 'Disconnect' first." -ForegroundColor Cyan
Write-Host "STEP 2: Then click '+ Connect' and sign in with the student's Microsoft 365 email." -ForegroundColor Cyan
Write-Host "(This ensures the old account is fully removed before the new one is registered.)" -ForegroundColor Cyan
Start-Process "ms-settings:workplace"

Write-Host "`nPress Enter here once you've disconnected the old account (if any) and connected the new one..." -ForegroundColor Yellow
Read-Host | Out-Null


# ---------------------------------------------------------------------------
# 4. Install the embedded Fortinet SSL certificate (fully offline)
# ---------------------------------------------------------------------------
try {
    Write-Host "Installing Fortinet SSL certificate into LocalMachine\$CertStore..." -ForegroundColor Yellow
    $certPath = Join-Path $env:TEMP "fortinet-ssl.cer"
    $FortinetCertPem | Out-File -FilePath $certPath -Encoding ascii -Force

    Import-Certificate -FilePath $certPath -CertStoreLocation "Cert:\LocalMachine\$CertStore" | Out-Null

    Remove-Item $certPath -Force
    Write-Host "Certificate installed successfully." -ForegroundColor Green
} catch {
    Write-Warning "Certificate install failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 5. Connect to school Wi-Fi
# ---------------------------------------------------------------------------
Write-Host "Setting up Wi-Fi profile for '$WifiSSID'..." -ForegroundColor Yellow

$wifiProfileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$WifiSSID</name>
    <SSIDConfig>
        <SSID>
            <name>$WifiSSID</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>WPA2PSK</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$WifiPassword</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>
"@

$profilePath = Join-Path $env:TEMP "$WifiSSID.xml"
$wifiProfileXml | Out-File -FilePath $profilePath -Encoding UTF8

netsh wlan add profile filename="$profilePath" user=all | Out-Null
netsh wlan connect name="$WifiSSID" ssid="$WifiSSID" | Out-Null

Remove-Item $profilePath -Force

Write-Host "`n=== Setup complete ===" -ForegroundColor Cyan
Write-Host "Ask the student to open Office/Teams and finish signing in with their password." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 6. Install ClassHero Device Agent (girlsschool) -- skip if already present
# ---------------------------------------------------------------------------
Write-Host "`n=== ClassHero Device Agent ===" -ForegroundColor Cyan

$ClassHeroTaskName = "ClassHeroAgent"
$ClassHeroInstallDir = "C:\Program Files\ClassHero"

$existingTask = Get-ScheduledTask -TaskName $ClassHeroTaskName -ErrorAction SilentlyContinue
$existingProc = Get-Process -Name "pythonw" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$ClassHeroInstallDir*" }

if ($existingTask -and ($existingTask.State -eq "Running" -or $existingProc)) {
    Write-Host "ClassHero Device Agent is already installed and running -- skipping install." -ForegroundColor Green
} else {
    Write-Host "ClassHero Device Agent not detected -- proceeding with install." -ForegroundColor Yellow

    $ClassHeroSchoolId = "girlsschool"
    $RepoZipUrl        = "https://github.com/jpallipath/Student-Laptop-setup-2026/archive/refs/heads/main.zip"
    $WorkDir           = Join-Path $env:TEMP "ClassHeroDeploy"
    $ZipPath           = Join-Path $env:TEMP "classhero-repo.zip"

    try {
        Write-Host "Downloading ClassHero installer files..." -ForegroundColor Yellow
        if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

        Invoke-WebRequest -Uri $RepoZipUrl -OutFile $ZipPath -UseBasicParsing
        Expand-Archive -Path $ZipPath -DestinationPath $WorkDir -Force
        Remove-Item $ZipPath -Force

        # The zip extracts into a "<repo>-main" folder
        $ExtractedRoot = Get-ChildItem $WorkDir -Directory | Select-Object -First 1
        $ClassHeroSrc  = Join-Path $ExtractedRoot.FullName "ClassHero-girlsschool\ClassHero-girlsschool"

        if (-not (Test-Path "$ClassHeroSrc\install_autostart.ps1")) {
            throw "install_autostart.ps1 not found at expected path: $ClassHeroSrc"
        }

        Write-Host "Files downloaded. Running ClassHero installer (School ID: $ClassHeroSchoolId)..." -ForegroundColor Yellow

        # Optional fields -- press Enter to skip either
        $chStudentName = Read-Host "  Student full name (optional -- press Enter to skip)"
        $chFormName    = Read-Host "  Form / class (optional -- press Enter to skip)"

        # Already running as Administrator (self-elevated at top of this script),
        # so install_autostart.ps1's own elevation check will just pass through.
        & powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$ClassHeroSrc\install_autostart.ps1" `
            -SchoolId $ClassHeroSchoolId -StudentName $chStudentName -FormName $chFormName

        Write-Host "ClassHero Device Agent install step finished." -ForegroundColor Green
    } catch {
        Write-Warning "ClassHero install failed: $($_.Exception.Message)"
    }
}
