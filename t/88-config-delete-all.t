#!/usr/bin/env perl
use Test2::V0;
use lib 't/lib';
use TestRepo;
use Path::Tiny;
use Git::Native;
use Git::Native::Config;
use Git::Libgit2 qw( GIT_ERROR GIT_EINVALIDSPEC GIT_EREADONLY );

# Git::Native::Config->delete_all - karr ticket k38.
#
# git_config_delete_multivar crashes the process on a valueless entry, so every
# case that touches one runs in a child perl: a regression shows up as a red
# test (the child dies of a signal), not a dead harness.

sub local_config_file { path( $_[0] )->child( '.git', 'config' ) }

# Run $code (a string of perl, given $dir) in a fresh perl; return
# ( exit status, signal, stdout ). The child opens the repo at $dir through
# TestRepo's isolated config.
sub in_child {
  my ( $dir, $code ) = @_;
  my $script = join "\n",
    'use lib "t/lib"; use TestRepo; use Git::Native; use Git::Native::Error;',
    '$| = 1; my $dir = shift; my $repo = Git::Native->open($dir);',
    $code;
  my $out = '';
  open my $fh, '-|', $^X, '-Ilib', '-e', $script, "$dir" or die "cannot run perl: $!";
  local $/;
  $out = <$fh>;
  close $fh;
  return ( $? >> 8, $? & 127, $out // '' );
}

sub fresh_values {
  my ($dir) = @_;
  return [ local_config_file($dir)->slurp_utf8 =~ /^\s*v\b(?:\s*=\s*(\S+))?\s*$/mg ];
}

subtest 'public method' => sub { can_ok 'Git::Native::Config', ['delete_all'] };

subtest 'a two-valued multivar is removed, siblings survive' => sub {
  my ( $init, $dir ) = TestRepo::new_repo();
  local_config_file($dir)->append("[multi]\n\tv = one\n\tv = two\n\tother = keep\n");
  my $repo = Git::Native->open("$dir");
  is $repo->config->delete_all('multi.v'), 1, 'returns 1';
  is $repo->config_string('multi.v'), undef, 'gone in memory';
  is( Git::Native->open("$dir")->config_string('multi.v'), undef, 'gone on disk' );
  is $repo->config_string('multi.other'), 'keep', 'a sibling survives';
};

subtest 'a single-valued key and an absent key' => sub {
  my ( $repo, $dir ) = TestRepo::new_repo();
  $repo->config->set_string( 'one.k', 'x' );
  is $repo->config->delete_all('one.k'), 1, 'single value: 1';
  is $repo->config_string('one.k'), undef, 'removed';
  is $repo->config->delete_all('never.set'), 1, 'absent key: 1';
  is $repo->config->delete_all('never.set'), 1, 'and again';
};

subtest 'a lone valueless entry (karr.readonly) is removed - in a child' => sub {
  my ( $init, $dir ) = TestRepo::new_repo();
  local_config_file($dir)->append("[karr]\n\treadonly\n");
  my ( $exit, $sig, $out ) = in_child( $dir, q{print $repo->config->delete_all('karr.readonly'), "\n";} );
  is $sig, 0, 'the child did not die of a signal';
  is $exit, 0, 'and exited cleanly';
  is $out, "1\n", 'delete_all returned 1';
  is( Git::Native->open("$dir")->config_snapshot->get_bool('karr.readonly'), undef, 'gone on disk' );
};

subtest 'a valueless entry next to others is refused, not a crash - in a child' => sub {
  my ( $init, $dir ) = TestRepo::new_repo();
  local_config_file($dir)->append("[multi]\n\tv = one\n\tv\n\tv = two\n");
  my $before = local_config_file($dir)->slurp_utf8;
  my ( $exit, $sig, $out ) = in_child( $dir, q{
    eval { $repo->config->delete_all('multi.v'); 1 } and print "no error\n";
    my $e = $@;
    print ref $e && $e->isa('Git::Native::Error') ? 'native ' . $e->code : "other: $e", "\n";
  } );
  is $sig, 0, 'the child did not die of a signal';
  is $exit, 0, 'and exited cleanly';
  is $out, 'native ' . GIT_ERROR . "\n", 'a Git::Native::Error with GIT_ERROR';
  is local_config_file($dir)->slurp_utf8, $before, 'the file is untouched';
};

subtest 'a valueless entry only in the global config does not matter' => sub {
  my $global = path( "$TestRepo::HOME", '.gitconfig' );
  $global->spew_utf8("[multi]\n\tv\n");
  my ( $init, $dir ) = TestRepo::new_repo();
  local_config_file($dir)->append("[multi]\n\tv = one\n\tv = two\n");
  my ( $exit, $sig, $out ) = in_child( $dir, q{print $repo->config->delete_all('multi.v'), "\n";} );
  $global->remove;
  is $sig, 0, 'no signal';
  is $out, "1\n", 'the local values are removed';
  is fresh_values($dir), [], 'none left in .git/config';
};

subtest 'invalid name and snapshot' => sub {
  my ( $repo, $dir ) = TestRepo::new_repo();
  my $err = dies { $repo->config->delete_all('nodot') };
  isa_ok $err, ['Git::Native::Error'], 'invalid name throws a Git::Native::Error';
  is $err->code, GIT_EINVALIDSPEC, 'with GIT_EINVALIDSPEC' if ref $err;

  local_config_file($dir)->append("[multi]\n\tv = one\n\tv = two\n");
  my $r2 = Git::Native->open("$dir");
  for my $key ( 'multi.v', 'x.y' ) {
    my $e = dies { $r2->config_snapshot->delete_all($key) };
    isa_ok $e, ['Git::Native::Error'], "snapshot delete_all('$key') throws";
    is $e->code, GIT_EREADONLY, 'with GIT_EREADONLY' if ref $e;
  }
  is $r2->config_string('multi.v'), 'two', 'values survive';
};

subtest 'an external edit behind an open config is seen' => sub {
  my ( $repo, $dir ) = TestRepo::new_repo();
  my $held = $repo->config;
  local_config_file($dir)->append("[hand]\n\tv = one\n\tv = two\n");
  is $held->delete_all('hand.v'), 1, 'returns 1';
  is fresh_values($dir), [], 'gone from .git/config';
};

done_testing;
