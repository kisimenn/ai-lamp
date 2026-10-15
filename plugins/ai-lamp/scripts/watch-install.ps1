# 画面の見張りを「パソコン起動時に自動で始まる」ようにする（任意機能）
#   ・見張り用のファイルを %USERPROFILE%\.cache\ai-lamp\watch にコピーする
#     （プラグインの場所は更新のたびに変わるので、そこを直接指さない。
#       また Claude のデスクトップアプリから AppData に書いたファイルは、アプリ専用の場所に
#       置き換えられて外から見えないので、AppData は使わない）
#   ・スタートアップフォルダにショートカットを置く
#   ・すぐに見張りを始める
# やめるときは watch-uninstall.ps1
$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:USERPROFILE '.cache\ai-lamp\watch'
[void](New-Item -ItemType Directory -Force -Path $dest)
Copy-Item -Force (Join-Path $PSScriptRoot 'lamp.ps1'), (Join-Path $PSScriptRoot 'lamp-watch.ps1') $dest

$watch = Join-Path $dest 'lamp-watch.ps1'
$args_ = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watch`""
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ai-lamp-watch.lnk'
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = (Get-Command powershell.exe).Source
$sc.Arguments = $args_
$sc.WindowStyle = 7   # 最小化
$sc.Description = 'AI通知ランプ 画面の見張り'
$sc.Save()

# すぐに見張りを始める。Claude のアプリから実行しても、アプリを閉じたとき一緒に止まらないよう、
# Windows に直接起動してもらう（このスクリプトの子プロセスにしない）
$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like '*lamp-watch.ps1*' }
if (-not $running) {
    $cmd = "`"$($sc.TargetPath)`" $args_"
    [void](Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd })
}
"画面の見張りを有効にしました（次回からパソコン起動時に自動で始まります）"
"  見張り本体: $watch"
"  自動起動  : $lnk"
