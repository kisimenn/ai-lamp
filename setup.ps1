# AI通知ランプ まとめて設定（Windows）
#   Claude Code / Codex に「この setup.ps1 を実行して」と頼めば、次をまとめて行う。
#     1. プラグイン一式を %USERPROFILE%\.cache\ai-lamp\market にコピー（展開したフォルダを消しても困らないように）
#     2. Claude Code にプラグインを入れる（入っていれば入れ直す）
#        GitHub から入れる（更新が届く）。GitHub に届かないときは 1. のコピーから入れる
#     3. Codex が入っていれば、Codex 用のフックも入れる
#     4. 既読で消える機能: -Watch でオン、-NoWatch でオフ（どちらも無ければ今のまま）
#   何度実行しても同じ結果になる。外すときは uninstall.ps1
#
#   実行例: powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 -Watch
param([switch]$Watch, [switch]$NoWatch, [switch]$NoCodex)

$ErrorActionPreference = 'Stop'
$GitHubRepo = 'kisimenn/ai-lamp'   # 配布リポジトリ（公開前に書き換える）
$here = $PSScriptRoot
$market = Join-Path $env:USERPROFILE '.cache\ai-lamp\market'
$scripts = Join-Path $market 'plugins\ai-lamp\scripts'
$results = @()
$didClaude = $false; $didCodex = $false

# Claude Code のコマンドを探す（デスクトップアプリ同梱の新しいもの → PATH 上のもの の順）
function Find-Claude {
    $bundled = Get-ChildItem (Join-Path $env:APPDATA 'Claude\claude-code') -Recurse -Filter claude.exe -Depth 2 -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]$_.Directory.Parent.Name } catch { [version]'0.0' } } -Descending | Select-Object -First 1
    if ($bundled) { return $bundled.FullName }
    foreach ($p in @("$env:USERPROFILE\.local\bin\claude.exe")) { if (Test-Path $p) { return $p } }
    $cmd = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Quiet($exe, [string[]]$argv) {
    # PowerShell 5.1 は外部コマンドのエラー出力を「止まるエラー」として扱うので、ここだけ止めない
    $ErrorActionPreference = 'Continue'
    $out = & $exe @argv 2>&1 | Out-String
    return @{ ok = ($LASTEXITCODE -eq 0); text = $out.Trim() }
}

# 子のスクリプトを動かし、本当に成功したかを確かめる（出力を捨てずに、終了コードと「成功の文」を見る）
function Invoke-Step($file, [string]$okText) {
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
    return @{ ok = ($LASTEXITCODE -eq 0 -and $out -match [regex]::Escape($okText)); text = $out.Trim() }
}

# 1. プラグイン一式をコピー
if (-not (Test-Path (Join-Path $here '.claude-plugin\marketplace.json'))) {
    throw ".claude-plugin フォルダが見つかりません。ダウンロードして展開したフォルダの中で実行してください: $here"
}
Remove-Item -Recurse -Force $market -ErrorAction SilentlyContinue
[void](New-Item -ItemType Directory -Force -Path $market)
Copy-Item -Recurse -Force (Join-Path $here 'plugins') $market
Copy-Item -Recurse -Force (Join-Path $here '.claude-plugin') $market
$results += "OK プラグイン一式をコピーしました: $market"

# 2. Claude Code にプラグインを入れる（いったん外して入れ直す＝何度実行しても同じ）
$claude = Find-Claude
if ($claude) {
    [void](Invoke-Quiet $claude @('plugin', 'marketplace', 'remove', 'ai-lamp-market'))
    $from = 'GitHub'
    $r1 = @{ ok = $false; text = '' }
    if ($GitHubRepo -notmatch 'OWNER') { $r1 = Invoke-Quiet $claude @('plugin', 'marketplace', 'add', $GitHubRepo) }
    if (-not $r1.ok) {
        # GitHub に届かない（git が無い・ネットが無いなど）ときは、コピーから入れる（更新は届かない）
        $from = 'このパソコンのコピー'
        [void](Invoke-Quiet $claude @('plugin', 'marketplace', 'remove', 'ai-lamp-market'))
        $r1 = Invoke-Quiet $claude @('plugin', 'marketplace', 'add', $market)
    }
    $r2 = Invoke-Quiet $claude @('plugin', 'install', 'ai-lamp@ai-lamp-market')
    if ($r1.ok -and $r2.ok) {
        $results += "OK Claude Code にプラグインを入れました（入れ元: $from。Claude を開き直すと有効になります）"
        $didClaude = $true
    } else {
        $results += "NG Claude Code へのプラグインの追加に失敗しました:`n$($r1.text)`n$($r2.text)"
    }
} else {
    $results += "-- Claude Code が見つからないので、Claude 用の設定は飛ばしました"
}

