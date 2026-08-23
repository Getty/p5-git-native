# ABSTRACT: A libgit2 blob object

package Git::Native::Blob;
our $VERSION = '0.006';
use Moo;
use Git::Libgit2::FFI ();
use Git::Native::Oid ();

has _handle => ( is => 'ro', required => 1 );
has _owner  => ( is => 'ro', required => 1 );   # Repository - keeps repo alive

has oid => ( is => 'lazy' );
sub _build_oid {
  my $self = shift;
  Git::Native::Oid->from_ptr(
    Git::Libgit2::FFI::git_object_id( $self->_handle )
  );
}

sub size {
  my $self = shift;
  return Git::Libgit2::FFI::git_blob_rawsize( $self->_handle );
}

sub content {
  my $self = shift;
  my $ptr  = Git::Libgit2::FFI::git_blob_rawcontent( $self->_handle );
  my $size = $self->size;
  return '' unless $ptr && $size > 0;
  return Git::Libgit2::FFI::ffi()->cast( 'opaque', "string($size)", $ptr );
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_blob_free( $self->{_handle} ) if $self->{_handle};
}

1;

=synopsis

  my $blob = $repo->blob($oid);
  say $blob->size;
  say $blob->content;

=description

A libgit2 blob, exposing C<oid>, C<size>, C<content>. Freed when the
object goes out of scope. Obtained from
L<Git::Native::Repository/blob> or L<Git::Native::Repository/object>; the
blob keeps its repository alive for as long as it is itself in scope.

Blobs are created from a Perl scalar with
L<Git::Native::Repository/blob_create_frombuffer>, which returns the OID
rather than a Blob.

=attr oid

  say $blob->oid;   # full hex

The blob's L<Git::Native::Oid>. Computed on first use from the object
handle.

=method size

  say $blob->size;   # 6

Size of the blob content in bytes.

=method content

  my $bytes = $blob->content;

The raw blob content as a byte string, copied out of libgit2's buffer, so
it stays valid after the Blob goes away. Binary-safe: NUL bytes and
non-UTF-8 data survive unchanged, and nothing is decoded — a text file
comes back as bytes, not characters. An empty blob yields the empty
string.

=seealso

L<Git::Native::Repository>, L<Git::Native::Tree>, L<Git::Native::Oid>

=cut
