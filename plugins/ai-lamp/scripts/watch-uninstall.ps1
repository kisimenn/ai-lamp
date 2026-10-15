# 画面の見張りをやめる（自動起動を外し、動いている見張りを止め、コピーしたファイルを消す）
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ai-lamp-watch.lnk'
Remove-Item -Force $lnk -ErrorAction SilentlyContinue

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*lamp-watch.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Remove-Item -Recurse -Force (Join-Path $env:USERPROFILE '.cache\ai-lamp\watch') -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $env:LOCALAPPDATA 'ai-lamp') -ErrorAction SilentlyContinue   # v0.3.0 の置き場所
"画面の見張りを無効にしました"
