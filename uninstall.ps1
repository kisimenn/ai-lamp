# AI通知ランプ まとめて外す（Windows）
#   Claude Code のプラグイン、Codex のフック、既読で消える機能、ランプの記録をすべて外す。
#   実行例: powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
$scripts = Join-Path $PSScriptRoot 'plugins\ai-lamp\scripts'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'watch-uninstall.ps1') | Out-Null
"OK 既読で消える機能を外しました"

if (Test-Path (Join-Path $env:USERPROFILE '.codex\hooks.json')) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'codex-uninstall.ps1') | Out-Null
    "OK Codex のフックを外しました"
}

$claude = Get-ChildItem (Join-Path $env:APPDATA 'Claude\claude-code') -Recurse -Filter claude.exe -Depth 2 -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]$_.Directory.Parent.Name } catch { [version]'0.0' } } -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $claude) { $claude = (Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if ($claude) {
    & $claude plugin uninstall ai-lamp@ai-lamp-market 2>&1 | Out-Null
    & $claude plugin marketplace remove ai-lamp-market 2>&1 | Out-Null
    "OK Claude Code のプラグインを外しました"
}

Remove-Item -Recurse -Force (Join-Path $env:USERPROFILE '.cache\ai-lamp') -ErrorAction SilentlyContinue
"OK ランプの記録を消しました"
"Claude（や Codex）のアプリを一度閉じて、開き直すと完全に外れます。"
