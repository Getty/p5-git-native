# ABSTRACT: A libgit2 repository handle

package Git::Native::Repository;
our $VERSION = '0.001';
use Moo;
use Carp ();
use Git::Libgit2 qw( check_rc GIT_OBJECT_BLOB GIT_OBJECT_TREE GIT_OBJECT_COMMIT );
use Git::Libgit2::FFI ();
use FFI::Platypus::Buffer qw( scalar_to_buffer );
use Git::Native::Reference ();
use Git::Native::Blob ();
use Git::Native::Tree ();
use Git::Native::TreeBuilder ();
use Git::Native::Commit ();
use Git::Native::Signature ();
use Git::Native::Oid ();

has _handle => ( is => 'ro', required => 1 );

sub workdir { Git::Libgit2::FFI::git_repository_workdir( $_[0]->_handle ) }
sub gitdir  { Git::Libgit2::FFI::git_repository_path(    $_[0]->_handle ) }
sub is_bare { Git::Libgit2::FFI::git_repository_is_bare( $_[0]->_handle ) ? 1 : 0 }

# ---------- references ----------

sub reference {
  my ( $self, $name ) = @_;
  check_rc Git::Libgit2::FFI::git_reference_lookup( \my $ref, $self->_handle, $name );
  return Git::Native::Reference->new( _handle => $ref, _owner => $self );
}

sub reference_create {
  my ( $self, $name, $oid, %opts ) = @_;
  $oid = Git::Native::Oid->from_hex($oid) if !ref $oid;
  check_rc Git::Libgit2::FFI::git_reference_create(
    \my $ref, $self->_handle, $name, $oid->ptr,
    $opts{force} ? 1 : 0,
    $opts{message} // '',
  );
  return Git::Native::Reference->new( _handle => $ref, _owner => $self );
}

sub reference_delete {
  my ( $self, $name ) = @_;
  check_rc Git::Libgit2::FFI::git_reference_remove( $self->_handle, $name );
  return $self;
}

sub reference_exists {
  my ( $self, $name ) = @_;
  my $rc = Git::Libgit2::FFI::git_reference_lookup( \my $ref, $self->_handle, $name );
  if ( $rc == 0 ) {
    Git::Libgit2::FFI::git_reference_free($ref);
    return 1;
  }
  return 0;
}

# Returns list of full ref names. Optional `glob` filters libgit2-side.
sub reference_names {
  my ( $self, %opts ) = @_;
  my $iter;
  if ( $opts{glob} ) {
    check_rc Git::Libgit2::FFI::git_reference_iterator_glob_new(
      \$iter, $self->_handle, $opts{glob},
    );
  }
  else {
    check_rc Git::Libgit2::FFI::git_reference_iterator_new( \$iter, $self->_handle );
  }
  my @names;
  while (1) {
    my $rc = Git::Libgit2::FFI::git_reference_next_name( \my $name, $iter );
    last if $rc == -31;  # GIT_ITEROVER
    check_rc $rc;
    push @names, $name;
  }
  Git::Libgit2::FFI::git_reference_iterator_free($iter);
  return \@names;
}

# ---------- blobs / trees / commits ----------

sub blob_create_frombuffer {
  my ( $self, $content ) = @_;
  my $raw = "\0" x 20;
  my ($oid_p)     = scalar_to_buffer($raw);
  my ($content_p) = scalar_to_buffer($content);
  check_rc Git::Libgit2::FFI::git_blob_create_from_buffer(
    $oid_p, $self->_handle, $content_p, length($content),
  );
  return Git::Native::Oid->from_raw($raw);
}

sub blob {
  my ( $self, $oid ) = @_;
  $oid = Git::Native::Oid->from_hex($oid) if !ref $oid;
  check_rc Git::Libgit2::FFI::git_blob_lookup( \my $b, $self->_handle, $oid->ptr );
  return Git::Native::Blob->new( _handle => $b, _owner => $self );
}

sub tree {
  my ( $self, $oid ) = @_;
  $oid = Git::Native::Oid->from_hex($oid) if !ref $oid;
  check_rc Git::Libgit2::FFI::git_tree_lookup( \my $t, $self->_handle, $oid->ptr );
  return Git::Native::Tree->new( _handle => $t, _owner => $self );
}

sub tree_builder {
  my $self = shift;
  check_rc Git::Libgit2::FFI::git_treebuilder_new( \my $tb, $self->_handle, undef );
  return Git::Native::TreeBuilder->new( _handle => $tb, _owner => $self );
}

