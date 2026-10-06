use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/lib";
use TestRepo;
use Path::Tiny;
use MIME::Base64 qw( encode_base64 );
use Digest::SHA qw( sha1 sha256 hmac_sha1 );
use FFI::Platypus::Buffer qw( scalar_to_buffer );
use Git::Libgit2 qw( GIT_DIRECTION_FETCH GIT_DIRECTION_PUSH cert_hostkey_offsets );
use Git::Native::Remote ();

# The port is part of a host's identity in known_hosts. OpenSSH files a host
# on the default port under its bare name and a host on any other port under
# "[host]:port" - in plain entries and inside the HMAC of hashed ones alike.
# libgit2 hands the certificate_check callback the bare host name only, so a
# matcher that works from that alone gets both directions wrong:
#
#   * a hashed "[host]:2222" entry never matches, and with HashKnownHosts
#     (the Debian/Ubuntu default) every ssh://host:2222/ remote is refused
#     although `ssh` connects fine;
#   * a plain "[host]:2222" entry is taken for the host on every port, so the
#     key of one service vouches for another service on the same machine.
#
# Network-free: the name, the URL parsing and the matching are pure logic, and
# the callback is driven from Perl with a synthetic git_cert_hostkey.

# TestRepo redirects HOME; on Windows the matcher reads these two as well.
delete @ENV{qw( USERPROFILE PROGRAMDATA )};

my $HOST = 'git.unit-test.invalid';

my $key     = join '', map { chr } 0 .. 255;
my $key64   = encode_base64( $key, '' );
my $other   = 'the key of another service on the same machine';
my $other64 = encode_base64( $other, '' );

# A hashed host field the way OpenSSH writes it: |1|salt|HMAC-SHA1(name).
sub hashed_field {
  my ($name) = @_;
  my $salt = pack 'C*', 1 .. 20;
  return '|1|' . encode_base64( $salt, '' ) . '|'
       . encode_base64( hmac_sha1( $name, $salt ), '' );
}

# Run $code with a throwaway HOME whose known_hosts has $content.
sub with_known_hosts {
  my ( $content, $code ) = @_;
  my $home = Path::Tiny->tempdir;
  $home->child('.ssh')->mkpath;
  $home->child( '.ssh', 'known_hosts' )->spew_utf8($content);
  local $ENV{HOME} = "$home";
  return $code->();
}

sub match_against {
  my ( $content, %args ) = @_;
  return with_known_hosts( $content, sub {
    Git::Native::Remote::_known_hosts_match(
      $args{host} // $HOST, 'sha1', $args{want} // sha1($key), $args{port},
    );
  } );
}

subtest 'the name a host is filed under' => sub {
  my $name = \&Git::Native::Remote::_known_hosts_name;
  is $name->( $HOST, 22 ),    $HOST,           'port 22: the bare host name';
  is $name->( $HOST, undef ), $HOST,           'no port known: the bare host name';
  is $name->( $HOST, 2222 ),  "[$HOST]:2222",  'any other port: [host]:port';
  is $name->( '::1', 2222 ),  '[::1]:2222',    'an IPv6 address is bracketed the same way';
};

subtest 'the port of a remote URL' => sub {
  my $port = \&Git::Native::Remote::_ssh_port_from_url;
  my @cases = (
    [ "ssh://git\@$HOST:2222/repo.git",      2222, 'ssh:// with a port' ],
    [ "ssh://git\@$HOST/repo.git",             22, 'ssh:// without a port' ],
    [ "ssh://$HOST:2222/repo.git",           2222, 'ssh:// with a port, no user' ],
    [ "ssh://git\@$HOST:/repo.git",            22, 'ssh:// with an empty port' ],
    [ "ssh://git\@$HOST:02222/repo.git",     2222, 'a port is a number, not a string' ],
    [ "SSH://git\@$HOST:2222/repo.git",      2222, 'the scheme is case-insensitive' ],
    [ "git+ssh://git\@$HOST:2222/repo.git",  2222, 'git+ssh://' ],
    [ "ssh+git://git\@$HOST:2222/repo.git",  2222, 'ssh+git://' ],
    [ 'ssh://git@[::1]:2222/repo.git',       2222, 'ssh:// with an IPv6 address and a port' ],
    [ 'ssh://git@[2001:db8::22]/repo.git',     22, 'the tail of an IPv6 address is not a port' ],
    [ "git\@$HOST:owner/repo.git",             22, 'scp-like' ],
    [ "git\@$HOST:2222/repo.git",              22, 'scp-like: digits after the colon are path, not port' ],
    [ "[git\@$HOST:2222]:owner/repo.git",    2222, 'scp-like with a bracketed user@host:port' ],
    [ "[$HOST:2222]:owner/repo.git",         2222, 'scp-like with a bracketed host:port' ],
    [ 'git@[2001:db8::22]:owner/repo.git',     22, 'scp-like with an IPv6 address' ],
    [ 'https://example.invalid:8443/r.git',    22, 'not an SSH URL: the default (never consulted)' ],
    [ undef,                                   22, 'no URL at all: the default' ],
  );
  for my $case (@cases) {
    my ( $url, $want, $what ) = @$case;
    is $port->($url), $want, $what;
  }
};

