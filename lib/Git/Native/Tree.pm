# ABSTRACT: A libgit2 tree object

package Git::Native::Tree;
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

=synopsis

  my $tree = $commit->tree;
  for my $entry (@{ $tree->entries }) {
    say "$entry->{name} -> $entry->{oid}";
  }

=description

A libgit2 tree object. Entries are returned as plain hashrefs with
C<name>, C<oid>, C<mode>, C<type>.

A Tree is a single directory level, not a recursive listing: an entry of
type C<GIT_OBJECT_TREE> is a subdirectory you look up separately with
L<Git::Native::Repository/tree>.

A Tree taken from a L<Git::Native::Commit> holds its repository, so it
outlives the Commit it came from — walking C<< $repo->object($oid)->tree >>
in one expression is safe.

=attr oid

  say $tree->oid;

The tree's L<Git::Native::Oid>. Computed on first use.

=method entrycount

  say $tree->entrycount;

Number of entries in this tree level.

=method entries

  for my $e ( @{ $tree->entries } ) {
    printf "%06o %s %s\n", $e->{mode}, $e->{oid}, $e->{name};
  }

All entries, in libgit2's order, as an arrayref of plain hashrefs. Each
carries C<name> (this level only, no path), C<oid> (a
L<Git::Native::Oid>), C<mode> (the numeric git filemode — C<0100644> for a
regular file, C<0100755> executable, C<0120000> symlink, C<040000> a
subtree) and C<type> (the C<git_object_t> value: 1 commit, 2 tree, 3 blob,
4 tag — the C<GIT_OBJECT_*> constants exported by L<Git::Libgit2>).

=method entry_by_name

  my $e = $tree->entry_by_name('hello.txt');

The single entry hashref for C<$name>, in the same shape C<entries>
returns, or C<undef> when this tree has no such entry. C<$name> is one
path component, not a path: C<'lib/Foo.pm'> does not match.

=seealso

L<Git::Native::TreeBuilder>, L<Git::Native::Commit>, L<Git::Native::Blob>

=cut
