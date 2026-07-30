@echo off
setlocal EnableDelayedExpansion

title ClassHero Device Agent - Installer

color 0B
echo.
echo  =====================================================
echo   ClassHero Device Agent Installer
echo  =====================================================
echo.
echo  Please enter the details for this student device.
echo  (Press Enter to skip optional fields)
echo.

:: ── Collect School ID (required) ──────────────────────────────────────────────
:GET_SCHOOL
set "SchoolId="
set /p "SchoolId=  School ID (required, e.g. sherborne-boys): "
if "!SchoolId!"=="" (
    echo   ERROR: School ID cannot be empty.  Please try again.
    goto GET_SCHOOL
)

:: ── Collect optional info ─────────────────────────────────────────────────────
set "StudentName="
set /p "StudentName=  Student full name    (optional - press Enter to skip): "

set "FormName="
set /p "FormName=  Form / class          (optional, e.g. 5C, press Enter to skip): "

echo.
echo  ----- Please confirm -----
echo    School ID : !SchoolId!
echo    Student   : !StudentName!
echo    Form      : !FormName!
echo.
echo  Starting installation (a UAC prompt may appear - click YES)...
echo.

:: ── Call the PowerShell installer directly.
:: The PS1 handles its own UAC self-elevation internally.
PowerShell.exe -ExecutionPolicy Bypass -NoProfile ^
  -File "%~dp0install_autostart.ps1" ^
  -SchoolId "!SchoolId!" ^
  -StudentName "!StudentName!" ^
  -FormName "!FormName!"

echo.
echo  Done.  You can close this window.
echo.
pause
endlocal