subtest 'host field: a hashed entry for another port' => sub {
  my $in    = \&Git::Native::Remote::_host_in_field;
  my $name  = Git::Native::Remote::_known_hosts_name( $HOST, 2222 );
  my $field = hashed_field("[$HOST]:2222");

  ok $in->( $name, $field ),
    'a hashed [host]:2222 entry matches the host on port 2222';
  ok !$in->( Git::Native::Remote::_known_hosts_name( $HOST, 22 ), $field ),
    'and not the same host on port 22';
  ok !$in->( Git::Native::Remote::_known_hosts_name( $HOST, 2200 ), $field ),
    'nor on a third port';
  ok !$in->( $name, hashed_field($HOST) ),
    'a hashed entry for the bare host does not cover port 2222';
};

subtest 'host field: a plain entry for another port' => sub {
  my $in     = \&Git::Native::Remote::_host_in_field;
  my $p22    = Git::Native::Remote::_known_hosts_name( $HOST, 22 );
  my $p2222  = Git::Native::Remote::_known_hosts_name( $HOST, 2222 );

  ok $in->( $p2222, "[$HOST]:2222" ), '[host]:2222 matches the host on port 2222';
  ok !$in->( $p22, "[$HOST]:2222" ),
    '[host]:2222 does NOT match the host on port 22';
  ok !$in->( Git::Native::Remote::_known_hosts_name( $HOST, 2200 ), "[$HOST]:2222" ),
    'nor the host on a third port';
  ok !$in->( $p2222, $HOST ),
    'an entry for the bare host does not cover port 2222';
  ok $in->( $p2222, "other.invalid,[$HOST]:2222" ),
    'a comma list is still searched';
  ok $in->( $p2222, '[*.unit-test.invalid]:2222' ),
    'a wildcard inside the brackets matches on that port';
  ok !$in->( $p2222, '*.unit-test.invalid' ),
    'a bare wildcard does not reach into another port';
  ok $in->( $p22, "[$HOST]:22" ),
    'an explicit [host]:22 is still the host on the default port';
};

subtest 'known_hosts file: the port selects the entry' => sub {
  my $both = "$HOST ssh-ed25519 $other64\n"
           . hashed_field("[$HOST]:2222") . " ssh-ed25519 $key64\n";

  my ( $matched, $seen ) = match_against( $both, port => 2222 );
  is $matched, 1, 'the hashed [host]:2222 entry authorises the key on port 2222';
  is $seen, 1, 'and only that entry counts for the host on that port';

  ( $matched, $seen ) = match_against( $both, port => 22 );
  is $matched, 0,
    'the key cached for port 2222 is not accepted on port 22';
  is $seen, 1,
    'the port-22 entry was seen, so the caller reports a key mismatch';

  ( $matched, $seen ) = match_against( $both );
  is $matched, 0, 'without a port the lookup is the port-22 one';

  ( $matched, $seen ) = match_against(
    "[$HOST]:2222 ssh-ed25519 $key64\n", port => 22,
  );
  is $matched, 0, 'a plain [host]:2222 entry is not accepted on port 22';
  is $seen, 0, 'the host is unknown on port 22';

  ( $matched, $seen ) = match_against(
    "[$HOST]:2222 ssh-ed25519 $key64\n", port => 2200,
  );
  is $matched, 0, 'a plain [host]:2222 entry is not accepted on port 2200';
  is $seen, 0, 'the host is unknown on that port';

};

