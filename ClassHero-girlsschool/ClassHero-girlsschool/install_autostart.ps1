# ============================================================
#  ClassHero Device Agent - Windows Installer  v2.1
#  Run as Administrator on each student machine.
#
#  What this script does:
#   1. Copies agent script + config to C:\Program Files\ClassHero\
#   2. Downloads Python 3.11 Embeddable (offline-friendly fallback below)
#   3. Enables pip, installs requests & psutil into the bundle
#   4. Creates a Scheduled Task with THREE triggers:
#       - At system startup  (covers power-on / restart)
#       - At user logon      (fallback if startup fires before network)
#       - On wake from sleep (resumes heartbeat after standby/hibernate)
#   5. Adds a Windows Defender exclusion for the install folder
#   6. Starts the task immediately
# ============================================================

param(
    [string]$ParamsFile  = "",   # legacy: path to temp INI (not used in new install.bat)
    [string]$SchoolId    = "",
    [string]$StudentName = "",
    [string]$FormName    = ""
)

# ── Self-elevate if not running as Administrator ───────────────────────────────
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $_isAdmin) {
    Write-Host ""
    Write-Host "  Requesting administrator privileges..." -ForegroundColor Yellow
    $argList  = @(
        '-ExecutionPolicy', 'Bypass',
        '-NoProfile',
        '-File', "`"$PSCommandPath`"",
        '-SchoolId',    "`"$SchoolId`"",
        '-StudentName', "`"$StudentName`"",
        '-FormName',    "`"$FormName`""
    )
    Start-Process PowerShell.exe -Verb RunAs -ArgumentList $argList -Wait
    exit
}

# Now running as Administrator
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

# ── Fallback: prompt interactively if values weren't passed (direct admin run) ─
if (-not $SchoolId) {
    Write-Host ""
    Write-Host "=== ClassHero Device Setup ==" -ForegroundColor Cyan
    Write-Host ""
    while (-not $SchoolId) {
        $SchoolId = (Read-Host "  School ID (required, e.g. sherborne-boys)").Trim()
        if (-not $SchoolId) { Write-Host "  School ID cannot be empty." -ForegroundColor Red }
    }
    $StudentName = (Read-Host "  Student full name (optional)").Trim()
    $FormName    = (Read-Host "  Form / class (optional)").Trim()
}

Write-Host ""
Write-Host "  School ID   : $SchoolId" -ForegroundColor Gray
if ($StudentName) { Write-Host "  Student     : $StudentName" -ForegroundColor Gray }
if ($FormName)    { Write-Host "  Form        : $FormName"    -ForegroundColor Gray }
Write-Host ""

$TaskName   = "ClassHeroAgent"
$InstallDir = "C:\Program Files\ClassHero"
$ScriptSrc  = "$PSScriptRoot\device_agent.py"
$CfgSrc     = "$PSScriptRoot\agent_config.ini"
$ScriptDest = "$InstallDir\device_agent.py"
$CfgDest    = "$InstallDir\agent_config.ini"
$PyDir      = "$InstallDir\python"
$PythonW    = "$PyDir\pythonw.exe"

# Python 3.11 embeddable - bundled in the deploy folder (no internet needed)
$BundledPyDir = "$PSScriptRoot\python"
$PyZipUrl     = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip"
$PyZip        = "$env:TEMP\python-embed.zip"

$DefaultBackendUrls = @(
    "https://web-production-60a8ad.up.railway.app",
    "https://ai-school-backend-production.up.railway.app"
)

