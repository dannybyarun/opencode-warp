@echo off
setlocal
set "PS=powershell.exe"
where powershell.exe >nul 2>nul || set "PS=pwsh.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0opencode-warp.ps1" %*
exit /b %ERRORLEVEL%