subtest 'known_hosts file: an unknown port falls back to the bare host' => sub {
  # OpenSSH does this ("checking without port identifier"): when nothing at
  # all is filed under [host]:port, the same key is looked up once more under
  # the bare host name, and accepted if that entry carries exactly this key.
  # Typical case: one sshd reachable on two ports, cached via port 22 only.
  my ( $matched, $seen, $revoked ) = match_against(
    "$HOST ssh-ed25519 $key64\n", port => 2222,
  );
  is $matched, 1, 'the key cached for the bare host is accepted on port 2222';

  ( $matched ) = match_against(
    hashed_field($HOST) . " ssh-ed25519 $key64\n", port => 2222,
  );
  is $matched, 1, 'a hashed entry for the bare host serves the fallback too';

  ( $matched, $seen ) = match_against(
    "$HOST ssh-ed25519 $other64\n", port => 2222,
  );
  is $matched, 0, 'a bare-host entry with another key does not';
  is $seen, 0,
    'and the host stays unknown on that port - the caller suggests ssh-keyscan -p';

  # The fallback is for a port nothing is known about. Once [host]:port has
  # an entry, that entry is the answer: a different key there is a mismatch,
  # and the bare host's key must not paper over it.
  for my $entry ( "[$HOST]:2222", hashed_field("[$HOST]:2222") ) {
    ( $matched, $seen ) = match_against(
      "$HOST ssh-ed25519 $key64\n$entry ssh-ed25519 $other64\n", port => 2222,
    );
    is $matched, 0,
      'a [host]:2222 entry with another key is a mismatch, no fallback';
    is $seen, 1, 'reported as a known host whose key differs';
  }

  ( $matched, $seen, $revoked ) = match_against(
    "$HOST ssh-ed25519 $key64\n\@revoked $HOST ssh-ed25519 $key64\n",
    port => 2222,
  );
  is $matched, 0, 'a key revoked for the bare host is not accepted via the fallback';
  is $revoked, 1, 'and is reported as revoked';

  ( $matched, $seen, $revoked ) = match_against(
    "$HOST ssh-ed25519 $key64\n\@revoked [$HOST]:2222 ssh-ed25519 $key64\n",
    port => 2222,
  );
  is $matched, 0, 'nor a key revoked for [host]:2222';
  is $revoked, 1, 'reported as revoked as well';

  ( $matched ) = match_against(
    "*.unit-test.invalid,!$HOST ssh-ed25519 $key64\n", port => 2222,
  );
  is $matched, 0, 'a negated pattern excludes the host on the fallback path too';

  # The other direction stays closed: the fallback only ever drops the port.
  ( $matched, $seen ) = match_against(
    "[$HOST]:2222 ssh-ed25519 $key64\n", port => 22,
  );
  is $matched, 0, 'a [host]:2222 entry is still not accepted on port 22';
  ( $matched, $seen ) = match_against(
    "[$HOST]:2222 ssh-ed25519 $key64\n", port => 2200,
  );
  is $matched, 0, 'nor on another port, by way of the fallback';
};

# A git_cert_hostkey as libssh2 would hand it over: cert_type at offset 0, the
# hash bits and the fingerprints where Git::Libgit2 says they are.
sub fake_hostkey_cert {
  my ($blob) = @_;
  my %off = cert_hostkey_offsets();
  my $buf = "\0" x 256;
  substr( $buf, 0, 4 )            = pack 'l', Git::Native::Remote::GIT_CERT_HOSTKEY_LIBSSH2();
  substr( $buf, $off{type}, 4 )   = pack 'l', Git::Native::Remote::GIT_CERT_SSH_SHA256();
  substr( $buf, $off{sha256}, 32 ) = sha256($blob);
  return $buf;
}

