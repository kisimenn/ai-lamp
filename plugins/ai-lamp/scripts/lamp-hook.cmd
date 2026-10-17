@echo off
rem AI notification lamp - hook entry for Codex.
rem Uses lamp-hook.exe (fast) if it exists, otherwise runs lamp.ps1 with PowerShell (slow but works).
if exist "%~dp0lamp-hook.exe" (
  "%~dp0lamp-hook.exe" %1
) else (
  powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0lamp.ps1" %1
)
exit /b 0
