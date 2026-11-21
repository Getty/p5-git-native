#!/usr/bin/env perl
use Test2::V0;
use lib 't/lib';
use TestRepo;
use IO::Socket::INET;
use Git::Native;
use Git::Native::Error;

# karr ticket k39: Git::Native::Error->http_status, parsed from libgit2's
# "unexpected http status code: N" message. The body of the response is not
# reachable through libgit2 1.9 (see the POD), so only the status is tested.

subtest 'the parser' => sub {
  my $mk = sub { Git::Native::Error->new( code => -1, klass => 34, message => $_[0] ) };
  is $mk->('unexpected http status code: 403')->http_status, 403, '403';
  is $mk->('unexpected http status code: 500')->http_status, 500, '500, as a number';
  is $mk->('unexpected http status code: 404')->http_status + 1, 405, 'numeric';
  is $mk->('object not found')->http_status, undef, 'undef for another message';
  is $mk->('unexpected http status code: abc')->http_status, undef, 'undef for a non-number';
  is( Git::Native::Error->new( code => -1 )->http_status, undef, 'undef for the default message' );
  ok !Git::Native::Error->can('http_body'), 'there is no http_body: libgit2 does not expose it';
};

subtest 'a real 403 from a local 127.0.0.1 server' => sub {
  my $srv = IO::Socket::INET->new(
    Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', ReuseAddr => 1,
  ) or skip_all "cannot listen on 127.0.0.1: $!";
  my $port = $srv->sockport;

  my $pid = fork // skip_all "fork failed: $!";
  if ( !$pid ) {
    local $SIG{ALRM} = sub { exit 0 };
    alarm 20;
    while ( my $c = $srv->accept ) {
      my $req = '';
      while ( my $l = <$c> ) { $req .= $l; last if $l =~ /^\r?\n$/ }
      my $body = "You have exceeded a secondary rate limit.\n";
      print $c "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n"
        . 'Content-Length: ' . length($body) . "\r\nConnection: close\r\n\r\n$body";
      close $c;
    }
    exit 0;
  }
  close $srv;

  my ( $repo, $dir ) = TestRepo::new_repo();
  my $remote = $repo->remote_anonymous("http://127.0.0.1:$port/r.git");
  my $err = dies { $remote->list_refs };
  kill 'TERM', $pid;
  waitpid $pid, 0;

  isa_ok $err, ['Git::Native::Error'], 'the refused request throws a Git::Native::Error';
  diag "got: " . ( defined $err ? "$err" : 'no exception' ) unless ref $err;
  is $err->http_status, 403, 'http_status is 403' if ref $err;
};

done_testing;
