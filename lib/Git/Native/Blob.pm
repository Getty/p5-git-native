# ABSTRACT: A libgit2 blob object

package Git::Native::Blob;
our $VERSION = '0.001';
use Moo;
use FFI::Platypus 2.00;
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
  my $ffi = FFI::Platypus->new( api => 2 );
  return $ffi->cast( 'opaque', "string($size)", $ptr );
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_blob_free( $self->{_handle} ) if $self->{_handle};
}

1;

=head1 SYNOPSIS

  my $blob = $repo->blob($oid);
  say $blob->size;
  say $blob->content;

=head1 DESCRIPTION

A libgit2 blob, exposing C<oid>, C<size>, C<content>. Freed when the
object goes out of scope.

=cut
