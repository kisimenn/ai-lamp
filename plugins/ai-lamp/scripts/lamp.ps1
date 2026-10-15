# AI通知ランプ 送信スクリプト（Windows / PowerShell 版）v0.3
# host/lamp.py と同じ動き。Windows に最初から入っている PowerShell だけで動く（Python 不要）。
#
#   使い方: lamp.ps1 <work|done|ask|error|end|seen|tick>
#   stdin : フックの JSON（session_id だけ使う。無くても動く）
#   seen  : 画面の見張り（lamp-watch.ps1）から「ユーザーが見た」と知らせる。
#           done / ask / error を消し、その後に遅れて届く done では点け直さない
#   tick  : 記録の見直しだけ（見張りが30秒ごとに呼ぶ。打ち切られた「作業中」を外すため）
#
# 複数セッションを同時に動かしたとき、いちばん優先度の高い状態を表示する（ask > error > work > done > off）。
# 状態が変わったときだけランプに送る。失敗しても必ず exit 0（Claude Code の作業を止めない）。
param([string]$Kind)

$ErrorActionPreference = 'Stop'
$Priority = @{ ask = 4; error = 3; work = 2; done = 1; off = 0 }
$KnownVids = '303A', '2E8A', '10C4', '1209'   # Espressif, Raspberry Pi, Silicon Labs(CP2102N), CH552(ch55xduino)
$NoResetVids = '303A', '10C4'             # 開くとリセットされる基板。DTR を立てない
$SessionTtl = 12 * 3600                   # 12時間更新のないセッションは忘れる
$WorkTtl = 2 * 3600                       # 保険: 「作業中」のまま2時間合図のないセッションは忘れる
# 「ここまでやり直す」や Esc で止めると完了の合図が来ない。その会話は、時間ではなく
# Claude の会話の記録（transcript）を見て外す:
#   ・やり直し/再開: 新しい会話は、元の会話の発言を同じ整理番号（uuid）のまま引き継ぐ。
#                    整理番号が共通している古い会話は、置き去りになったとみなして外す
#   ・Esc で止めた : 記録の最後の行が「Request interrupted by user」 → その会話を外す
# 読むのは整理番号と止めた印だけ。中身は使わない・外に送らない。
$InterruptMark = 'Request interrupted by user'

function Get-Val($d, $k) { if ($d -and $d.ContainsKey($k)) { $d[$k] } }

# ---------- シリアル ----------
function Open-Lamp($port, $vid) {
    $s = New-Object System.IO.Ports.SerialPort $port, 115200
    $s.ReadTimeout = 500; $s.WriteTimeout = 500; $s.NewLine = "`n"
    $s.DtrEnable = -not ($NoResetVids -contains $vid)   # Pico は DTR が無いと返事しないことがある
    $s.RtsEnable = $false
    $s.Open()
    $s
}

# 1行送って、期待する返事が来るか（関係ない行は3行まで読み飛ばす）
# 見張り・フック・確認用のプログラムが同時にランプを開かないよう、名前付きの目印で順番待ちする
function Invoke-Lamp($port, $vid, $line, $expect) {
    $mx = New-Object System.Threading.Mutex($false, 'Local\ai-lamp-serial')
    $held = $false
    try {
        try { $held = $mx.WaitOne(1500) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { return $false }
        $s = Open-Lamp $port $vid
        try {
            $s.DiscardInBuffer()
            $s.Write("$line`n")
            for ($i = 0; $i -lt 3; $i++) {
                $r = $s.ReadLine().Trim()
                if ($r.StartsWith($expect)) { return $true }
                if ($r -eq 'ERR') { return $false }
            }
            return $false
        } finally { $s.Close() }
    } catch { return $false }
    finally { if ($held) { $mx.ReleaseMutex() }; $mx.Dispose() }
}

# 既知のマイコンの COM ポート一覧（Port と Vid）
#   速さのため、まず Windows の機器の登録情報（読むだけ）から探す。見つからなければ従来の問い合わせ（数秒かかる）
function Get-LampPorts {
    $present = [System.IO.Ports.SerialPort]::GetPortNames()
    $knownInRegistry = 0
    $fast = @(foreach ($vid in $KnownVids) {
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like "VID_$vid*" } | ForEach-Object {
                Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $n = (Get-ItemProperty (Join-Path $_.PSPath 'Device Parameters') -ErrorAction SilentlyContinue).PortName
                    if ($n) { $knownInRegistry++ }
                    if ($n -and ($present -contains $n)) { [pscustomobject]@{ Port = $n; Vid = $vid } }
                }
            }
    })
    if ($fast.Count) { return $fast }
    # 前に挿したことのあるランプの記録はあるのに、今そのポートが無い＝抜けている。遅い探し方（6 秒ほど）はしない
    # （抜いたまま作業しても、合図のたびに待たされないように）
    if ($knownInRegistry -gt 0) { return @() }
    Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%(COM%'" | ForEach-Object {
        if ($_.Name -match '\((COM\d+)\)') {
            $com = $Matches[1]
            if ($_.PNPDeviceID -match 'VID_([0-9A-Fa-f]{4})' -and $KnownVids -contains $Matches[1].ToUpper()) {
                [pscustomobject]@{ Port = $com; Vid = $Matches[1].ToUpper() }
            }
        }
    }
}

