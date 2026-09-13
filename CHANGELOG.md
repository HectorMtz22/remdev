# Changelog

All notable changes to the OpenCode harness template are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut with `/harness-release` (`bin/harness release <level>`), which
rolls the **Unreleased** section below into a dated version heading and tags
`vX.Y.Z`. Add your in-flight changes under **Unreleased**.

## [Unreleased]

## [0.3.0] - 2026-08-28

### Changed

- Ported the harness to OpenCode: commands now live in `.opencode/commands/`,
  rules consolidate into a single `AGENTS.md` (region-tier), MCP tools are
  referenced as `<prefix>_<resource>` + `action`, superpowers skills are invoked
  via the `skill` tool, and `opencode.jsonc` declares the plugin + tracker MCP
  server. `bin/harness` and the sync mechanics are unchanged, re-pointed at the
  `.opencode/` layout (upstream repo is now `HectorMtz22/opencode-harness-template`).
- `sync pull` no longer clobbers harness files a consumer has customized: each
  `sync`-tier file is diffed against the locked baseline commit and **kept** when
  it was modified locally (only untouched files are overwritten). `sync plan`
  labels these `keep … (locally modified)` instead of `overwrite`. A repo with no
  lock yet (first sync) has no baseline, so overwrite stays the default there.

## [0.2.0] - 2026-07-10

### Added

- `/harness-sync` and `bin/harness sync plan|pull|push`: keep a consumer's copy
  of the harness in step with this template over a git remote named `harness`.
  `pull` overwrites `sync`-tier files from the latest `vX.Y.Z` tag and splices
  only the `HARNESS:BEGIN…END` block of `region`-tier files (preserving project
  content); `push` branches, commits the managed files, and opens a PR upstream.
- `.opencode/harness.lock` recording a consumer's synced `version`/`commit`/`remote`.
- Region markers around the harness-managed blocks of `AGENTS.md` and
  `.gitignore`, plus `harness-sync.md` added to the manifest (`sync` tier).
- Tested helpers behind sync: `region_splice`/`region_extract`, lock read/write,
  and latest-tag resolution (fetched into a private `refs/harness-remote/*`
  namespace so consumer tags never collide).

## [0.1.0] - 2026-07-08

### Added

- Harness versioning: a `VERSION` file, this `CHANGELOG.md`, and a
  `/harness-release` command backed by a tested `bin/harness` helper
  (semver bump, changelog roll, `git commit` + `git tag vX.Y.Z`).
- `.opencode/harness-manifest` classifying every harness path as `sync`,
  `region`, or `ignore` — the basis for a future `/harness-sync`.
- `tests/test.sh`, the repo's first test harness (self-contained, no bats).
- Planning and building commands: `/task-init`, `/issues-init`,
  `/task-implement`, `/task-run`, plus tracker setup via `/harness-setup`
  and `/harness-bootstrap`.
