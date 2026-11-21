requires 'perl'              => '5.020';
requires 'Carp';
requires 'Digest::SHA';
requires 'Exporter';
requires 'FFI::Platypus'     => '2.00';
requires 'Git::Libgit2'      => '0.008';
requires 'MIME::Base64';
requires 'Moo'               => '2.000000';
requires 'Scalar::Util';
requires 'Throwable::Error';
requires 'namespace::clean';

on test => sub {
  requires 'Alien::Libgit2' => '0.003';
  requires 'ExtUtils::CBuilder';
  requires 'File::Find';
  requires 'File::Temp';
  requires 'FindBin';
  requires 'Path::Tiny';
  requires 'Test2::V0';
  requires 'Test::More';
};
