# Agent workflow for this repo

This file captures how feature work is done in this repo by automated coding
agents (OpenCode with the `superpowers` plugin and an MCP server for your issue
tracker). It's a recipe, not a rule. Tracker coordinates live in
`.opencode/tracker.md` — run `/harness-setup` to create it. **Always use
superpowers** — invoke the named skill at each stage. See
[`HARNESS.md`](HARNESS.md) for the full TDD detail.

Four slash commands wrap the loop — a planning pair and a building pair, each
scaling from a single task to a whole epic/backlog: **`/task-init`** /
**`/issues-init`** (front half) and **`/task-implement`** / **`/task-run`**
(back half).

## What this is

`remdev` is a **multi-project repo** of macOS live-wallpaper tooling. Each
top-level directory is a self-contained project with its own build script.
There is no shared package — keep projects independent.

| Project | What | Stack | Tests |
|---|---|---|---|
| [`LiveWallpaper/`](LiveWallpaper/) | Menu-bar app that sets a live video as the desktop wallpaper | Swift (`swiftc`, shell build) | build only — no automated tests |
| [`LiveLockscreen/`](LiveLockscreen/) | `.saver` bundle that plays a live video on the macOS lock screen | Swift (`swiftc`, shell build) | build only — no automated tests |
| `replace-wallpaper.sh` | Standalone helper script for wallpaper swapping | bash | none |

`LiveWallpaper/build.sh` embeds the `LiveLockscreen.saver` bundle (it calls
`LiveLockscreen/build.sh` first), so building `LiveWallpaper` also verifies
`LiveLockscreen`.

## Per-project commands

```bash
# LiveWallpaper (also builds LiveLockscreen)
bash LiveWallpaper/build.sh    # build
bash LiveWallpaper/build.sh    # run/verify: codesign the .app or `open build/LiveWallpaper.app`

# LiveLockscreen
bash LiveLockscreen/build.sh   # build the .saver bundle
bash LiveLockscreen/install.sh # install into ~/Library/Screen Savers
```

There is no test suite yet — verification means a clean build (`set -e`/`-euo
pipefail` in both scripts fail fast). When testable logic (parsing, video
validation, retries) is extracted, add tests via `swift test` with a
`Package.swift` and update this table.

## Conventions

- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/),
  scoped per project: `feat(<project>): …`, `fix(<project>): …`,
  `test(<project>): …`, `chore: …`. One project per commit where possible.
- **PRs:** one feature per PR; opened once the branch is verified, green,
  committed, and clean (see [`HARNESS.md`](HARNESS.md)). Code-review *fixes*
  wait for the user.
- **Branch off the default branch first — never commit to it directly.** Commit
  at green points so the branch is PR-ready.

<!-- HARNESS:BEGIN -->
<!-- Managed by the harness; `harness sync pull` replaces this block. Keep your
     project-specific content above this marker. -->
## Workflow & agents

The full loop (brainstorm → spec → issue(s) → worktree → TDD → verify → review →
PR) lives in [`HARNESS.md`](HARNESS.md), wrapped by four commands — a planning
pair, **`/task-init`** (one task → issue(s)) and **`/issues-init`** (one epic →
many linked issues), and a building pair, **`/task-implement`** (issues you name
→ PRs) and **`/task-run`** (the whole backlog, auto-ordered → PRs). Key rules:

- **Always use superpowers.** Invoke the named skill at each stage via the
  OpenCode `skill` tool (`brainstorming`, `using-git-worktrees`,
  `test-driven-development`, `dispatching-parallel-agents`,
  `verification-before-completion`, `requesting-code-review`).
  **Report findings, don't auto-fix.**
- **Specs and plans are local-only** under `docs/superpowers/` (gitignored).
  **Never commit them.** The committed record is the code + PR.
- **Issues live in the tracker** (configured in `.opencode/tracker.md` — run
  `/harness-setup` to create it) — project `project_code`. Each issue gets a
  project label and a type label (`feat`/`fix`/`refactor`/`test`/`docs`/`chore`);
  states go `Todo → In Progress → In Review (PR open) → Done (merged)`. Not in
  local files.
- **Always use worktrees** under `.worktrees/` (gitignored) for implementation;
  never work in the main checkout. Multiple issues run as parallel agents, one
  worktree each.
- **Conventional commits always**, scoped per sub-project.

## TL;DR

1. **`/task-init`** runs the `brainstorming` skill → a design at
   `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` (gitignored, local-only)
   → files **issue(s)** in the configured project (`project_code`) (state `Todo`,
   project + type labels). For a broad goal, **`/issues-init`** does the same at
   epic scale: it decomposes into many PR-sized issues, files them under a parent
   grouping, and sets **blocks/blocked-by** relations so the backlog is
   pre-ordered.