# ランプに状態を送る。送れたら @(ポート, VID)、だめなら $null
#   速さのため、前回見つけた場所には「ID?」を聞かずにすぐ送る（ランプ以外なら OK が返らないので探し直す）
function Send-Target($cachedPort, $cachedVid, $target, $app) {
    $line = Get-LampLine $target $app
    if ($env:AI_LAMP_PORT) {
        if (Invoke-Lamp $env:AI_LAMP_PORT '' $line 'OK') { return @($env:AI_LAMP_PORT, '') }
        return $null
    }
    if ($cachedPort -and (Invoke-Lamp $cachedPort $cachedVid $line 'OK')) { return @($cachedPort, $cachedVid) }
    foreach ($p in Get-LampPorts) {
        if ((Invoke-Lamp $p.Port $p.Vid 'ID?' 'AILAMP') -and (Invoke-Lamp $p.Port $p.Vid $line 'OK')) { return @($p.Port, $p.Vid) }
    }
    return $null
}

# 光り方の好み（お客さんが AI に頼むと書き換わる colors.json）からランプに送る文を作る
#   例: { "brightness": 50, "work": { "color": [128, 0, 255], "mode": "breathe" } }
#   color は [赤, 緑, 青] か "rainbow"（虹色）。mode は solid / breathe / blink / fastblink
#   brightness は 1〜100（%）。色を決めていない状態は、今までどおりの光り方（S <状態>）
#   いつも先に明るさ（B）を送る（好みのファイルを消したときに、明るさが元に戻るように）
#   ほかに使える項目（どれも書かなければ使わない）:
#     "night":     { "from": "22:00", "to": "07:00", "brightness": 20 }  夜の間だけ明るさを変える
#     "celebrate": true                                                  終わったときに虹色でお祝い（ファーム v1.1 から）
#     "long_work": { "minutes": 10, "color": [160, 0, 255] }            作業がこの時間続いたら色を変える（ファーム v1.1 から）
#     "codex" / "claude": { "work": {...}, "done": {...}, "ask": {...} } その AI のときだけ使う色（上の work などより優先）
function Get-LampLine($target, $app) {
    $bright = 255
    $color = $null
    $extra = @()
    try {
        $f = Join-Path $dir 'colors.json'
        if (Test-Path $f) {
            $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $pref = $js.DeserializeObject([System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8))
            if ($pref.ContainsKey('brightness')) {
                $pct = [double]$pref['brightness']
                if ($pct -ge 1 -and $pct -le 100) { $bright = [int][Math]::Round($pct * 255 / 100) }
            }
            # 夜の明るさ（from〜to の時刻の間。日をまたいでもよい）
            $night = $pref['night']
            if ($night -is [System.Collections.IDictionary]) {
                try {
                    $nowMin = (Get-Date).Hour * 60 + (Get-Date).Minute
                    $fm = [TimeSpan]::Parse([string]$night['from']).TotalMinutes
                    $tm = [TimeSpan]::Parse([string]$night['to']).TotalMinutes
                    $inNight = if ($fm -le $tm) { $nowMin -ge $fm -and $nowMin -lt $tm } else { $nowMin -ge $fm -or $nowMin -lt $tm }
                    $np = [double]$night['brightness']
                    if ($inNight -and $np -ge 1 -and $np -le 100) { $bright = [int][Math]::Round($np * 255 / 100) }
                } catch { }
            }
            if ($target -ne 'off') {
                # その AI 用の色があればそれを、無ければふつうの色を使う
                $e = $null
                if ($app -and $pref[$app] -is [System.Collections.IDictionary] -and $pref[$app][$target]) { $e = $pref[$app][$target] }
                elseif ($pref[$target] -is [System.Collections.IDictionary]) { $e = $pref[$target] }
                if ($e) {
                    $c = $e['color']; $mode = [string]$e['mode']
                    if (@('solid', 'breathe', 'blink', 'fastblink') -notcontains $mode) { $mode = 'solid' }
                    if ($c -is [string] -and $c -eq 'rainbow') {
                        $color = "R $mode"   # 虹色（ランプのファーム v1.0 から）
                    } else {
                        $rgb = @($c | ForEach-Object { [Math]::Max(0, [Math]::Min(255, [int]$_)) })
                        if ($rgb.Count -eq 3) { $color = "C $($rgb[0]) $($rgb[1]) $($rgb[2]) $mode" }
                    }
                }
                # 長い作業の目安（作業中のときだけ）
                $lw = $pref['long_work']
                if ($target -eq 'work' -and $lw -is [System.Collections.IDictionary]) {
                    $min = [double]$lw['minutes']
                    $lc = @($lw['color'] | ForEach-Object { [Math]::Max(0, [Math]::Min(255, [int]$_)) })
                    if ($min -ge 1 -and $min -le 500 -and $lc.Count -eq 3) { $extra += "L $([int]($min * 60)) $($lc[0]) $($lc[1]) $($lc[2])" }
                }
                # 終わったときのお祝い
                if ($target -eq 'done' -and $hookEvent -eq 'Stop' -and $pref['celebrate'] -eq $true) { $extra += 'X' }   # 返事が終わった瞬間だけ
            }
        }
    } catch { }   # 好みのファイルが壊れていても、今までどおりに光らせる
    if (-not $color) { $color = "S $target" }
    return (@("B $bright", $color) + $extra) -join "`n"
}

