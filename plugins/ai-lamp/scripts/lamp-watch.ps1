# AI通知ランプ 常駐の係（Windows / PowerShell 版）: 画面の見張り（既読で消える機能）と、受付箱の合図の送信（v0.8）
#
# ランプが「完了 / 質問待ち / エラー」を表示したあとに、
# Claude の画面がいちばん前にある状態でマウスかキーボードを触ったら、ランプを消す。
#
# 見ているもの（これ以外は見ない・記録しない）:
#   ・いちばん前にあるアプリの名前（例: claude）
#   ・最後にマウスかキーボードを触った時刻（どのキーを押したかは見ない）
#
#   使い方: lamp-watch.ps1          （画面なしで常駐。watch-install.ps1 が起動時に自動で動かす）
#           lamp-watch.ps1 -Show    （動作確認用。何をしたか表示する）
#
# Claude の画面とみなすアプリは %USERPROFILE%\.cache\ai-lamp\watch-apps.txt に1行1つ書く（.exe なし）
#   例: claude / Code（VS Code）/ WindowsTerminal
#   claude（Claude のデスクトップアプリ）と ChatGPT・Codex（Codex のデスクトップアプリは中身の名前が ChatGPT）は最初から対象。
#   ファイルに書いたアプリは、それに付け足される。書き換えたら見張りを起動し直す
param([switch]$Show)

$dir = if ($env:AI_LAMP_STATE_DIR) { $env:AI_LAMP_STATE_DIR } else { Join-Path $env:USERPROFILE '.cache\ai-lamp' }
$stateFile = Join-Path $dir 'state.json'
$appsFile = Join-Path $dir 'watch-apps.txt'
$Apps = @('claude', 'ChatGPT', 'Codex')
if (Test-Path $appsFile) {
    $list = @(Get-Content $appsFile -Encoding UTF8 | ForEach-Object { $_.Trim() -replace '\.exe$', '' } | Where-Object { $_ -and -not $_.StartsWith('#') })
    $Apps = @($Apps + $list | Select-Object -Unique)
}
$NoticeStates = 'done', 'ask', 'error'    # 消す対象（作業中は消さない）
$LampPs1 = Join-Path $PSScriptRoot 'lamp.ps1'
# v0.8: 受付箱（合図係 lamp-hook.exe が合図を置く）。ここを 0.1 秒ごとに見て、すぐランプに送る
$queueDir = Join-Path $dir 'queue'
# 既読で消える機能を使わない人は、このファイルがある（受付箱の仕事だけする）
$seenOffFile = Join-Path $dir 'seen-off'

# 二重に動かない
$mutex = New-Object System.Threading.Mutex($false, 'Local\ai-lamp-watch')
if (-not $mutex.WaitOne(0)) { if ($Show) { 'すでに見張りが動いています' }; exit 0 }

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LampWatch {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    // 最後にマウスかキーボードを触ってから何秒たったか
    public static double SecondsSinceInput() {
        var info = new LASTINPUTINFO(); info.cbSize = (uint)Marshal.SizeOf(info);
        if (!GetLastInputInfo(ref info)) return -1;
        return unchecked((uint)Environment.TickCount - info.dwTime) / 1000.0;
    }
    // いちばん前にある画面のプロセス番号
    public static uint ForegroundPid() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid; }
}
'@
Add-Type -AssemblyName System.Web.Extensions
$json = New-Object System.Web.Script.Serialization.JavaScriptSerializer

if ($Show) { "見張り開始: $($Apps -join ', ') が前面で操作されたらランプを消す（Ctrl+C で終了）" }

# 動作の記録（いつ始まり、いつ終わったか、エラー）。強制終了されたときは「終了」が残らない
$logFile = Join-Path $dir 'watch.log'
function Write-WatchLog($msg) {
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 100KB) { Move-Item -Force $logFile "$logFile.old" }
        Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -Encoding UTF8
    } catch { }
}
Write-WatchLog "開始 PID=$PID 対象=$($Apps -join ',')"
$lastErr = ''

$lastTick = Get-Date
try {
while ($true) {
    # 受付箱の合図を、届いた順に送る（書きかけの .tmp は読まない。5 分より古いものは捨てる）
    try {
        if (Test-Path $queueDir) {
            foreach ($f in @(Get-ChildItem $queueDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                try {
                    $parts = $f.BaseName -split '[-.]'
                    $ticks = [long]$parts[0]; $qKind = $parts[-1]
                    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    if (([DateTime]::UtcNow.Ticks - $ticks) / 10000000 -lt 300) { & $LampPs1 $qKind -InputJson $text -QueuedTicks $ticks }
                } catch { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
            }
        }
    } catch { }
    try {
        $st = $null
        if (Test-Path $stateFile) { $st = $json.DeserializeObject([System.IO.File]::ReadAllText($stateFile)) }
        # 作業中・質問待ちのあいだは30秒ごとに記録を見直す（Esc などで打ち切られた会話を外すため）
        if ($st -and $st.ContainsKey('sent') -and (@('work', 'ask') -contains $st['sent']) -and ((Get-Date) - $lastTick).TotalSeconds -ge 30) {
            $lastTick = Get-Date
            & $LampPs1 tick   # 同じ PowerShell の中で動かす（新しく起動しないので速い）
        }
        if ($st -and $st.ContainsKey('sent') -and ($NoticeStates -contains $st['sent']) -and -not (Test-Path $seenOffFile)) {
            $sentAt = if ($st.ContainsKey('sent_at') -and $st['sent_at']) { [double]$st['sent_at'] } else { 0 }
            $idle = [LampWatch]::SecondsSinceInput()
            $touchedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 - $idle
            # ランプが点いた「あと」に触った、かつ、そのとき Claude の画面が前にある
            # 点いてから 1.5 秒は消さない（画面を触っている最中だと、緑が一瞬しか見えず「チカッと光った」ように見えるため。2026-10-17）
            if ($idle -ge 0 -and $touchedAt -gt $sentAt + 1.5) {
                $fg = (Get-Process -Id ([LampWatch]::ForegroundPid()) -ErrorAction SilentlyContinue).ProcessName
                if ($Apps -contains $fg) {
                    & $LampPs1 seen   # 同じ PowerShell の中で動かす（新しく起動しないので速い）
                    if ($Show) { "$(Get-Date -Format HH:mm:ss) $($st['sent']) を消しました" }
                    # 消せたかを確かめ、消せなかった（ランプが外れている等）ときだけ 2 秒待つ（連打しない）
                    $after = $null; try { $after = $json.DeserializeObject([System.IO.File]::ReadAllText($stateFile)) } catch { }
                    if (-not ($after -and $after.ContainsKey('sent') -and $after['sent'] -eq 'off')) { Start-Sleep -Seconds 2 }
                }
            }
        }
    } catch {
        if ($Show) { "エラー: $_" }   # 見張りは止まらないようにする
        if ("$_" -ne $lastErr) { Write-WatchLog "エラー: $_"; $lastErr = "$_" }   # 同じエラーは1回だけ記録
    }
    Start-Sleep -Milliseconds 100
}
} finally {
    Write-WatchLog "終了 PID=$PID"
}
