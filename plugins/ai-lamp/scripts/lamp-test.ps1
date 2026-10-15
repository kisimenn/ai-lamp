# ランプがつながっているか確かめて、緑に 2 秒光らせてから消す（Windows）
#   setup.ps1 の最後に呼ぶ。「ランプの確認をして」と頼まれたときにも使える
#   結果は日本語の 1〜2 行で表示する（AI はそれをそのままお客さんに伝えればよい）
#   見つけた場所は記録（state.json）に残すので、最初の合図から探さずにすぐ送れる
#   必ず exit 0
$ErrorActionPreference = 'Stop'
$KnownVids = '303A', '2E8A', '10C4', '1209'   # Espressif, Raspberry Pi, CP2102N, CH552(ch55xduino)
$NoResetVids = '303A', '10C4'                 # 開くとリセットされる基板。DTR を立てない

function Open-Lamp($port, $vid) {
    $s = New-Object System.IO.Ports.SerialPort $port, 115200
    $s.ReadTimeout = 800; $s.WriteTimeout = 800; $s.NewLine = "`n"
    $s.DtrEnable = -not ($NoResetVids -contains $vid)
    $s.RtsEnable = $false
    $s.Open()
    $s
}

# 1 行送って、期待する返事が来るか（関係ない行は 3 行まで読み飛ばす）
function Send-Line($s, $line, $expect) {
    $s.Write("$line`n")
    for ($i = 0; $i -lt 3; $i++) {
        try { if ($s.ReadLine().Trim().StartsWith($expect)) { return $true } } catch { return $false }
    }
    return $false
}

# ランプらしい機器の一覧。まず Windows の機器の登録情報（読むだけ・速い）から、無ければ従来の問い合わせ（数秒）
function Get-Candidates {
    $present = [System.IO.Ports.SerialPort]::GetPortNames()
    $fast = @(foreach ($vid in $KnownVids) {
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like "VID_$vid*" } | ForEach-Object {
                Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $n = (Get-ItemProperty (Join-Path $_.PSPath 'Device Parameters') -ErrorAction SilentlyContinue).PortName
                    if ($n -and ($present -contains $n)) { [pscustomobject]@{ Port = $n; Vid = $vid } }
                }
            }
    })
    if ($fast.Count) { return $fast }
    @(Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%(COM%'" | ForEach-Object {
        if ($_.Name -match '\((COM\d+)\)') {
            $com = $Matches[1]
            if ($_.PNPDeviceID -match 'VID_([0-9A-Fa-f]{4})' -and $KnownVids -contains $Matches[1].ToUpper()) {
                [pscustomobject]@{ Port = $com; Vid = $Matches[1].ToUpper() }
            }
        }
    })
}

# 送信プログラム（lamp.ps1）や見張りと同時にランプを開かないよう、同じ目印で順番待ちする
$mx = New-Object System.Threading.Mutex($false, 'Local\ai-lamp-serial')
$held = $false
try {
    try { $held = $mx.WaitOne(3000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
    $candidates = @(Get-Candidates)
    $found = $null
    foreach ($c in $candidates) {
        try {
            $s = Open-Lamp $c.Port $c.Vid
            try {
                $s.DiscardInBuffer()
                if (Send-Line $s 'ID?' 'AILAMP') {
                    $found = $c
                    [void](Send-Line $s 'S done' 'OK')      # 緑に光らせる
                    Start-Sleep -Seconds 2
                    [void](Send-Line $s 'S off' 'OK')       # 消す
                    break
                }
            } finally { $s.Close() }
        } catch { }
    }
    if ($held) { $mx.ReleaseMutex(); $held = $false }

    if ($found) {
        # ・ランプへの表示を手で変えたので、次の合図で必ず送り直すよう sent を空にする
        # ・見つけた場所を記録しておき、最初の合図から探さずにすぐ送れるようにする
        $dir = if ($env:AI_LAMP_STATE_DIR) { $env:AI_LAMP_STATE_DIR } else { Join-Path $env:USERPROFILE '.cache\ai-lamp' }
        $stateFile = Join-Path $dir 'state.json'
        Add-Type -AssemblyName System.Web.Extensions
        $json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $utf8 = New-Object System.Text.UTF8Encoding $false
        try {
            [void](New-Item -ItemType Directory -Force -Path $dir)
            $st = $null
            if (Test-Path $stateFile) { try { $st = $json.DeserializeObject([System.IO.File]::ReadAllText($stateFile, $utf8)) } catch { } }
            if (-not $st) { $st = @{ sessions = @{} } }
            $st['sent'] = $null; $st['port'] = $found.Port; $st['vid'] = $found.Vid
            [System.IO.File]::WriteAllText($stateFile, $json.Serialize($st), $utf8)
        } catch { }
        "OK ランプが見つかりました（$($found.Port)）。ランプが 2 秒ほど緑に光ったのを確かめてください。"
    } elseif ($candidates.Count) {
        "NG ランプらしい機器（$(($candidates | ForEach-Object { $_.Port }) -join '、')）はありますが、返事がありません。ランプを USB から抜いて、挿し直してから、もう一度確かめてください。"
    } else {
        "NG ランプが見つかりません。ランプを USB に挿してください（挿すと虹色が流れます）。挿したあと、もう一度確かめてください。"
    }
} catch {
    "NG ランプの確認中にエラーが起きました: $_"
} finally {
    if ($held) { $mx.ReleaseMutex() }
    $mx.Dispose()
}
exit 0
