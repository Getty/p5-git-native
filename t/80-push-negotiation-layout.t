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

# Remote->push installs a push_negotiation closure by writing a pointer at a
# hardcoded offset of git_remote_callbacks and reads git_push_update by field
# offsets inside the closure. A wrong offset does not throw: the closure just
# never gets installed, or reads the wrong bytes out of the update. t/79
# watches the behaviour against a libgit2 whose layout matches; this measures
# the layout itself the way t/75 does for git_cert_hostkey - offsetof() against
# the git2.h Alien::Libgit2 installed, compile-time only, skipped with the
# reason when there is no compiler, no reachable header, or the header does not
# describe the loaded library.

my $c_source = <<'END_C';
#include <stddef.h>
#include <stdio.h>
#include <git2.h>

int main(void) {
  printf("header_version %s\n",            LIBGIT2_VERSION);
  printf("callbacks_push_negotiation %lu\n",
    (unsigned long) offsetof(git_remote_callbacks, push_negotiation));
  printf("callbacks_push_update_reference %lu\n",
    (unsigned long) offsetof(git_remote_callbacks, push_update_reference));
  printf("callbacks_transport %lu\n",
    (unsigned long) offsetof(git_remote_callbacks, transport));
  printf("push_update_src_refname %lu\n",
    (unsigned long) offsetof(git_push_update, src_refname));
  printf("push_update_dst_refname %lu\n",
    (unsigned long) offsetof(git_push_update, dst_refname));
  printf("push_update_src %lu\n",
    (unsigned long) offsetof(git_push_update, src));
  printf("push_update_dst %lu\n",
    (unsigned long) offsetof(git_push_update, dst));
  printf("sizeof_oid %lu\n", (unsigned long) sizeof(git_oid));
  return 0;
}
END_C

my $builder = ExtUtils::CBuilder->new( quiet => 1 );
my $tmp = Path::Tiny->tempdir('git-native-pushneg-probe-XXXXXXXX');
my $src = $tmp->child('push_negotiation_probe.c');
$src->spew($c_source);

my $cc_log = $tmp->child('cc.log');

sub one_line {
  my ($text) = @_;
  return '' unless defined $text && length $text;
  $text =~ s/\s+/ /g;
  $text =~ s/\A\s|\s\z//g;
  return $text;
}

# The compiler is a child process writing to fd 2, so take fd 2 over with a
# real file and fold what lands there into the skip reason.
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
  return ( $out, one_line($err), one_line($log) );
}

my @cflags = split ' ', Alien::Libgit2->cflags;

my ( $obj, $compile_err, $compile_log ) = run_capturing(sub {
  $builder->compile( source => "$src", extra_compiler_flags => \@cflags );
});
skip_all 'cannot compile the offsetof probe - no C compiler on this machine, '
       . 'or git2.h is not reachable from Alien::Libgit2->cflags ("'
       . join( ' ', @cflags ) . '"): '
       . join( ' ', grep { length } $compile_err, $compile_log )
  unless $obj;

my $exe = $tmp->child('push_negotiation_probe')->stringify;
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
  unless defined $probe{callbacks_push_negotiation};

note 'probe: '.join( ', ', map { $_.'='.$probe{$_} } sort keys %probe );

my $runtime_version = scalar Git::Libgit2::version();
my ($header_version) = ( $probe{header_version} // '' ) =~ /([0-9]+\.[0-9]+\.[0-9]+)/;
skip_all 'git2.h says libgit2 '.( $header_version // $probe{header_version} // '?' )
       . ' but the loaded library reports '.$runtime_version
       . ' - the header does not describe the struct Remote.pm actually uses'
  unless defined $header_version && $header_version eq $runtime_version;

note 'measuring libgit2 '.$runtime_version.' via '.join( ' ', @cflags );

subtest 'git_remote_callbacks.push_negotiation' => sub {
  is Git::Native::Remote::CALLBACKS_PUSH_NEGOTIATION_OFFSET(),
    $probe{callbacks_push_negotiation},
    'CALLBACKS_PUSH_NEGOTIATION_OFFSET == offsetof(git_remote_callbacks, push_negotiation)';
  is Git::Native::Remote::CALLBACKS_PUSH_UPDATE_REF_OFFSET(),
    $probe{callbacks_push_update_reference},
    'its neighbour push_update_reference, which Remote.pm already writes, agrees';
  cmp_ok $probe{callbacks_push_negotiation}, '<', $probe{callbacks_transport},
    'push_negotiation sits before transport, as the ticket describes';
};

subtest 'git_push_update field offsets' => sub {
  my %want = (
    PUSH_UPDATE_SRC_REFNAME_OFFSET => 'push_update_src_refname',
    PUSH_UPDATE_DST_REFNAME_OFFSET => 'push_update_dst_refname',
    PUSH_UPDATE_SRC_OID_OFFSET     => 'push_update_src',
    PUSH_UPDATE_DST_OID_OFFSET     => 'push_update_dst',
  );
  for my $const ( sort keys %want ) {
    my $code = Git::Native::Remote->can($const);
    ok $code, "Git::Native::Remote::$const exists" or next;
    is $code->(), $probe{ $want{$const} },
      "$const == offsetof(git_push_update, $want{$const}) == $probe{ $want{$const} }";
  }
  is $probe{sizeof_oid}, 20, 'a git_oid is 20 bytes, as the oid reads assume';
};

done_testing;
