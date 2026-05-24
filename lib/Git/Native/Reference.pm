# ABSTRACT: A Git reference (branch, tag, HEAD)

package Git::Native::Reference;
use Moo;
use Git::Libgit2 qw( check_rc );
use Git::Libgit2::FFI ();
use Git::Native::Oid ();

has _handle => ( is => 'ro', required => 1 );
has _owner  => ( is => 'ro', required => 1 );   # Repository

sub name {
  Git::Libgit2::FFI::git_reference_name( $_[0]->_handle );
}

sub target {
  my $self = shift;
  my $p    = Git::Libgit2::FFI::git_reference_target( $self->_handle );
  return undef unless $p;
  return Git::Native::Oid->from_ptr($p);
}

sub is_symbolic {
  Git::Libgit2::FFI::git_reference_type( $_[0]->_handle ) == 2 ? 1 : 0;
}

sub delete {
  my $self = shift;
  check_rc Git::Libgit2::FFI::git_reference_delete( $self->_handle );
  return $self;
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_reference_free( $self->{_handle} )
    if $self->{_handle};
}

1;

=synopsis

  my $ref = $repo->reference('refs/heads/main');
  say $ref->name;
  say $ref->target;     # OID
  $ref->delete;

=description

A Git reference. Direct refs return an C<oid> target; symbolic refs
need C<peel> (TODO) to resolve.

=cut
