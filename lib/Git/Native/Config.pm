# ABSTRACT: A libgit2 configuration handle

package Git::Native::Config;
use Moo;
use Carp ();
use Git::Libgit2::FFI ();
use Git::Native::Error qw( check_rc );

has _handle => ( is => 'ro', required => 1 );
has _owner  => ( is => 'ro' );   # Repository (when repo-derived) - keeps it alive

# get_string($key): the value, or undef when the key is unset.
# libgit2 only guarantees git_config_get_string on a *snapshot* config;
# use Repository->config_snapshot / config_string for reads.
sub get_string {
  my ( $self, $key ) = @_;
  my $rc = Git::Libgit2::FFI::git_config_get_string( \my $out, $self->_handle, $key );
  return undef if $rc < 0;   # GIT_ENOTFOUND etc. - treat as "unset"
  return $out;
}

# get_bool($key): 1 / 0 for a git-style boolean, or undef when the key is
# unset. libgit2's git_config_get_bool isn't bound in Git::Libgit2, so we
# parse the string value here using git's own bool rules:
#   true   = "true" / "yes" / "on" / a present-but-empty value
#   false  = "false" / "no" / "off"
#   else   = parse as an integer; non-zero is true, zero is false
# (all case-insensitive). A non-bool, non-integer value croaks, matching
# how git itself rejects e.g. `--bool` on "banana".
sub get_bool {
  my ( $self, $key ) = @_;
  my $val = $self->get_string($key);
  return undef unless defined $val;
  $val =~ s/\A\s+//;
  $val =~ s/\s+\z//;
  return 1 if $val eq '';
  my $lc = lc $val;
  return 1 if $lc eq 'true'  || $lc eq 'yes' || $lc eq 'on';
  return 0 if $lc eq 'false' || $lc eq 'no'  || $lc eq 'off';
  if ( $val =~ /\A[+-]?[0-9]+\z/ ) {
    return $val != 0 ? 1 : 0;
  }
  Carp::croak "get_bool: '$key' value '$val' is not a valid boolean";
}

# set_string($key, $value): only valid on a live (non-snapshot) config.
sub set_string {
  my ( $self, $key, $value ) = @_;
  check_rc Git::Libgit2::FFI::git_config_set_string( $self->_handle, $key, $value );
  return $self;
}

# snapshot(): a read-only point-in-time copy. Returns a fresh Config.
sub snapshot {
  my $self = shift;
  check_rc Git::Libgit2::FFI::git_config_snapshot( \my $snap, $self->_handle );
  return Git::Native::Config->new( _handle => $snap, _owner => $self->_owner );
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_config_free( $self->{_handle} ) if $self->{_handle};
}

1;

=synopsis

  my $cfg = $repo->config;                  # live, writable
  $cfg->set_string('user.name', 'Ada');

  say $repo->config_string('user.name');    # 'Ada' (fresh snapshot read)

  my $snap = $repo->config_snapshot;
  say $snap->get_string('user.email');

=description

A libgit2 configuration handle. Wraps C<git_config*>; freed
automatically when the object goes out of scope.

Reads go through C<get_string>, which libgit2 only supports reliably on a
B<snapshot> config — get one via L<Git::Native::Repository/config_snapshot>
or the L<Git::Native::Repository/config_string> convenience. Writes
(C<set_string>) require a live config from L<Git::Native::Repository/config>.

=cut
