@echo off
rem AI notification lamp - hook entry (Claude Code and Codex).
rem Uses lamp-hook.exe (fast) if it exists, otherwise runs lamp.ps1 with PowerShell (slow but works).
set "LAMPEXE=%~dp0lamp-hook.exe"
if not exist "%LAMPEXE%" set "LAMPEXE=%USERPROFILE%\.cache\ai-lamp\bin\lamp-hook.exe"
if exist "%LAMPEXE%" (
  "%LAMPEXE%" %1
) else (
  powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0lamp.ps1" %1
)
exit /b 0
