# Codex（アプリ・ターミナル・VS Code）でもランプを光らせる
#   ・lamp.ps1 を %USERPROFILE%\.cache\ai-lamp\bin にコピーする（場所が変わらないように）
#   ・%USERPROFILE%\.codex\hooks.json にランプ用のフックを追記する（ほかの設定は消さない）
#   ・追記したあと、Codex で一度だけ「このフックを使ってよいか」を承認する必要がある（入力欄の下に出る黄色い点付きのフックのアイコン →「すべて許可」。ターミナルは /hooks）
# やめるときは codex-uninstall.ps1
#
# Codex の合図とランプの対応（Codex にはエラーで止まった合図が無い。Claude Code のエラーも v0.5 から橙＝「あなたの出番」）
#   UserPromptSubmit / PostToolUse → 作業中、PermissionRequest → 質問待ち、Stop → 完了、
#   Interrupt / SessionEnd → そのセッションの表示を消す
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$utf8 = New-Object System.Text.UTF8Encoding $false

$bin = Join-Path $env:USERPROFILE '.cache\ai-lamp\bin'
[void](New-Item -ItemType Directory -Force -Path $bin)
Copy-Item -Force (Join-Path $PSScriptRoot 'lamp.ps1') $bin
$lamp = Join-Path $bin 'lamp.ps1'

# v0.8: 速くするための合図係（lamp-hook.exe）を作る（build-hook.ps1）。フックは lamp-hook.cmd を呼ぶ。
#   作れなかったとき・場所に空白があるときは、今までどおり PowerShell で lamp.ps1 を呼ぶ
$hookCmd = $null
try {
    [void](& (Join-Path $PSScriptRoot 'build-hook.ps1'))
    if ((Test-Path (Join-Path $bin 'lamp-hook.exe')) -and ($bin -notmatch '\s')) { $hookCmd = Join-Path $bin 'lamp-hook.cmd' }
} catch { }

$codexDir = Join-Path $env:USERPROFILE '.codex'
[void](New-Item -ItemType Directory -Force -Path $codexDir)
$hooksFile = Join-Path $codexDir 'hooks.json'

$doc = @{}
if (Test-Path $hooksFile) {
    Copy-Item -Force $hooksFile "$hooksFile.bak-ai-lamp"   # 念のため控えを取る
    $doc = $json.DeserializeObject([System.IO.File]::ReadAllText($hooksFile, $utf8))
}
if (-not $doc.ContainsKey('hooks') -or -not $doc['hooks']) { $doc['hooks'] = @{} }
$hooks = $doc['hooks']

# Interrupt / SessionEnd は Codex の上限が 3 秒（既定 1 秒）。SessionEnd は必ず同期で動く（公式 hooks の説明、2026-10-12 確認）
function New-LampGroup($state, $timeout) {
    @{ hooks = @(@{
        type    = 'command'
        command = $(if ($hookCmd) { "$hookCmd $state" } else { "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$lamp`" $state" })
        async   = $true
        timeout = $timeout
    }) }
}
$plan = [ordered]@{
    UserPromptSubmit  = @('work', 15)
    PostToolUse       = @('work', 15)
    PermissionRequest = @('ask', 15)
    Stop              = @('done', 15)
    Interrupt         = @('end', 3)
    SessionEnd        = @('end', 3)
}

foreach ($ev in $plan.Keys) {
    # 前に入れたランプ用のフックは取り除いてから入れ直す（二重にしない）
    # （パイプラインは使わない: 中身が PSObject に包まれて保存で失敗する。ほかのフックがあると入らなかった）
    $groups = [System.Collections.ArrayList]::new()
    if ($hooks.ContainsKey($ev) -and $hooks[$ev]) {
        foreach ($g in $hooks[$ev]) { if ($json.Serialize($g) -notmatch 'ai-lamp') { [void]$groups.Add($g) } }
    }
    [void]$groups.Add((New-LampGroup $plan[$ev][0] $plan[$ev][1]))
    $hooks[$ev] = $groups.ToArray()
}

[System.IO.File]::WriteAllText($hooksFile, $json.Serialize($doc), $utf8)
"Codex 用のランプのフックを入れました: $hooksFile"
"  呼び方: $(if ($hookCmd) { '速い合図係（lamp-hook）' } else { 'PowerShell（lamp.ps1）' })"
"次に、ランプのフックを承認してください。Codex アプリは、入力欄の下に出る、黄色い点付きのフックのアイコン →「フックの確認」で、lamp-hook または lamp.ps1 と書かれたランプ用のフックを許可します（全部ランプ用なら「すべて許可」、ほかのフックもあればランプ用だけ選んで「選択した項目を許可」）。これで完了で、設定画面でもう一度同じ操作をする必要はありません。アイコンが無いときは承認済みのこともあるので 設定 → Hooks で確かめます。ターミナルの Codex は /hooks。承認したら新しい会話から光ります。"
