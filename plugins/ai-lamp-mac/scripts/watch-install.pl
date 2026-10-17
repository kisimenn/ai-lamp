#!/usr/bin/perl
# AI通知ランプ 既読で消える機能を入れる（Mac 版）v0.8.2 ※Mac の実機ではまだ試していない（試験中）
#   Mac の起動時に lamp-watch.pl が自動で動くようにする（~/Library/LaunchAgents に 1 つ置くだけ。管理者の許可は要らない）
#   入れると Mac が「バックグラウンド項目が追加されました」と通知することがある（ランプの見張りなので、そのままでよい）
#   使い方: watch-install.pl            （入れて、すぐ動かす）
#           watch-install.pl --uninstall（外す）
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $Label = 'local.ai-lamp.watch';
my $home = $ENV{HOME} || (getpwuid($<))[7];
my $agents = "$home/Library/LaunchAgents";
my $plist = "$agents/$Label.plist";
my $uid = $<;
my $script = abs_path(dirname(__FILE__)) . '/lamp-watch.pl';
my $uninstall = grep { $_ eq '--uninstall' } @ARGV;

# 動いている見張りを止める（無くてもよい）
system("/bin/launchctl bootout gui/$uid '$plist' >/dev/null 2>&1");
system("/bin/launchctl unload '$plist' >/dev/null 2>&1");   # 古い macOS 用

if ($uninstall) {
    unlink $plist;
    print "OK 既読で消える機能を外しました\n";
    exit 0;
}

sub xml { my $s = shift; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; return $s; }

mkdir "$home/Library"; mkdir $agents;
my $p = xml($script);
my $log = xml("$home/.cache/ai-lamp/watch-launchd.log");
open(my $fh, '>', $plist) or do { print "NG 既読で消える機能を入れられませんでした（$plist に書けません）\n"; exit 1; };
print $fh <<"XML";
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$Label</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/perl</string><string>$p</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
XML
close $fh;

my $rc = system("/bin/launchctl bootstrap gui/$uid '$plist' >/dev/null 2>&1");
$rc = system("/bin/launchctl load -w '$plist' >/dev/null 2>&1") if $rc != 0;   # 古い macOS 用
if ($rc == 0) {
    print "OK 既読で消える機能を入れました（Mac 版は試験中。Mac が「バックグラウンド項目が追加されました」と通知することがありますが、ランプの見張りなのでそのままで大丈夫です）\n";
} else {
    print "NG 既読で消える機能を始められませんでした（Mac を再起動すると動くことがあります）\n";
}
