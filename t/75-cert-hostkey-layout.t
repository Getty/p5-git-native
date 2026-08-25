use strict;
use warnings;
use Test2::V0;
use FindBin;
use lib "$FindBin::Bin/lib";
use TestRepo;
use Git::Native::Remote ();
use Git::Libgit2 ();
use Alien::Libgit2;
use ExtUtils::CBuilder;
use Path::Tiny;

# Git::Native::Remote hardcodes the git_cert_hostkey field offsets it reads in
# the SSH host-key check (_verify_known_host): the git_cert_ssh_t bitmask, and
# the two fingerprint buffers it compares against known_hosts. Nothing in a
# normal test run touches them - the only caller is the certificate_check
# closure, which libgit2 invokes from inside a live SSH handshake, so the
# coverage lives in t/40-remote-ssh.t and skips without TEST_GIT_NATIVE_SSH_URL.
#
# That is the same shape as the git_fetch_options.prune bug fixed in 0.006: a
# constant probed once against libgit2 1.5, still compiled in, silently reading
# the wrong bytes the day the struct moves. prune at least had t/20 and t/49
# watching it. These three had nothing, and a reordered struct would not throw
# - it would compare a fingerprint against whatever landed at offset 24 and
# reject every host, or worse, accept on a coincidence.
#
# So measure them. libgit2 ships no git_cert_hostkey_init, so the marker-scan
# trick behind Git::Libgit2::fetch_options_prune_offset does not apply here and
# there is no allocator to hand us a real struct. What is available is the
# header Alien::Libgit2 installs alongside the library it built: offsetof() on
# the actual declaration, which is the definition of the answer rather than an
# inference from one. Compiling it needs a C compiler; it does NOT need to link
# libgit2, because offsetof and the enum values are resolved entirely at
# compile time - so this test cannot be broken by a runtime linker path.
#
# Its blind spot is a header that does not describe the loaded library, so the
# probe reports LIBGIT2_VERSION and the file skips rather than asserts when it
# disagrees with git_libgit2_version().

my $c_source = <<'END_C';
#include <stddef.h>
#include <stdio.h>
#include <git2.h>

int main(void) {
  printf("header_version %s\n",           LIBGIT2_VERSION);
  printf("sizeof_cert_hostkey %lu\n",     (unsigned long) sizeof(git_cert_hostkey));
  printf("cert_type %lu\n",               (unsigned long) offsetof(git_cert, cert_type));
  printf("type %lu\n",                    (unsigned long) offsetof(git_cert_hostkey, type));
  printf("hash_sha1 %lu\n",               (unsigned long) offsetof(git_cert_hostkey, hash_sha1));
  printf("hash_sha256 %lu\n",             (unsigned long) offsetof(git_cert_hostkey, hash_sha256));
  printf("GIT_CERT_X509 %d\n",            (int) GIT_CERT_X509);
  printf("GIT_CERT_HOSTKEY_LIBSSH2 %d\n", (int) GIT_CERT_HOSTKEY_LIBSSH2);
  printf("GIT_CERT_SSH_SHA1 %d\n",        (int) GIT_CERT_SSH_SHA1);
  printf("GIT_CERT_SSH_SHA256 %d\n",      (int) GIT_CERT_SSH_SHA256);
  return 0;
}
END_C

my $builder = ExtUtils::CBuilder->new( quiet => 1 );

my $tmp = Path::Tiny->tempdir('git-native-cert-probe-XXXXXXXX');
my $src = $tmp->child('cert_hostkey_probe.c');
$src->spew($c_source);

# ExtUtils::CBuilder writes the compiler's own diagnostics to STDERR, and the
# compiler is a child process, so an in-memory handle would not catch them -
# take fd 2 over with a real file and fold whatever lands there into the skip
# reason. A missing git2.h is the expected failure and must say so.
my $cc_log = $tmp->child('cc.log');

sub one_line {
  my ($text) = @_;
  return '' unless defined $text && length $text;
  $text =~ s/\s+/ /g;
  $text =~ s/\A\s|\s\z//g;
  return $text;
}

sub run_capturing {
  my ($code) = @_;
  open my $save_err, '>&', \*STDERR or die 'cannot dup STDERR: '.$!;
  open STDERR, '>', "$cc_log"       or die 'cannot redirect STDERR: '.$!;
  my $out = eval { $code->() };
  my $err = $@;
  open STDERR, '>&', $save_err      or die 'cannot restore STDERR: '.$!;
  close $save_err;
  my $log = $cc_log->exists ? $cc_log->slurp : '';
  $cc_log->remove if $cc_log->exists;
  # A skip reason is a single TAP line, and a compiler diagnostic is not - the
  # rest of it would spill out after the plan as junk.
  return ( $out, one_line($err), one_line($log) );
}

my @cflags = split ' ', Alien::Libgit2->cflags;

