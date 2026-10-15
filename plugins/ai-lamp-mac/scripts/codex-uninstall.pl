#!/usr/bin/perl
# Codex からランプのフックを外す（Mac 版。ほかのフックは残す）
use strict;
use warnings;
use JSON::PP;
use File::Path qw(remove_tree);

my $home = $ENV{HOME} or die "HOME が分かりません\n";
my $hooksFile = "$home/.codex/hooks.json";
my $js = JSON::PP->new->utf8->canonical->pretty;

if (-f $hooksFile) {
    open(my $fh, '<', $hooksFile) or die "hooks.json を読めません: $!\n";
    local $/;
    my $txt = <$fh>;
    close $fh;
    my $doc = (defined $txt && $txt =~ /\S/) ? $js->decode($txt) : {};
    if (ref($doc->{hooks}) eq 'HASH') {
        my $hooks = $doc->{hooks};
        foreach my $ev (keys %$hooks) {
            my @groups = ref($hooks->{$ev}) eq 'ARRAY' ? grep { encode_json($_) !~ /ai-lamp/ } @{ $hooks->{$ev} } : ();
            if (@groups) { $hooks->{$ev} = \@groups; } else { delete $hooks->{$ev}; }
        }
    }
    open(my $out, '>', $hooksFile) or die "hooks.json に書けません: $!\n";
    print $out $js->encode($doc);
    close $out;
}
remove_tree("$home/.cache/ai-lamp/bin");
print "Codex からランプのフックを外しました\n";
