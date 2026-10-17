# 画面の見張りを「パソコン起動時に自動で始まる」ようにする（任意機能）
#   ・見張り用のファイルを %USERPROFILE%\.cache\ai-lamp\watch にコピーする
#     （プラグインの場所は更新のたびに変わるので、そこを直接指さない。
#       また Claude のデスクトップアプリから AppData に書いたファイルは、アプリ専用の場所に
#       置き換えられて外から見えないので、AppData は使わない）
#   ・スタートアップフォルダにショートカットを置く
#   ・すぐに見張りを始める
# やめるときは watch-uninstall.ps1
#
# v0.8: この係は「既読で消える機能」と「受付箱の合図をすぐランプに送る仕事」の両方をする（常駐の係）。
#   -Seen on   既読で消える機能をオン（何も付けないときもこれ）
#   -Seen off  既読で消える機能をオフ（係は動かして、受付箱の仕事だけする）
#   -Seen keep 既読で消える機能は今のまま（初めてならオフ）
param([ValidateSet('on', 'off', 'keep')][string]$Seen = 'on')
$ErrorActionPreference = 'Stop'

$base = Join-Path $env:USERPROFILE '.cache\ai-lamp'
$seenOff = Join-Path $base 'seen-off'
[void](New-Item -ItemType Directory -Force -Path $base)
$firstTime = -not (Test-Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'ai-lamp-watch.lnk'))
if ($Seen -eq 'on') { Remove-Item -Force $seenOff -ErrorAction SilentlyContinue }
elseif ($Seen -eq 'off' -or ($Seen -eq 'keep' -and $firstTime)) { [System.IO.File]::WriteAllText($seenOff, '') }
$dest = Join-Path $env:USERPROFILE '.cache\ai-lamp\watch'
[void](New-Item -ItemType Directory -Force -Path $dest)
Copy-Item -Force (Join-Path $PSScriptRoot 'lamp.ps1'), (Join-Path $PSScriptRoot 'lamp-watch.ps1') $dest

$watch = Join-Path $dest 'lamp-watch.ps1'
$ps = (Get-Command powershell.exe).Source
# Windows 11 は、ふつうに起動するとターミナルの窓が開いてしまう（-WindowStyle Hidden でも）。
# conhost の --headless で起動すると、窓を一切出さずに動く
$conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
$args_ = "--headless `"$ps`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watch`""
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ai-lamp-watch.lnk'
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = $conhost
$sc.Arguments = $args_
$sc.WindowStyle = 7   # 最小化
$sc.Description = 'AI通知ランプ 画面の見張り'
$sc.Save()

# すぐに見張りを始める。Claude のアプリから実行しても、アプリを閉じたとき一緒に止まらないよう、
# Windows に直接起動してもらう（このスクリプトの子プロセスにしない）
$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like '*lamp-watch.ps1*' }
foreach ($p in @($running)) { if ($p) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } }
if ($running) { Start-Sleep -Milliseconds 500 }
if ($true) {
    $cmd = "`"$($sc.TargetPath)`" $args_"
    [void](Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd })
}
"常駐の係を入れました（次回からパソコン起動時に自動で始まります）。既読で消える機能: $(if (Test-Path $seenOff) { 'オフ' } else { 'オン' })"
"画面の見張りを有効にしました"
"  見張り本体: $watch"
"  自動起動  : $lnk"