my ( $obj, $compile_err, $compile_log ) = run_capturing(sub {
  $builder->compile(
    source               => "$src",
    extra_compiler_flags => \@cflags,
  );
});
skip_all 'cannot compile the offsetof probe - no C compiler on this machine, '
       . 'or git2.h is not reachable from Alien::Libgit2->cflags ("'
       . join( ' ', @cflags ) . '"): '
       . join( ' ', grep { length } $compile_err, $compile_log )
  unless $obj;

my $exe = $tmp->child('cert_hostkey_probe')->stringify;
my ( $linked, $link_err, $link_log ) = run_capturing(sub {
  $builder->link_executable( objects => [$obj], exe_file => $exe );
});
skip_all 'cannot link the offsetof probe: '
       . join( ' ', grep { length } $link_err, $link_log )
  unless $linked && -x $linked;

open my $probe_fh, '-|', $linked
  or skip_all 'cannot run the offsetof probe: '.$!;
my %probe = map { chomp; split ' ', $_, 2 } <$probe_fh>;
close $probe_fh;
skip_all 'the offsetof probe produced no usable output'
  unless defined $probe{sizeof_cert_hostkey};

note 'probe: '.join( ', ', map { $_.'='.$probe{$_} } sort keys %probe );

# The header only speaks for the library it was installed with. If the loaded
# libgit2 is a different one, these offsets describe someone else's struct and
# asserting them would be worse than not asserting at all.
my $runtime_version = scalar Git::Libgit2::version();
my ($header_version) = ( $probe{header_version} // '' ) =~ /([0-9]+\.[0-9]+\.[0-9]+)/;
skip_all 'git2.h says libgit2 '.( $header_version // $probe{header_version} // '?' )
       . ' but the loaded library reports '.$runtime_version
       . ' - the header does not describe the struct Remote.pm actually reads'
  unless defined $header_version && $header_version eq $runtime_version;

note 'measuring libgit2 '.$runtime_version.' via '.join( ' ', @cflags );

# ---- the offsets Remote.pm reads from Git::Libgit2 ----

my %off = Git::Libgit2::cert_hostkey_offsets();

subtest 'git_cert_hostkey field offsets' => sub {
  # Remote.pm no longer compiles the offsets in; it reads them from
  # Git::Libgit2::cert_hostkey_offsets (karr #30), so that is what gets
  # measured against offsetof() here.
  for my $case ( [ type => 'type' ], [ sha1 => 'hash_sha1' ],
                 [ sha256 => 'hash_sha256' ] ) {
    my ( $key, $field ) = @$case;
    is $off{$key}, $probe{$field},
      "cert_hostkey_offsets $key == offsetof(git_cert_hostkey, $field) == $probe{$field}";
  }

  ok !Git::Native::Remote->can('CERT_HOSTKEY_TYPE_OFFSET'),
    'the compiled-in copy of the offsets is gone from Remote.pm';

  # _make_certcheck_thunk reads the cert kind at the cert pointer itself, with
  # no constant to name the 0 - so the 0 gets pinned here instead.
  is $probe{cert_type}, 0,
    'git_cert.cert_type is at offset 0, where the certcheck thunk reads it';
};

subtest 'the fingerprint reads stay inside the struct' => sub {
  # An offset can be right while the read still runs off the end - that is what
  # would happen if a future libgit2 dropped a hash field and the struct shrank
  # under an offset that still looked plausible.
  my $size = $probe{sizeof_cert_hostkey};
  cmp_ok $off{type} + 4, '<=', $size,
    'the 4-byte git_cert_ssh_t read fits in the '.$size.'-byte struct';
  cmp_ok $off{sha1} + 20, '<=', $size,
    'the 20-byte SHA1 read fits';
  cmp_ok $off{sha256} + 32, '<=', $size,
    'the 32-byte SHA256 read fits';
};

subtest 'git_cert_t and git_cert_ssh_t values' => sub {
  # These are enum values rather than offsets, so a change would be an ABI
  # break libgit2 is unlikely to make - but they are compiled in the same
  # block, from the same 1.5 probe, and cost nothing to measure alongside.
  my @cases = (
    [ 'GIT_CERT_X509',            'GIT_CERT_X509'            ],
    [ 'GIT_CERT_HOSTKEY_LIBSSH2', 'GIT_CERT_HOSTKEY_LIBSSH2' ],
    [ 'GIT_CERT_SSH_SHA1',        'GIT_CERT_SSH_SHA1'        ],
    [ 'GIT_CERT_SSH_SHA256',      'GIT_CERT_SSH_SHA256'      ],
  );
  for my $case (@cases) {
    my ( $const, $c_name ) = @$case;
    my $code = Git::Native::Remote->can($const);
    ok $code, 'Git::Native::Remote::'.$const.' exists' or next;
    is $code->(), $probe{$c_name},
      $const.' == '.$c_name.' == '.$probe{$c_name};
  }

  # The two hash bits are a bitmask _verify_known_host tests with & - if they
  # ever shared a bit the SHA256 branch would swallow a SHA1-only host key.
  is Git::Native::Remote::GIT_CERT_SSH_SHA1()
   & Git::Native::Remote::GIT_CERT_SSH_SHA256(), 0,
    'the SHA1 and SHA256 bits do not overlap';
};

done_testing;
