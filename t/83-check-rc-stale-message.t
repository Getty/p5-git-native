#!/usr/bin/env perl
use Test2::V0;
use lib 't/lib';
use TestRepo;
use Git::Native;
use Git::Libgit2 qw( GIT_EREADONLY );
use Git::Libgit2::Error ();
use Git::Libgit2::FFI ();
use Git::Native::Error qw( check_rc );

# check_rc and the stale libgit2 message - karr ticket k37.
#
# check_rc builds its Git::Native::Error from git_error_last(), libgit2's
# thread-local error. That state carries no return code: libgit2 does not clear
# it on success (taking a config snapshot leaves a stat failure on the missing
# global .gitconfig behind, rc 0), and some functions return a negative code
# without setting an error at all. git_config_delete_entry on a snapshot is one:
# GIT_EREADONLY straight from config.c, no git_error_set (libgit2 1.9.3). Before
# the fix, Config->delete on a snapshot threw the right code with the message
# of an earlier, unrelated call.
#
# The fix has two halves, and each has a subtest here that goes red without it:
#   * Config->delete clears the error state right before git_config_delete_entry
#     (the first subtest);
#   * check_rc reports an empty state (klass 0, GIT_ERROR_NONE) with the
#     '<unknown libgit2 error>' default instead of libgit2's "no error" (the
#     first and second subtests).
# The third subtest is the control: a message libgit2 does set must still come
# through, so "drop every message" cannot pass this file.

my $DEFAULT = '<unknown libgit2 error>';

subtest 'a snapshot delete does not carry the message of an earlier call' => sub {
  my ( $repo, $dir ) = TestRepo::new_repo();

  # Two earlier calls that leave an error behind without throwing: the
  # idempotent delete swallows its GIT_ENOTFOUND, the snapshot succeeds after
  # failing to stat a config file it does not need.
  $repo->config->delete('stale.marker');
  my $snap = $repo->config_snapshot;

  # Read the pending state without touching it. If nothing were pending, the
  # assertions below would pass on the unfixed code too.
  my $pending = Git::Libgit2::Error->last;
  isnt $pending->klass, 0, 'control: an error from an earlier call is pending'
    or diag 'nothing pending - this subtest cannot tell stale from fresh';
  note 'pending before the delete: ' . $pending->message;

  my $err = dies { $snap->delete('x.y') };
  isa_ok $err, ['Git::Native::Error'], 'delete on a snapshot throws a Git::Native::Error'
    or return;
  is $err->code, GIT_EREADONLY, 'with GIT_EREADONLY - the code was never the problem';

  isnt $err->message, $pending->message, 'the message is not the one left pending';
  unlike $err->message, qr/stale\.marker/, 'it does not name the key of the earlier delete';
  unlike $err->message, qr/\Q$TestRepo::HOME\E/,
    'nor a config file the snapshot failed to stat';

  # Measured on 1.9.3: libgit2 sets nothing for this rc, so klass is 0 and the
  # message is the default. A libgit2 that starts setting its own message is
  # not a regression; the assertions above still hold for it.
  if ( $err->klass == 0 ) {
    is $err->message, $DEFAULT, "no libgit2 message: the '$DEFAULT' default";
  }
  else {
    note 'libgit2 now sets its own message here: ' . $err->message;
    pass 'libgit2 set a message of its own for GIT_EREADONLY';
  }
};

subtest 'check_rc reports an empty error state as unknown, not as "no error"' => sub {
  Git::Libgit2::FFI::git_error_clear();
  is( Git::Libgit2::Error->last->klass, 0, 'control: the error state is empty' );

  my $err = dies { check_rc(GIT_EREADONLY) };
  isa_ok $err, ['Git::Native::Error'], 'a negative rc still throws' or return;
  is $err->code,    GIT_EREADONLY, 'the code is the rc';
  is $err->klass,   0,             'klass is 0, GIT_ERROR_NONE';
  is $err->message, $DEFAULT,      "the message is '$DEFAULT'";
};

subtest 'a message libgit2 does set still comes through' => sub {
  my ( $repo, $dir ) = TestRepo::new_repo();
  my $err = dies { $repo->reference('refs/heads/nope') };
  isa_ok $err, ['Git::Native::Error'], 'a missing ref throws' or return;
  ok $err->is_not_found, 'as not-found';
  isnt $err->klass, 0, 'with a non-zero klass';
  like $err->message, qr{refs/heads/nope}, "and libgit2's own message naming the ref";
};

done_testing;
