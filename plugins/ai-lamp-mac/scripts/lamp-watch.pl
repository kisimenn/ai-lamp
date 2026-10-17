#!/usr/bin/perl
# AI通知ランプ 既読で消える機能（Mac 版）v0.8.2 ※Mac の実機ではまだ試していない（試験中）
#
# ランプが「完了 / あなたの出番」を表示したあとに、
# Claude か Codex（ChatGPT）の画面がいちばん前にある状態でマウスかキーボードを触ったら、ランプを消す。
# あわせて、作業中・出番のあいだは 30 秒ごとに記録を見直す（Esc で止めた会話を外す。lamp.pl tick）。
#
# 見ているもの（これ以外は見ない・記録しない）:
#   ・いちばん前にあるアプリの名前（lsappinfo。Mac に最初から入っている。許可の画面は出ない）
#   ・最後にマウスかキーボードを触ってから何秒たったか（ioreg の HIDIdleTime。どのキーを押したかは見ない）
#
#   使い方: lamp-watch.pl          （launchd が起動時に自動で動かす。watch-install.pl で入れる）
#           lamp-watch.pl --show   （動作確認用。何をしたか表示する）
#
# 対象のアプリは ~/.cache/ai-lamp/watch-apps.txt に 1 行 1 つ書くと付け足せる（最初から Claude・ChatGPT・Codex）
# ~/.cache/ai-lamp/seen-off があるときは、消さない（記録の見直しだけする）
use strict;
use warnings;
use JSON::PP;
use Time::HiRes qw(time sleep);
use Fcntl qw(:DEFAULT :flock);
use File::Basename qw(dirname);

my $Show = grep { $_ eq '--show' } @ARGV;
my $home = $ENV{HOME} || (getpwuid($<))[7];
my $dir = $ENV{AI_LAMP_STATE_DIR} || "$home/.cache/ai-lamp";
mkdir("$home/.cache"); mkdir($dir);
my $stateFile = "$dir/state.json";
my $seenOff = "$dir/seen-off";
my $lampPl = dirname(__FILE__) . '/lamp.pl';
my %Notice = map { $_ => 1 } qw(done ask error);   # 消す対象（作業中は消さない）

my @Apps = qw(claude chatgpt codex);
if (open(my $af, '<', "$dir/watch-apps.txt")) {
    while (my $l = <$af>) { $l =~ s/^\s+|\s+$//g; push @Apps, lc $l if $l ne '' && $l !~ /^#/; }
    close $af;
}
my %AppSet = map { $_ => 1 } @Apps;

# 二重に動かない（異常終了してもロックは自動で外れる）
sysopen(my $lock, "$dir/watch.lock", O_RDWR | O_CREAT, 0600) or exit 0;
unless (flock($lock, LOCK_EX | LOCK_NB)) { print "すでに見張りが動いています\n" if $Show; exit 0; }

sub watch_log {
    my ($msg) = @_;
    eval {
        my $f = "$dir/watch.log";
        rename($f, "$f.old") if -f $f && -s $f > 100 * 1024;
        my @lt = localtime();
        if (open(my $lf, '>>', $f)) { printf $lf "%04d-%02d-%02d %02d:%02d:%02d %s\n", $lt[5] + 1900, $lt[4] + 1, $lt[3], $lt[2], $lt[1], $lt[0], $msg; close $lf; }
        1;
    };
}

# 最後にマウスかキーボードを触ってから何秒たったか（読めなければ -1）
sub idle_seconds {
    my $out = `/usr/sbin/ioreg -c IOHIDSystem -d 4 2>/dev/null`;
    return $1 / 1e9 if defined $out && $out =~ /"HIDIdleTime"\s*=\s*(\d+)/;
    return -1;
}

# いちばん前にあるアプリの名前（小文字。読めなければ空）
sub front_app {
    my $asn = `/usr/bin/lsappinfo front 2>/dev/null`;
    return '' unless defined $asn;
    $asn =~ s/\s+$//;
    return '' if $asn eq '';
    my $info = `/usr/bin/lsappinfo info -only name '$asn' 2>/dev/null`;
    return lc $1 if defined $info && $info =~ /"LSDisplayName"\s*=\s*"([^"]*)"/;
    return '';
}

sub read_state {
    open(my $sf, '<', $stateFile) or return undef;
    local $/;
    my $txt = <$sf>;
    close $sf;
    my $d = eval { JSON::PP->new->decode($txt) };
    return ref($d) eq 'HASH' ? $d : undef;
}

$SIG{TERM} = $SIG{INT} = sub { watch_log("終了 PID=$$"); exit 0; };
watch_log("開始 PID=$$ 対象=" . join(',', @Apps));
print "見張り開始: " . join(', ', @Apps) . " が前面で操作されたらランプを消す（Ctrl+C で終了）\n" if $Show;

my $lastTick = time;
my $lastErr = '';
while (1) {
    eval {
        my $st = read_state();
        my $sent = $st ? ($st->{sent} // '') : '';
        # 作業中・出番のあいだは 30 秒ごとに記録を見直す
        if (($sent eq 'work' || $sent eq 'ask') && time - $lastTick >= 30) {
            $lastTick = time;
            system('/usr/bin/perl', $lampPl, 'tick');
        }
        if ($Notice{$sent} && !-e $seenOff) {
            my $sentAt = $st->{sent_at} // 0;
            my $idle = idle_seconds();
            # ランプが点いた「あと」に触った（点いてから 1.5 秒は消さない。Windows 版と同じ）
            if ($idle >= 0 && time - $idle > $sentAt + 1.5) {
                my $fg = front_app();
                if ($AppSet{$fg}) {
                    system('/usr/bin/perl', $lampPl, 'seen');
                    print scalar(localtime) . " $sent を消しました（$fg）\n" if $Show;
                    # 消せなかった（ランプが外れている等）ときだけ 2 秒待つ（連打しない）
                    my $after = read_state();
                    sleep(2) unless $after && ($after->{sent} // '') eq 'off';
                }
            }
        }
        1;
    } or do {
        my $e = "$@";
        print "エラー: $e" if $Show;
        if ($e ne $lastErr) { watch_log("エラー: $e"); $lastErr = $e; }
    };
    # 消す対象が点いているときは 0.3 秒ごと、それ以外は 1 秒ごとに見る（Mac を重くしない）
    my $st = read_state();
    sleep(($st && $Notice{$st->{sent} // ''}) ? 0.3 : 1);
}
