---
description: Sync the harness with its upstream template — pull updates in, or push local harness changes back as a PR
---

# /harness-sync — keep this repo's harness in step with the template

Runs **in a consumer** repo (one that adopted this harness). Talks to the
upstream template through a git remote named `harness` (versions are its
`vX.Y.Z` tags) and drives `bin/harness sync`. All the risky mechanics —
resolving the latest tag, overwriting `sync`-tier files, splicing only the
marked block of `region`-tier files, writing `.opencode/harness.lock` — live in
`bin/harness` and are unit-tested; this command just orchestrates and shows you
the plan first.

Direction (ask if empty): **$ARGUMENTS**

## One-time setup

The consumer needs the template added as a remote named `harness`:

```bash
git remote add harness <template-repo-url>
```

`bin/harness sync` will tell you this (with the exact command) if the remote is
missing.

## Pull (template → this repo)

1. **Plan first.** Run `bin/harness sync plan`. It fetches the template's tags
   into a private ref namespace (never touching your own tags), reads the
   manifest at the latest version, and prints the version delta plus every
   `overwrite` (a `sync`-tier file replaced wholesale), `keep` (a `sync` file you
   customized since the last sync — diffed against the locked baseline commit and
   left untouched), and `splice` (a `region` file where only the
   `HARNESS:BEGIN…END` block changes). **Nothing is written.**
2. **Show the user the plan** and confirm before applying.
3. **Apply.** On approval run `bin/harness sync pull`. It refuses on a dirty
   tree — commit or stash first. It overwrites the untouched `sync` files, **keeps**
   any `sync` file you customized since the last sync (so local work is never
   clobbered), splices the `region` blocks (your project content outside the
   markers is preserved), and rewrites `.opencode/harness.lock` with the new
   `version` / `commit` / `remote`.
4. **Review the diff** (`git diff`), run the repo's tests, then commit —
   e.g. `chore(harness): sync to v<version>`. The lock file records what you're on.

## Push (this repo → template, as a PR)

Use when you've improved a `sync`/`region` file locally and want it upstream.

1. Run `bin/harness sync push <topic>`. It checks that a managed file actually
   changed, creates branch `harness-sync/<topic>`, commits **only** the managed
   files, and hands off to `gh pr create --repo <template>`.
2. If `gh` isn't installed it prints the exact `git push` + `gh pr create`
   commands to run by hand — the branch and commit already exist.
3. **Report** the branch name and PR URL (or the manual commands).

## Guardrails

- **Consumer-only for pull/push**; the template itself cuts versions with
  `/harness-release`.
- **Always `plan` before `pull`** and show the user — `pull` overwrites managed
  files.
- **Region files keep project content** outside the `HARNESS:BEGIN…END` markers;
  never hand-edit inside those markers (a pull will replace it).
- `.opencode/harness.lock` is the consumer's synced-state record — commit it.
- `bin/harness` owns the mechanics; don't reimplement sync logic in this command.
