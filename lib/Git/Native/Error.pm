# ABSTRACT: Exception class for Git::Native

package Git::Native::Error;
use Moo;
use Exporter qw( import );
use Git::Libgit2::Error ();
extends 'Throwable::Error';

our @EXPORT_OK = qw( check_rc );

has code    => ( is => 'ro', required => 1 );
has klass   => ( is => 'ro', default  => 0 );

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  my %args = @args == 1 && ref $args[0] ? %{ $args[0] } : @args;
  $args{message} //= '<unknown libgit2 error>';
  return $class->$orig(\%args);
};

# check_rc($rc): pass non-negative rc straight through; on a negative rc,
# pull libgit2's thread-local error (a low-level Git::Libgit2::Error) and
# re-throw it as a Throwable Git::Native::Error so no raw libgit2 error
# object leaks above this layer. Every FFI int-return goes through here, so
# callers in Git::Native import check_rc from THIS module, not Git::Libgit2.
sub check_rc {
  my ($rc) = @_;
  return $rc if !defined $rc || $rc >= 0;
  my $low = Git::Libgit2::Error->last($rc);
  __PACKAGE__->throw(
    code    => $low->code,
    klass   => $low->klass,
    message => $low->message,
  );
}

1;

=synopsis

  use Git::Native::Error;
  Git::Native::Error->throw(
    code    => -3,
    klass   => 11,
    message => 'object not found',
  );

=description

Throwable exception used by L<Git::Native> when libgit2 reports an error.
Attributes mirror the C C<git_error> struct plus the return code.

=func check_rc

  use Git::Native::Error qw( check_rc );
  check_rc Git::Libgit2::FFI::some_call(...);

Pass-through for a non-negative return code; on a negative one it reads
libgit2's thread-local error (a low-level L<Git::Libgit2::Error>) and
re-throws it as a C<Git::Native::Error>. Every wrapper in the distribution
routes its FFI int-returns through this so no raw libgit2 error object
escapes the API.

=cut
