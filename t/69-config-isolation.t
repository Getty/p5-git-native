use Test2::V0;
use lib 't/lib';
use TestRepo;
use Git::Native;
use Path::Tiny;

# Regression test for the TestRepo config isolation (karr-9).
#
# The suite used to isolate itself with GIT_CONFIG_GLOBAL=/dev/null and
# GIT_CONFIG_SYSTEM=/dev/null. That works for the git CLI and does exactly
# nothing for libgit2 1.5, which does not know those variables: it resolves the
# global and XDG config levels from its own sysdir search path, guessed from
# HOME / XDG_CONFIG_HOME during git_libgit2_init. So every assertion about a
# real config key was answered from the developer's ~/.gitconfig, and every
# test commit was signed with the developer's identity.
#
# TestRepo now redirects HOME (and XDG_CONFIG_HOME) into a throwaway directory
# from a BEGIN block that runs before Git::Native is loaded. This file pins
# that down from three sides:
#
#   * the isolated repository sees no global identity at all,
#   * a probe config placed in the redirected HOME *is* read, so the assertion
#     above is measuring the global level and not just an empty universe,
#   * a subprocess without TestRepo, with HOME pointed at a fixture, reads that
#     fixture's config - the leak channel is real, and TestRepo closes it.
#
# Known gap, deliberately not asserted here: the *system* level
# (/etc/gitconfig) is still visible. libgit2 hardcodes that path, ignores
# GIT_CONFIG_SYSTEM and GIT_CONFIG_NOSYSTEM alike, and the supported override
# git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH) is not bound by Git::Libgit2 0.005.
# Asserting on it either way would only pin this machine's /etc/gitconfig.

my $PROBE_EMAIL = 'global-probe@example.invalid';
my $LEAK_EMAIL  = 'leak-probe@example.invalid';

subtest 'HOME is redirected, and the CLI variables are still set' => sub {
  # Both mechanisms have to be in place: the env vars cover a git CLI a
  # fixture might shell out to, the HOME redirect covers libgit2 itself.
  is $ENV{GIT_CONFIG_GLOBAL}, '/dev/null', 'GIT_CONFIG_GLOBAL still pinned';
  is $ENV{GIT_CONFIG_SYSTEM}, '/dev/null', 'GIT_CONFIG_SYSTEM still pinned';

  is $ENV{HOME}, "$TestRepo::HOME", 'HOME points at the throwaway directory';
  ok -d $ENV{HOME}, 'the throwaway HOME exists';
  isnt $ENV{HOME}, $TestRepo::REAL_HOME, 'HOME is not the real one';
  is $ENV{XDG_CONFIG_HOME}, "$TestRepo::HOME/.config",
    'XDG_CONFIG_HOME is inside the throwaway HOME too';
};

subtest 'a TestRepo repository has no global identity' => sub {
  my ( $repo, $tmp ) = TestRepo::new_repo();

  is $repo->config_string('user.email'), undef, 'user.email is unset';
  is $repo->config_string('user.name'),  undef, 'user.name is unset';

  # The visible consequence, and the one that used to be machine-dependent:
  # commit_create / tag_create fall back to signature_default, which now takes
  # the documented placeholder instead of whoever is sitting at the keyboard.
  my $sig = $repo->signature_default;
  is $sig->email, 'unconfigured@example.invalid',
    'signature_default falls back to the placeholder identity';
  is $sig->name, 'Git::Native', 'and to the placeholder name';
};

subtest 'the real ~/.gitconfig on this machine is invisible' => sub {
  # The literal statement of the bug: whatever identity the developer has
  # configured must not answer a config_string on a test repository.
  my $real = defined $TestRepo::REAL_HOME
    ? path( $TestRepo::REAL_HOME, '.gitconfig' ) : undef;

  skip_all 'no ~/.gitconfig on this machine - nothing to leak'
    unless $real && $real->is_file;

  my $raw = eval { $real->slurp_utf8 } // '';
  my ($email) = $raw =~ /^\s*email\s*=\s*(\S+)/m;

  skip_all "~/.gitconfig has no user.email to probe with ($real)"
    unless defined $email;

  my ( $repo, $tmp ) = TestRepo::new_repo();
  isnt $repo->config_string('user.email'), $email,
    'the identity from the real ~/.gitconfig does not reach a test repository';
  isnt $repo->signature_default->email, $email,
    'and does not end up signing test commits';
};

