# ABSTRACT: A libgit2 branch (thin wrapper over git_reference)

package Git::Native::Branch;
use Moo;
use Git::Libgit2 qw( check_rc );
use Git::Libgit2::FFI ();
use Git::Native::Oid ();

use constant {
  GIT_BRANCH_LOCAL  => 1,
  GIT_BRANCH_REMOTE => 2,
  GIT_BRANCH_ALL    => 3,
};

has _handle => ( is => 'ro', required => 1 );  # git_reference*
has _owner  => ( is => 'ro', required => 1 );
has type    => ( is => 'ro', default  => sub { GIT_BRANCH_LOCAL } );

sub name {
  my $self = shift;
  check_rc Git::Libgit2::FFI::git_branch_name( \my $n, $self->_handle );
  return $n;
}

sub refname { Git::Libgit2::FFI::git_reference_name( $_[0]->_handle ) }

sub target {
  my $self = shift;
  my $oidp = Git::Libgit2::FFI::git_reference_target( $self->_handle );
  return undef unless $oidp;
  return Git::Native::Oid->from_ptr($oidp);
}

sub is_head { Git::Libgit2::FFI::git_branch_is_head( $_[0]->_handle ) ? 1 : 0 }
sub is_local  { $_[0]->type == GIT_BRANCH_LOCAL  ? 1 : 0 }
sub is_remote { $_[0]->type == GIT_BRANCH_REMOTE ? 1 : 0 }

sub delete {
  my $self = shift;
  check_rc Git::Libgit2::FFI::git_branch_delete( $self->_handle );
  return $self;
}

sub rename {
  my ( $self, $new_name, %opts ) = @_;
  check_rc Git::Libgit2::FFI::git_branch_move(
    \my $new_ref, $self->_handle, $new_name, $opts{force} ? 1 : 0,
  );
  return ref($self)->new( _handle => $new_ref, _owner => $self->_owner, type => $self->type );
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_reference_free( $self->{_handle} ) if $self->{_handle};
}

1;

=synopsis

  my $b = $repo->branch('main');
  say $b->name;          # 'main'
  say $b->refname;       # 'refs/heads/main'
  say $b->target->hex;   # commit OID
  $b->rename('trunk');

=description

Wraps a libgit2 branch (which is really a C<git_reference> under
C<refs/heads/*> or C<refs/remotes/*>). Constructed by
L<Git::Native::Repository/branch> and L<Git::Native::Repository/branches>.

=cut
