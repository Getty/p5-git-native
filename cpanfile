requires 'perl'              => '5.020';
requires 'Carp';
requires 'Git::Libgit2'      => '0.007';
requires 'Moo'               => '2.000000';
requires 'Path::Tiny';
requires 'Throwable::Error';
requires 'namespace::clean';

on test => sub {
  requires 'Alien::Libgit2';
  requires 'ExtUtils::CBuilder';
  requires 'Test2::V0';
};
