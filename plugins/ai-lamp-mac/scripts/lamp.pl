#!/usr/bin/perl
# AI通知ランプ 送信スクリプト（Mac 版）v0.8.6
# Windows 版（lamp.ps1）と同じ動き。Mac に最初から入っている Perl だけで動く（ほかのソフトは不要）。
#
#   使い方: lamp.pl <work|done|ask|error|end|seen|tick|test>
#   test  : ランプを探して緑に 2 秒光らせ、結果を日本語で表示する（setup.sh の最後に使う）
#   stdin : フックの JSON（session_id と transcript_path だけ使う。無くても動く）
#   seen  : 「ユーザーが見た」と知らせる。done / ask を消し、その後に遅れて届く done では点け直さない
#   tick  : 記録の見直しだけ（打ち切られた「作業中」を外す）
#
# 色は 3 つ（青=作業中 / 緑=完了 / 橙=あなたの出番）。error は ask（橙）に読み替える。
# 複数セッションを同時に動かしたとき、いちばん優先度の高い状態を表示する（ask > work > done > off）。
# 状態が変わったときだけランプに送る。失敗しても必ず exit 0（Claude Code / Codex の作業を止めない）。
#
# ランプは /dev/cu.usbmodem* として見える（CH552 の USB シリアル）。「ID?」に「AILAMP」と答えたものだけをランプとみなす。
# 試験用: AI_LAMP_STATE_DIR（記録の場所を変える）、AI_LAMP_PORT（ポートを決め打ち）、
#         AI_LAMP_FAKE_LOG（ランプの代わりに、送る行をこのファイルに書く。Mac 以外での動作確認用）
use strict;
use warnings;
use JSON::PP;
use Time::HiRes qw(time sleep);
use Fcntl qw(:DEFAULT :flock);
use POSIX qw(:termios_h);

my %Priority    = (ask => 4, error => 3, work => 2, done => 1, off => 0);
my $SessionTtl  = 12 * 3600;   # 12時間更新のないセッションは忘れる
my $WorkTtl     = 2 * 3600;    # 保険: 「作業中」のまま2時間合図のないセッションは忘れる
my $InterruptMark = 'Request interrupted by user';   # Esc で止めたときに会話の記録の最後に残る印

my $Kind = shift(@ARGV) // '';
my $json = JSON::PP->new->utf8->canonical;

eval { main(); 1 } or print STDERR "ai-lamp: $@";
exit 0;

# ---------- シリアル ----------
sub open_lamp {
    my ($port) = @_;
    sysopen(my $fh, $port, O_RDWR | O_NOCTTY | O_NONBLOCK) or return undef;
    my $fd = fileno($fh);
    my $t = POSIX::Termios->new;
    unless ($t->getattr($fd)) { close $fh; return undef; }
    $t->setiflag(0); $t->setoflag(0); $t->setlflag(0);
    $t->setcflag(CS8 | CREAD | CLOCAL);
    # 通信速度（USB シリアルでは意味がない）。Mac は速度をそのままの数で指定する。Perl の標準に B115200 は無い
    my $baud = eval { POSIX::B115200() } // 115200;
    eval { $t->setispeed($baud); $t->setospeed($baud); };
    $t->setcc(VMIN, 0); $t->setcc(VTIME, 0);
    $t->setattr($fd, TCSANOW);   # 速度の設定だけ断られても、生のまま通す設定（エコー無し）は効くので止めない
    return $fh;   # 開くと DTR が立つ（CH552 は DTR が無いと返事しない）
}

