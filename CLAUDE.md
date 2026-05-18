# Git::Native

High-level Moo wrapper over L<Git::Libgit2>. This is the API CPAN
consumers see. Name contrasts deliberately with `Git::Wrapper` and
`Git::Repository` (both shell out to the `git` binary).

## Stack

`Git::Native` (Moo) -> `Git::Libgit2` (FFI) -> `Alien::Libgit2` (libgit2 C lib).

## Class Layout

```
Git::Native               ->open / ->init / ->clone

Git::Native::Repository   workdir, gitdir, is_bare
                          ->config, ->reference($name), ->references(prefix => ...)
                          ->remote($name), ->odb, ->tree_builder
                          ->signature_default
                          ->commit_create(tree =>, parents =>, message =>, ...)
                          ->blob_create_frombuffer($scalar)
                          ->object($oid)
                          DESTROY: git_repository_free

Git::Native::Reference    name, target_oid, is_symbolic
                          ->set_target($oid, message => ...) / ->delete / ->peel($kind)

Git::Native::Config       ->get_string / ->get_bool / ->set_string / ->snapshot

Git::Native::Blob         ->content, ->size, ->oid
Git::Native::Tree         ->entries, ->entry_by_name
Git::Native::TreeBuilder  ->insert(name =>, oid =>, mode => 0100644) / ->write
Git::Native::Commit       ->author, ->committer, ->message, ->tree, ->parents, ->oid
Git::Native::Remote       ->url
                          ->fetch / ->push / ->credentials  (Phase 4)
Git::Native::Signature    name, email, when
Git::Native::Oid          stringify hex, ->raw (20B), ->short(7)
Git::Native::Error        isa Throwable::Error; code, klass, message
```

## Memory Ownership

Each Moo wrapper holds one opaque libgit2 handle. `DESTROY` calls the
matching `git_*_free`. Child objects (e.g. a `Tree` returned from a
`Commit`) hold a strong ref to their parent in `_owner` so the parent
outlives the child - no use-after-free.

## Error Handling

Every FFI call with an `int` return code goes through `_check($rc)` in
`Git::Libgit2`. On negative rc, the C error string is fetched via
`Git::Libgit2::Error->last`, then re-thrown as a `Git::Native::Error`
(Throwable). No raw libgit2 codes leak above this layer.

## Test Hygiene

All tests run with `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null`
to avoid polluting the user's `~/.gitconfig` (the exact bug Git::Raw
shipped). Enforced in `t/lib/TestRepo.pm`.