subtest 'counter-probe: a config in the redirected HOME IS read' => sub {
  # Without this, the subtests above would pass just as well if libgit2 had
  # stopped reading the global level for some unrelated reason. Dropping a
  # config into the redirected HOME is the same channel the developer's
  # ~/.gitconfig used to come through - it has to still work, only now it
  # points somewhere harmless.
  my $probe = path( "$TestRepo::HOME", '.gitconfig' );
  $probe->spew_utf8("[user]\n\temail = $PROBE_EMAIL\n\tname = Global Probe\n");

  my ( $repo, $tmp ) = TestRepo::new_repo();
  is $repo->config_string('user.email'), $PROBE_EMAIL,
    'the global level is read from the redirected HOME';
  is $repo->signature_default->email, $PROBE_EMAIL,
    'and it does reach signature_default - so the isolation is what silences it';

  $probe->remove;
  my ( $after, $after_tmp ) = TestRepo::new_repo();
  is $after->config_string('user.email'), undef,
    'and it is gone again once the probe config is removed';
};

subtest 'repository-local config is deliberately NOT isolated' => sub {
  # Tests are expected to configure the repository they just created (that is
  # how t/67-signature.t gets a deterministic identity). Isolating the local
  # level too would break that, so pin the layering: local wins over global,
  # and it survives with no global config at all.
  my ( $repo, $tmp ) = TestRepo::new_repo();
  $repo->config->set_string( 'user.email', 'local@example.invalid' );
  $repo->config->set_string( 'user.name',  'Local Tester' );

  is $repo->config_string('user.email'), 'local@example.invalid',
    'a repo-local value is readable';
  is $repo->signature_default->email, 'local@example.invalid',
    'and signature_default uses it';

  my $probe = path( "$TestRepo::HOME", '.gitconfig' );
  $probe->spew_utf8("[user]\n\temail = $PROBE_EMAIL\n");
  is $repo->config_string('user.email'), 'local@example.invalid',
    'the repo-local level still outranks the global one';
  $probe->remove;
};

subtest 'a process without TestRepo really does read $HOME/.gitconfig' => sub {
  # This one needs a subprocess: libgit2 resolves its search path once, at
  # init, so the difference between "isolated" and "not isolated" cannot be
  # produced inside an already-initialised process. The fixture HOME plays the
  # part of the developer's home directory.
  my $fixture = Path::Tiny->tempdir;
  $fixture->child('.gitconfig')
    ->spew_utf8("[user]\n\temail = $LEAK_EMAIL\n\tname = Leak Probe\n");

  my $script = Path::Tiny->tempfile( SUFFIX => '.pl' );
  $script->spew_utf8( <<'PROBE' );
use strict;
use warnings;
use lib 't/lib';
BEGIN { require TestRepo if $ENV{PROBE_WITH_TESTREPO} }
use Path::Tiny;
use Git::Native;
my $tmp  = Path::Tiny->tempdir;
my $repo = Git::Native->init( "$tmp", initial_branch => 'main' );
print "HOME=$ENV{HOME}\n";
print "EMAIL=", $repo->config_string('user.email') // '(unset)', "\n";
PROBE

  my $run = sub {
    my ($with_testrepo) = @_;
    local $ENV{HOME}                 = "$fixture";
    local $ENV{XDG_CONFIG_HOME}      = "$fixture/.config";
    local $ENV{GIT_CONFIG_GLOBAL}    = '/dev/null';
    local $ENV{GIT_CONFIG_SYSTEM}    = '/dev/null';
    local $ENV{PROBE_WITH_TESTREPO}  = $with_testrepo ? 1 : 0;
    my $out = qx{$^X -Ilib "$script" 2>&1};
    die "probe process failed (rc=$?): $out" if $?;
    my %got = $out =~ /^(\w+)=(.*)$/mg;
    return \%got;
  };

  my $without = $run->(0);
  my $with    = $run->(1);

  is $without->{EMAIL}, $LEAK_EMAIL,
    'without TestRepo, libgit2 reads $HOME/.gitconfig despite GIT_CONFIG_GLOBAL=/dev/null';
  is $without->{HOME}, "$fixture", 'that process kept the HOME it was given';

  is $with->{EMAIL}, '(unset)', 'with TestRepo loaded first, that config is invisible';
  isnt $with->{EMAIL}, $without->{EMAIL},
    'the two runs disagree - the isolation is doing the work, not the environment';

  isnt $with->{HOME}, "$fixture", 'TestRepo redirected HOME away from the fixture';
  ok !-e $with->{HOME},
    'and the throwaway HOME was cleaned up when the process exited';
};

done_testing;
