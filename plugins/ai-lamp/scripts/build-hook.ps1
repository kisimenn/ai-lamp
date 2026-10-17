# 合図係（lamp-hook.exe）を、このパソコンの中で作る（v0.8.1）
#   ・Windows に最初から入っている C# の道具（csc.exe）で lamp-hook.cs から作る。ネットからプログラムは取ってこない
#   ・置き場所は %USERPROFILE%\.cache\ai-lamp\bin（場所が変わらないように。lamp.ps1・lamp-hook.cmd も一緒に置く）
#   ・作れなかったときも困らない（フックの入口 lamp-hook.cmd が、今までどおり PowerShell で lamp.ps1 を動かす）
$ErrorActionPreference = 'Stop'
$bin = Join-Path $env:USERPROFILE '.cache\ai-lamp\bin'
[void](New-Item -ItemType Directory -Force -Path $bin)
Copy-Item -Force (Join-Path $PSScriptRoot 'lamp.ps1'), (Join-Path $PSScriptRoot 'lamp-hook.cmd') $bin

$exe = Join-Path $bin 'lamp-hook.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { "合図係を作れませんでした（C# の道具が見つからない）。PowerShell で光らせます"; exit 0 }

$tmp = "$exe.new"
$ErrorActionPreference = 'Continue'
$out = & $csc /nologo /target:exe /optimize+ "/out:$tmp" (Join-Path $PSScriptRoot 'lamp-hook.cs') 2>&1 | Out-String
$ErrorActionPreference = 'Stop'
if (Test-Path $tmp) {
    # 使用中で上書きできないことがあるので、作ってから入れ替える
    try { Move-Item -Force $tmp $exe } catch { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }
}
if (Test-Path $exe) { "合図係を作りました: $exe" } else { "合図係を作れませんでした。PowerShell で光らせます:`n$out" }