# -- 1. Copy agent files ------------------------------------------------------
Write-Host ""
Write-Host "=== Installing ClassHero Device Agent ===" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $ScriptSrc)) {
    Write-Host "ERROR: device_agent.py not found at $ScriptSrc" -ForegroundColor Red
    Write-Host "Run this script from inside the deploy\ folder." -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item $ScriptSrc -Destination $InstallDir -Force

# Write the config with the values entered above (overrides any bundled config)
$BackendUrlsList = @($DefaultBackendUrls)
if (Test-Path $CfgSrc) {
    try {
        $cfgRaw = Get-Content $CfgSrc -Raw
        $backendUrlsMatch = [regex]::Match($cfgRaw, '(?im)^\s*backend_urls\s*=\s*(.+)$')
        if ($backendUrlsMatch.Success -and $backendUrlsMatch.Groups[1].Value.Trim()) {
            foreach ($u in ($backendUrlsMatch.Groups[1].Value -split ',')) {
                $candidate = $u.Trim().TrimEnd('/')
                if ($candidate -and -not ($BackendUrlsList -contains $candidate)) {
                    $BackendUrlsList += $candidate
                }
            }
        }

        $legacyBackendMatch = [regex]::Match($cfgRaw, '(?im)^\s*backend_url\s*=\s*(.+)$')
        if ($legacyBackendMatch.Success -and $legacyBackendMatch.Groups[1].Value.Trim()) {
            $legacyBackend = $legacyBackendMatch.Groups[1].Value.Trim().TrimEnd('/')
            if ($legacyBackend -and -not ($BackendUrlsList -contains $legacyBackend)) {
                $BackendUrlsList += $legacyBackend
            }
        }
    } catch {
    }
}

$BackendUrls = ($BackendUrlsList -join ', ')
$PrimaryBackendUrl = $BackendUrlsList[0]
$AgentVersion = "2.0.1"
$CfgContent = @"
[agent]
school_id       = $SchoolId
student_name    = $StudentName
form_name       = $FormName
backend_urls    = $BackendUrls
backend_url     = $PrimaryBackendUrl
agent_version   = $AgentVersion
heartbeat_every = 30
"@
# Write BOM-free UTF-8 — PowerShell 5's "UTF8" adds a BOM that breaks Python's configparser
[System.IO.File]::WriteAllText($CfgDest, $CfgContent, [System.Text.UTF8Encoding]::new($false))
Write-Host "[1/5] Agent files copied and config written." -ForegroundColor Green

# -- 2. Copy or download Python embeddable ------------------------------------
if (Test-Path $PythonW) {
    Write-Host "[2/5] Python already installed at $PyDir - skipping." -ForegroundColor Green

} elseif (Test-Path "$BundledPyDir\pythonw.exe") {
    Write-Host "[2/5] Copying bundled Python from deploy folder..." -ForegroundColor Cyan
    Copy-Item $BundledPyDir -Destination $PyDir -Recurse -Force
    Write-Host "[2/5] Python copied to $PyDir" -ForegroundColor Green

} else {
    Write-Host "[2/5] No bundled Python found - downloading from python.org (~8 MB)..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $PyZipUrl -OutFile $PyZip -UseBasicParsing
        Write-Host "      Extracting..." -ForegroundColor Gray
        New-Item -ItemType Directory -Force -Path $PyDir | Out-Null
        Expand-Archive -Path $PyZip -DestinationPath $PyDir -Force
        Remove-Item $PyZip -Force
        Write-Host "[2/5] Python extracted to $PyDir" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Download failed and no bundled Python found." -ForegroundColor Red
        Write-Host "Run build_bundle.ps1 on your admin machine first," -ForegroundColor Yellow
        Write-Host "then copy the whole deploy\ folder to this PC." -ForegroundColor Yellow
        exit 1
    }
}

# -- 3. Enable pip in embeddable Python ---------------------------------------
Write-Host "[3/5] Configuring pip..." -ForegroundColor Cyan

$PthFile = Get-ChildItem $PyDir -Filter "python3*._pth" | Select-Object -First 1
if ($PthFile) {
    $PthContent = Get-Content $PthFile.FullName -Raw
    if ($PthContent -match "#import site") {
        $PthContent = $PthContent -replace "#import site", "import site"
        Set-Content $PthFile.FullName $PthContent
        Write-Host "      Enabled site-packages in $($PthFile.Name)" -ForegroundColor Gray
    }
}

if (-not (Test-Path "$PyDir\Scripts\pip.exe")) {
    try {
        $GetPip = "$PyDir\get-pip.py"
        Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $GetPip -UseBasicParsing
        & "$PyDir\python.exe" $GetPip --quiet 2>&1 | Out-Null
        Remove-Item $GetPip -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "      WARNING: pip bootstrap failed. Will try python -m pip fallback." -ForegroundColor Yellow
    }
}

Write-Host "      Installing requests + psutil..." -ForegroundColor Gray
$WheelsDir = "$PSScriptRoot\wheels"
$pipExe    = if (Test-Path "$PyDir\Scripts\pip.exe") { "$PyDir\Scripts\pip.exe" } else { $null }

if (Test-Path $WheelsDir) {
    # -- Offline install from bundled wheels (no internet needed) --
    Write-Host "      Using bundled wheels (offline install)..." -ForegroundColor Gray
    $pipArgs = @("install", "requests", "psutil",
                 "--no-index", "--find-links", $WheelsDir,
                 "--no-warn-script-location")
    if ($pipExe) { $pipOut = & $pipExe @pipArgs 2>&1 }
    else          { $pipOut = & "$PyDir\python.exe" -m pip @pipArgs 2>&1 }
} else {
    # -- Online install fallback (school must allow pypi.org) --
    Write-Host "      No bundled wheels found - downloading from PyPI..." -ForegroundColor Yellow
    $pipArgs = @("install", "requests", "psutil", "--no-warn-script-location")
    if ($pipExe) { $pipOut = & $pipExe @pipArgs 2>&1 }
    else          { $pipOut = & "$PyDir\python.exe" -m pip @pipArgs 2>&1 }
}

