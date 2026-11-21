#!/usr/bin/env perl
use Test2::V0;
use lib 't/lib';
use TestRepo;
use Path::Tiny;
use Git::Native;
use Git::Native::Config;
use Git::Libgit2 qw( GIT_ERROR GIT_EINVALIDSPEC GIT_EREADONLY );

# Git::Native::Config->delete - karr ticket k36.
#
# The consumer is karr's read-only flag: a valueless `[karr] readonly` entry
# in .git/config that has to be removable natively. The contract:
#
#   * delete($name) removes the entry from the level libgit2 writes to - the
#     repository's own .git/config - and returns 1;
#   * a key not set at that level returns 1 as well (GIT_ENOTFOUND counts as
#     "already gone", the way reference_delete is idempotent);
#   * every other libgit2 failure throws a Git::Native::Error;
#   * there is no unset-all: a multivar is refused, not deleted.
#
# The load-bearing part is staleness, the same trap as the index (CLAUDE.md,
# "Index"): libgit2 caches the live git_config* in the repository and hands the
# same object to every git_repository_config call. After a write from outside
# the process, git_config_delete_entry on that cached object answers
# GIT_ENOTFOUND (-3, measured on 1.9.3) and leaves the key on disk - which the
# idempotent contract above would then report as success. delete therefore
# refreshes before it deletes, and the three staleness subtests at the bottom
# are what go red if that refresh is removed.

# The two CLI staleness subtests write and read the config through the git CLI,
# the way a user running `git config` in a shell would. TestRepo already points
# GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM at /dev/null, so the CLI sees only the
# repository level. Without git those two skip loudly; the hand-edit subtest
# still covers the refresh.
my $HAVE_GIT = do {
  my $v = `git --version 2>/dev/null`;
  defined $v && $v =~ /^git version/;
};
diag 'git is not on PATH: the two git-CLI staleness subtests will be skipped; '
  . 'the refresh in Config->delete is then covered by the hand-edit subtest only'
  unless $HAVE_GIT;

# The repository's own config file, as git reads it.
sub local_config_file { path( $_[0] )->child( '.git', 'config' ) }

# git config --local --get-all KEY, as (exit status, values). Exit status 1 is
# git's "key not found".
sub git_get_all {
  my ( $dir, $key ) = @_;
  my @out = `git -C "$dir" config --local --get-all $key`;
  my $rc  = $? >> 8;
  chomp @out;
  return ( $rc, @out );
}

# Contract 9: every throw is the typed wrapper error, never the FFI layer's.
# The diag shows what came back instead, so a red run says why.
sub is_native_error {
  my ( $err, $label ) = @_;
  my $ok = isa_ok $err, ['Git::Native::Error'], "$label throws a Git::Native::Error";
  diag "got instead: " . ( defined $err ? "$err" : 'no exception' ) unless $ok;
  ok !( ref $err && $err->isa('Git::Libgit2::Error') ),
    "$label does not leak a Git::Libgit2::Error";
  return $ok;
}

subtest 'Config has a public delete method' => sub {
  can_ok 'Git::Native::Config', ['delete'];
};

subtest 'a key set through this config is deleted, in memory and on disk' => sub {
  my ( $repo, $dir ) = TestRepo::new_repo();
  my $cfg = $repo->config;
  $cfg->set_string( 'own.k',     'x' );
  $cfg->set_string( 'own.other', 'y' );
  is $repo->config_string('own.k'), 'x', 'control: the key is set before the delete';

  is $cfg->delete('own.k'), 1, 'delete returns 1';
  is $repo->config_string('own.k'), undef, 'the same repository no longer sees it';
  is( Git::Native->open("$dir")->config_string('own.k'), undef,
    'a freshly opened repository does not see it either - it is gone from disk' );

  # It removes one entry, not the section it lives in.
  is $repo->config_string('own.other'), 'y', 'a sibling key in the same section survives';
};

subtest 'an absent key is already gone: delete returns 1 and does not throw' => sub {
  my ( $repo, $dir ) = TestRepo::new_repo();
  my $cfg = $repo->config;

  my $first;
  ok lives { $first = $cfg->delete('never.set') }, 'deleting a key that was never set lives'
    or diag $@;
  is $first, 1, 'and returns 1';
  is $cfg->delete('never.set'), 1, 'a second call returns 1 again';
  is $cfg->delete('no.such.subsection'), 1, 'so does a key in a section that does not exist';

  # Idempotent on a key that DID exist: the second delete of the same key is
  # the not-found path, and must not turn into an error.
  $cfg->set_string( 'once.k', 'x' );
  is $cfg->delete('once.k'), 1, 'deleting a real key returns 1';
  is $cfg->delete('once.k'), 1, 'deleting it again returns 1, not an error';
};

