use Test2::V0;
use lib 't/lib';
use TestRepo;
use Git::Native;

# blob_create_frombuffer hands libgit2 the scalar's internal buffer. For a
# string with Perl's UTF-8 flag set that buffer holds the UTF-8 encoding,
# which is longer than length() counts characters - passing length() cut the
# blob off silently, with a valid oid coming back. A blob is bytes, so the
# method stores the string's character values as bytes (utf8::downgrade) and
# croaks on a character above 0xFF, which has no single-byte form.

my ( $repo, $tmp ) = TestRepo::new_repo();

subtest 'a UTF-8-flagged string with only Latin-1 characters is stored whole' => sub {
  my $s = "\x{fc}\x{fc}\x{fc}caf\x{e9}\n";
  utf8::upgrade($s);
  ok utf8::is_utf8($s), 'fixture carries the UTF-8 flag';

  my $oid  = $repo->blob_create_frombuffer($s);
  my $blob = $repo->blob($oid);
  is $blob->size, 8, 'one stored byte per character';
  is $blob->content, "\xfc\xfc\xfccaf\xe9\n", 'identical bytes read back';
  is $oid->hex, $repo->blob_create_frombuffer("\xfc\xfc\xfccaf\xe9\n")->hex,
    'same oid as the unflagged spelling of the same string';
};

subtest 'content assembled from decoded text keeps its tail' => sub {
  my $s = "plain " . do { my $d = "\x{e4}\x{f6}\x{fc}"; utf8::upgrade($d); $d } . " tail";
  my $blob = $repo->blob( $repo->blob_create_frombuffer($s) );
  is $blob->content, "plain \xe4\xf6\xfc tail", 'tail after the upgraded part is present';
};

subtest 'an encoded string round-trips byte for byte' => sub {
  my $bytes = "\xc3\xbc\xc3\xbc\xe2\x82\xac";
  my $blob = $repo->blob( $repo->blob_create_frombuffer($bytes) );
  is $blob->content, $bytes, 'caller-encoded UTF-8 is stored unchanged';
  is $blob->size, 7, 'size is the byte length';
};

subtest 'a wide character croaks instead of storing a truncated blob' => sub {
  my $wide = "\x{fc}\x{20ac}";
  my $err  = dies { $repo->blob_create_frombuffer($wide) };
  like $err, qr/blob_create_frombuffer/, 'names the method';
  like $err, qr/wide character|encode/i, 'says why';
  ok !ref $err, 'a plain croak, not a Git::Native::Error';
};

subtest 'the caller\'s scalar is left alone' => sub {
  my $s = "\xfc";
  utf8::upgrade($s);
  $repo->blob_create_frombuffer($s);
  ok utf8::is_utf8($s), 'flag untouched';
  is $s, "\xfc", 'value untouched';
};

done_testing;
