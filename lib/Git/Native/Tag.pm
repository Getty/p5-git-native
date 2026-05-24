# ABSTRACT: A libgit2 annotated tag

package Git::Native::Tag;
use Moo;
use Git::Libgit2 qw( check_rc );
use Git::Libgit2::FFI ();
use Git::Native::Oid ();

has _handle => ( is => 'ro', required => 1 );  # git_tag*
has _owner  => ( is => 'ro', required => 1 );

sub name    { Git::Libgit2::FFI::git_tag_name(    $_[0]->_handle ) }
sub message { Git::Libgit2::FFI::git_tag_message( $_[0]->_handle ) }

sub target_id {
  my $self = shift;
  my $oidp = Git::Libgit2::FFI::git_tag_target_id( $self->_handle );
  return Git::Native::Oid->from_ptr($oidp);
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_tag_free( $self->{_handle} ) if $self->{_handle};
}

1;

=head1 SYNOPSIS

  my $tag = $repo->tag('v1.0.0');
  say $tag->name;          # 'v1.0.0'
  say $tag->message;       # tagger message
  say $tag->target_id->hex;

=head1 DESCRIPTION

Wraps a libgit2 annotated tag object. Lightweight tags are plain refs
under C<refs/tags/*> and don't get a Tag wrapper - look them up with
L<Git::Native::Repository/reference> instead.

=cut