# 動作の記録（会話の中身は書かない。種類・合図の名前・会話番号の先頭・結果・かかった時間だけ）
function Write-Event($msg) {
    try {
        $log = Join-Path $dir 'events.log'
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 200KB) { Move-Item -Force $log "$log.old" }
        [System.IO.File]::AppendAllText($log, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $msg`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

# ---------- メイン ----------
try {
    # 遅れの調査用: PowerShell が起動されてから、ここに来るまでの時間（起動の重さ）
    $bootMs = -1
    # 見張り（seen/tick）は同じ PowerShell の中から呼ばれるので、起動時間は測らない（意味のない大きな数になるため）
    if ($Kind -ne 'seen' -and $Kind -ne 'tick') { try { $bootMs = [int]((Get-Date) - (Get-Process -Id $PID).StartTime).TotalMilliseconds } catch { } }
    if (@('work', 'done', 'ask', 'error', 'end', 'seen', 'tick') -notcontains $Kind) {
        [Console]::Error.WriteLine('usage: lamp.ps1 <work|done|ask|error|end|seen|tick>')
        exit 0
    }
    # v0.5: エラーは「あなたの出番」として質問待ちと同じ橙にまとめる（Claude と Codex で色の意味をそろえる）。
    # 古いフックから error が届いても橙になるよう、ここで読み替える。赤（ランプの S error）は将来用に空けておく
    if ($Kind -eq 'error') { $Kind = 'ask' }

    # フックの JSON からセッション番号だけ取り出す（バイトで受けて UTF-8 として読む）
    $session = 'default'
    if ($Kind -ne 'seen' -and $Kind -ne 'tick' -and [Console]::IsInputRedirected) {
        $ms = New-Object System.IO.MemoryStream
        [Console]::OpenStandardInput().CopyTo($ms)
        $raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $m = [regex]::Match($raw, '"session_id"\s*:\s*"([^"]+)"')
        if ($m.Success) { $session = $m.Groups[1].Value }
        $m = [regex]::Match($raw, '"hook_event_name"\s*:\s*"([^"]+)"')
        if ($m.Success) { $hookEvent = $m.Groups[1].Value }
        $m = [regex]::Match($raw, '"transcript_path"\s*:\s*"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { $transcriptEsc = $m.Groups[1].Value }
    }

    $dir = if ($env:AI_LAMP_STATE_DIR) { $env:AI_LAMP_STATE_DIR } else { Join-Path $env:USERPROFILE '.cache\ai-lamp' }
    [void](New-Item -ItemType Directory -Force -Path $dir)
    $stateFile = Join-Path $dir 'state.json'
    $lockFile = Join-Path $dir 'state.lock'
    Add-Type -AssemblyName System.Web.Extensions
    $json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $transcript = $null
    if ($transcriptEsc) { try { $transcript = $json.Deserialize('"' + $transcriptEsc + '"', [string]) } catch { } }

    # 会話の記録の先頭にある発言の整理番号（uuid）の一覧
    function Get-Uuids($path) {
        $ids = @{}
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $ids }
        foreach ($line in (Get-Content -LiteralPath $path -TotalCount 300 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $mm = [regex]::Match($line, '"uuid"\s*:\s*"([0-9a-fA-F-]{36})"')
            if ($mm.Success) { $ids[$mm.Groups[1].Value] = $true }
        }
        return $ids
    }

    # 会話の記録が「止められました」で終わっているか（最後の 8KB だけ読む）
    function Test-Interrupted($path) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            try {
                $len = [Math]::Min($fs.Length, 8192)
                [void]$fs.Seek(-$len, 'End')
                $buf = New-Object byte[] $len
                [void]$fs.Read($buf, 0, $len)
            } finally { $fs.Close() }
            $lines = [System.Text.Encoding]::UTF8.GetString($buf) -split "`n" | Where-Object { $_.Trim() }
            if (-not $lines) { return $false }
            return ([string]@($lines)[-1]).Contains($InterruptMark)
        } catch { return $false }
    }

    # 複数のフックが同時に動くので、状態ファイルはロックしてから触る
    $deadline = (Get-Date).AddSeconds(3)
    $lock = $null
    while (-not $lock) {
        try { $lock = [System.IO.File]::Open($lockFile, 'CreateNew', 'Write', 'None') }
        catch {
            # 異常終了で残ったロックは10秒で無効とみなす
            $item = Get-Item $lockFile -ErrorAction SilentlyContinue
            if ($item -and ((Get-Date) - $item.LastWriteTime).TotalSeconds -gt 10) {
                Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
                continue
            }
            if ((Get-Date) -gt $deadline) { exit 0 }
            Start-Sleep -Milliseconds 20
        }
    }

    try {
        $st = $null
        if (Test-Path $stateFile) {
            try { $st = $json.DeserializeObject([System.IO.File]::ReadAllText($stateFile, $utf8)) } catch { }
        }
        if (-not $st) { $st = @{} }
        $sessions = Get-Val $st 'sessions'
        if (-not $sessions) { $sessions = @{} }

        if ($Kind -eq 'end') {
            [void]$sessions.Remove($session)
        } elseif ($Kind -eq 'tick') {
            # 記録の見直しだけ（下の集約で古い「作業中」が外れる）
        } elseif ($Kind -eq 'seen') {
            # 見た: お知らせ中のセッションをすべて消灯扱いにする
            foreach ($k in @($sessions.Keys)) {
                $v = $sessions[$k]
                if (@('done', 'ask', 'error') -contains (Get-Val $v 'state')) { $v['state'] = 'off'; $v['seen'] = $true }
            }
        } elseif ($Kind -eq 'done' -and (Get-Val (Get-Val $sessions $session) 'seen')) {
            $sessions[$session]['ts'] = $now   # 見たあとに遅れて届いた done は無視（点け直さない）
        } else {
            $isNew = -not $sessions.ContainsKey($session)
            # 記録の場所（届かないこともある。Codex など）。必ず文字か $null にする
            # （何も出力しない式をそのまま入れると PowerShell 特有の「空」が入り、保存で失敗するため）
            $tp = $null
            if ($transcript) { $tp = [string]$transcript }
            else { $prev = Get-Val (Get-Val $sessions $session) 'tp'; if ($prev) { $tp = [string]$prev } }
            $app = if ($tp -and $tp -match '[\\/]\.claude[\\/]') { 'claude' } elseif ($tp -and $tp -notmatch '[\\/]\.codex[\\/]') { 'claude' } else { 'codex' }
            $sessions[$session] = @{ state = $Kind; ts = $now; tp = $tp; app = $app }
            # 初めて見る会話なら、発言を引き継いだ元の会話（やり直し・再開の元）を外す（置き去りになっているため）
            if ($isNew -and $tp) {
                $mine = Get-Uuids $tp
                if ($mine.Count) {
                    foreach ($k in @($sessions.Keys)) {
                        if ($k -eq $session) { continue }
                        $other = Get-Val $sessions[$k] 'tp'
                        if (-not $other -or $other -eq $tp) { continue }
                        foreach ($id in (Get-Uuids $other).Keys) {
                            if ($mine.ContainsKey($id)) { [void]$sessions.Remove($k); break }
                        }
                    }
                }
            }
        }

        # 生きているセッションの中で、いちばん優先度の高い状態を選ぶ
        $alive = @{}
        $target = 'off'
        $leadApp = $null; $leadTs = -1
        foreach ($k in @($sessions.Keys)) {
            $v = $sessions[$k]
            $age = $now - [double](Get-Val $v 'ts')
            $state = Get-Val $v 'state'
            if ($state -eq 'work' -and $age -ge $WorkTtl) { continue }
            # Esc で止めた会話を外す（今まさに合図が来た会話や、15秒以内に合図のあった会話は調べない）
            if (@('work', 'ask') -contains $state -and $k -ne $session -and $age -ge 15 -and (Test-Interrupted (Get-Val $v 'tp'))) { continue }
            if ($age -lt $SessionTtl) {
                $alive[$k] = $v
                if ($Priority[(Get-Val $v 'state')] -gt $Priority[$target]) { $target = Get-Val $v 'state'; $leadTs = -1 }
                if ((Get-Val $v 'state') -eq $target -and [double](Get-Val $v 'ts') -gt $leadTs) { $leadTs = [double](Get-Val $v 'ts'); $leadApp = Get-Val $v 'app' }
            }
        }
        $st['sessions'] = $alive

        $result = 'same'
        # 頼んだ・終わった・許可を求めた、の合図のときは、同じ色でも必ず送り直す
        # （ランプが自動で再起動した・挿し直した、などで表示が消えていても、ここで正しい色に戻る）
        $force = @('UserPromptSubmit', 'Stop', 'PermissionRequest', 'Notification') -contains $hookEvent
        if ($target -ne (Get-Val $st 'sent') -or $force) {
            $found = Send-Target (Get-Val $st 'port') (Get-Val $st 'vid') $target $leadApp
            if ($found) {
                $st['sent'] = $target; $st['port'] = $found[0]; $st['vid'] = $found[1]; $st['sent_at'] = $now
                $result = "ok($($found[0]))"
            } else {
                $st['sent'] = $null   # ランプ未接続。次回また試す
                $result = 'NG(ランプに届かない)'
            }
        }
        $sid = if ($session.Length -gt 8) { $session.Substring(0, 8) } else { $session }
        Write-Event ("{0} event={1} session={2} target={3} send={4} {5}ms boot={6}ms" -f $Kind, $hookEvent, $sid, $target, $result, [int](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 - $now) * 1000), $bootMs)

        $tmp = "$stateFile.tmp"
        [System.IO.File]::WriteAllText($tmp, $json.Serialize($st), $utf8)
        Move-Item -Force $tmp $stateFile
    } finally {
        $lock.Close()
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    }

    # 画面の見張りが止まっていたら起動し直す
    #   ・見張りを使っている人だけ（スタートアップのショートカットと見張りのファイルがある）
    #   ・完了/質問待ち/エラーの合図のときだけ、多くても1分に1回だけ確かめる
    #   ・Claude のアプリと一緒に止まらないよう、Windows（WMI）に起動してもらう
    if (@('done', 'ask', 'error') -contains $Kind) {
        try {
            $watch = Join-Path $env:USERPROFILE '.cache\ai-lamp\watch\lamp-watch.ps1'
            $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ai-lamp-watch.lnk'
            $stamp = Join-Path $dir 'watch-check'
            $recent = (Test-Path $stamp) -and ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds -lt 60
            if ((Test-Path $watch) -and (Test-Path $lnk) -and -not $recent) {
                [System.IO.File]::WriteAllText($stamp, '')
                $m = $null
                if ([System.Threading.Mutex]::TryOpenExisting('Local\ai-lamp-watch', [ref]$m)) {
                    $m.Dispose()   # 動いている
                } else {
                    $cmd = "`"$((Get-Command powershell.exe).Source)`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watch`""
                    [void](Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd })
                }
            }
        } catch { }
    }
} catch {
    [Console]::Error.WriteLine("ai-lamp: $_")   # フックは失敗しても Claude Code の作業を止めない
}
exit 0
