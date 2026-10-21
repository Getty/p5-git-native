# Git::Native House Rules

Apply to every task in the Git::Native distribution unless explicitly overridden. Bias:
caution over speed on non-trivial work; use judgment on trivial tasks. Subagents get their
conventions from the skills force-loaded via `briefing.skills` — this file is for the main agent.

## Engineering discipline

1. **Think before coding** — State assumptions; when uncertain, ask rather than guess, present
   interpretations if ambiguous, and push back when a simpler approach exists. Stop when
   confused; name what's unclear.
2. **Simplicity first** — Minimum code that solves the problem. Nothing speculative. No
   abstractions for single-use code.
3. **Surgical changes** — Touch only what you must. Don't "improve" adjacent code, comments,
   or formatting. Match existing style.
4. **Goal-driven execution** — Define success criteria, loop until verified.
5. **Surface conflicts, don't average them** — Contradicting patterns: pick one (more
   recent / more tested), explain why, flag the other for cleanup. Don't blend.
6. **Read before you write** — Before new code, read exports, immediate callers, shared roles.
   "Looks orthogonal" is dangerous, especially across the wrapper/role mesh and libgit2 offsets.
7. **Tests verify intent, not just behavior** — Tests encode WHY behavior matters. A test
   that can't fail when business logic changes is wrong.
8. **Checkpoint after every significant step** — Summarize: done / verified / left. Don't
   continue from a state you can't describe back.
9. **Match the codebase's conventions, even if you disagree** — Conformance > taste.
   Surface a harmful convention; don't fork silently.
10. **Fail loud** — "Done" is wrong if anything was skipped silently. "Tests pass" is wrong
    if any were skipped (live network tests `t/40-remote-ssh.t` / `t/41-remote-https.t` skip
    without env vars — say so). Surface uncertainty, don't hide it.

## Delegation

This rule depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch behavior-relevant
  Git::Native code yourself — delegate to the right `git-native-*` agent. Your lane: coordinate,
  inspect, plan, review diffs, run tests, write/curate docs and Changes notes. When in doubt,
  delegate. Why: the `git-native-*` agents get their skills force-loaded via `briefing.skills`;
  the bare main agent gets no briefing and would touch the libgit2 quirks with too little context.
- **You cannot spawn subagents** (you ARE a `git-native-*` agent): The delegation lock does
  not apply to you — implement, refactor, debug, and test per these rules, in your lane.
  Cross-lane changes get handed off to the owning worker.

| Task | Agent |
|---|---|
| Local-repo wrappers, objects, refs, config | `git-native-worker` (default) |
| Remote, credentials, clone / fetch / push, FFI struct margins, known_hosts | `git-native-network-worker` |
| clone quirks, status, tag / refname / head surface | `git-native-phase5-worker` |
| Write and extend tests for all of the above | `git-native-test-writer` |
| Pre-release audit — advisory only, never `dzil release` | `git-native-release-manager` |

Behavior-relevant = runtime behavior, public API, the wrappers under `lib/Git/Native/`, FFI
struct layouts, error handling, tests, performance and memory ownership. Pure prose docs, ADRs
and `Changes` notes are not. The lane split in detail: skill `git-native-core`.

**Only `git-native-release-manager` commits.** A worker leaves a commit-ready tree and hands its card
to `review`; you then dispatch `git-native-release-manager` to cut the commit and close the card.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope — don't
invoke the `kanban-issues-karr-coordination` skill first, just use it. Board state lives in
`refs/karr/*` in this repo (one board, no cross-repo handoff). Day-to-day:

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create "Title" --priority high --tags a,b --body '…'` — new · `karr edit ID -a "note"` ·
  `--claim NAME` · `--block "why"` — update
- `karr move ID in-progress --claim NAME` — start · `karr handoff ID --claim NAME --note "…"` — to review
- mutating commands auto-sync; `karr sync --pull|--push` for explicit exchange

Use karr to record decisions worth solidifying, drift to reconcile, and follow-up work
that should not block the current change. Full command surface: skill `kanban-issues-karr-coordination`.

## Public issues (GitHub `Getty/p5-git-native`) — never act without instruction

Two trackers, two universes. **karr** is the AI/agent work board — internal, ours, churned
freely. **GitHub issues** (`gh` CLI, `github.com/Getty/p5-git-native`) are the **public
tracker: real humans' bug reports and feature requests**, outward-facing, under the maintainer's account.

Security rule: **never act on a GitHub issue or PR on your own initiative — not even to read
it.** No listing, viewing, commenting, editing, closing, or creating unless the user explicitly
tells you to handle a specific public item. Incoming user tickets are NOT a queue the agent
drains; every write is confirmed first because it publishes under the maintainer's name.

## Release — never without permission

`dzil build` / `dzil test` are fine anytime. `dzil release` and any CPAN upload are STRICTLY
forbidden without the maintainer's explicit go-ahead — even if a plan or TODO lists "release" as
the next step. The `[@Author::GETTY]` bundle bumps `$VERSION` and tags on release; for anything
heading toward release: stop and ask. Pre-release audit goes through `git-native-release-manager`.