# 3. Codex
if (-not $NoCodex -and (Test-Path (Join-Path $env:USERPROFILE '.codex'))) {
    $r = Invoke-Step (Join-Path $scripts 'codex-install.ps1') 'Codex 用のランプのフックを入れました'
    # hooks.json に 6 つのランプ用フックが本当に入ったかも確かめる
    $hj = Join-Path $env:USERPROFILE '.codex\hooks.json'
    $count = 0
    if (Test-Path $hj) { $count = ([regex]::Matches((Get-Content $hj -Raw -Encoding UTF8), 'ai-lamp')).Count }
    if (-not $r.ok -or $count -lt 6) {
        $results += "NG Codex 用のフックを入れられませんでした（ランプ用のフック $count / 6 件）:`n$($r.text)"
    } else {
    $results += "OK Codex 用のフックを入れました（ランプのフックを承認してください。Codex アプリは、入力欄の下に出る、黄色い点付きのフックのアイコン →「フックの確認」で、lamp-hook または lamp.ps1 と書かれたランプ用のフックを許可（全部ランプ用なら「すべて許可」、ほかのフックもあればランプ用だけ選んで「選択した項目を許可」）。これで完了で、設定画面でもう一度同じ操作をする必要はありません。アイコンが無いときは承認済みのこともあるので 設定 → Hooks で確かめます。ターミナルの Codex は /hooks）"
        $didCodex = $true
    }
} elseif (-not $NoCodex) {
    $results += "-- Codex は入っていないようなので、Codex 用の設定は飛ばしました"
}

# 4. 常駐の係（v0.8）と既読で消える機能
#    常駐の係は、合図をすぐランプに送るためにいつも入れる（重いパソコンでも速く光るように）。
#    既読で消える機能は -Watch でオン、-NoWatch でオフ（どちらも無ければ今のまま。初めてならオフ）
$seen = if ($Watch) { 'on' } elseif ($NoWatch) { 'off' } else { 'keep' }
$ErrorActionPreference = 'Continue'
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'watch-install.ps1') -Seen $seen 2>&1 | Out-String
$ok = ($LASTEXITCODE -eq 0 -and $out -match '常駐の係を入れました')
$ErrorActionPreference = 'Stop'
# 係が本当に動き始めたか（係の目印があるか）を少し待って確かめる
$running = $false
for ($i = 0; $i -lt 10 -and -not $running; $i++) {
    Start-Sleep -Milliseconds 500
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\ai-lamp-watch', [ref]$m)) { $m.Dispose(); $running = $true }
}
$seenOn = -not (Test-Path (Join-Path $env:USERPROFILE '.cache\ai-lamp\seen-off'))
if ($ok -and $running) {
    $results += "OK 常駐の係を入れました（合図をすぐランプに送ります。パソコン起動時に自動で動きます）"
    $results += $(if ($seenOn) { "OK 既読で消える機能はオンです" } else { "-- 既読で消える機能はオフです" })
} else { $results += "NG 常駐の係を始められませんでした（ランプは光りますが、少し遅くなります）:`n$out" }

# 5. ランプがつながっているか確かめて、緑に 2 秒光らせる（AI もお客さんも、結果をそのまま見ればよい）
$test = Join-Path $scripts 'lamp-test.ps1'
if (Test-Path $test) {
    $results += (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test | Out-String).Trim()
}

# 結果は UTF-8 で出す（AI のアプリが読むときに文字化けしないように。子のスクリプトの出力を受け取り終わってから切り替える）
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
"=== AI通知ランプの設定結果 ==="
$results
# 最後の案内は、実際に設定したアプリだけを対象にする
$apps = @()
if ($didClaude) { $apps += 'Claude' }
if ($didCodex) { $apps += 'Codex' }
if ($apps.Count -gt 0) {
    "最後に、$($apps -join ' と ') のアプリを終了して、開き直してください。"
    if ($didClaude) {
        "  ・Claude アプリは右上の × では裏で動き続けることがあるので、左上の「≡」→「ファイル」→「終了」で終了します（画面の見本: https://raw.githubusercontent.com/kisimenn/ai-lamp/main/docs/claude-quit.png）。"
    }
    if ($didCodex) {
        "  ・Codex アプリは右上の × では裏で動き続けることがあるので、メニューの「ファイル」→「ChatGPT を終了」で終了します（Codex でもメニューには「ChatGPT」と出ます。画面の見本: https://raw.githubusercontent.com/kisimenn/ai-lamp/main/docs/codex-quit.png）。"
        "  ・開き直したら、まだ承認していなければランプのフックを承認します（承認済みなら不要）。"
    }
    "  ・そのあと新しい会話で作業を頼み、青 → 緑 と光るか確かめてください（上の緑 2 秒は「ランプが見つかった」確認で、AI との連動はこれから確かめます）。"
}
""
"光り方は、AI に頼めば変えられます。たとえば:"
"  ・「作業中の色を紫にして」"
"  ・「夜は暗くして」"
"  ・「作業が終わったら虹色でお祝いして」"
"  ・「作業が10分を超えたら色を変えて」"
"  ・「やさしい光り方にして」（ほかに 派手・夜用・集中）"
