#!/usr/bin/env perl
use Test2::V0;
use lib 't/lib';
use TestRepo;
use Git::Libgit2 qw( init_lib );
use Git::Libgit2::Error ();
use Git::Native::Remote ();
use Git::Native::Error ();
use Git::Native ();
use FFI::Platypus::Buffer qw( scalar_to_buffer );

# karr ticket k49: when the user's credential coderef dies (or returns the
# wrong thing) the thunk returns -1 to libgit2. libgit2 sets no message for
# that, so check_rc used to report whatever an earlier call left in the
# thread-local error slot - e.g. "config value http.followRedirects was not
# found". The thunk now sets a GIT_ERROR_CALLBACK message of its own.
#
# A file:// remote never calls the credential callback, so this drives the
# thunk directly (as t/52 does) and reads the libgit2 error slot the way
# check_rc does.

init_lib();

my ( $repo, $dir ) = TestRepo::new_repo();

# Leave a stale, unrelated message in libgit2's error slot.
sub stale_error {
  eval { $repo->reference('refs/heads/does-not-exist') };
  my $e = Git::Libgit2::Error->last;
  like $e->message, qr/not found|does-not-exist/i, 'precondition: a stale not-found message is in the slot';
}

sub call_thunk {
  my ($cb) = @_;
  my ($closure) = Git::Native::Remote::_make_credential_thunk($cb);
  my $buf = "\0" x 8;
  my ($addr) = scalar_to_buffer($buf);
  my $rc;
  local $SIG{__WARN__} = sub { };
  $rc = $closure->( $addr, 'https://example.invalid/r.git', 'git', 3, 0 );
  return $rc;
}

subtest 'a dying coderef surfaces a message naming the callback failure' => sub {
  stale_error();
  is call_thunk( sub { die "no credentials for you\n" } ), -1, 'rc is -1';

  my $e = Git::Libgit2::Error->last;
  like $e->message, qr/credential callback died: no credentials for you/,
    'the libgit2 error names the callback failure and its reason';
  unlike $e->message, qr/not found|does-not-exist/i, 'and is not the stale lookup message';

  # And through check_rc, as fetch / push would throw it.
  my $err = dies { Git::Native::Error::check_rc(-1) };
  isa_ok $err, ['Git::Native::Error'], 'check_rc throws a Git::Native::Error';
  like $err->message, qr/credential callback died: no credentials for you/,
    'whose message is the callback failure';
};

subtest 'a wrong return value surfaces a message naming the callback failure' => sub {
  stale_error();
  is call_thunk( sub { 'not a credential' } ), -1, 'rc is -1';
  my $e = Git::Libgit2::Error->last;
  like $e->message, qr/credentials callback must return a Git::Native::Credential/,
    'the libgit2 error carries the diagnosis';
};

done_testing;