subtest 'the certificate_check callback looks the host up with its port' => sub {
  delete local $ENV{GIT_NATIVE_SSH_INSECURE};
  my $cert = fake_hostkey_cert($key);
  my ($cert_ptr) = scalar_to_buffer($cert);
  my $known = hashed_field("[$HOST]:2222") . " ssh-ed25519 $key64\n";

  my $check = sub {
    my ($port) = @_;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my ( $closure, $keep ) = Git::Native::Remote::_make_certcheck_thunk($port);
    my $rc = with_known_hosts( $known, sub { $closure->( $cert_ptr, 0, $HOST, 0 ) } );
    return ( $rc, join '', @warnings );
  };

  my ( $rc, $warned ) = $check->(2222);
  is $rc, 0, 'port 2222: the hashed [host]:2222 entry accepts the key';
  is $warned, '', 'without a warning';

  ( $rc, $warned ) = $check->(22);
  is $rc, -1, 'port 22: the same key is rejected';
  like $warned, qr/'\Q$HOST\E' is not in known_hosts/,
    'the host is reported under its port-22 name';
  like $warned, qr/`ssh-keyscan \Q$HOST\E >> /,
    'and the suggested ssh-keyscan needs no port';

  # Through the callback, the bare-host fallback included.
  {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my ( $closure, $keep ) = Git::Native::Remote::_make_certcheck_thunk(2222);
    my $rc = with_known_hosts(
      "$HOST ssh-ed25519 $key64\n", sub { $closure->( $cert_ptr, 0, $HOST, 0 ) },
    );
    is $rc, 0, 'port 2222 with only a bare-host entry for this key: accepted';
    is join( '', @warnings ), '', 'without a warning';
  }

  ( $rc, $warned ) = $check->(2200);
  is $rc, -1, 'port 2200: rejected';
  like $warned, qr/'\[\Q$HOST\E\]:2200' is not in known_hosts/,
    'the warning names the host the way known_hosts files it';
  like $warned, qr/`ssh-keyscan -p 2200 \Q$HOST\E >> /,
    'and the suggested ssh-keyscan carries the port';
};

subtest 'the callback reports a revoked key as revoked' => sub {
  # The fake certificate lives here, so the one warning _known_hosts_match
  # cannot be asked about (t/64 pins its return values) is checked here too.
  delete local $ENV{GIT_NATIVE_SSH_INSECURE};
  my $cert = fake_hostkey_cert($key);
  my ($cert_ptr) = scalar_to_buffer($cert);

  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  my ( $closure, $keep ) = Git::Native::Remote::_make_certcheck_thunk(2222);
  my $rc = with_known_hosts(
    "[$HOST]:2222 ssh-ed25519 $key64\n\@revoked * ssh-ed25519 $key64\n",
    sub { $closure->( $cert_ptr, 0, $HOST, 0 ) },
  );
  my $warned = join '', @warnings;

  is $rc, -1, 'the connection is refused';
  like $warned, qr/'\[\Q$HOST\E\]:2222' is marked \@revoked/,
    'the warning says the key is revoked';
  unlike $warned, qr/ssh-keyscan|GIT_NATIVE_SSH_INSECURE/,
    'and does not suggest fetching the key again or bypassing the check';
};

subtest 'the port comes from the URL the operation connects to' => sub {
  my ( $repo, $tmp ) = TestRepo::new_repo();
  $repo->remote_create( 'origin', "ssh://git\@$HOST:2222/repo.git" );

  my $remote = $repo->remote('origin');
  is $remote->_ssh_port(GIT_DIRECTION_FETCH), 2222, 'fetch: the port of the URL';
  is $remote->_ssh_port(GIT_DIRECTION_PUSH),  2222, 'push without a pushurl: the same';

  $repo->config->set_string( 'remote.origin.pushurl', "ssh://git\@$HOST:2200/repo.git" );
  $remote = $repo->remote('origin');
  is $remote->_ssh_port(GIT_DIRECTION_FETCH), 2222, 'fetch still uses the URL';
  is $remote->_ssh_port(GIT_DIRECTION_PUSH),  2200, 'push connects to the pushurl, so its port counts';

  is $repo->remote_anonymous("git\@$HOST:owner/repo.git")->_ssh_port(GIT_DIRECTION_FETCH),
    22, 'an scp-like URL is port 22';
};

done_testing;
