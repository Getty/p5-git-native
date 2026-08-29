use Test2::V0;
use Git::Native;
use Git::Native::Blob;
use Git::Native::Branch;
use Git::Native::Commit;
use Git::Native::Config;
use Git::Native::Credential;
use Git::Native::Error;
use Git::Native::Index;
use Git::Native::Oid;
use Git::Native::Reference;
use Git::Native::Remote;
use Git::Native::Repository;
use Git::Native::Revwalker;
use Git::Native::Signature;
use Git::Native::Tag;
use Git::Native::Tree;
use Git::Native::TreeBuilder;

ok( Git::Native->can('open'),     'Git::Native->open exists' );
ok( Git::Native->can('open_ext'), 'Git::Native->open_ext exists' );
ok( Git::Native->can('init'),     'Git::Native->init exists' );
ok( Git::Native::Error->can('throw'),       'Error->throw exists' );
ok( Git::Native::Credential->can('userpass'), 'Credential->userpass exists' );
ok( Git::Native::Remote->can('new'),        'Remote->new exists' );
ok( Git::Native::Config->can('get_string'), 'Config->get_string exists' );
ok( Git::Native->can('reference_name_is_valid'), 'Git::Native->reference_name_is_valid exists' );

# 0.006 dropped `use Moo` from the entry package, which took the constructor
# with it: every sub here is a class method and Git::Native->new only ever
# returned an object no caller read. Pin the removal so it does not creep back
# in the day someone adds an attribute.
ok( !Git::Native->can('new'), 'Git::Native has no constructor (Moo dropped in 0.006)' );

done_testing;
