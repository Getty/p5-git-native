use Test2::V0;
use Git::Native;

ok( Git::Native->can('open'),     'Git::Native->open exists' );
ok( Git::Native->can('open_ext'), 'Git::Native->open_ext exists' );
ok( Git::Native->can('init'),     'Git::Native->init exists' );

done_testing;
