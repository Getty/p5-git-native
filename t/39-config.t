use Test2::V0;
use lib 't/lib';
use TestRepo;
use Git::Native;
use Git::Native::Config;

my ( $repo, $tmp ) = TestRepo::new_repo();   # keep $tmp alive

# Live config: write a couple of values.
my $cfg = $repo->config;
isa_ok( $cfg, ['Git::Native::Config'], 'config returns a Config' );
$cfg->set_string( 'user.name',  'Native Tester' );
$cfg->set_string( 'user.email', 'native@example.invalid' );

# config_string reads off a fresh snapshot.
is( $repo->config_string('user.name'),  'Native Tester',           'config_string user.name' );
is( $repo->config_string('user.email'), 'native@example.invalid',  'config_string user.email' );

# Unset key -> undef (not an exception).
is( $repo->config_string('does.not.exist'), undef, 'missing key is undef' );

# Explicit snapshot object.
my $snap = $repo->config_snapshot;
isa_ok( $snap, ['Git::Native::Config'], 'config_snapshot returns a Config' );
is( $snap->get_string('user.name'), 'Native Tester', 'snapshot get_string' );

# ---- get_bool: git's boolean rules over a string value ----
# Write a spread of values, then read them off ONE fresh snapshot
# (get_string/get_bool are only reliable on a snapshot).
$cfg->set_string( "truthy.$_", $_ ) for qw( true yes on 1 17 );
$cfg->set_string( "falsy.$_",  $_ ) for qw( false no off 0 );
$cfg->set_string( 'bool.empty', '' );        # present but empty -> true
$cfg->set_string( 'bool.mixed', 'TrUe' );    # case-insensitive
$cfg->set_string( 'bool.bad',   'banana' );  # not a boolean -> croaks

my $b = $repo->config_snapshot;
is( $b->get_bool("truthy.$_"), 1, "get_bool '$_' is true" )  for qw( true yes on 1 17 );
is( $b->get_bool("falsy.$_"),  0, "get_bool '$_' is false" ) for qw( false no off 0 );
is( $b->get_bool('bool.empty'), 1, 'present-but-empty value is true' );
is( $b->get_bool('bool.mixed'), 1, 'get_bool is case-insensitive' );

# Unset key -> undef, mirroring get_string (not an exception).
is( $b->get_bool('does.not.exist'), undef, 'missing key -> undef' );

# A non-boolean, non-integer value croaks like git's own --bool.
like( dies { $b->get_bool('bool.bad') }, qr/not a valid boolean/,
  'non-boolean value croaks' );

done_testing;
