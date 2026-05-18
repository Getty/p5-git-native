# ABSTRACT: Exception class for Git::Native

package Git::Native::Error;
our $VERSION = '0.001';
use Moo;
extends 'Throwable::Error';

has code    => ( is => 'ro', required => 1 );
has klass   => ( is => 'ro', default  => 0 );

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  my %args = @args == 1 && ref $args[0] ? %{ $args[0] } : @args;
  $args{message} //= '<unknown libgit2 error>';
  return $class->$orig(\%args);
};

1;

=head1 SYNOPSIS

  use Git::Native::Error;
  Git::Native::Error->throw(
    code    => -3,
    klass   => 11,
    message => 'object not found',
  );

=head1 DESCRIPTION

Throwable exception used by L<Git::Native> when libgit2 reports an error.
Attributes mirror the C C<git_error> struct plus the return code.

=cut
