# ABSTRACT: A libgit2 configuration handle

package Git::Native::Config;
our $VERSION = '0.007';
use Moo;
use Git::Libgit2::FFI ();
use Git::Libgit2 qw( GIT_ENOTFOUND GIT_ERROR );
use Git::Native::Error qw( check_rc );

has _handle => ( is => 'ro', required => 1 );
has _owner  => ( is => 'ro' );   # Repository (when repo-derived) - keeps it alive

# get_string($key): the value, or undef when the key is unset. Only
# GIT_ENOTFOUND maps to undef; any other libgit2 failure throws via check_rc
# (matching get_bool) - we don't silently swallow real errors as "unset".
# libgit2 only guarantees git_config_get_string on a *snapshot* config;
# use Repository->config_snapshot / config_string for reads.
sub get_string {
  my ( $self, $key ) = @_;
  my $rc = Git::Libgit2::FFI::git_config_get_string( \my $out, $self->_handle, $key );
  return undef if $rc == GIT_ENOTFOUND;   # unset
  check_rc $rc;
  return $out;
}

# get_bool($key): 1 / 0 for a git-style boolean, or undef when the key is
# unset. libgit2 does the parsing via git_config_get_bool (true/yes/on/1,
# false/no/off/0, integers by non-zero) - we don't reimplement git's bool
# rules in Perl. A present-but-non-boolean value (e.g. "banana") makes
# libgit2 return an error, which check_rc turns into a Git::Native::Error;
# only GIT_ENOTFOUND maps to undef.
sub get_bool {
  my ( $self, $key ) = @_;
  my $rc = Git::Libgit2::FFI::git_config_get_bool( \my $out, $self->_handle, $key );
  return undef if $rc == GIT_ENOTFOUND;   # unset
  check_rc $rc;                           # other negatives (e.g. non-boolean) throw
  return $out ? 1 : 0;
}

# set_string($key, $value): only valid on a live (non-snapshot) config.
sub set_string {
  my ( $self, $key, $value ) = @_;
  check_rc Git::Libgit2::FFI::git_config_set_string( $self->_handle, $key, $value );
  return $self;
}

# git_config_delete_entry is not among the functions Git::Libgit2::FFI
# attaches; it is only needed here, so it is looked up on first use.
my $delete_entry_fn;

# delete($key): remove the entry from the level libgit2 writes to (the
# repository's own config file) and return 1. GIT_ENOTFOUND also returns 1 -
# not set at that level is "already gone", like reference_delete. Everything
# else throws via check_rc: a multivar (-1; delete_all is the unset-all), an
# invalid name (GIT_EINVALIDSPEC), a snapshot (GIT_EREADONLY).
sub delete {
  my ( $self, $key ) = @_;
  $delete_entry_fn //= Git::Libgit2::FFI::ffi()->function(
    git_config_delete_entry => [ 'git_config', 'string' ] => 'int',
  );
  # Refresh first. libgit2 caches the live git_config* in the repository, and
  # git_config_delete_entry looks the key up in the cached entries without
  # re-reading the file - after a write by another process it answers
  # GIT_ENOTFOUND with the key still on disk, which the idempotent return
  # below would report as success (measured, libgit2 1.9.3; t/82 subtests
  # 9-11). 1.9.3 has no public git_config_refresh; taking a snapshot re-reads
  # the changed files into the live config as a side effect, so take one and
  # drop it.
  check_rc Git::Libgit2::FFI::git_config_snapshot( \my $refreshed, $self->_handle );
  Git::Libgit2::FFI::git_config_free($refreshed);
  # On a read-only config (a snapshot) git_config_delete_entry returns
  # GIT_EREADONLY without setting an error (libgit2 1.9.3 config.c), so
  # check_rc would attach whatever the refresh above or an earlier call left
  # behind - measured: a stat failure on the global .gitconfig (k37). Clear
  # first, so the error state check_rc reads belongs to this call.
  Git::Libgit2::FFI::git_error_clear();
  my $rc = $delete_entry_fn->call( $self->_handle, $key );
  return 1 if $rc == GIT_ENOTFOUND;   # not set at the writable level
  check_rc $rc;
  return 1;
}

# The functions delete_all needs are not attached by Git::Libgit2::FFI either;
# looked up once, on first use.
my %fn;
sub _fn {
  my ( $name, $args, $ret ) = @_;
  return $fn{$name} //= Git::Libgit2::FFI::ffi()->function( $name => $args => $ret );
}

