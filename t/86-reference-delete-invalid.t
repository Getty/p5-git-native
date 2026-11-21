#!/usr/bin/env perl
use Test2::V0;
use lib 't/lib';
use TestRepo;
use Git::Native;
use Git::Libgit2 qw( GIT_EINVALIDSPEC );

# karr ticket k50: git_reference_remove does not validate the name, so
# reference_delete('refs/heads/a..b') used to report success like an absent
# ref. Decision: an invalid name throws is_invalid_spec; an absent but valid
# ref stays an idempotent success (t/63).

my ( $repo, $dir ) = TestRepo::new_repo();

subtest 'an invalid refname throws is_invalid_spec' => sub {
  for my $name ( 'refs/heads/a..b', 'refs/heads/a b', 'refs/heads/x.lock', 'refs/heads/', '' ) {
    my $err = dies { $repo->reference_delete($name) };
    isa_ok $err, ['Git::Native::Error'], "'$name' throws a Git::Native::Error";
    is $err->code, GIT_EINVALIDSPEC, "'$name' carries GIT_EINVALIDSPEC";
    ok $err->is_invalid_spec, "'$name' answers is_invalid_spec";
  }
  my $err = dies { $repo->reference_delete(undef) };
  ok $err && $err->is_invalid_spec, 'undef is an invalid name too';
};

subtest 'an absent but valid ref is still an idempotent success' => sub {
  my $ret;
  ok lives { $ret = $repo->reference_delete('refs/heads/never-existed') },
    'deleting an absent valid ref does not throw';
  ref_is $ret, $repo, 'and returns the repository';
};

done_testing;