sub commit {
  my ( $self, $oid ) = @_;
  $oid = Git::Native::Oid->from_hex($oid) if !ref $oid;
  check_rc Git::Libgit2::FFI::git_commit_lookup( \my $c, $self->_handle, $oid->ptr );
  return Git::Native::Commit->new( _handle => $c, _owner => $self );
}

# commit_create(%args): tree => Oid|hex, parents => [Oid|hex, ...],
# message => str, update_ref => 'HEAD', author => Signature, committer => Signature
sub commit_create {
  my ( $self, %args ) = @_;

  my $tree_oid = $args{tree};
  $tree_oid = Git::Native::Oid->from_hex($tree_oid) if !ref $tree_oid;

  # commit_create takes git_tree*, so we need to look it up.
  check_rc Git::Libgit2::FFI::git_tree_lookup( \my $tree_h, $self->_handle, $tree_oid->ptr );

  my $sig_author    = $args{author}    // $self->signature_default;
  my $sig_committer = $args{committer} // $sig_author;

  # Parents: libgit2 wants an array of git_commit*. We pass undef for 0,
  # otherwise look up each parent into commits and pass an opaque[] array.
  # FFI::Platypus passes Perl arrays of opaque via 'opaque[]'.
  my @parent_oids = @{ $args{parents} // [] };
  my @parent_handles;
  for my $p (@parent_oids) {
    $p = Git::Native::Oid->from_hex($p) if !ref $p;
    check_rc Git::Libgit2::FFI::git_commit_lookup( \my $c, $self->_handle, $p->ptr );
    push @parent_handles, $c;
  }

  my $raw = "\0" x 20;
  my ($oid_p) = scalar_to_buffer($raw);

  # Build a parents-array pointer if non-empty.
  # FFI::Platypus 2: we declared parents as 'opaque' — accepting NULL or a pointer.
  # To pass an array we need a temporary buffer of pointers. For MVP, support 0..1 parent.
  if ( @parent_handles == 0 ) {
    check_rc Git::Libgit2::FFI::git_commit_create(
      $oid_p, $self->_handle, $args{update_ref},
      $sig_author->_handle, $sig_committer->_handle,
      $args{message_encoding} // 'UTF-8',
      $args{message},
      $tree_h,
      0, undef,
    );
  }
  else {
    # Pack pointer array. Each pointer is a 64-bit value on x86_64.
    my $parents_buf = pack 'J*', @parent_handles;
    my ($parents_p) = scalar_to_buffer($parents_buf);
    check_rc Git::Libgit2::FFI::git_commit_create(
      $oid_p, $self->_handle, $args{update_ref},
      $sig_author->_handle, $sig_committer->_handle,
      $args{message_encoding} // 'UTF-8',
      $args{message},
      $tree_h,
      scalar(@parent_handles), $parents_p,
    );
  }

  Git::Libgit2::FFI::git_commit_free($_) for @parent_handles;
  Git::Libgit2::FFI::git_tree_free($tree_h);

  return Git::Native::Oid->from_raw($raw);
}

sub signature_default {
  my $self = shift;
  my $rc = Git::Libgit2::FFI::git_signature_default( \my $sig, $self->_handle );
  if ( $rc == 0 ) {
    # We got an allocated git_signature*; wrap it without going through
    # Signature::_build_handle.
    my $obj = Git::Native::Signature->new(
      name  => '<from-config>',  # placeholder; we own the C handle
      email => '<from-config>',
    );
    $obj->{_handle} = $sig;
    return $obj;
  }
  # Fallback if no user.name/email configured.
  return Git::Native::Signature->new(
    name  => 'Git::Native',
    email => 'unconfigured@example.invalid',
  );
}

sub DEMOLISH {
  my $self = shift;
  Git::Libgit2::FFI::git_repository_free( $self->{_handle} )
    if $self->{_handle};
}

1;

=head1 SYNOPSIS

  my $repo = Git::Native->open('/path/to/.git');
  my $main = $repo->reference('refs/heads/main');
  say $main->target;

  my $blob_oid = $repo->blob_create_frombuffer("hi\n");
  my $tb       = $repo->tree_builder;
  $tb->insert(name => 'hi.txt', oid => $blob_oid, mode => 0100644);
  my $tree_oid = $tb->write;
  my $commit_oid = $repo->commit_create(
    update_ref => 'HEAD',
    tree       => $tree_oid,
    parents    => [$main->target],
    message    => 'add greeting',
  );

=head1 DESCRIPTION

The main entry point for working with a Git repository through
L<Git::Native>. Wraps C<git_repository*>; freed automatically.

=cut