2. **`/task-implement [project_code-…]`** picks up the issue(s) and, for each,
   moves it to `In Progress` and **creates a worktree** under `.worktrees/<topic>/`
   on a new branch (gitignored) via the `using-git-worktrees` skill. To run the
   backlog instead of naming issues, **`/task-run`** derives parallel/sequential
   batches (from those relations + file-overlap), then drives this same machinery
   batch by batch.
3. **Dispatch a subagent** to implement inside that worktree, following TDD.
   Multiple issues → `dispatching-parallel-agents`, one agent per worktree, in a
   single message.
4. **Run `requesting-code-review`** on each branch.
5. **Report findings, ask before fixing.**
6. **Open a PR automatically** once the branch is verified, green, committed, and
   clean (no Important+ findings remain), then move the issue to **In Review**
   (and to **Done** when the PR merges). Only the fix decision in step 5 waits
   for the user.

## Why worktrees

Subagents touch a lot of files. Doing implementation in a separate worktree on a
feature branch keeps the main checkout clean and lets the parent agent inspect
the diff without context pollution.

When two or more independent tasks are dispatched in parallel, each gets its own
worktree, branch, and PR, so the diffs never tangle. Worktree setup goes through
`using-git-worktrees`; implementation **always** happens in a worktree, never in
the main checkout.

```bash
git worktree add -b <type>/<scope>-<topic> .worktrees/<topic> <default-branch>
```

`.worktrees/` is gitignored.

## Issue tracking

Issues live in the tracker (configured in `.opencode/tracker.md`), not in local
files. Project `project_code`. `/task-init` files them; `/task-implement` reads
and advances them.

- **States:** `Todo` → `In Progress` → `In Review` (PR open) → `Done` (merged)
  (resolve ids at runtime; create any your tracker lacks — e.g. Plane ships
  without `In Review`).
- **Labels:** one **project** label plus one **type** label (`feat`, `fix`,
  `refactor`, `test`, `docs`, `chore`) per issue.
- One issue ≈ one PR-sized chunk; independent issues enable parallel agents.
- The issue description carries the problem/approach/code-map/test-list and a
  pointer to the local spec filename.

## Why a separate spec workspace

`docs/superpowers/specs/` holds design docs the agent uses to align with the user
before coding. They are local-only (gitignored) because they're scratch
artifacts, not project documentation. The committed PR description and code are
the durable record.

## Subagents

For an implementation task that's bigger than a single edit, use
`subagent-driven-development` to dispatch a subagent with:

- A pointer to its **issue** and the linked design doc.
- The exact worktree path and a "do not touch the main checkout or sibling
  worktrees" instruction.
- An explicit code map (files to touch).
- A "report back briefly" instruction (so the parent's context isn't flooded).

When tasks run in parallel, use `dispatching-parallel-agents`: dispatch one
subagent per worktree in a single message. Keep them on disjoint files; sequence
anything that overlaps.

The parent verifies the diff and test results (`verification-before-completion`)
before moving on.

## Code review

Always run `requesting-code-review` before opening a PR. Report findings to the
user grouped by severity. **Do not auto-fix** — the user decides which items are
in scope.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):
`<type>(<scope>): <subject>`. Common types: `feat`, `fix`, `refactor`, `test`,
`docs`, `chore`. The scope is usually the top-level project directory.

## Tests first

Implementation follows TDD: write the failing test, watch it fail, make it pass,
refactor. Subagents dispatched for non-trivial work should be told to
red/green/refactor and to include the failing-test commit in the diff (or at
minimum show the failing run in their report).

## Versioning & sync

The harness is versioned so a consumer can track the upstream template. It's
driven by the tested `bin/harness` helper behind two thin commands:
`/harness-release` (template-only — bump `VERSION`/`CHANGELOG.md`, tag `vX.Y.Z`)
and `/harness-sync` (in a consumer — `plan`/`pull`/`push`).

`.opencode/harness-manifest` tiers every path: `sync` (overwritten on pull),
`region` (only the `HARNESS:BEGIN…END` block is replaced, project content kept),
`ignore` (never synced). A pull refuses on a dirty tree and writes the synced
state to `.opencode/harness.lock`; a push branches, commits only the managed
files, and opens a PR upstream. **Plan before every pull** and show the user.
Don't reimplement any of this in the markdown commands — the mechanics (semver,
manifest, region splice, lock) are unit-tested in `bin/harness`.

## Layout summary

```
.worktrees/                              # gitignored, agent worktrees
.opencode/commands/                      # /task-init, /issues-init, /task-implement, /task-run, /harness-* (committed)
.opencode/harness-manifest               # path → sync/region/ignore tier
.opencode/harness.lock                   # consumer-only: which harness version is installed
bin/harness                              # tested helper: release + sync mechanics
tests/test.sh                            # bin/harness test suite
VERSION  CHANGELOG.md                    # harness semver + changelog
docs/
  superpowers/                           # gitignored
    specs/YYYY-MM-DD-<topic>-design.md   # design docs (issues live in the tracker, not on disk)
<project>/                               # actual project
```
<!-- HARNESS:END -->
