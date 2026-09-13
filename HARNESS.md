# Development Harness (TDD)

The repeatable loop for shipping a change in this repo. It assumes OpenCode
with the `superpowers` plugin (declared in `opencode.jsonc`) and your tracker
(configured in `.opencode/tracker.md`, reached via an MCP server). It complements
[`AGENTS.md`](AGENTS.md) (the *why* of worktrees/specs) with the *how* of TDD and
issue tracking. Coordinates live in `.opencode/tracker.md` — run `/harness-setup`
to create it.

Optimize for the **simplest approach that passes a test**, and **verify every
step with real output** before moving on. **Always use superpowers** — invoke
the relevant skill at each stage rather than improvising.

---

## The loop at a glance

```
brainstorm ─▶ spec ─▶ issue(s) ─▶ worktree ─▶ TDD ─▶ verify ─▶ review ─▶ PR
  (skill)    (local)  (tracker)  (gitignored) (R/G/R) (skill)  (skill)
└─────────── /task-init ──────┘  └──────────── /task-implement ───────────┘
└────────── /issues-init ──────┘  └───────────────── /task-run ────────────┘
      (same, but one epic → many        (same, but reads the backlog and
        linked issues at once)          orders the batches for you)
```

Four slash commands drive the loop — two for planning, two for building, each
pair scaling from a single task to a whole epic/backlog:

- **`/task-init [description]`** — brainstorm → local spec → issue(s).
- **`/issues-init [epic]`** — decompose an epic → many linked issues (blocks
  relations + a parent grouping), so `/task-run` can order them.
- **`/task-implement [project_code-12 …]`** — worktree → TDD → verify → review
  → PR for the issues you name, with parallel agents when there are multiple.
- **`/task-run [ids|label]`** — read the backlog, plan a parallel/sequential
  order from blocks-relations + file-overlap, then drive `/task-implement`'s
  machinery batch by batch.

Issues live in the tracker (project `project_code`). Specs and plans
stay *local* and *gitignored* under `docs/superpowers/`; worktrees live under
`.worktrees/` (also gitignored). **Never commit either.** The durable record is
the code, the tracked issue, and the PR.

---

## Set up the tracker (once per repo)

Before the loop, configure and provision the tracker:

1. **`/harness-setup`** — choose the tracker (default Plane); writes
   `.opencode/tracker.md`.
2. **`/harness-bootstrap`** — create the project (if missing), the
   `Todo → In Progress → In Review → Done` states, the type labels, and the
   weekly (Mon→Sun) cycles. Idempotent — re-run to top up future cycles.

---

## 0. Decide the size

- **Trivial** (one-line fix, typo, obvious tweak): skip straight to TDD on a
  worktree branch. No spec, no issue.
- **Non-trivial** (new feature, behavior change, multi-file): run the full loop
  via `/task-init` then `/task-implement`.

When unsure, treat it as non-trivial — a 10-line spec is cheap.

---

## 1. Brainstorm (non-trivial only) — `brainstorming`

Run `/task-init`, which invokes the `brainstorming` skill to pressure-test the
idea before any code. Goal: agree on the **simplest** approach and surface
unknowns. The skill writes the spec and gets your approval.

## 2. The spec — local only

The brainstorming skill writes to:

```
docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md
```

Gitignored. Keep it short: problem, chosen approach, the code map (files to
touch), and the test list (what proves it works). This is the contract the
implementation agent works against.

## 3. Issue(s) — the tracker