# delete_all($key): remove every value of a multivar at the repository's own
# config level and return 1; 1 as well when nothing is set there.
#
# git_config_delete_multivar (and git_config_set_multivar) SEGFAULT the whole
# process as soon as the level holds a valueless entry for the key (`[karr]` +
# `readonly`, no `=`): the value regexp is matched against a NULL value. Any
# regexp does it, also one that cannot match the valueless entry (measured,
# libgit2 1.9.3), so the entries are walked first with a multivar iterator,
# which hands the NULL back as a plain NULL pointer. A lone valueless entry is
# an ordinary delete_entry. A valueless entry next to others cannot be removed
# without the crash, so that case is refused with a Git::Native::Error and the
# file is left alone (k38).
sub delete_all {
  my ( $self, $key ) = @_;
  # Same refresh as delete: libgit2's cached config does not see writes by
  # another process, which would make a stale "not found" look like success.
  check_rc Git::Libgit2::FFI::git_config_snapshot( \my $refreshed, $self->_handle );
  Git::Libgit2::FFI::git_config_free($refreshed);

  # Walk the repository level only: that is the one delete_multivar works on,
  # so a valueless entry in the global config is none of its business.
  my ( $total, $valueless ) = ( 0, 0 );
  my $rc = _fn( git_config_open_level => [ 'opaque*', 'git_config', 'int' ] => 'int' )
    ->call( \my $local, $self->_handle, 5 );   # GIT_CONFIG_LEVEL_LOCAL
  if ( $rc != GIT_ENOTFOUND ) {
    check_rc $rc;
    my $new_rc = _fn( git_config_multivar_iterator_new =>
        [ 'opaque*', 'git_config', 'string', 'string' ] => 'int' )
      ->call( \my $iter, $local, $key, undef );
    if ( $new_rc == 0 ) {
      my $next = _fn( git_config_next => [ 'opaque*', 'opaque' ] => 'int' );
      my $ffi  = Git::Libgit2::FFI::ffi();
      while ( ( $rc = $next->call( \my $entry, $iter ) ) == 0 ) {
        $total++;
        # git_config_entry starts with name, value; value is NULL for a
        # valueless entry.
        $valueless++ unless $ffi->cast( 'opaque', 'opaque[2]', $entry )->[1];
      }
      _fn( git_config_iterator_free => ['opaque'] => 'void' )->call($iter);
    }
    Git::Libgit2::FFI::git_config_free($local);
    # not found = nothing at this level; GIT_ITEROVER (-31) ends the walk.
    check_rc $new_rc unless $new_rc == 0 || $new_rc == GIT_ENOTFOUND;
    check_rc $rc if $total && $rc != -31;
  }

  if ($valueless) {
    if ( $total == 1 ) {
      return $self->delete($key);
    }
    Git::Native::Error->throw(
      code    => GIT_ERROR,
      klass   => 7,   # GIT_ERROR_CONFIG
      message => "cannot delete all values of '$key': it has a valueless entry "
        . "next to other values and libgit2 crashes on that",
    );
  }
  my $drc = _fn( git_config_delete_multivar => [ 'git_config', 'string', 'string' ] => 'int' )
    ->call( $self->_handle, $key, '.*' );
  return 1 if $drc == GIT_ENOTFOUND;
  check_rc $drc;
  return 1;
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

  $cfg->delete('user.name');                # 1, also when already unset

  my $snap = $repo->config_snapshot;
  say $snap->get_string('user.email');

=description

A libgit2 configuration handle. Wraps C<git_config*>; freed
automatically when the object goes out of scope.

Reads go through C<get_string>, which libgit2 only supports reliably on a
B<snapshot> config — get one via L<Git::Native::Repository/config_snapshot>
or the L<Git::Native::Repository/config_string> convenience. Writes
(C<set_string>, C<delete>) require a live config from
L<Git::Native::Repository/config>.

A repository config sees the merged view git itself would use: the
repository's own C<config> file plus the global and system levels.

=method get_string

  my $name = $repo->config_snapshot->get_string('user.name');

The value of C<$key>, or C<undef> when the key is not set anywhere in the
config. Only "not found" becomes C<undef> — any other libgit2 failure
throws a L<Git::Native::Error>, so an unreadable config is never silently
reported as unset.

Call it on a snapshot. On a live config libgit2 refuses the read and this
throws; L<Git::Native::Repository/config_string> takes a snapshot for you.

=method get_bool

  if ( $repo->config_snapshot->get_bool('core.bare') ) { ... }

1 or 0 for a git-style boolean, or C<undef> when the key is not set —
which is why the test is C<defined>, not truth, when "unset" and "false"
have to be told apart. libgit2 does the parsing (C<true>/C<yes>/C<on>/1,
C<false>/C<no>/C<off>/0, integers by non-zero), so git's own rules apply.
A key set to something that is not a boolean at all throws a
L<Git::Native::Error> rather than coming back C<undef>.

=method set_string

  $repo->config->set_string('user.name', 'Ada');

Write C<$value> under C<$key> and return the config. Needs a live config —
a snapshot is read-only and throws. The write lands in the highest-priority
writable level, i.e. the repository's own config file.

=method delete

  $repo->config->delete('user.name');

Remove C<$key> and return 1. Like L</set_string> it needs a live config and
works on the highest-priority writable level, the repository's own config
file; the global and system levels are never touched. A key that is not set
at that level returns 1 as well, so deleting twice is harmless. That
includes a key set only in the global config, which the merged view keeps
answering afterwards, and a key set at both levels, whose global value
shows through again once the local one is gone.

A key with several values (a multivar) throws a L<Git::Native::Error> and
keeps every value; L</delete_all> removes those. A name git does not accept
throws as well (C<is_invalid_spec>), and so does a snapshot, with
C<GIT_EREADONLY>, even for a key that is not set. C<delete> sees writes made
by other processes since the config was opened, such as C<git config> in a
shell or a hand edit of the file.

=method delete_all

  $repo->config->delete_all('remote.origin.fetch');

Remove every value of a key that has several (a multivar) and return 1; it
removes a single-valued key too. Same scope as L</delete>: the repository's own
config file only, 1 for a key not set there, a snapshot throws
C<GIT_EREADONLY>, an invalid name throws (C<is_invalid_spec>), and writes made
by other processes since the config was opened are seen.

A valueless entry (C<[karr]> then C<readonly>, no C<=>) is the hazard: libgit2
1.9's C<git_config_delete_multivar> crashes the whole process when the level
holds one. C<delete_all> walks the values first and never calls it then. A
key whose only entry is valueless is deleted normally. A valueless entry
B<next to other values> cannot be removed safely, so that call throws a
L<Git::Native::Error> (code C<GIT_ERROR>) and leaves the file untouched; remove
the entries one at a time by hand in that case.

=method snapshot

  my $snap = $repo->config->snapshot;

A frozen, read-only copy of the config as it stands right now, returned as
a fresh Config. Later writes through the live config are not visible in it;
take a new snapshot to see them.

=seealso

L<Git::Native::Repository>

=cut
