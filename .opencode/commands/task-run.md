---
description: Read the tracker backlog, plan a parallel/sequential order, and drive it through /task-implement
---

# /task-run — run the backlog, auto-ordered

`/task-implement` scaled to the whole backlog. Where `/task-implement` builds the
issues **you** name in the order you give, `/task-run` reads the tracker board,
works out which issues can build **in parallel** and which must go **in
sequence**, shows you that plan, then runs the same worktree → TDD → verify →
review → PR machinery batch by batch. Same engine, plus an ordering layer.

Requested scope (may be empty): **$ARGUMENTS**

## Tracker coordinates

Read these from `.opencode/tracker.md` (written by `/harness-setup`): `tracker`,
`mcp_prefix`, `project_code`, `project_id`. If the file is missing, tell the user
to run `/harness-setup` first.

- Project = `project_code` (pass `project_id` to MCP tools that need it).
- Resolve states **by name at runtime** via `<mcp_prefix>_state` (`action: list`):
  **"Todo"**, **"In Progress"**, **"In Review"**, **"Done"**.
- Read dependency links via the tracker's relation tool
  (Plane `<mcp_prefix>_workitem_relation` with `action: list`; **blocks / blocked-by**). If
  the tracker has no relations, skip this signal and order by file-overlap alone.

## Steps

1. **Resolve the work list.**
   - No args → list work items in the **Todo** state.
   - Args that look like identifiers (`project_code-…`) → fetch those.
   - An arg that names a label → filter Todo issues to it.
   - For each issue, read the description and open the linked local spec under
     `docs/superpowers/` to extract its **code map** (the files it touches).

2. **Build the execution plan from two signals.**
   - **Tracker relations** — if A **blocks** B, B waits for A.
   - **File-overlap** — if two issues' code maps share any file, they can't run
     concurrently.
   - Sequence a pair if **either** signal says they collide; otherwise they can
     share a batch. Topologically sort into ordered **batches**: a batch is a set
     of issues with no unmet blocker and no pairwise file-overlap. Batches run in
     order; issues **within** a batch run in parallel.

3. **Show the plan and get approval.** Lay out the batches, what runs in parallel,
   and **why** each sequenced pair is sequenced (blocks-relation vs. file-overlap).
   Wait for the user to approve or adjust before dispatching anything.

4. **Execute batch by batch** — reuse `/task-implement`'s mechanics per issue:
   - Move each issue in the batch to **In Progress**; create one worktree each
     (via the `using-git-worktrees` skill, `<type>/<scope>-<topic>` under
     `.worktrees/`).
   - Dispatch the batch's implementation agents in a **single message**
      (via the `dispatching-parallel-agents` and `subagent-driven-development`
      skills),
      each following TDD (red → green → refactor, full suite). Give each its issue +
      spec, worktree path, code map, and "don't touch the main checkout or sibling
      worktrees".
   - **Verify (parent):** inspect each diff and run the full project suite
      (via the `verification-before-completion` skill).
   - **Code review (parent):** run the `requesting-code-review` skill per branch.
     **Report findings grouped by severity (Critical / Important / Minor) and ask
     which to fix — do NOT auto-fix.** Apply only what the user approves, re-review.
   - **Commit + PR (parent):** worktree agents run from the main checkout, so the
     **parent** commits at green points, pushes, and **opens the PR automatically**
     once a branch is verified, green, committed, and clean (no Important+
     findings). Conventional-commit title; move the issue to **In Review**
     (→ **Done** when the PR merges).
   - Start the **next batch** only once the current batch's issues are PR-open
     (their blockers resolved).

5. **Report a run summary** — issues built, PRs opened, and anything left blocked
   or skipped.

## Guardrails

- **Report review findings; don't auto-fix.** The auto-open-PR gate is the only
  hands-off step; the fix decision always waits for the user.
- **The parent does all commits/PRs and tracker writes** — worktree agents only
  implement and report back.
- **Worktrees always; never commit to the default branch.** Keep a batch's
  parallel agents on **disjoint files** — that's exactly what the plan guarantees.
- **If the tracker MCP server is unreachable**, say so and offer to proceed with
  issue IDs the user names (file-overlap-only ordering) or to stop.
