@echo off
rem Startet den nativen Co-op-Launcher ohne sichtbares Konsolenfenster.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0launcher-gui.ps1"