# Verify packages actually installed - exit loudly if not
$verifyOut = & "$PyDir\python.exe" -c "import requests, psutil; print('OK')" 2>&1
if ($verifyOut -notmatch "OK") {
    Write-Host "" -ForegroundColor Red
    Write-Host "ERROR: Failed to install required Python packages (requests, psutil)." -ForegroundColor Red
    Write-Host "       pip output:" -ForegroundColor Yellow
    $pipOut | ForEach-Object { Write-Host "         $_" -ForegroundColor Gray }
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host "      Packages installed and verified OK." -ForegroundColor Green

# Verify pythonw.exe exists — critical, fail clearly if missing
if (-not (Test-Path $PythonW)) {
    Write-Host "" 
    Write-Host "ERROR: pythonw.exe not found at $PythonW" -ForegroundColor Red
    Write-Host "       Python installation failed (possibly blocked by firewall or AV)." -ForegroundColor Red
    Write-Host "       Try disabling antivirus temporarily and re-running this installer." -ForegroundColor Yellow
    Write-Host "       Or copy the 'python' folder from another machine into: $InstallDir\python" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host "[3/5] Python packages installed." -ForegroundColor Green

# -- 4. Register Scheduled Task -----------------------------------------------
Write-Host "[4/5] Creating Scheduled Task..." -ForegroundColor Cyan

foreach ($OldName in @("Details", "ClassHeroAgent")) {
    if (Get-ScheduledTask -TaskName $OldName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $OldName -Confirm:$false
        Write-Host "      Removed old task: $OldName" -ForegroundColor Yellow
    }
}

$Action = New-ScheduledTaskAction `
    -Execute          $PythonW `
    -Argument         "`"$ScriptDest`"" `
    -WorkingDirectory $InstallDir

$TriggerStartup = New-ScheduledTaskTrigger -AtStartup
$TriggerLogon   = New-ScheduledTaskTrigger -AtLogOn

$WakeEventClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
                               -Namespace Root/Microsoft/Windows/TaskScheduler
$TriggerWake = New-CimInstance -CimClass $WakeEventClass -ClientOnly
$TriggerWake.Enabled      = $true
$TriggerWake.Subscription = "<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>"
$TriggerWake.Delay        = "PT30S"

$Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit         (New-TimeSpan -Days 0) `
    -RestartCount               3 `
    -RestartInterval            (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false `
    -Hidden

# Allow task to run on battery (set via XML after registration)
$Settings.DisallowStartIfOnBatteries = $false
$Settings.StopIfGoingOnBatteries     = $false

$Principal = New-ScheduledTaskPrincipal `
    -UserId    "SYSTEM" `
    -RunLevel  Highest `
    -LogonType ServiceAccount

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $Action `
    -Trigger     @($TriggerStartup, $TriggerLogon, $TriggerWake) `
    -Settings    $Settings `
    -Principal   $Principal `
    -Description "ClassHero Device Agent - reports device info to the school dashboard." `
    -Force | Out-Null

Write-Host "[4/5] Scheduled task '$TaskName' registered." -ForegroundColor Green

# -- 5. Add Windows Defender exclusion ----------------------------------------
Write-Host "[5/5] Adding Windows Defender exclusion for $InstallDir ..." -ForegroundColor Cyan
try {
    Add-MpPreference -ExclusionPath $InstallDir -ErrorAction Stop
    Write-Host "[5/5] Defender exclusion added." -ForegroundColor Green
} catch {
    Write-Host "[5/5] Defender exclusion skipped (may already exist or Defender not active)." -ForegroundColor Yellow
}

# -- Start immediately ---------------------------------------------------------
Start-ScheduledTask -TaskName $TaskName

# -- Verify agent is actually running ------------------------------------------
$LogPath = "C:\ProgramData\ClassHero\agent.log"
Write-Host ""
Write-Host "Waiting for agent to start..." -ForegroundColor Cyan
Start-Sleep -Seconds 6

$TaskState = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State
$AgentProc = Get-Process -Name "pythonw" -ErrorAction SilentlyContinue

if ($TaskState -eq "Running" -or $AgentProc) {
    Write-Host "============================================="  -ForegroundColor Cyan
    Write-Host " ClassHero Agent is RUNNING!"                  -ForegroundColor Green
    Write-Host "  Task:  $TaskName (startup + logon + wake)"   -ForegroundColor White
    Write-Host "  Log:   $LogPath"                             -ForegroundColor White
    Write-Host "============================================="  -ForegroundColor Cyan
} else {
    Write-Host "============================================="  -ForegroundColor Yellow
    Write-Host " WARNING: Agent may not have started yet."     -ForegroundColor Yellow
    Write-Host "  Task state: $TaskState"                      -ForegroundColor Yellow
    Write-Host "  Check log: $LogPath"                         -ForegroundColor Yellow
    Write-Host "  Or run: schtasks /run /tn ClassHeroAgent"    -ForegroundColor Yellow
    Write-Host "============================================="  -ForegroundColor Yellow
}

if (Test-Path $LogPath) {
    Write-Host ""
    Write-Host "--- Agent log (last 5 lines) ---" -ForegroundColor Gray
    Get-Content $LogPath | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}

Write-Host ""
Read-Host "Press Enter to close this window"