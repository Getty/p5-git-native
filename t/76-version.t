use strict;
use warnings;
use Test2::V0;
use File::Find ();
use Path::Tiny;

# 0.006 gave every module its own $VERSION. Before that only the main module
# carried one, so Git::Native::Repository->VERSION and its siblings answered
# undef -- a dependency pinning "Git::Native::Foo 0.006" got undef back and its
# check silently passed. This walks lib/ rather than a hand-kept list so the
# next module added without a $VERSION fails here instead of shipping bare.

my $lib = path('lib');
skip_all 'no lib/ to scan' unless $lib->is_dir;

my @modules;
File::Find::find(
  sub {
    return unless /\.pm\z/;
    my $rel = path($File::Find::name)->relative($lib);
    ( my $mod = "$rel" ) =~ s{/}{::}g;
    $mod =~ s/\.pm\z//;
    push @modules, $mod;
  },
  "$lib",
);

@modules = sort @modules;
ok( scalar(@modules), 'found modules under lib/' );

for my $mod (@modules) {
  require( ( $mod =~ s{::}{/}gr ) . '.pm' );
  my $v = $mod->VERSION;
  ok( defined $v && length $v, "$mod carries a \$VERSION (" . ( $v // 'undef' ) . ')' );
}

done_testing;
