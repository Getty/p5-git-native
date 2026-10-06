# Git::Native

Native Git for Perl via [libgit2](https://libgit2.org/) — no fork/exec, no XS.

An idiomatic [Moo](https://metacpan.org/pod/Moo) wrapper over
[Git::Libgit2](https://metacpan.org/pod/Git::Libgit2) (which binds `libgit2`
through [FFI::Platypus](https://metacpan.org/pod/FFI::Platypus) via
[Alien::Libgit2](https://metacpan.org/pod/Alien::Libgit2)). Git work runs
in-process — no `git` subprocess per operation.

## Why it exists

Use it instead of [Git::Wrapper](https://metacpan.org/pod/Git::Wrapper) or
[Git::Repository](https://metacpan.org/pod/Git::Repository) when you want Git
operations without forking the `git` binary every time.

- [Git::Wrapper](https://metacpan.org/pod/Git::Wrapper), [Git::Repository](https://metacpan.org/pod/Git::Repository) — shell out to `git`
- [Git::Raw](https://metacpan.org/pod/Git::Raw) — XS bindings, unmaintained since 2022, known segfaults
- [Git::PurePerl](https://metacpan.org/pod/Git::PurePerl) — pure-Perl, read-only, no push/pull

`Git::Native` gives you RAII handle management: child objects hold a strong
reference to their parent, and handles are freed via `DESTROY` so there is no
use-after-free.

## Synopsis

```perl
use Git::Native;

my $repo = Git::Native->open('/path/to/.git');
my $main = $repo->reference('refs/heads/main');
say $main->target;     # commit OID

# Build a commit without forking git
my $blob_oid = $repo->blob_create_frombuffer("hello\n");
my $tb       = $repo->tree_builder;
$tb->insert(name => 'hi.txt', oid => $blob_oid, mode => 0100644);
my $tree_oid = $tb->write;
my $commit_oid = $repo->commit_create(
  update_ref => 'HEAD',
  tree       => $tree_oid,
  parents    => [$main->target],
  message    => 'add greeting',
);
```

## Installation

```bash
cpanm Git::Native
```

`libgit2` itself is provided automatically through `Alien::Libgit2`.

### Windows

Works with Strawberry Perl, from `cmd.exe`, PowerShell and Git Bash alike.
Things to know:

- `cmd.exe` and PowerShell set no `HOME`. SSH host keys are looked up in
  `%USERPROFILE%\.ssh\known_hosts` (and `known_hosts2`) as well, then in
  `%PROGRAMDATA%\ssh\ssh_known_hosts`. For a key file path of your own use
  `$ENV{HOME} // $ENV{USERPROFILE}`.
- A `file://` URL for a drive path needs three slashes:
  `file:///C:/repos/x.git`, not `file://C:/repos/x.git`.
- HTTPS remotes fail with `user rejected certificate for <host>` when
  `libgit2` was built by `Alien::Libgit2` under Strawberry Perl: its OpenSSL
  has no CA store on the machine. Start the process with `SSL_CERT_FILE`
  pointing at a PEM bundle, e.g. the one `Mozilla::CA` ships. Setting
  `$ENV{SSL_CERT_FILE}` from inside Perl is too late. SSH is not affected.

## See also

- [Git::Libgit2](https://metacpan.org/pod/Git::Libgit2) — the low-level FFI bindings layer
- [Alien::Libgit2](https://metacpan.org/pod/Alien::Libgit2)
- [FFI::Platypus](https://metacpan.org/pod/FFI::Platypus)
- [libgit2](https://libgit2.org/)

## License

This software is copyright (c) 2026 by Torsten Raudssus.

This is free software; you can redistribute it and/or modify it under the same
terms as the Perl 5 programming language system itself.
