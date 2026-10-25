@echo off
rem Convenience for cmd.exe, where `opencode --stand` cannot be a function.
call "%~dp0opencode-warp.cmd" %*
exit /b %ERRORLEVEL%