> **Tracker setup (one-time):** `/harness-bootstrap` creates the four required
> states — `Todo`, `In Progress`, `In Review`, `Done` — along with the type
> labels and weekly cycles. Run it once before starting the loop (see "Set up
> the tracker" above). If you're on a tracker without bootstrap support, create
> any missing states by hand — put `In Review` in the "started" group, ordered
> just before `Done` — so `/task-implement` can move an issue there when its PR
> opens.

`/task-init` files the work in the tracker, project `project_code`. One
issue ≈ one PR-sized chunk. Each issue gets:

- **State `Todo`** (resolve state ids at runtime).
- A **project label** (the sub-project the work touches) and a **type label**
  (`feat`, `fix`, `refactor`, `test`, `docs`, `chore`) — resolve label ids at
  runtime.
- A description carrying the problem, approach, code map, test list, and the
  local spec filename.

Use multiple independent issues to coordinate **parallel agents** — each agent
owns one issue in its own worktree.

## 4. Worktree — `using-git-worktrees`

Implementation always happens in an isolated worktree so the main checkout stays
clean. `/task-implement` uses the `using-git-worktrees` skill:

```bash
git worktree add -b <type>/<scope>-<topic> .worktrees/<topic> <default-branch>
```

`.worktrees/` is gitignored. One worktree per issue/branch. For independent
issues, create multiple worktrees and dispatch one agent each — they won't
collide.

## 5. TDD: Red → Green → Refactor — `test-driven-development`

This is the core. **Never write production code without a failing test first.**

1. **Red** — write the smallest test that captures the next behavior. Run it,
   **watch it fail for the right reason** (assertion, not import error).
   ```bash
   <test command for a single test>
   ```
2. **Green** — write the *minimum* code to pass. No extra cases, no speculative
   options. Run the test, watch it pass.
3. **Refactor** — clean up names/duplication with the test green. Re-run.
4. **Widen** — run the **full project suite** before considering the step done:
   ```bash
   <test command for the full suite>
   ```

Repeat per behavior. Commit at green points using conventional-commit messages —
the back half (verify → review → PR) needs the work committed and the tree clean.

### Test conventions

- Tests mirror the source tree: `src/.../features/<feature>/service.py` →
  `tests/features/<feature>/test_service.py`.
- Pure helpers (`shared/`) get class-grouped happy-path + error tests; use the
  framework's raises/throws assertion for typed errors.
- Shared fixtures live in a `conftest.py` (or equivalent).
- One assert-able behavior per test; name it `test_<does_what>`.

### Projects without a test harness yet

If a project has no test suite and you change its behavior, **add a test harness
first** (the simplest one that fits):

- A script in a tested language → add a test runner and a `tests/` dir, or
  extract the logic into an importable function and test that.
- A shell script → a `bats` test or a small `test.sh` asserting on output.

Don't expand untested scripts further without this.

## 6. Verify for real — `verification-before-completion`

Beyond green tests, run the actual command once to confirm end-to-end behavior.
Report what you observed.

## 7. Code review — always — `requesting-code-review`

Run the `requesting-code-review` skill on the branch before any PR.

- Report findings to the user **grouped by severity** (Critical / Important /
  Minor).
- **Do not auto-fix.** The user decides scope. Re-review after agreed fixes.

## 8. PR & close out — automatic

Open a PR **automatically** as soon as a branch is **verified, green, committed,
and clean**: no Important+ findings outstanding, the full suite passing, and the
working tree clean. No need to ask first. Conventional-commit title with scope
(`feat(<project>): …`). One feature per PR. Then move the issue to
**In Review**; set it to **Done** when the PR merges.

Only the PR-open step is automatic — the review *fix* decision still waits for
the user (§7).

---

## Parallel agents — `dispatching-parallel-agents`

For work that splits cleanly, `/task-implement` runs issues concurrently:

1. `/task-init` files N independent issues (disjoint files).
2. Create N worktrees (one per issue) via the `using-git-worktrees` skill.
3. Dispatch one subagent per worktree in a **single message** so they run
   concurrently (`dispatching-parallel-agents` +
   `subagent-driven-development`). Each agent gets: its issue + spec, its
   worktree path, a "don't touch the main checkout or other worktrees"
   instruction, the code map, and a "report back briefly" instruction.
4. The parent verifies each diff + test run, then reviews and PRs them
   independently, moving each issue to `In Review` on PR-open (and to `Done` when
   it merges).

Keep agents on **disjoint files** — if two issues touch the same module,
sequence them instead.

**`/task-run` automates this triage.** Instead of you hand-picking the disjoint
set, it reads the backlog, derives the batches from the tracker's blocks-relations
+ file-overlap, and runs each batch through steps 2–4 above — parallel where safe,
sequential where two issues collide. Pair it with `/issues-init`, which files the
issues already linked so the ordering is explicit.

---

## Versioning & sync

The harness is itself versioned so a repo that adopted it can track upstream
changes. The mechanics live in the tested `bin/harness` helper; two thin
commands drive it.

- **Cut a version (template repo only)** — `/harness-release <major|minor|patch>`
  bumps `VERSION`, rolls the `CHANGELOG.md` **Unreleased** section into a dated
  heading, commits, and tags `vX.Y.Z`.
- **The manifest** — `.opencode/harness-manifest` classifies every path:
  - `sync` — harness-owned; overwritten wholesale on a pull, **except** files you
    customized since the last sync (diffed against the locked baseline commit),
    which are **kept**.
  - `region` — mixed; only the `HARNESS:BEGIN…END` block is replaced, so your
    project content (the `AGENTS.md` project table, extra `.gitignore` lines)
    survives.
  - `ignore` — template-only or project-owned; never synced.
- **Pull updates into a consumer** — `/harness-sync` (needs the template as a
  git remote named `harness`). Always **plan first** (`bin/harness sync plan` —
  a read-only dry run of every overwrite/splice + the version delta), show the
  user, then `pull`. Pull refuses on a dirty tree and records the synced
  `version`/`commit`/`remote` in `.opencode/harness.lock` (commit that file).
- **Push a local harness fix back** — `/harness-sync push <topic>` branches,
  commits **only** the managed files, and opens a PR against the template (falls
  back to printing the manual `gh` command if `gh` is absent).

`sync`-tier files are overwritten rather than 3-way merged, but a pull **keeps**
any you've customized locally (diffed against the locked baseline commit) instead
of clobbering them — push your improvement back upstream when you want it in the
template. Never hand-edit inside a region's markers; a pull replaces that block.

## Guardrails

- **Issues in the tracker; specs/plans local.** `docs/superpowers/` and
  `.worktrees/` are gitignored — never `git add` them.
- **Always superpowers.** Use the named skill at each stage; don't improvise the
  workflow.
- **Worktrees always.** Implementation never happens in the main checkout.
- **Branch off the default branch; never commit to it.** Commit at green points;
  open the PR **automatically** once the branch is verified, green, committed,
  and clean (§8). The review fix decision still waits for the user.
- **Conventional commits always.** `<type>(<scope>): <subject>`; scope is the
  sub-project.
- **Simplest first.** If a test passes without a new abstraction or dependency,
  don't add one.
- **No green claim without a run.** Paste/observe real output.