# 改行までの 1 行を読む。timeout 秒たっても来なければ undef
sub read_line {
    my ($fh, $bufref, $timeout) = @_;
    my $end = time + $timeout;
    while (1) {
        if ($$bufref =~ s/^(.*?)\r?\n//) { return $1; }
        my $left = $end - time;
        return undef if $left <= 0;
        my $rin = '';
        vec($rin, fileno($fh), 1) = 1;
        my $n = select(my $rout = $rin, undef, undef, $left);
        if ($n && $n > 0) {
            my $chunk;
            my $r = sysread($fh, $chunk, 256);
            if (defined $r && $r > 0) { $$bufref .= $chunk; }
            elsif (defined $r && $r == 0) { return undef; }
            elsif (!$!{EAGAIN} && !$!{EINTR}) { return undef; }
        }
    }
}

# 1行送って、期待する返事が来るか（関係ない行は3行まで読み飛ばす）
# 光り方の好み（お客さんが AI に頼むと書き換わる colors.json）からランプに送る文を作る（Windows の lamp.ps1 と同じ）
#   例: { "brightness": 50, "work": { "color": [128, 0, 255], "mode": "breathe" } }
#   color は [赤, 緑, 青] か "rainbow"（虹色）。mode は solid / breathe / blink / fastblink
#   brightness は 1〜100（%）。色を決めていない状態は今までどおり（S <状態>）。いつも先に明るさ（B）を送る
sub lamp_line {
    my ($dir, $target, $app, $event) = @_;
    my $bright = 255;
    my $color;
    my @extra;
    if (open(my $cf, '<', "$dir/colors.json")) {
        local $/;
        my $pref = eval { JSON::PP->new->relaxed->decode(<$cf>) };
        close $cf;
        if (ref($pref) eq 'HASH') {
            my $pct = $pref->{brightness};
            if (defined $pct && $pct =~ /^[\d.]+$/ && $pct >= 1 && $pct <= 100) { $bright = int($pct * 255 / 100 + 0.5); }
            # 夜の明るさ（from〜to の時刻の間。日をまたいでもよい）
            my $n = $pref->{night};
            if (ref($n) eq 'HASH' && ($n->{from} // '') =~ /^(\d+):(\d+)$/) {
                my $fm = $1 * 60 + $2;
                if (($n->{to} // '') =~ /^(\d+):(\d+)$/) {
                    my $tm = $1 * 60 + $2;
                    my @lt = localtime();
                    my $nm = $lt[2] * 60 + $lt[1];
                    my $in = $fm <= $tm ? ($nm >= $fm && $nm < $tm) : ($nm >= $fm || $nm < $tm);
                    my $np = $n->{brightness};
                    if ($in && defined $np && $np =~ /^[\d.]+$/ && $np >= 1 && $np <= 100) { $bright = int($np * 255 / 100 + 0.5); }
                }
            }
            if ($target ne 'off') {
                # その AI 用の色があればそれを、無ければふつうの色を使う
                my $e;
                if ($app && ref($pref->{$app}) eq 'HASH' && ref($pref->{$app}{$target}) eq 'HASH') { $e = $pref->{$app}{$target}; }
                elsif (ref($pref->{$target}) eq 'HASH') { $e = $pref->{$target}; }
                if ($e) {
                    my $mode = $e->{mode} // 'solid';
                    $mode = 'solid' unless $mode =~ /^(solid|breathe|blink|fastblink)$/;
                    if (defined $e->{color} && !ref($e->{color}) && $e->{color} eq 'rainbow') {
                        $color = "R $mode";   # 虹色（ランプのファーム v1.0 から）
                    } elsif (ref($e->{color}) eq 'ARRAY' && @{ $e->{color} } == 3) {
                        my @rgb = map { my $v = int($_ // 0); $v < 0 ? 0 : $v > 255 ? 255 : $v } @{ $e->{color} };
                        $color = "C @rgb $mode";
                    }
                }
                # 長い作業の目安（作業中のときだけ）
                my $lw = $pref->{long_work};
                if ($target eq 'work' && ref($lw) eq 'HASH' && ref($lw->{color}) eq 'ARRAY' && @{ $lw->{color} } == 3) {
                    my $min = $lw->{minutes} // 0;
                    if ($min =~ /^[\d.]+$/ && $min >= 1 && $min <= 500) {
                        my @lc = map { my $v = int($_ // 0); $v < 0 ? 0 : $v > 255 ? 255 : $v } @{ $lw->{color} };
                        push @extra, 'L ' . int($min * 60) . " @lc";
                    }
                }
                # 終わったときのお祝い
                push @extra, 'X' if $target eq 'done' && ($event // '') eq 'Stop' && $pref->{celebrate} && JSON::PP::is_bool($pref->{celebrate});
            }
        }
    }
    $color //= "S $target";
    return join("\n", "B $bright", $color, @extra);
}

sub invoke_lamp {
    my ($port, $line, $expect) = @_;
    if ($ENV{AI_LAMP_FAKE_LOG}) {
        if (open(my $lf, '>>', $ENV{AI_LAMP_FAKE_LOG})) { print $lf "$line\n"; close $lf; }
        return 1;
    }
    my $fh = open_lamp($port) or return 0;
    my $ok = 0;
    eval {
        sleep(0.05);
        eval { POSIX::tcflush(fileno($fh), TCIFLUSH()); };
        syswrite($fh, "$line\n");
        my $buf = '';
        for (1 .. 3) {
            my $r = read_line($fh, \$buf, 0.5);
            last unless defined $r;
            $r =~ s/\s+$//;
            if (index($r, $expect) == 0) { $ok = 1; last; }
            last if $r eq 'ERR';
        }
        1;
    };
    close $fh;
    return $ok;
}

sub find_lamp {
    my ($cached) = @_;
    return 'fake' if $ENV{AI_LAMP_FAKE_LOG};
    return $ENV{AI_LAMP_PORT} if $ENV{AI_LAMP_PORT};
    return $cached if $cached && -e $cached && invoke_lamp($cached, 'ID?', 'AILAMP');
    foreach my $p (glob('/dev/cu.usbmodem*')) {
        return $p if invoke_lamp($p, 'ID?', 'AILAMP');
    }
    return undef;
}

# ---------- 会話の記録（transcript）の見直し ----------
# 先頭 300 行にある発言の整理番号（uuid）の一覧
sub get_uuids {
    my ($path) = @_;
    my %ids;
    return \%ids unless $path && -f $path;
    if (open(my $fh, '<', $path)) {
        binmode $fh;
        my $n = 0;
        while (my $l = <$fh>) {
            last if ++$n > 300;
            $ids{$1} = 1 if $l =~ /"uuid"\s*:\s*"([0-9a-fA-F-]{36})"/;
        }
        close $fh;
    }
    return \%ids;
}

# 会話の記録が「止められました」で終わっているか（最後の 8KB だけ読む）
sub test_interrupted {
    my ($path) = @_;
    return 0 unless $path && -f $path;
    my $res = 0;
    eval {
        open(my $fh, '<', $path) or die;
        binmode $fh;
        my $size = -s $fh;
        my $len = $size < 8192 ? $size : 8192;
        seek($fh, $size - $len, 0);
        read($fh, my $buf, $len);
        close $fh;
        my @lines = grep { /\S/ } split(/\n/, $buf);
        $res = (@lines && index($lines[-1], $InterruptMark) >= 0) ? 1 : 0;
        1;
    };
    return $res;
}

# ---------- メイン ----------
sub main {
    unless (grep { $_ eq $Kind } qw(work done ask error end seen tick test diag)) {
        print STDERR "usage: lamp.pl <work|done|ask|error|end|seen|tick|test|diag>\n";
        return;
    }
    if ($Kind eq 'test') { lamp_test(); return; }
    if ($Kind eq 'diag') { lamp_diag(); return; }
    # 色は3つ。エラーは「あなたの出番」として橙（ask）にまとめる
    $Kind = 'ask' if $Kind eq 'error';

    # フックの JSON から session_id と transcript_path だけ取り出す
    my ($session, $transcript, $hookEvent) = ('default', undef, '');
    if ($Kind ne 'seen' && $Kind ne 'tick' && !-t STDIN) {
        local $/;
        my $raw = <STDIN>;
        $raw = '' unless defined $raw;
        $session = $1 if $raw =~ /"session_id"\s*:\s*"([^"]+)"/;
        $hookEvent = $1 if $raw =~ /"hook_event_name"\s*:\s*"([^"]+)"/;
        if ($raw =~ /"transcript_path"\s*:\s*("(?:[^"\\]|\\.)*")/) {
            my $s = eval { JSON::PP->new->decode("[$1]")->[0] };
            $transcript = $s if defined $s && length $s;
        }
    }

    my $home = $ENV{HOME} || (getpwuid($<))[7];
    my $dir = $ENV{AI_LAMP_STATE_DIR} || "$home/.cache/ai-lamp";
    unless (-d $dir) { mkdir($_) for ($home . '/.cache', $dir); }
    my $stateFile = "$dir/state.json";
    my $lockFile  = "$dir/state.lock";
    my $now = time;
    my $t0 = time;
    my $sendRes = 'same';

    # 複数のフックが同時に動くので、状態ファイルはロックしてから触る（異常終了してもロックは自動で外れる）
    sysopen(my $lock, $lockFile, O_RDWR | O_CREAT, 0600) or return;
    my $deadline = time + 3;
    until (flock($lock, LOCK_EX | LOCK_NB)) {
        return if time > $deadline;
        sleep(0.02);
    }

    my $st = {};
    if (-f $stateFile && open(my $sf, '<', $stateFile)) {
        local $/;
        my $txt = <$sf>;
        close $sf;
        my $d = eval { $json->decode($txt) };
        $st = $d if ref($d) eq 'HASH';
    }
    my $sessions = ref($st->{sessions}) eq 'HASH' ? $st->{sessions} : {};

    if ($Kind eq 'end') {
        delete $sessions->{$session};
    } elsif ($Kind eq 'tick') {
        # 記録の見直しだけ（下の集約で古い「作業中」が外れる）
    } elsif ($Kind eq 'seen') {
        # 見た: お知らせ中のセッションをすべて消灯扱いにする
        foreach my $k (keys %$sessions) {
            my $v = $sessions->{$k};
            if (ref $v eq 'HASH' && grep { ($v->{state} // '') eq $_ } qw(done ask error)) {
                $v->{state} = 'off';
                $v->{seen} = 1;
            }
        }
    } elsif ($Kind eq 'done' && ref($sessions->{$session}) eq 'HASH' && $sessions->{$session}{seen}) {
        $sessions->{$session}{ts} = $now;   # 見たあとに遅れて届いた done は無視（点け直さない）
    } else {
        my $isNew = !exists $sessions->{$session};
        my $tp = $transcript;
        if (!defined $tp && ref($sessions->{$session}) eq 'HASH') { $tp = $sessions->{$session}{tp}; }
        # どの AI の会話か（Claude は記録が .claude の下にある。記録が届かないのは Codex）
        my $app = (defined $tp && $tp !~ m{/\.codex/}) ? 'claude' : 'codex';
        $sessions->{$session} = { state => $Kind, ts => $now, tp => $tp, app => $app };
        # 初めて見る会話なら、発言を引き継いだ元の会話（やり直し・再開の元）を外す（置き去りになっているため）
        if ($isNew && $tp) {
            my $mine = get_uuids($tp);
            if (%$mine) {
                foreach my $k (keys %$sessions) {
                    next if $k eq $session;
                    my $other = ref($sessions->{$k}) eq 'HASH' ? $sessions->{$k}{tp} : undef;
                    next if !$other || $other eq $tp;
                    foreach my $id (keys %{ get_uuids($other) }) {
                        if ($mine->{$id}) { delete $sessions->{$k}; last; }
                    }
                }
            }
        }
    }

    # 生きているセッションの中で、いちばん優先度の高い状態を選ぶ
    my %alive;
    my $target = 'off';
    my ($leadApp, $leadTs) = (undef, -1);
    foreach my $k (keys %$sessions) {
        my $v = $sessions->{$k};
        next unless ref $v eq 'HASH';
        my $age = $now - ($v->{ts} // 0);
        my $state = $v->{state} // 'off';
        next if $state eq 'work' && $age >= $WorkTtl;
        # Esc で止めた会話を外す（今まさに合図が来た会話や、15秒以内に合図のあった会話は調べない）
        next if ($state eq 'work' || $state eq 'ask') && $k ne $session && $age >= 15 && test_interrupted($v->{tp});
        if ($age < $SessionTtl) {
            $alive{$k} = $v;
            if (($Priority{$state} // 0) > $Priority{$target}) { $target = $state; $leadTs = -1; }
            if ($state eq $target && ($v->{ts} // 0) > $leadTs) { $leadTs = $v->{ts} // 0; $leadApp = $v->{app}; }
        }
    }
    $st->{sessions} = \%alive;

    # 頼んだ・終わった・許可を求めた、の合図のときは、同じ色でも必ず送り直す
    # （ランプが自動で再起動した・挿し直した、などで表示が消えていても、ここで正しい色に戻る）
    my $force = grep { $hookEvent eq $_ } qw(UserPromptSubmit Stop PermissionRequest Notification);
    if (($st->{sent} // '') ne $target || $force) {
        my $port = find_lamp($st->{port});
        if (defined $port && invoke_lamp($port, lamp_line($dir, $target, $leadApp, $hookEvent), 'OK')) {
            $st->{sent} = $target; $st->{port} = $port; $st->{sent_at} = $now;
            $sendRes = "ok($port)";
        } else {
            $st->{sent} = undef;   # ランプ未接続。次回また試す
            $sendRes = defined $port ? "NG(ランプが返事をしませんでした: $port)" : 'NG(ランプが見つかりません)';
        }
    }

    my $tmp = "$stateFile.tmp";
    if (open(my $of, '>', $tmp)) {
        print $of $json->encode($st);
        close $of;
        rename($tmp, $stateFile);
    }
    close $lock;
    write_event($dir, sprintf('%s event=%s session=%s target=%s send=%s %dms', $Kind, $hookEvent, substr($session, 0, 8), $target, $sendRes, (time - $t0) * 1000));
}

# 動作の記録（合図の種類・会話番号の先頭・結果・かかった時間。会話の中身は書かない）。Windows 版と同じ形
# 「光らない」と言われたとき、AI がここを見て「合図が来ていない」のか「ランプに届いていない」のかを切り分ける
sub write_event {
    my ($dir, $msg) = @_;
    eval {
        my $f = "$dir/events.log";
        rename($f, "$f.old") if -f $f && -s $f > 200 * 1024;
        my @lt = localtime();
        my $ms = int((time - int(time)) * 1000);
        if (open(my $lf, '>>', $f)) {
            printf $lf "%04d-%02d-%02d %02d:%02d:%02d.%03d %s\n", $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0], $ms, $msg;
            close $lf;
        }
        1;
    };
}

# ---------- Mac の機器の一覧（ioreg）で、ランプがどこまでつながっているか ----------
#   lamp: Mac が「AI Lamp」を見つけた / acm, data: 通信の係（AppleUSBACMControl / AppleUSBACMData）が付いた
#   bsd: 通信の口（IOSerialBSDClient → /dev/cu.*）ができた / boot: ランプが書き込み待ち（CH55x の書き込み用の名前 4348:55e0 / 1a86:55e0）
#   試験用: AI_LAMP_FAKE_IOREG（ioreg -p IOService -w0 の代わりに読むファイル）、AI_LAMP_FAKE_IOUSB（ioreg -p IOUSB -l -w0 の代わり）
sub usb_report {
    my %r = (lamp => 0, acm => 0, data => 0, bsd => 0, boot => 0, tree => []);
    my $io;
    if ($ENV{AI_LAMP_FAKE_IOREG}) { open($io, '<', $ENV{AI_LAMP_FAKE_IOREG}) or undef $io; }
    else { open($io, '-|', '/usr/sbin/ioreg', '-p', 'IOService', '-w0') or undef $io; }
    if ($io) {
        my $in = -1;   # 「AI Lamp」の行の深さ（その下の行だけ拾う）
        while (my $l = <$io>) {
            next unless $l =~ /^(.*?)\+-o (.+?)\s*$/;
            my ($depth, $node) = (length($1), $2);
            $in = -1 if $in >= 0 && $depth <= $in;
            if ($in < 0 && $node =~ /^AI Lamp(@|\s|$)/) { $in = $depth; $r{lamp}++; }
            next if $in < 0;
            my $short = $node;
            $short =~ s/\s*<class ([\w.]+).*$/ ($1)/;
            push @{ $r{tree} }, ('  ' x int(($depth - $in) / 2)) . $short;
            # 係の名前は macOS の版で変わることがあるので、広めに見る（名前そのものは tree に残る）
            $r{acm}  = 1 if $node =~ /ACMControl|CDCControl|USBSerial/i;
            $r{data} = 1 if $node =~ /ACMData|CDCData|USBSerial/i;
            $r{bsd}  = 1 if $node =~ /IOSerialBSDClient/;
        }
        close $io;
    }
    my $iu;
    if ($ENV{AI_LAMP_FAKE_IOUSB}) { open($iu, '<', $ENV{AI_LAMP_FAKE_IOUSB}) or undef $iu; }
    else { open($iu, '-|', '/usr/sbin/ioreg', '-p', 'IOUSB', '-l', '-w0') or undef $iu; }
    if ($iu) {
        my $vid = -1;
        while (my $l = <$iu>) {
            $vid = $1 if $l =~ /"idVendor" = (\d+)/;
            $r{boot} = 1 if $l =~ /"idProduct" = 21984\b/ && ($vid == 17224 || $vid == 6790);
        }
        close $iu;
    }
    return \%r;
}

# ---------- この Mac について（アクセサリの許可がある Apple シリコンか／会社などの管理下か） ----------
#   試験用: AI_LAMP_FAKE_MACINFO（"arm" や "arm,managed" のように書く）
sub mac_info {
    my %m = (arm => 0, managed => 0);
    if (defined $ENV{AI_LAMP_FAKE_MACINFO}) {
        $m{arm} = 1 if $ENV{AI_LAMP_FAKE_MACINFO} =~ /arm/;
        $m{managed} = 1 if $ENV{AI_LAMP_FAKE_MACINFO} =~ /managed/;
        return \%m;
    }
    my $a = `/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null`;
    $m{arm} = 1 if defined $a && $a =~ /^\s*1/;
    my $p = `/usr/bin/profiles status -type enrollment 2>/dev/null`;
    $m{managed} = 1 if defined $p && $p =~ /MDM enrollment:\s*Yes/i;
    return \%m;
}

# ---------- 原因を調べる（光らないときに AI が実行する。会話の中身やほかの機器の名前は出さない） ----------
sub lamp_diag {
    my @c = glob('/dev/cu.usbmodem*');
    my $r = usb_report();
    my $os = `/usr/bin/sw_vers -productVersion 2>/dev/null`; chomp $os;
    my $hw = `/usr/sbin/sysctl -n hw.model 2>/dev/null`; chomp $hw;
    print "=== AI通知ランプの調べ（lamp.pl diag）===\n";
    print "macOS $os / $hw\n";
    print "Mac がランプを見つけた: " . ($r->{lamp} ? "はい" : "いいえ") . "\n";
    print "通信の係（ACM）: " . ($r->{acm} ? "付いた" : "付いていない") . " / データの係: " . ($r->{data} ? "付いた" : "付いていない") . "\n";
    print "通信の口: " . (@c ? join(', ', @c) : ($r->{bsd} ? "係はできたが /dev/cu.usbmodem* が無い" : "無い")) . "\n";
    print "書き込み待ちの状態: " . ($r->{boot} ? "はい（抜いて挿し直す）" : "いいえ") . "\n";
    my $port = @c ? find_lamp(undef) : undef;
    print "ランプの返事: " . (defined $port ? "あり（$port）" : (@c ? "無し" : "（口が無いので試していない）")) . "\n";
    print "--- ランプの下の様子（ioreg）---\n";
    print "$_\n" for (@{ $r->{tree} } ? @{ $r->{tree} } : ('（AI Lamp が一覧にありません）'));
    # 会社などが管理している Mac は、USB の機器を黙って止める決まりが入っていることがある
    print "--- この Mac の管理（profiles）---\n";
    my @mdm = grep { /Enrolled|MDM/i } `/usr/bin/profiles status -type enrollment 2>&1`;
    print @mdm ? @mdm : "（調べられませんでした）\n";
    # USB とアクセサリの許可まわりの記録（直近 3 分。失敗・拒否などの行だけ。ランプを挿し直してすぐ実行すると残る）
    print "--- USB の記録（直近 3 分、失敗・拒否などの行だけ）---\n";
    my @log;
    if (open(my $lg, '-|', '/usr/bin/log', 'show', '--last', '3m', '--style', 'compact', '--predicate',
             'subsystem BEGINSWITH "com.apple.iokit.IOUSB" OR eventMessage CONTAINS[c] "usb" OR eventMessage CONTAINS[c] "accessor"')) {
        while (my $l = <$lg>) {
            next unless $l =~ /fail|error|enumerat|accessor|denied|disallow|restrict|block|1209|c550|AI Lamp|over.?current/i;
            chomp $l; push @log, substr($l, 0, 220);
        }
        close $lg;
    }
    @log = @log[-15 .. -1] if @log > 15;
    print @log ? join("\n", @log) . "\n" : "（該当する記録はありません）\n";
    print "（AI へ）この結果をそのままお客さんに見せ、うまくいかないときは「この結果を、リベシティのメッセージで送ってください」と伝える。\n";
}

# ---------- ランプの確認（setup.sh の最後） ----------
sub lamp_test {
    my $home = $ENV{HOME} || (getpwuid($<))[7];
    my $dir = $ENV{AI_LAMP_STATE_DIR} || "$home/.cache/ai-lamp";
    my $port = find_lamp(undef);
    unless (defined $port) {
        my @c = glob('/dev/cu.usbmodem*');
        # 通信の口が無いときは、Mac の機器の一覧（ioreg）で、どこまで進んでいるかを見て分ける
        my $r = usb_report();
        if (@c)            { print "NG USB の機器（" . join(', ', @c) . "）はありますが、ランプの返事がありませんでした。ランプを挿し直してから、もう一度 setup.sh を実行してください。\n"; }
        elsif ($r->{boot}) { print "NG ランプが「書き込みを待つ状態」になっています（ふだんの光り方をしません）。ランプを抜いて 5 秒待ってから挿し直し、もう一度確かめてください。\n"; }
        elsif ($r->{lamp} && !$r->{acm}) { print "NG Mac はランプを見つけていますが、通信の係（ドライバー）がまだ付いていません。Mac がランプとの通信を許可していないことがあります。ランプを抜いて 5 秒待ってから挿し直し、『アクセサリの接続を許可しますか？』と出たら『許可』を押して、もう一度確かめてください。設定そのものは済んでいます。\n"; }
        elsif ($r->{lamp}) { print "NG Mac はランプを見つけて通信の係も付いていますが、通信の口（/dev/cu.usbmodem…）ができていません。ランプを挿し直して、もう一度確かめてください。\n"; }
        else {
            # 電気は届くのに一覧に出ない。いちばん多いのは Mac の「アクセサリの接続の許可」で止められているとき
            #   （前に「許可しない」を押した／ロック中に挿した／会社などの管理で止められている）。ケーブルはその次
            my $m = mac_info();
            print "NG Mac がランプを通信の相手として見つけていません（電気だけ届いている状態です）。設定そのものは済んでいるので、つながればそのまま使えます。\n";
            if ($m->{managed}) {
                print "（AI へ）この Mac は会社などの管理下にあります。USB の機器が管理の決まりで止められていることがあります。お客さんに伝え、管理している人に「USB の機器（AI Lamp）を使えるか」を聞いてもらう。お客さんの代わりに設定を変えない。\n";
            }
            if ($m->{arm}) {
                print "（AI へ）次の順に案内する（1 回の返事でまとめて）:\n";
                print "  1. 設定画面を開く: open 'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension'（開かなければ「システム設定 → プライバシーとセキュリティ」を開いてもらう）\n";
                print "  2. 下の方の「アクセサリの接続を許可」を「毎回確認」にしてもらう（今より安全側の設定。変えるのはお客さん。AI は変えない）\n";
                print "  3. Mac のロックを外した状態で、ランプを抜いて 5 秒待ってから挿し直す →「アクセサリの接続を許可しますか？ AI Lamp」と出たら「許可」\n";
                print "  4. 「挿した」の返事が来たら、もう一度 test を実行する。それでも NG なら、別の USB の口・パソコンに直接挿す（ハブや変換アダプタを外す）を試す\n";
            } else {
                print "（AI へ）ランプを抜いて 5 秒待ってから、パソコンに直接（ハブや変換アダプタを使わずに）挿し直してもらい、別の USB の口でも試してもらう。\n";
            }
        }
        print "（AI へ）原因をくわしく調べるときは: /usr/bin/perl \"$0\" diag\n";
        return;
    }
    invoke_lamp($port, 'S done', 'OK');
    sleep(2);
    invoke_lamp($port, 'S off', 'OK');
    # 見つけたポートを記録に残す（次の合図ですぐ送れるように）。sent は空にして、次の合図で必ず送る
    if (-d $dir || mkdir($dir)) {
        my $st = {};
        if (open(my $sf, '<', "$dir/state.json")) { local $/; my $d = eval { $json->decode(<$sf>) }; $st = $d if ref($d) eq 'HASH'; close $sf; }
        $st->{port} = $port; $st->{sent} = undef;
        if (open(my $of, '>', "$dir/state.json.tmp")) { print $of $json->encode($st); close $of; rename("$dir/state.json.tmp", "$dir/state.json"); }
    }
    print "OK ランプが見つかりました（$port）。いま緑に 2 秒光ったはずです。\n";
}
