@echo off
REM Rejuvenation Co-op -- Installer-Starter
REM Doppelklick genuegt. Startet den grafischen Installer.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 (
  echo.
  echo Es ist ein Fehler aufgetreten. Fenster mit einer Taste schliessen.
  pause >nul
)
endlocal
