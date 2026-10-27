use Test2::V0;
use lib 't/lib';
use TestRepo;
use File::Temp qw( tempfile );
use Git::Native;
use Git::Native::Oid;

# Oid->from_buffer hashes a Perl buffer as a git object of a given type without
# a repository and without writing anything (git_odb_hash). git hash-object
# is the reference: same bytes, same type, same oid.

sub git_hash {
  my ( $type, $bytes ) = @_;
  my ( $fh, $file ) = tempfile( UNLINK => 1 );
  binmode $fh;
  print {$fh} $bytes;
  close $fh;
  # --literally: tree and commit buffers here are not well-formed objects.
  my $out = qx{git hash-object --literally -t $type $file};
  chomp $out;
  return $out;
}

subtest 'blob matches git hash-object' => sub {
  is(
    Git::Native::Oid->from_buffer( '', 'blob' )->hex,
    'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391',
    'the empty blob is git\'s well-known empty-blob oid'
  );
  for my $bytes ( "hello\n", 'no newline', "line1\nline2\n", 'x' x 100_000 ) {
    my $oid = Git::Native::Oid->from_buffer( $bytes, 'blob' );
    isa_ok $oid, ['Git::Native::Oid'], 'an Oid comes back';
    is $oid->hex, git_hash( blob => $bytes ),
      'blob of ' . length($bytes) . ' bytes';
  }
};

subtest 'binary bytes including NUL and high bytes' => sub {
  my $bytes = join '', map { chr } 0 .. 255;
  is(
    Git::Native::Oid->from_buffer( $bytes, 'blob' )->hex,
    git_hash( blob => $bytes ),
    'all 256 byte values hash whole, NUL does not end the buffer'
  );
  my $nul = "abc\0def\0";
  isnt(
    Git::Native::Oid->from_buffer( $nul, 'blob' )->hex,
    Git::Native::Oid->from_buffer( 'abc', 'blob' )->hex,
    'bytes after a NUL count'
  );
};

subtest 'tree, commit and tag buffers' => sub {
  my $blob = Git::Native::Oid->from_buffer( "hello\n", 'blob' );
  my $tree = "100644 hello.txt\0" . $blob->raw;
  my $tree_oid = Git::Native::Oid->from_buffer( $tree, 'tree' );
  is $tree_oid->hex, git_hash( tree => $tree ), 'tree buffer';

  my $commit = "tree $tree_oid\n"
    . "author A <a\@example.com> 1700000000 +0000\n"
    . "committer A <a\@example.com> 1700000000 +0000\n\nmsg\n";
  my $commit_oid = Git::Native::Oid->from_buffer( $commit, 'commit' );
  is $commit_oid->hex, git_hash( commit => $commit ), 'commit buffer';

  my $tag = "object $commit_oid\ntype commit\ntag v1\n"
    . "tagger A <a\@example.com> 1700000000 +0000\n\nrelease\n";
  is(
    Git::Native::Oid->from_buffer( $tag, 'tag' )->hex,
    git_hash( tag => $tag ),
    'tag buffer'
  );

  isnt(
    Git::Native::Oid->from_buffer( $tree, 'blob' )->hex, $tree_oid->hex,
    'the type is part of the hash'
  );
};

subtest 'agrees with a repository and writes nothing' => sub {
  my ( $repo, $tmp ) = TestRepo::new_repo();
  my $stored = $repo->blob_create_frombuffer("stored\n");
  is(
    Git::Native::Oid->from_buffer( "stored\n", 'blob' )->hex,
    $stored->hex,
    'same oid as blob_create_frombuffer'
  );
  my $before = qx{git -C $tmp count-objects};
  Git::Native::Oid->from_buffer( "never stored\n", 'blob' );
  is qx{git -C $tmp count-objects}, $before, 'the object database is untouched';
};

subtest 'a character string is bytes when it fits' => sub {
  my $latin = "caf\xe9";
  utf8::upgrade($latin);
  is(
    Git::Native::Oid->from_buffer( $latin, 'blob' )->hex,
    git_hash( blob => "caf\xe9" ),
    'an upgraded string hashes as one byte per character'
  );
  is $latin, "caf\xe9", 'the caller\'s string is unchanged';
};

subtest 'bad input croaks' => sub {
  like dies { Git::Native::Oid->from_buffer( "\x{263a}", 'blob' ) },
    qr/from_buffer.*wide character/i, 'a character above 0xFF croaks';
  like dies { Git::Native::Oid->from_buffer( 'x', 'bogus' ) },
    qr/from_buffer.*unknown object type 'bogus'.*blob, commit, tag, tree/,
    'an unknown type croaks and names the valid ones';
  like dies { Git::Native::Oid->from_buffer( 'x', 'any' ) },
    qr/unknown object type/, 'any is no concrete type';
  like dies { Git::Native::Oid->from_buffer( 'x', 'BLOB' ) },
    qr/unknown object type/, 'type names are lower case';
  like dies { Git::Native::Oid->from_buffer( 'x' ) },
    qr/from_buffer requires an object type/, 'the type is required';
  like dies { Git::Native::Oid->from_buffer( undef, 'blob' ) },
    qr/from_buffer requires a buffer/, 'undef buffer croaks';
  like dies { Git::Native::Oid->from_buffer( [], 'blob' ) },
    qr/from_buffer requires a buffer/, 'a reference is no buffer';
  my $line = __LINE__ + 1;
  my $err = dies { Git::Native::Oid->from_buffer( 'x', 'bogus' ) };
  like $err, qr/at \S+ line $line/, 'the croak blames the caller';
};

done_testing;
