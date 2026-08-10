package TestRepo;
use strict;
use warnings;
use Path::Tiny;

# --- config isolation -------------------------------------------------------
#
# Keep the developer's real git config out of the suite - the exact bug
# Git::Raw shipped.
#
# GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM only reach the git CLI. libgit2 1.5
# does not know those variables at all (nor GIT_CONFIG_NOSYSTEM): it resolves
# the global and XDG config levels through its own sysdir search path, guessed
# from HOME / XDG_CONFIG_HOME once, during git_libgit2_init. Both sets are kept
# - the env vars for any git CLI a fixture shells out to, the HOME redirect for
# libgit2 itself.
#
# The redirect has to happen before `use Git::Native` below: that load pulls in
# Git::Native::Credential, which calls init_lib() at load time, so libgit2 is
# already initialised - and its search path already resolved - by the time this
# module's body runs. Assigning $ENV{HOME} after the `use` provably changes
# nothing (karr-9).
#
# Scope of the redirect, on purpose:
#   global + XDG  isolated - nothing of ~/.gitconfig reaches a test repo.
#   repository    untouched - tests set user.name / user.email on the repo they
#                 just created and must keep seeing those values.
#   system        NOT isolated. /etc/gitconfig still applies; libgit2 hardcodes
#                 that path and the only supported override,
#                 git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH), is not bound by
#                 Git::Libgit2 0.005.
#
# t/69-config-isolation.t is the regression test for all of this.

our $REAL_HOME;
our $HOME;

BEGIN {
  die "TestRepo must be loaded before Git::Native - libgit2 caches its config "
    . "search path at init, so the HOME redirect below would come too late\n"
    if $INC{'Git/Libgit2.pm'};

  $ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
  $ENV{GIT_CONFIG_SYSTEM} = '/dev/null';

  # Live network tests need the operator's real ~/.ssh (keys, known_hosts),
  # which the redirect would hide; they restore HOME from here.
  $REAL_HOME = $ENV{HOME};

  # One throwaway HOME per test process. File::Temp hands out a unique
  # directory, so parallel test files never share one, and the tempdir guard
  # removes it on exit exactly like the test repos below.
  $HOME                 = Path::Tiny->tempdir('git-native-home-XXXXXXXX');
  $ENV{HOME}            = "$HOME";
  $ENV{XDG_CONFIG_HOME} = $HOME->child('.config')->stringify;
}

use Git::Native;

sub new_repo {
  my $tmp  = Path::Tiny->tempdir;
  # Pin the default branch to 'main' so tests don't depend on libgit2's
  # compiled-in default: Debian patches it to 'main', upstream/Homebrew
  # still defaults to 'master'.
  my $repo = Git::Native->init( "$tmp", initial_branch => 'main' );
  return ( $repo, $tmp );
}

1;