subtest 'a multivar is refused with a Git::Native::Error and both values survive' => sub {
  # No unset-all on purpose (see the valueless subtest below for why). The
  # file is written before the repository is opened, so this measures the
  # multivar refusal and not the staleness covered further down.
  my ( $init, $dir ) = TestRepo::new_repo();
  local_config_file($dir)->append("[multi]\n\tv = one\n\tv = two\n");
  my $repo = Git::Native->open("$dir");

  my $err = dies { $repo->config->delete('multi.v') };
  is_native_error( $err, 'delete on a multivar' ) or return;
  is $err->code, GIT_ERROR, 'with the generic GIT_ERROR code (-1)';
  # GIT_ERROR is what libgit2 answers for half its failures, so the code alone
  # would also pass on an unrelated one. The message is what names the reason.
  like $err->message, qr/multivar/, 'and a message naming the multivar';

  my @values = local_config_file($dir)->slurp_utf8 =~ /^\s*v\s*=\s*(\S+)\s*$/mg;
  is \@values, [qw( one two )], 'both values are still in .git/config';
  is( Git::Native->open("$dir")->config_string('multi.v'), 'two',
    'and libgit2 still reads the key (last value wins)' );
};

subtest 'a valueless boolean entry (karr.readonly) is deleted' => sub {
  # Exactly how karr marks a board read-only: `[karr]` + `readonly` with no
  # `= value`, which git reads as true. This is the entry the card exists for.
  # git_config_delete_multivar segfaults on such an entry (measured, 1.9.3) -
  # one more reason there is no unset-all.
  my ( $init, $dir ) = TestRepo::new_repo();
  local_config_file($dir)->append("[karr]\n\treadonly\n");
  my $repo = Git::Native->open("$dir");
  is $repo->config_snapshot->get_bool('karr.readonly'), 1,
    'control: the valueless entry reads as true';

  is $repo->config->delete('karr.readonly'), 1, 'delete returns 1';
  is $repo->config_snapshot->get_bool('karr.readonly'), undef,
    'the same repository reads it as unset';
  is( Git::Native->open("$dir")->config_snapshot->get_bool('karr.readonly'), undef,
    'and so does a freshly opened one - it is gone from disk' );
};

subtest 'delete reaches the repository level only' => sub {
  # The documented scope, not a bug: libgit2 deletes from the level it writes
  # to, the repository's .git/config. A key that lives only in the global
  # config is "not set at that level", so delete reports it gone - and the
  # merged view keeps answering it from the global file, untouched.
  my $global = path( "$TestRepo::HOME", '.gitconfig' );
  my $content = "[globalonly]\n\tk = from-global\n[both]\n\tk = from-global\n";
  $global->spew_utf8($content);

  my ( $repo, $dir ) = TestRepo::new_repo();
  is $repo->config_string('globalonly.k'), 'from-global',
    'control: the global key is visible through the merged view';

  is $repo->config->delete('globalonly.k'), 1,
    'deleting a global-only key returns 1 - it is not set at the local level';
  is $repo->config_string('globalonly.k'), 'from-global',
    'the merged view still answers it from the global level';
  is $global->slurp_utf8, $content, 'the global config file is byte-for-byte untouched';

  # Same key at both levels: the local one wins until it is deleted, then the
  # global one shows through. Pins that delete took the local entry and only
  # the local entry.
  $repo->config->set_string( 'both.k', 'from-local' );
  is $repo->config_string('both.k'), 'from-local', 'control: the local value outranks the global one';
  is $repo->config->delete('both.k'), 1, 'deleting the shadowing local key returns 1';
  is $repo->config_string('both.k'), 'from-global', 'and the global value shows through again';
  is $global->slurp_utf8, $content, 'the global file is still untouched';

  $global->remove;
};

