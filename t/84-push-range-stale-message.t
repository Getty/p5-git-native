#!/usr/bin/env perl
use Test2::V0;
use lib 't/lib';
use TestRepo;
use Git::Native;
use Git::Libgit2 qw( GIT_ENOTFOUND );
use Git::Libgit2::Error ();

# Revwalker->push_range and the stale libgit2 message - karr ticket k48, the
# audit that followed k37 (t/83-check-rc-stale-message.t).
#
# "@{-N}" means "the N-th branch checked out before this one", read from the
# "checkout: moving from" entries of the HEAD reflog. With fewer than N such
# entries libgit2's revparse returns GIT_ENOTFOUND without calling
# git_error_set (1.9.3 revparse.c:204, the same in 1.5.1), and
# git_revwalk_push_range hands that rc straight back. Before the fix check_rc
# then attached whatever an earlier, unrelated call had left in the error state
# - measured: "reference 'refs/heads/stale-marker' not found" from the
# reference_exists probe below.
#
# The first subtest goes red when the git_error_clear in push_range is removed.
# The second is the control: a push_range failure libgit2 does describe must
# keep its own message, so "drop every message" cannot pass this file.

my $DEFAULT = '<unknown libgit2 error>';

# A repository with one commit on main, made through libgit2: its HEAD reflog
# holds "commit (initial)" and no checkout entry, so even @{-1} has nothing to
# resolve to. Returns the tempdir too - the caller must hold it, or the
# directory is gone before the first push_range and HEAD itself is not found.
sub fixture {
  my ( $repo, $dir ) = TestRepo::new_repo();
  my $cfg = $repo->config;
  $cfg->set_string( 'user.name',  'Test' );
  $cfg->set_string( 'user.email', 'test@example.invalid' );
  my $tb = $repo->tree_builder;
  $tb->insert( name => 'f', oid => $repo->blob_create_frombuffer("x\n") );
  $repo->commit_create(
    tree       => $tb->write,
    message    => "c\n",
    update_ref => 'HEAD',
  );
  return ( $repo, $dir );
}

for my $spec ( '@{-1}..HEAD', 'HEAD..@{-99}' ) {
  subtest "push_range('$spec') does not carry the message of an earlier call" => sub {
    my ( $repo, $dir ) = fixture();

    # If HEAD itself did not resolve, revparse would fail on the HEAD lookup
    # with a message of its own before ever reaching the silent path, and this
    # subtest would pass without the fix.
    ok lives { $repo->revwalker->push_range('HEAD..HEAD') },
      'control: HEAD resolves, so only the @{-N} side can fail';

    # An earlier call that leaves an error behind without throwing:
    # reference_exists answers 0 for a missing ref and swallows libgit2's
    # not-found, message and all.
    ok !$repo->reference_exists('refs/heads/stale-marker'), 'the probe ref is absent';

    # Read the pending state without touching it. If nothing were pending, the
    # assertions below would pass on the unfixed code too.
    my $pending = Git::Libgit2::Error->last;
    isnt $pending->klass, 0, 'control: an error from an earlier call is pending'
      or diag 'nothing pending - this subtest cannot tell stale from fresh';
    note 'pending before push_range: ' . $pending->message;

    my $err = dies { $repo->revwalker->push_range($spec) };
    isa_ok $err, ['Git::Native::Error'], 'an unresolvable @{-N} throws a Git::Native::Error'
      or return;
    is $err->code, GIT_ENOTFOUND, 'with GIT_ENOTFOUND - the code was never the problem';
    ok $err->is_not_found, 'is_not_found answers';

    isnt $err->message, $pending->message, 'the message is not the one left pending';
    unlike $err->message, qr/stale-marker/, 'it does not name the ref of the earlier probe';

    # Measured on 1.9.3: libgit2 sets nothing for this rc, so klass is 0 and the
    # message is the default. A libgit2 that starts setting its own message is
    # not a regression; the assertions above still hold for it.
    if ( $err->klass == 0 ) {
      is $err->message, $DEFAULT, "no libgit2 message: the '$DEFAULT' default";
    }
    else {
      note 'libgit2 now sets its own message here: ' . $err->message;
      pass 'libgit2 set a message of its own for the unresolvable @{-N}';
    }
  };
}

subtest 'a push_range failure libgit2 does describe keeps its message' => sub {
  my ( $repo, $dir ) = fixture();
  ok !$repo->reference_exists('refs/heads/stale-marker'), 'the same earlier probe';

  my $err = dies { $repo->revwalker->push_range('nope..HEAD') };
  isa_ok $err, ['Git::Native::Error'], 'an unknown revision throws' or return;
  ok $err->is_not_found, 'as not-found';
  isnt $err->klass, 0, 'with a non-zero klass';
  like $err->message, qr/nope/, "and libgit2's own message naming the revision";
  unlike $err->message, qr/stale-marker/, 'not the message of the earlier probe';
};

done_testing;
