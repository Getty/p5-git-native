# ABSTRACT: Build a libgit2 tree object entry by entry

package Git::Native::TreeBuilder;
our $VERSION = '0.006';
use Moo;
use Git::Libgit2::FFI ();
use Git::Native::Error qw( check_rc );
use Git::Native::Oid ();
use FFI::Platypus::Buffer qw( scalar_to_buffer );

has _handle => ( is => 'ro', required => 1 );
has _owner  => ( is => 'ro', required => 1 );   # Repository

sub insert {
  my ( $self, %args ) = @_;
  my $oid = $args{oid};
  $oid = Git::Native::Oid->from_hex($oid) if !ref $oid;
  check_rc Git::Libgit2::FFI::git_treebuilder_insert(
    \my $entry,
    $self->_handle,
    $args{name},
    $oid->ptr,
    $args{mode} // 0100644,
  );
  return $self;
}

sub remove {
  my ( $self, $name ) = @_;
  check_rc Git::Libgit2::FFI::git_treebuilder_remove( $self->_handle, $name );
  return $self;
}

sub write {
  my $self = shift;
  my $raw  = "\0" x 20;
  my ($p)  = scalar_to_buffer($raw);
  check_rc Git::Libgit2::FFI::git_treebuilder_write( $p, $self->_handle );
  return Git::Native::Oid->from_raw($raw);
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_treebuilder_free( $self->{_handle} )
    if $self->{_handle};
}

1;

=synopsis

  my $tb = $repo->tree_builder;
  $tb->insert(name => 'hello.txt', oid => $blob_oid, mode => 0100644);
  my $tree_oid = $tb->write;

=description

In-memory tree assembler. C<insert>/C<remove> mutate the builder;
C<write> persists it as a tree object and returns its OID.

Get one from L<Git::Native::Repository/tree_builder>. It always starts
empty — to amend an existing tree, insert its entries yourself from
L<Git::Native::Tree/entries>. Nothing reaches the object database until
C<write>.

=method insert

  $tb->insert( name => 'hello.txt', oid => $blob_oid, mode => 0100644 );
  $tb->insert( name => 'lib',       oid => $tree_oid, mode => 040000  );

Add an entry, or replace the one already under that C<name>. C<oid> is a
L<Git::Native::Oid> or a 40-character hex string, C<name> is a single path
component (subdirectories are separate trees, inserted by their own OID),
and C<mode> is the numeric git filemode — C<0100644> regular (the
default), C<0100755> executable, C<0120000> symlink, C<040000> subtree.
Returns the builder, so calls chain.

=method remove

  $tb->remove('hello.txt');

Drop the entry with that name from the builder. Returns the builder.

=method write

  my $tree_oid = $tb->write;

Write the accumulated entries into the repository as a tree object and
return its L<Git::Native::Oid>. The builder stays usable afterwards; the
result is the input for L<Git::Native::Repository/commit_create>.

=seealso

L<Git::Native::Tree>, L<Git::Native::Repository>

=cut
