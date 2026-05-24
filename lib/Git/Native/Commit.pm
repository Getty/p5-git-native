# ABSTRACT: A libgit2 commit object

package Git::Native::Commit;
use Moo;
use Git::Libgit2 qw( check_rc );
use Git::Libgit2::FFI ();
use Git::Native::Oid ();
use Git::Native::Tree ();

has _handle => ( is => 'ro', required => 1 );
has _owner  => ( is => 'ro', required => 1 );   # Repository

has oid => ( is => 'lazy' );
sub _build_oid {
  Git::Native::Oid->from_ptr(
    Git::Libgit2::FFI::git_object_id( $_[0]->_handle )
  );
}

sub message {
  Git::Libgit2::FFI::git_commit_message( $_[0]->_handle );
}

sub tree {
  my $self = shift;
  check_rc Git::Libgit2::FFI::git_commit_tree( \my $t, $self->_handle );
  return Git::Native::Tree->new( _handle => $t, _owner => $self->_owner );
}

sub tree_oid {
  Git::Native::Oid->from_ptr(
    Git::Libgit2::FFI::git_commit_tree_id( $_[0]->_handle )
  );
}

sub parent_count {
  Git::Libgit2::FFI::git_commit_parentcount( $_[0]->_handle );
}

sub parent_oids {
  my $self = shift;
  my @out;
  my $n = $self->parent_count;
  for my $i ( 0 .. $n - 1 ) {
    push @out, Git::Native::Oid->from_ptr(
      Git::Libgit2::FFI::git_commit_parent_id( $self->_handle, $i )
    );
  }
  return \@out;
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_commit_free( $self->{_handle} ) if $self->{_handle};
}

1;

=head1 SYNOPSIS

  my $commit = $repo->commit($oid);
  say $commit->message;
  say $commit->tree_oid;

=head1 DESCRIPTION

A libgit2 commit object exposing C<oid>, C<message>, C<tree>, C<tree_oid>,
C<parent_count>, C<parent_oids>.

=cut