subtest 'an invalid name throws GIT_EINVALIDSPEC' => sub {
  my ( $repo, $dir ) = TestRepo::new_repo();
  for my $name ( 'nodot', 'bad key.x y' ) {
    my $err = dies { $repo->config->delete($name) };
    is_native_error( $err, "delete('$name')" ) or next;
    is $err->code, GIT_EINVALIDSPEC, "delete('$name') carries GIT_EINVALIDSPEC";
    is $err->is_invalid_spec, 1, "delete('$name') answers is_invalid_spec";
  }
};

subtest 'a snapshot refuses delete with GIT_EREADONLY, even for an absent key' => sub {
  # The message is deliberately not asserted: libgit2 returns -40 here without
  # setting an error of its own, so ->message is whatever the previous libgit2
  # call left behind (measured: a stat failure from taking the snapshot).
  my ( $repo, $dir ) = TestRepo::new_repo();
  $repo->config->set_string( 'own.k', 'x' );

  # Absent key first: the read-only refusal must win over the idempotent
  # not-found path, or a delete on the wrong handle would report success.
  my $absent = dies { $repo->config_snapshot->delete('x.y') };
  is_native_error( $absent, 'delete of an absent key on a snapshot' ) or return;
  is $absent->code, GIT_EREADONLY, 'with GIT_EREADONLY, not a quiet 1';

  my $present = dies { $repo->config_snapshot->delete('own.k') };
  is_native_error( $present, 'delete of a present key on a snapshot' ) or return;
  is $present->code, GIT_EREADONLY, 'with GIT_EREADONLY';
  is $repo->config_string('own.k'), 'x', 'and the key is still there';
};

# ---------------------------------------------------------------------------
# Staleness: the refresh inside Config->delete.
#
# Without the refresh, all three subtests below still see delete return 1 -
# GIT_ENOTFOUND is the idempotent path - so the return value cannot tell. The
# on-disk checks after it are the assertions that go red.
#
# ORDER MATTERS. Repository->config_string / config_snapshot refresh the same
# cached git_config* that delete uses (measured: a config_string between the
# external write and the delete makes even an unrefreshed delete succeed). So
# nothing may read the config between the external write and the delete, or
# these subtests measure nothing.
# ---------------------------------------------------------------------------
subtest 'an external git CLI write is deleted through a freshly fetched config' => sub {
  skip_all 'git is not on PATH - no way to make the external write this subtest needs'
    unless $HAVE_GIT;

  my ( $repo, $dir ) = TestRepo::new_repo();
  is system( 'git', '-C', "$dir", 'config', '--local', 'ext.k', 'v' ), 0,
    'git config writes ext.k behind libgit2\'s back';

  is $repo->config->delete('ext.k'), 1, 'delete returns 1';

  my ( $rc, @values ) = git_get_all( "$dir", 'ext.k' );
  is $rc, 1, 'git config --get exits 1: the key is gone on disk';
  is \@values, [], 'and prints nothing';
  is $repo->config_string('ext.k'), undef, 'a fresh config_string agrees';
};

subtest 'an external git CLI write is deleted through a config held across it' => sub {
  skip_all 'git is not on PATH - no way to make the external write this subtest needs'
    unless $HAVE_GIT;

  my ( $repo, $dir ) = TestRepo::new_repo();
  my $held = $repo->config;
  is system( 'git', '-C', "$dir", 'config', '--local', 'ext.k', 'v' ), 0,
    'git config writes ext.k while a Config is held';

  is $held->delete('ext.k'), 1, 'delete through the held Config returns 1';

  my ( $rc, @values ) = git_get_all( "$dir", 'ext.k' );
  is $rc, 1, 'git config --get exits 1: the key is gone on disk';
  is \@values, [], 'and prints nothing';
  is $repo->config_string('ext.k'), undef, 'a fresh config_string agrees';
};

subtest 'a hand edit of .git/config behind an open repository is deleted too' => sub {
  # The same staleness without the git CLI, so the refresh is covered on a
  # machine that has no git. Appending changes the file's size, which is what
  # libgit2's refresh checks.
  my ( $repo, $dir ) = TestRepo::new_repo();
  my $held = $repo->config;
  local_config_file($dir)->append("[hand]\n\tk = v\n");

  is $held->delete('hand.k'), 1, 'delete returns 1';
  unlike local_config_file($dir)->slurp_utf8, qr/^\s*k\s*=\s*v\s*$/m,
    'the entry is gone from .git/config';
  is( Git::Native->open("$dir")->config_string('hand.k'), undef,
    'and a freshly opened repository does not see it' );
};

done_testing;
