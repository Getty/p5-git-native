# ABSTRACT: Native Git for Perl via libgit2 (FFI, no fork/exec)

package Git::Native;
our $VERSION = '0.001';
use Moo;
use Carp ();
use Git::Libgit2 qw( init_lib check_rc GIT_REPOSITORY_INIT_BARE );
use Git::Libgit2::FFI ();
use Git::Native::Repository ();

# Ensure libgit2 is initialised before first use.
my $_init_count = 0;
sub _ensure_init {
  return if $_init_count;
  $_init_count = init_lib();
}

sub open {
  my ( $class, $path ) = @_;
  Carp::croak "Git::Native->open requires a path" unless defined $path;
  _ensure_init();
  my $repo;
  check_rc Git::Libgit2::FFI::git_repository_open( \$repo, $path );
  return Git::Native::Repository->new( _handle => $repo );
}

sub open_ext {
  my ( $class, $start_path, %opts ) = @_;
  _ensure_init();
  my $repo;
  check_rc Git::Libgit2::FFI::git_repository_open_ext(
    \$repo, $start_path,
    $opts{flags} // 0,
    $opts{ceiling_dirs},
  );
  return Git::Native::Repository->new( _handle => $repo );
}

sub init {
  my ( $class, $path, %opts ) = @_;
  Carp::croak "Git::Native->init requires a path" unless defined $path;
  _ensure_init();
  my $repo;
  my $flags = $opts{bare} ? GIT_REPOSITORY_INIT_BARE : 0;
  check_rc Git::Libgit2::FFI::git_repository_init( \$repo, $path, $flags );
  return Git::Native::Repository->new( _handle => $repo );
}

1;

=head1 SYNOPSIS

  use Git::Native;

  my $repo = Git::Native->open('/path/to/.git');
  my $main = $repo->reference('refs/heads/main');
  say $main->target;     # commit OID

  # Build a commit without forking git
  my $blob_oid = $repo->blob_create_frombuffer("hello\n");
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

L<Git::Native> is a Moo wrapper around L<Git::Libgit2> (which binds
C<libgit2> via L<FFI::Platypus>). Use it instead of L<Git::Wrapper> or
L<Git::Repository> when you want to do Git work without forking the
C<git> binary on every operation.

Contrast:
- L<Git::Wrapper>, L<Git::Repository>: shell out to C<git>
- L<Git::Raw>: XS bindings, unmaintained since 2022, known segfaults
- L<Git::PurePerl>: pure-Perl read-only, no push/pull

=head1 METHODS

=head2 open($path)

Open an existing repository at C<$path>. Returns a L<Git::Native::Repository>.

=head2 open_ext($start_path, %opts)

Same as C<git_repository_open_ext> — walks up from C<$start_path>.
C<flags> and C<ceiling_dirs> are forwarded.

=head2 init($path, %opts)

Initialise a new repository. C<bare =E<gt> 1> creates a bare repo.

=head1 SEE ALSO

L<Alien::Libgit2>, L<Git::Libgit2>, L<FFI::Platypus>, L<libgit2|https://libgit2.org/>

=cut
