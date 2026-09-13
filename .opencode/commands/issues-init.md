---
description: Decompose an epic into many linked tracker issues, ready for /task-run
---

# /issues-init — decompose an epic into issues

Take a broad goal and fan it out into several **PR-sized issues** in the
configured tracker, linked by dependency, ready for `/task-run`. This is
`/task-init` at _epic_ scale: where `/task-init` brainstorms one task,
`/issues-init` brainstorms the whole thing and files the batch. Specs stay local
and gitignored; issues (and their links) live in the tracker.

Epic description (may be empty — ask if so): **$ARGUMENTS**

## Tracker coordinates

Read these from `.opencode/tracker.md` (written by `/harness-setup`): `tracker`,
`mcp_prefix`, `project_code`, `project_id`. If the file is missing, tell the user
to run `/harness-setup` first.

- Project = `project_code` (pass `project_id` to MCP tools that need it).
- Resolve states, labels, and the relation type **by name at runtime** — don't
  hardcode UUIDs:
  - `<mcp_prefix>_state` (`action: list`) → pick the state named **"Todo"**.
  - `<mcp_prefix>_label` (`action: list`) → map label names to IDs.
- **Grouping + dependency links** are tracker-specific — use what yours supports:
  - _Grouping:_ a parent **epic** (Plane `<mcp_prefix>_workitem_type` with
    `action: resolve`, name **Epic**), a parent
    issue or project (Linear), or a **milestone** (GitHub). Skip if none exists.
  - _Dependency links:_ **blocks / blocked-by** relations (Plane
    `<mcp_prefix>_workitem_relation` with `action: create`; Linear issue relations). If the
    tracker has no relation type (e.g. GitHub Issues), record each chunk's
    blockers **in its description** instead — `/task-run` still orders by
    file-overlap.

## Steps

1. **Brainstorm at epic altitude.** Invoke the `brainstorming` skill (via the
   `skill` tool), but aim
   one level up: agree on scope (in / out), then **decompose** the epic into
   independent, PR-sized chunks and their dependency order. For each chunk pin
   down: an imperative name, the **type** (`feat`/`fix`/`refactor`/`test`/`docs`/
   `chore`), the **project** it touches, a **code map** (files to touch), a test
   list, and **which sibling chunks block it**. Prefer more small independent
   chunks — disjoint code maps are what let `/task-run` parallelize them.

2. **Write one epic spec** to
   `docs/superpowers/specs/YYYY-MM-DD-<epic>-design.md` (local, gitignored), with
   a section per chunk. Get the user's approval on it (the brainstorming skill's
   normal gate). Each chunk section holds its own code map + test list — those get
   copied into the issue so `/task-run` can read them without opening the spec.

3. **Draft the issue bodies.** For **3+ chunks**, dispatch one drafting agent per
   chunk (via the `dispatching-parallel-agents` skill, single message) to write that
   chunk's issue description (problem, approach, code map, test list) from the epic
   spec, and **report the text back**. Agents draft only — they do **not** touch
   the tracker. For **≤2 chunks**, draft inline; don't spin up agents for that.

4. **File the batch (you, the parent, do every tracker write):**
   - Create the parent grouping (epic / parent / milestone) named for the goal,
     if the tracker supports one.
   - One work item per chunk: `project` = `project_code`; `state` = **Todo**;
     `labels` = `[project label id, type label id]`; `name` =
     conventional-commit-style summary; `description` = the drafted body plus a
     pointer to the epic spec section. Link each to the parent grouping.
   - Set **blocks / blocked-by** relations between chunks per the decomposition's
     dependency order (or, on a tracker without relations, leave the in-body
     blocker notes from the coordinates section).

5. **Report** the parent grouping and every issue identifier (e.g.
   `project_code-31 …`), the dependency graph (what blocks what, what's parallel),
   and tell the user to run **`/task-run`** next (or `/task-implement <ids>` to
   hand-pick).

## Guardrails

- **Specs/plans are local-only** (`docs/superpowers/` is gitignored). Never commit
  them; the issue description carries a pointer, nothing more.
- **One chunk ≈ one PR.** Bias toward several small, disjoint issues over one big
  one — that's what makes `/task-run`'s parallel batches possible.
- **The parent centralizes tracker writes.** Drafting agents return text only; you
  create the grouping, issues, and relations.
- **Don't write production code here** — `/issues-init` only plans and files.
- **If the tracker MCP server is unreachable**, say so and offer to proceed
  untracked: write the epic spec now and file the issues later.
