---
description: Cut a harness release — bump VERSION, roll CHANGELOG.md, commit, and tag (template repo only)
---

# /harness-release — cut a harness version

Runs **only in this template repo** (the upstream source of the harness), never
in a consumer. Bumps the version, rolls the changelog's **Unreleased** section
into a dated heading, commits, and tags `vX.Y.Z`.

Level (ask if empty): **$ARGUMENTS**

## Steps

1. **Preflight.** Confirm `## [Unreleased]` in `CHANGELOG.md` lists the changes
   you intend to ship, and that the tree is clean apart from `VERSION` /
   `CHANGELOG.md` — `bin/harness release` refuses on other uncommitted changes.
2. **Release.** Run `bin/harness release <level>` (`<level>` = `major`, `minor`,
   or `patch`).
3. **Report** the helper's output: the new `VERSION`, the new
   `## [<version>] - <date>` changelog heading, and the `v<version>` tag.
4. **Remind** the user this made a local commit + tag only — push with
   `git push && git push --tags` when ready; consumers then pick it up via
   `/harness-sync`.

## Guardrails

- **Template-only** — do not run in a consumer repo.
- Never pushes; leaves the commit and tag local for review.
- `bin/harness` owns the semver math and changelog roll — don't edit `VERSION`
  or the version headings by hand.
