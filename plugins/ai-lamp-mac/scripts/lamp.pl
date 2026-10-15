#!/usr/bin/perl
# AI通知ランプ 送信スクリプト（Mac 版）v0.6.1
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
    my ($dir, $target) = @_;
    my $bright = 255;
    my $color;
    if (open(my $cf, '<', "$dir/colors.json")) {
        local $/;
        my $pref = eval { JSON::PP->new->relaxed->decode(<$cf>) };
        close $cf;
        if (ref($pref) eq 'HASH') {
            my $pct = $pref->{brightness};
            if (defined $pct && $pct =~ /^[\d.]+$/ && $pct >= 1 && $pct <= 100) { $bright = int($pct * 255 / 100 + 0.5); }
            my $e = $target ne 'off' ? $pref->{$target} : undef;
            my $mode = ref($e) eq 'HASH' ? ($e->{mode} // 'solid') : 'solid';
            $mode = 'solid' unless $mode =~ /^(solid|breathe|blink|fastblink)$/;
            if (ref($e) eq 'HASH' && defined $e->{color} && !ref($e->{color}) && $e->{color} eq 'rainbow') {
                $color = "R $mode";   # 虹色（ランプのファーム v1.0 から）
            } elsif (ref($e) eq 'HASH' && ref($e->{color}) eq 'ARRAY' && @{ $e->{color} } == 3) {
                my @rgb = map { my $v = int($_ // 0); $v < 0 ? 0 : $v > 255 ? 255 : $v } @{ $e->{color} };
                $color = "C @rgb $mode";
            }
        }
    }
    $color //= "S $target";
    return "B $bright\n$color";
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
    unless (grep { $_ eq $Kind } qw(work done ask error end seen tick test)) {
        print STDERR "usage: lamp.pl <work|done|ask|error|end|seen|tick|test>\n";
        return;
    }
    if ($Kind eq 'test') { lamp_test(); return; }
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
        $sessions->{$session} = { state => $Kind, ts => $now, tp => $tp };
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
            $target = $state if ($Priority{$state} // 0) > $Priority{$target};
        }
    }
    $st->{sessions} = \%alive;

    # 頼んだ・終わった・許可を求めた、の合図のときは、同じ色でも必ず送り直す
    # （ランプが自動で再起動した・挿し直した、などで表示が消えていても、ここで正しい色に戻る）
    my $force = grep { $hookEvent eq $_ } qw(UserPromptSubmit Stop PermissionRequest Notification);
    if (($st->{sent} // '') ne $target || $force) {
        my $port = find_lamp($st->{port});
        if (defined $port && invoke_lamp($port, lamp_line($dir, $target), 'OK')) {
            $st->{sent} = $target; $st->{port} = $port; $st->{sent_at} = $now;
        } else {
            $st->{sent} = undef;   # ランプ未接続。次回また試す
        }
    }

    my $tmp = "$stateFile.tmp";
    if (open(my $of, '>', $tmp)) {
        print $of $json->encode($st);
        close $of;
        rename($tmp, $stateFile);
    }
    close $lock;
}

# ---------- ランプの確認（setup.sh の最後） ----------
sub lamp_test {
    my $home = $ENV{HOME} || (getpwuid($<))[7];
    my $dir = $ENV{AI_LAMP_STATE_DIR} || "$home/.cache/ai-lamp";
    my $port = find_lamp(undef);
    unless (defined $port) {
        my @c = glob('/dev/cu.usbmodem*');
        if (@c) { print "NG USB の機器（" . join(', ', @c) . "）はありますが、ランプの返事がありませんでした。ランプを挿し直してから、もう一度 setup.sh を実行してください。\n"; }
        else    { print "NG ランプが見つかりませんでした。USB に挿さっているか（挿すと虹色が流れるか）確かめてください。設定そのものは済んでいるので、挿せばそのまま使えます。\n"; }
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
