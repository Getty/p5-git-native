package TestRepo;
use strict;
use warnings;
use Path::Tiny;
use Git::Native;

# Pin libgit2 away from the user's gitconfig. The exact bug Git::Raw shipped.
$ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
$ENV{GIT_CONFIG_SYSTEM} = '/dev/null';

sub new_repo {
  my $tmp  = Path::Tiny->tempdir;
  my $repo = Git::Native->init("$tmp");
  return ( $repo, $tmp );
}

1;
