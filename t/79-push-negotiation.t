use Test2::V0;
use lib 't/lib';
use TestRepo;
use Git::Native;
use Git::Libgit2 qw( GIT_EUSER );
use Path::Tiny;

# git_remote_callbacks.push_negotiation runs after the remote advertised its
# refs and before anything is sent: `src` is what the remote holds for the ref
# now, `dst` what the push is about to write. A non-zero return aborts. That
# is the only hook a libgit2 caller has for what `git push --force-with-lease`
# does, so the contract pinned here is the one a lease is built on: the
# callback sees the remote's CURRENT value, and a veto stops the push with an
# error that is not a transport failure.

my $bare_dir = Path::Tiny->tempdir;
my $bare     = Git::Native->init( "$bare_dir", bare => 1 );
my $url      = TestRepo::file_url($bare_dir);

sub clone_with_commit {
  my ($msg) = @_;
  my $dir  = Path::Tiny->tempdir;
  my $repo = Git::Native->init("$dir");
  my $tb   = $repo->tree_builder;
  $tb->insert( name => 'f', oid => $repo->blob_create_frombuffer("$msg\n"),
               mode => 0100644 );
  my $oid = $repo->commit_create(
    tree => $tb->write, parents => [], message => $msg,
  );
  return ( $repo, $oid, $dir );
}

my ( $a, $oid_a, $keep_a ) = clone_with_commit('first');
my ( $b, $oid_b, $keep_b ) = clone_with_commit('second');
my $remote_a = $a->remote_create( origin => $url );
my $remote_b = $b->remote_create( origin => $url );
my $ref = 'refs/karr/lease';
$a->reference_create( $ref, $oid_a );
$b->reference_create( $ref, $oid_b );

my @seen;
my $spy = sub { push @seen, [@_]; return 1 };

subtest 'first push: the ref is new on the remote, src is undef' => sub {
  my $res = $remote_a->push( refspecs => ["+$ref:$ref"], negotiation => $spy );
  is scalar @seen, 1, 'callback ran once';
  is scalar @{ $seen[0] }, 1, 'with one update';
  is $seen[0][0], {
    src_refname => $ref,
    dst_refname => $ref,
    src         => undef,
    dst         => $oid_a->hex,
  }, 'zero src oid reported as undef, dst is the local oid in hex';
  ok $res->ok || @{ $res->updated }, 'push went through';
  is $bare->reference($ref)->target->hex, $oid_a->hex, 'remote holds A';
};

subtest 'second push after the remote ref moved: the callback sees the moved src' => sub {
  # B was never told about A's push; its forced push would overwrite it.
  @seen = ();
  $remote_b->push( refspecs => ["+$ref:$ref"], negotiation => $spy );
  is $seen[0][0]{src}, $oid_a->hex, 'src is the value A pushed, not what B expected';
  is $seen[0][0]{dst}, $oid_b->hex, 'dst is B\'s oid';
  is $bare->reference($ref)->target->hex, $oid_b->hex,
    'a true return lets the forced push overwrite';
};

subtest 'a false return aborts the push with a distinguishable error' => sub {
  # remote now holds B; A tries to force back to A under a lease on A.
  my $err = dies {
    $remote_a->push(
      refspecs   => ["+$ref:$ref"],
      negotiation => sub { return 0 },
    );
  };
  isa_ok $err, ['Git::Native::Error'], 'a Git::Native::Error';
  is $err->code, GIT_EUSER, 'code GIT_EUSER, not a transport code';
  like $err->message, qr/negotiation/i, 'message says who vetoed';
  is $bare->reference($ref)->target->hex, $oid_b->hex, 'remote ref untouched';
};

subtest 'a lease: veto exactly when the remote ref is not what the caller expects' => sub {
  my $lease = sub {
    my $expected = shift;
    return sub { my ($u) = @_; return ( $u->{src} // '' ) eq $expected };
  };
  my $err = dies {
    $remote_a->push( refspecs => ["+$ref:$ref"],
                     negotiation => $lease->( $oid_a->hex ) );
  };
  ok $err && $err->code == GIT_EUSER, 'stale lease (expects A, remote has B) aborts';
  is $bare->reference($ref)->target->hex, $oid_b->hex, 'nothing overwritten';

  ok lives {
    $remote_a->push( refspecs => ["+$ref:$ref"],
                     negotiation => $lease->( $oid_b->hex ) );
  }, 'a lease that matches lets the push through';
  is $bare->reference($ref)->target->hex, $oid_a->hex, 'forced update landed';
};

subtest 'an exception in the callback aborts the push and keeps its text' => sub {
  my $err = dies {
    $remote_b->push( refspecs => ["+$ref:$ref"],
                     negotiation => sub { die "lease broken\n" } );
  };
  isa_ok $err, ['Git::Native::Error'], 'a Git::Native::Error, not the raw die';
  is $err->code, GIT_EUSER, 'same code as a false return';
  like $err->message, qr/lease broken/, 'the exception text is carried';
  is $bare->reference($ref)->target->hex, $oid_a->hex, 'remote ref untouched';
};

subtest 'the callback gets one hash per update' => sub {
  my ( $c, $oid_c, $keep_c ) = clone_with_commit('third');
  my $rc = $c->remote_create( origin => $url );
  $c->reference_create( "$ref/x", $oid_c );
  $c->reference_create( "$ref/y", $oid_c );
  my @got;
  $rc->push( refspecs => [ "$ref/x:$ref/x", "$ref/y:$ref/y" ],
             negotiation => sub { @got = @_; 1 } );
  is [ sort map { $_->{dst_refname} } @got ], [ "$ref/x", "$ref/y" ],
    'both updates arrive in one call';
};

subtest 'without negotiation nothing changes' => sub {
  my $res = $remote_a->push( refspecs => ["+$ref:$ref"] );
  ok $res, 'plain push still works';
};

done_testing;
