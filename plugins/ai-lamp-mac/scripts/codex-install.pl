#!/usr/bin/perl
# Codex（アプリ・ターミナル・VS Code）でもランプを光らせる（Mac 版）
#   ・lamp.pl を ~/.cache/ai-lamp/bin にコピーする（場所が変わらないように）
#   ・~/.codex/hooks.json にランプ用のフックを追記する（ほかの設定は消さない。元は hooks.json.bak-ai-lamp に控える）
#   ・追記したあと、Codex で一度だけ「このフックを使ってよいか」を承認する必要がある（/hooks）
# やめるときは codex-uninstall.pl
#
# Codex の合図とランプの対応（Codex にはエラーで止まった合図が無い）
#   UserPromptSubmit / PostToolUse → 作業中、PermissionRequest → あなたの出番（橙）、Stop → 完了、
#   Interrupt / SessionEnd → そのセッションの表示を消す
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $home = $ENV{HOME} or die "HOME が分かりません\n";
my $bin  = "$home/.cache/ai-lamp/bin";
make_path($bin);
my $src = dirname(abs_path($0)) . '/lamp.pl';
copy($src, "$bin/lamp.pl") or die "lamp.pl をコピーできません: $!\n";
chmod 0755, "$bin/lamp.pl";
my $lamp = "$bin/lamp.pl";

my $codexDir = "$home/.codex";
make_path($codexDir);
my $hooksFile = "$codexDir/hooks.json";
my $js = JSON::PP->new->utf8->canonical->pretty;

my $doc = {};
if (-f $hooksFile) {
    copy($hooksFile, "$hooksFile.bak-ai-lamp");   # 念のため控えを取る
    open(my $fh, '<', $hooksFile) or die "hooks.json を読めません: $!\n";
    local $/;
    my $txt = <$fh>;
    close $fh;
    $doc = $js->decode($txt) if defined $txt && $txt =~ /\S/;
}
$doc->{hooks} = {} unless ref($doc->{hooks}) eq 'HASH';
my $hooks = $doc->{hooks};

# Interrupt / SessionEnd は Codex の上限が 3 秒（既定 1 秒）（公式 hooks の説明、2026-10-12 確認）
my @plan = (
    [UserPromptSubmit  => 'work', 15],
    [PostToolUse       => 'work', 15],
    [PermissionRequest => 'ask',  15],
    [Stop              => 'done', 15],
    [Interrupt         => 'end',  3],
    [SessionEnd        => 'end',  3],
);
foreach my $p (@plan) {
    my ($ev, $state, $timeout) = @$p;
    # 前に入れたランプ用のフックは取り除いてから入れ直す（二重にしない）
    my @groups = ref($hooks->{$ev}) eq 'ARRAY' ? grep { encode_json($_) !~ /ai-lamp/ } @{ $hooks->{$ev} } : ();
    push @groups, { hooks => [ { type => 'command', command => "/usr/bin/perl \"$lamp\" $state", async => JSON::PP::true, timeout => $timeout } ] };
    $hooks->{$ev} = \@groups;
}

open(my $out, '>', $hooksFile) or die "hooks.json に書けません: $!\n";
print $out $js->encode($doc);
close $out;
print "Codex 用のランプのフックを入れました: $hooksFile\n";
print "次に、ランプのフックを承認してください。Codex アプリは、入力欄の下に出る、黄色い点付きのフックのアイコン →「フックの確認」で、lamp.pl と書かれたランプ用のフックを許可します（全部ランプ用なら「すべて許可」、ほかのフックもあればランプ用だけ選んで「選択した項目を許可」）。これで完了で、設定画面でもう一度同じ操作をする必要はありません。アイコンが無いときは承認済みのこともあるので 設定 → Hooks で確かめます。ターミナルの Codex は /hooks。承認したら新しい会話から光ります。\n";
