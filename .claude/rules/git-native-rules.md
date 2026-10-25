# Git::Native House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Native Git for Perl via libgit2 (FFI, no fork/exec). Read first: exports, immediate callers,
shared roles — "looks orthogonal" is dangerous across the wrapper/role mesh and libgit2 offsets.
One karr board, no cross-repo handoff; use it to record decisions worth solidifying, drift to
reconcile, and follow-up work that should not block the current change.

## Agent team

| Task | Agent |
|---|---|
| Local-repo wrappers, objects, refs, config | `git-native-worker` (default) |
| Remote, credentials, clone / fetch / push, FFI struct margins, known_hosts | `git-native-network-worker` |
| clone quirks, status, tag / refname / head surface | `git-native-phase5-worker` |
| Write and extend tests for all of the above | `git-native-test-writer` |
| Commits, card → done, pre-release audit — advisory only, never releases | `git-native-release-manager` |
| Read-only research, audit, gap analysis | `git-native-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior, public API, the wrappers under `lib/Git/Native/`, FFI
struct layouts, error handling, tests, performance and memory ownership. Pure prose docs, ADRs
and `Changes` notes are not. The lane split in detail: skill `git-native-core`.
Cross-lane changes get handed off to the owning worker.

## Release

The `[@Author::GETTY]` bundle bumps `$VERSION` and tags on release. Pre-release audit goes
through `git-native-release-manager`.

## Hazards

- **Live network tests skip silently.** `t/40-remote-ssh.t` / `t/41-remote-https.t` skip
  without their env vars — "tests pass" must say they were skipped.
