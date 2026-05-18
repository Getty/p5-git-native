# ABSTRACT: A libgit2 tree object

package Git::Native::Tree;
our $VERSION = '0.001';
use Moo;
use Git::Libgit2::FFI ();
use Git::Native::Oid ();

has _handle => ( is => 'ro', required => 1 );
has _owner  => ( is => 'ro', required => 1 );   # Repository

has oid => ( is => 'lazy' );
sub _build_oid {
  my $self = shift;
  Git::Native::Oid->from_ptr(
    Git::Libgit2::FFI::git_object_id( $self->_handle )
  );
}

sub entrycount {
  Git::Libgit2::FFI::git_tree_entrycount( $_[0]->_handle );
}

# Returns a hashref { name => ..., oid => Git::Native::Oid, mode => ..., type => ... }
sub entries {
  my $self = shift;
  my @out;
  my $n = $self->entrycount;
  for my $i ( 0 .. $n - 1 ) {
    my $te = Git::Libgit2::FFI::git_tree_entry_byindex( $self->_handle, $i );
    push @out, _entry_to_hash($te);
  }
  return \@out;
}

sub entry_by_name {
  my ( $self, $name ) = @_;
  my $te = Git::Libgit2::FFI::git_tree_entry_byname( $self->_handle, $name );
  return undef unless $te;
  return _entry_to_hash($te);
}

sub _entry_to_hash {
  my ($te) = @_;
  return {
    name => Git::Libgit2::FFI::git_tree_entry_name($te),
    oid  => Git::Native::Oid->from_ptr( Git::Libgit2::FFI::git_tree_entry_id($te) ),
    mode => Git::Libgit2::FFI::git_tree_entry_filemode($te),
    type => Git::Libgit2::FFI::git_tree_entry_type($te),
  };
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_tree_free( $self->{_handle} ) if $self->{_handle};
}

1;

=head1 SYNOPSIS

  my $tree = $commit->tree;
  for my $entry (@{ $tree->entries }) {
    say "$entry->{name} -> $entry->{oid}";
  }

=head1 DESCRIPTION

A libgit2 tree object. Entries are returned as plain hashrefs with
C<name>, C<oid>, C<mode>, C<type>.

=cut
