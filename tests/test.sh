#!/usr/bin/env bash
# Self-contained test runner for bin/harness (no bats — not installed).
# Runs on macOS system bash 3.2 + BSD tools. Sources bin/harness to unit-test
# the pure helpers; uses temp git repos to test cmd_release.
#
# Each assertion is isolated: a single failure records a FAIL and keeps going.
# Exits non-zero if any assertion failed.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# Source the script under test. The guard in bin/harness prevents main from
# running on source.
. "$ROOT/bin/harness"

PASS=0
FAIL=0

TMPFILES=""
TMPDIRS=""
cleanup() {
  [ -n "$TMPFILES" ] && rm -f $TMPFILES
  [ -n "$TMPDIRS" ] && rm -rf $TMPDIRS
  return 0
}
trap cleanup EXIT

mktmp() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/harness-test.XXXXXX")
  TMPFILES="$TMPFILES $f"
  printf '%s' "$f"
}

mktmpdir() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/harness-test.XXXXXX")
  TMPDIRS="$TMPDIRS $d"
  printf '%s' "$d"
}

assert_eq() {
  # assert_eq "description" expected actual
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   - %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL - %s\n' "$desc"
    printf '         expected: [%s]\n' "$expected"
    printf '         actual:   [%s]\n' "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_ok() {
  # assert_ok "description" rc
  local desc="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    printf 'ok   - %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL - %s (expected rc 0, got %s)\n' "$desc" "$rc"
    FAIL=$((FAIL + 1))
  fi
}

assert_nonzero() {
  # assert_nonzero "description" rc
  local desc="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    printf 'ok   - %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL - %s (expected non-zero rc, got 0)\n' "$desc"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# semver_cmp
# ---------------------------------------------------------------------------
assert_eq "semver_cmp 1.2.3 1.2.4 -> -1" "-1" "$(semver_cmp 1.2.3 1.2.4)"
assert_eq "semver_cmp 1.2.3 1.2.3 ->  0" "0" "$(semver_cmp 1.2.3 1.2.3)"
assert_eq "semver_cmp 2.0.0 1.9.9 ->  1" "1" "$(semver_cmp 2.0.0 1.9.9)"
assert_eq "semver_cmp 0.10.0 0.9.0 -> 1 (numeric, not lexical)" "1" "$(semver_cmp 0.10.0 0.9.0)"
assert_eq "semver_cmp 1.0.0 1.0.10 -> -1 (numeric, not lexical)" "-1" "$(semver_cmp 1.0.0 1.0.10)"

# ---------------------------------------------------------------------------
# semver_bump
# ---------------------------------------------------------------------------
assert_eq "semver_bump 0.1.0 patch -> 0.1.1" "0.1.1" "$(semver_bump 0.1.0 patch)"
assert_eq "semver_bump 0.1.0 minor -> 0.2.0" "0.2.0" "$(semver_bump 0.1.0 minor)"
assert_eq "semver_bump 0.1.0 major -> 1.0.0" "1.0.0" "$(semver_bump 0.1.0 major)"
assert_eq "semver_bump 1.4.9 minor -> 1.5.0 (resets patch)" "1.5.0" "$(semver_bump 1.4.9 minor)"
assert_eq "semver_bump 3.7.2 major -> 4.0.0 (resets minor+patch)" "4.0.0" "$(semver_bump 3.7.2 major)"
semver_bump 1.0.0 bogus >/dev/null 2>&1
assert_nonzero "semver_bump with unknown level fails" "$?"

# ---------------------------------------------------------------------------
# manifest_tier / manifest_paths
# ---------------------------------------------------------------------------
MANIFEST=$(mktmp)
cat > "$MANIFEST" <<'EOF'
# harness manifest fixture
sync   HARNESS.md
sync   .opencode/commands/task-init.md

region AGENTS.md
region .gitignore

# trailing comment
ignore README.md
ignore VERSION
EOF

assert_eq "manifest_tier: sync path" "sync" "$(manifest_tier "$MANIFEST" HARNESS.md)"
assert_eq "manifest_tier: region path" "region" "$(manifest_tier "$MANIFEST" AGENTS.md)"
assert_eq "manifest_tier: listed ignore path" "ignore" "$(manifest_tier "$MANIFEST" README.md)"

t_out=$(manifest_tier "$MANIFEST" nope/not-listed.md)
t_rc=$?
assert_eq "manifest_tier: unlisted path prints nothing" "" "$t_out"
assert_nonzero "manifest_tier: unlisted path returns non-zero" "$t_rc"

MANIFEST_UNKNOWN_TIER=$(mktmp)
cat > "$MANIFEST_UNKNOWN_TIER" <<'EOF'
sync HARNESS.md
bogus some/path.md
EOF
manifest_tier "$MANIFEST_UNKNOWN_TIER" HARNESS.md >/dev/null 2>&1
assert_nonzero "manifest_tier: unknown tier is malformed -> non-zero" "$?"

MANIFEST_MISSING_PATH=$(mktmp)
cat > "$MANIFEST_MISSING_PATH" <<'EOF'
sync HARNESS.md
sync
EOF
manifest_tier "$MANIFEST_MISSING_PATH" HARNESS.md >/dev/null 2>&1
assert_nonzero "manifest_tier: line without a path -> non-zero" "$?"

exp_sync=$(printf '%s\n' 'HARNESS.md' '.opencode/commands/task-init.md')
assert_eq "manifest_paths sync" "$exp_sync" "$(manifest_paths "$MANIFEST" sync)"
exp_region=$(printf '%s\n' 'AGENTS.md' '.gitignore')
assert_eq "manifest_paths region" "$exp_region" "$(manifest_paths "$MANIFEST" region)"
exp_ignore=$(printf '%s\n' 'README.md' 'VERSION')
assert_eq "manifest_paths ignore" "$exp_ignore" "$(manifest_paths "$MANIFEST" ignore)"

# ---------------------------------------------------------------------------
# cmd_release (exercised against throwaway temp git repos)
# ---------------------------------------------------------------------------
setup_release_repo() {
  # Creates a clean git repo with VERSION=0.1.0, a Keep-a-Changelog CHANGELOG
  # with content under Unreleased, and an unrelated tracked file. Echoes path.
  local repo
  repo=$(mktmpdir)
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Harness Test"
  git -C "$repo" config commit.gpgsign false
  printf '0.1.0\n' > "$repo/VERSION"
  cat > "$repo/CHANGELOG.md" <<'EOF'
# Changelog

All notable changes to this harness are documented here.
The format is based on Keep a Changelog.

## [Unreleased]

- Added the widget.
- Fixed the doodad.
EOF
  printf 'unrelated tracked file\n' > "$repo/notes.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "init"
  printf '%s' "$repo"
}

# --- happy path: minor release ---
REPO=$(setup_release_repo)
(cd "$REPO" && HARNESS_RELEASE_DATE=2026-07-08 cmd_release minor) >/dev/null 2>&1
assert_ok "cmd_release minor exits 0" "$?"
assert_eq "cmd_release bumps VERSION 0.1.0 -> 0.2.0" "0.2.0" "$(cat "$REPO/VERSION")"

grep -q '^## \[0.2.0\] - 2026-07-08$' "$REPO/CHANGELOG.md"
assert_ok "changelog gains '## [0.2.0] - 2026-07-08' heading" "$?"
grep -q '^## \[Unreleased\]$' "$REPO/CHANGELOG.md"
assert_ok "changelog keeps '## [Unreleased]' heading" "$?"

uline=$(grep -n '^## \[Unreleased\]$' "$REPO/CHANGELOG.md" | head -1 | cut -d: -f1)
hline=$(grep -n '^## \[0.2.0\] - 2026-07-08$' "$REPO/CHANGELOG.md" | head -1 | cut -d: -f1)
cline=$(grep -n '^- Added the widget.$' "$REPO/CHANGELOG.md" | head -1 | cut -d: -f1)
if [ -n "$uline" ] && [ -n "$hline" ] && [ -n "$cline" ] && [ "$uline" -lt "$hline" ] && [ "$hline" -lt "$cline" ]; then
  release_order_ok=0
else
  release_order_ok=1
fi
assert_ok "prior Unreleased content now sits under the new version heading" "$release_order_ok"

assert_eq "release commit subject" "chore(harness): release v0.2.0" "$(git -C "$REPO" log -1 --pretty=%s)"
git -C "$REPO" rev-parse -q --verify refs/tags/v0.2.0 >/dev/null 2>&1
assert_ok "tag v0.2.0 created" "$?"
[ -z "$(git -C "$REPO" status --porcelain)" ]
assert_ok "working tree clean after release (VERSION+CHANGELOG committed)" "$?"

# --- refuses on a dirty unrelated tracked file ---
REPO2=$(setup_release_repo)
printf 'local edit\n' >> "$REPO2/notes.txt"
(cd "$REPO2" && HARNESS_RELEASE_DATE=2026-07-08 cmd_release patch) >/dev/null 2>&1
assert_nonzero "cmd_release refuses on dirty unrelated tracked file" "$?"
assert_eq "VERSION untouched after refusal" "0.1.0" "$(cat "$REPO2/VERSION")"
git -C "$REPO2" rev-parse -q --verify refs/tags/v0.1.1 >/dev/null 2>&1
assert_nonzero "no tag created on refusal" "$?"

# --- allowed: only VERSION/CHANGELOG dirty ---
REPO3=$(setup_release_repo)
printf '\n- Pending tweak.\n' >> "$REPO3/CHANGELOG.md"
(cd "$REPO3" && HARNESS_RELEASE_DATE=2026-07-08 cmd_release patch) >/dev/null 2>&1
assert_ok "cmd_release proceeds when only CHANGELOG is pre-dirty" "$?"
assert_eq "VERSION bumped 0.1.0 -> 0.1.1" "0.1.1" "$(cat "$REPO3/VERSION")"

# --- refuses to re-release an existing tag, leaving NO partial commit ---
REPO4=$(setup_release_repo)
git -C "$REPO4" tag v0.2.0                       # tag for the next minor already exists
before_head=$(git -C "$REPO4" rev-parse HEAD)
(cd "$REPO4" && HARNESS_RELEASE_DATE=2026-07-08 cmd_release minor) >/dev/null 2>&1
assert_nonzero "cmd_release refuses when tag v0.2.0 already exists" "$?"
assert_eq "VERSION untouched after tag-exists refusal" "0.1.0" "$(cat "$REPO4/VERSION")"
assert_eq "no partial release commit after tag-exists refusal" "$before_head" "$(git -C "$REPO4" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# The repo's real .opencode/harness-manifest is well-formed
# ---------------------------------------------------------------------------
REAL_MANIFEST="$ROOT/.opencode/harness-manifest"
manifest_paths "$REAL_MANIFEST" sync >/dev/null 2>&1
assert_ok "real manifest parses without error" "$?"
assert_eq "real manifest: bin/harness is sync" "sync" "$(manifest_tier "$REAL_MANIFEST" bin/harness)"
assert_eq "real manifest: AGENTS.md is region" "region" "$(manifest_tier "$REAL_MANIFEST" AGENTS.md)"
assert_eq "real manifest: README.md is ignore" "ignore" "$(manifest_tier "$REAL_MANIFEST" README.md)"
assert_eq "real manifest: harness-release.md is ignore" "ignore" "$(manifest_tier "$REAL_MANIFEST" .opencode/commands/harness-release.md)"
assert_eq "real manifest: tests/test.sh is sync" "sync" "$(manifest_tier "$REAL_MANIFEST" tests/test.sh)"
assert_eq "real manifest: harness-sync.md is sync" "sync" "$(manifest_tier "$REAL_MANIFEST" .opencode/commands/harness-sync.md)"
assert_eq "real manifest: harness.lock is ignore" "ignore" "$(manifest_tier "$REAL_MANIFEST" .opencode/harness.lock)"
assert_eq "real manifest: LICENSE is ignore" "ignore" "$(manifest_tier "$REAL_MANIFEST" LICENSE)"

# ---------------------------------------------------------------------------
# region_splice — replace only the marked block, preserve the rest
# ---------------------------------------------------------------------------
RB='<!-- HARNESS:BEGIN -->'
RE='<!-- HARNESS:END -->'

SPLICE_FILE=$(mktmp)
cat > "$SPLICE_FILE" <<EOF
project intro line
$RB
old harness line 1
old harness line 2
$RE
project outro line
EOF

NEWC=$(mktmp)
cat > "$NEWC" <<'EOF'
new harness line A
new harness line B
EOF

region_splice "$SPLICE_FILE" "$RB" "$RE" "$NEWC"
assert_ok "region_splice exits 0 on a well-formed file" "$?"
grep -q '^project intro line$' "$SPLICE_FILE"
assert_ok "region_splice preserves text before the block" "$?"
grep -q '^project outro line$' "$SPLICE_FILE"
assert_ok "region_splice preserves text after the block" "$?"
grep -q '^new harness line B$' "$SPLICE_FILE"
assert_ok "region_splice inserts the new content" "$?"
grep -q 'old harness line' "$SPLICE_FILE"
assert_nonzero "region_splice drops the old block content" "$?"
assert_eq "region_splice keeps exactly one BEGIN marker" "1" "$(grep -cxF "$RB" "$SPLICE_FILE")"
assert_eq "region_splice keeps exactly one END marker" "1" "$(grep -cxF "$RE" "$SPLICE_FILE")"

# --- error: markers missing, file untouched ---
NOMARK=$(mktmp)
printf 'just a normal file\nno markers here\n' > "$NOMARK"
NOMARK_BEFORE=$(cat "$NOMARK")
region_splice "$NOMARK" "$RB" "$RE" "$NEWC" >/dev/null 2>&1
assert_nonzero "region_splice fails when markers are missing" "$?"
assert_eq "region_splice leaves file unchanged when markers missing" "$NOMARK_BEFORE" "$(cat "$NOMARK")"

# --- error: unbalanced (BEGIN without END), file untouched ---
UNBAL=$(mktmp)
printf 'intro\n%s\nblock\n' "$RB" > "$UNBAL"
UNBAL_BEFORE=$(cat "$UNBAL")
region_splice "$UNBAL" "$RB" "$RE" "$NEWC" >/dev/null 2>&1
assert_nonzero "region_splice fails when END marker is missing (unbalanced)" "$?"
assert_eq "region_splice leaves file unchanged when unbalanced" "$UNBAL_BEFORE" "$(cat "$UNBAL")"

# ---------------------------------------------------------------------------
# lock_read / lock_write — consumer-side synced state round-trip
# ---------------------------------------------------------------------------
LOCK=$(mktmp)
lock_write "$LOCK" 0.3.0 abc123def harness
assert_ok "lock_write exits 0" "$?"
assert_eq "lock round-trip: version" "0.3.0" "$(lock_read "$LOCK" version)"
assert_eq "lock round-trip: commit" "abc123def" "$(lock_read "$LOCK" commit)"
assert_eq "lock round-trip: remote" "harness" "$(lock_read "$LOCK" remote)"

lock_read "$LOCK" nope >/dev/null 2>&1
assert_nonzero "lock_read on an absent key returns non-zero" "$?"
lock_read "${LOCK}.does-not-exist" version >/dev/null 2>&1
assert_nonzero "lock_read on a missing file returns non-zero" "$?"

# ---------------------------------------------------------------------------
# _max_semver — highest X.Y.Z from stdin, ignoring non-semver lines
# ---------------------------------------------------------------------------
assert_eq "_max_semver picks the highest (numeric, not lexical)" "0.10.0" \
  "$(printf '0.2.0\n0.10.0\n0.9.0\n' | _max_semver)"
assert_eq "_max_semver ignores non-semver lines" "1.0.0" \
  "$(printf 'garbage\nv1.0.0\n1.0.0\n0.9.9\n' | _max_semver)"
assert_eq "_max_semver with a single version" "2.3.4" "$(printf '2.3.4\n' | _max_semver)"
printf 'nope\n\n' | _max_semver >/dev/null 2>&1
assert_nonzero "_max_semver fails when no valid version present" "$?"

# ---------------------------------------------------------------------------
# region_extract — the lines strictly between the markers (exclusive)
# ---------------------------------------------------------------------------
EXTRACT_FILE=$(mktmp)
cat > "$EXTRACT_FILE" <<EOF
before
$RB
line one
line two
$RE
after
EOF
exp_block=$(printf '%s\n' 'line one' 'line two')
assert_eq "region_extract returns only the block content" "$exp_block" \
  "$(region_extract "$EXTRACT_FILE" "$RB" "$RE")"

# ---------------------------------------------------------------------------
# cmd_sync_plan / cmd_sync_pull (exercised against fixture upstream+consumer)
# ---------------------------------------------------------------------------
# Builds an "upstream" (template) repo tagged v0.2.0 and a "consumer" repo that
# has the upstream added as remote 'harness', older managed files, and a lock at
# 0.1.0. Echoes "<upstream>|<consumer>".
setup_sync_fixture() {
  local up con
  up=$(mktmpdir)
  con=$(mktmpdir)

  git -C "$up" init -q
  git -C "$up" config user.email t@e.com
  git -C "$up" config user.name T
  git -C "$up" config commit.gpgsign false
  mkdir -p "$up/.opencode"
  cat > "$up/.opencode/harness-manifest" <<'EOF'
sync   HARNESS.md
region AGENTS.md
ignore README.md
EOF
  printf 'UPSTREAM HARNESS v0.2.0\n' > "$up/HARNESS.md"
  cat > "$up/AGENTS.md" <<EOF
# upstream heading (not synced)
$RB
upstream managed block v0.2.0
$RE
EOF
  printf '0.2.0\n' > "$up/VERSION"
  git -C "$up" add -A
  git -C "$up" commit -q -m "upstream v0.2.0"
  git -C "$up" tag v0.2.0

  git -C "$con" init -q
  git -C "$con" config user.email t@e.com
  git -C "$con" config user.name T
  git -C "$con" config commit.gpgsign false
  git -C "$con" remote add harness "$up"
  mkdir -p "$con/.opencode"
  printf 'sync HARNESS.md\n' > "$con/.opencode/harness-manifest"
  printf 'old consumer harness\n' > "$con/HARNESS.md"
  cat > "$con/AGENTS.md" <<EOF
# My Project
project-owned intro line
$RB
stale managed block
$RE
project-owned outro line
EOF
  lock_write "$con/.opencode/harness.lock" 0.1.0 deadbeef harness
  git -C "$con" add -A
  git -C "$con" commit -q -m "consumer baseline"

  printf '%s|%s' "$up" "$con"
}

# --- sync plan: dry run, reports overwrites/splices/version delta, no writes ---
FIX=$(setup_sync_fixture)
CON=${FIX#*|}
plan_out=$( (cd "$CON" && cmd_sync_plan) 2>&1 )
assert_ok "cmd_sync_plan exits 0" "$?"
printf '%s\n' "$plan_out" | grep -q '0.1.0 -> 0.2.0'
assert_ok "sync plan reports the version delta 0.1.0 -> 0.2.0" "$?"
printf '%s\n' "$plan_out" | grep -Eq '^overwrite[[:space:]]+HARNESS.md$'
assert_ok "sync plan lists HARNESS.md as an overwrite" "$?"
printf '%s\n' "$plan_out" | grep -Eq '^splice[[:space:]]+AGENTS.md$'
assert_ok "sync plan lists AGENTS.md as a splice" "$?"
assert_eq "sync plan writes nothing (clean tree)" "" "$(git -C "$CON" status --porcelain)"
assert_eq "sync plan leaves HARNESS.md untouched" "old consumer harness" "$(cat "$CON/HARNESS.md")"

# --- sync pull: applies overwrites + splices, writes lock, preserves project text ---
FIX2=$(setup_sync_fixture)
UP2=${FIX2%%|*}
CON2=${FIX2#*|}
(cd "$CON2" && cmd_sync_pull) >/dev/null 2>&1
assert_ok "cmd_sync_pull exits 0" "$?"
assert_eq "pull overwrites the sync file from upstream" "UPSTREAM HARNESS v0.2.0" "$(cat "$CON2/HARNESS.md")"
grep -q '^upstream managed block v0.2.0$' "$CON2/AGENTS.md"
assert_ok "pull splices the upstream managed block into AGENTS.md" "$?"
grep -q '^project-owned intro line$' "$CON2/AGENTS.md"
assert_ok "pull preserves the project-owned line before the region" "$?"
grep -q '^project-owned outro line$' "$CON2/AGENTS.md"
assert_ok "pull preserves the project-owned line after the region" "$?"
grep -q 'stale managed block' "$CON2/AGENTS.md"
assert_nonzero "pull replaces the stale managed block" "$?"
assert_eq "pull updates the lock version" "0.2.0" "$(lock_read "$CON2/.opencode/harness.lock" version)"
assert_eq "pull records the upstream tag commit in the lock" \
  "$(git -C "$UP2" rev-parse v0.2.0^{commit})" "$(lock_read "$CON2/.opencode/harness.lock" commit)"

# --- sync pull refuses on a dirty tree ---
FIX3=$(setup_sync_fixture)
CON3=${FIX3#*|}
printf 'uncommitted edit\n' >> "$CON3/HARNESS.md"
(cd "$CON3" && cmd_sync_pull) >/dev/null 2>&1
assert_nonzero "cmd_sync_pull refuses on a dirty tree" "$?"

# --- sync pull must not truncate a local file when its sync path is absent at
#     the tag (a malformed tag/manifest must not cause silent data loss) ---
GUP=$(mktmpdir)
GCON=$(mktmpdir)
git -C "$GUP" init -q
git -C "$GUP" config user.email t@e.com
git -C "$GUP" config user.name T
git -C "$GUP" config commit.gpgsign false
mkdir -p "$GUP/.opencode"
cat > "$GUP/.opencode/harness-manifest" <<'EOF'
sync HARNESS.md
sync GHOST.md
EOF
printf 'UPSTREAM HARNESS\n' > "$GUP/HARNESS.md"   # GHOST.md deliberately absent
git -C "$GUP" add -A
git -C "$GUP" commit -q -m up
git -C "$GUP" tag v0.2.0

git -C "$GCON" init -q
git -C "$GCON" config user.email t@e.com
git -C "$GCON" config user.name T
git -C "$GCON" config commit.gpgsign false
git -C "$GCON" remote add harness "$GUP"
mkdir -p "$GCON/.opencode"
printf 'sync HARNESS.md\n' > "$GCON/.opencode/harness-manifest"
printf 'old harness\n' > "$GCON/HARNESS.md"
printf 'PRECIOUS local content\n' > "$GCON/GHOST.md"
git -C "$GCON" add -A
git -C "$GCON" commit -q -m con

(cd "$GCON" && cmd_sync_pull) >/dev/null 2>&1
assert_eq "pull overwrites the present sync file" "UPSTREAM HARNESS" "$(cat "$GCON/HARNESS.md")"
assert_eq "pull preserves a local file when its sync path is missing at the tag" \
  "PRECIOUS local content" "$(cat "$GCON/GHOST.md")"

# --- sync keeps a locally-modified sync file, overwrites an unmodified one -----
# Upstream carries two sync files across two versions; the consumer's lock points
# at the v0.1.0 baseline, with one file locally edited and one untouched.
MUP=$(mktmpdir)
MCON=$(mktmpdir)
git -C "$MUP" init -q
git -C "$MUP" config user.email t@e.com
git -C "$MUP" config user.name T
git -C "$MUP" config commit.gpgsign false
mkdir -p "$MUP/.opencode"
printf 'sync HARNESS.md\nsync KEEPME.md\n' > "$MUP/.opencode/harness-manifest"
printf 'harness v1\n' > "$MUP/HARNESS.md"
printf 'base\n' > "$MUP/KEEPME.md"
git -C "$MUP" add -A
git -C "$MUP" commit -q -m v1
git -C "$MUP" tag v0.1.0
MBASE=$(git -C "$MUP" rev-parse v0.1.0^{commit})
printf 'harness v2\n' > "$MUP/HARNESS.md"
printf 'base2\n' > "$MUP/KEEPME.md"
git -C "$MUP" add -A
git -C "$MUP" commit -q -m v2
git -C "$MUP" tag v0.2.0

git -C "$MCON" init -q
git -C "$MCON" config user.email t@e.com
git -C "$MCON" config user.name T
git -C "$MCON" config commit.gpgsign false
git -C "$MCON" remote add harness "$MUP"
mkdir -p "$MCON/.opencode"
printf 'sync HARNESS.md\nsync KEEPME.md\n' > "$MCON/.opencode/harness-manifest"
printf 'harness v1 LOCALLY EDITED\n' > "$MCON/HARNESS.md"   # customized since baseline
printf 'base\n' > "$MCON/KEEPME.md"                          # untouched since baseline
lock_write "$MCON/.opencode/harness.lock" 0.1.0 "$MBASE" harness
git -C "$MCON" add -A
git -C "$MCON" commit -q -m con

# plan annotates keep vs overwrite (baseline still v0.1.0)
mplan=$( (cd "$MCON" && cmd_sync_plan) 2>&1 )
printf '%s\n' "$mplan" | grep -Eq '^keep[[:space:]]+HARNESS.md \(locally modified\)$'
assert_ok "sync plan marks a locally-modified sync file as keep" "$?"
printf '%s\n' "$mplan" | grep -Eq '^overwrite[[:space:]]+KEEPME.md$'
assert_ok "sync plan marks an unmodified sync file as overwrite" "$?"

# pull keeps the modified file, overwrites the untouched one, advances the lock
(cd "$MCON" && cmd_sync_pull) >/dev/null 2>&1
assert_ok "cmd_sync_pull (keep-modified) exits 0" "$?"
assert_eq "pull keeps a locally-modified sync file" "harness v1 LOCALLY EDITED" "$(cat "$MCON/HARNESS.md")"
assert_eq "pull overwrites an unmodified sync file" "base2" "$(cat "$MCON/KEEPME.md")"
assert_eq "pull advances the lock even when a file was kept" "0.2.0" "$(lock_read "$MCON/.opencode/harness.lock" version)"

# ---------------------------------------------------------------------------
# cmd_sync_push — branch + commit managed diffs, hand off to gh (seam stubbed)
# ---------------------------------------------------------------------------
# _open_pr, when gh is unavailable, prints the manual command and still succeeds.
op_out=$(HARNESS_ASSUME_NO_GH=1 _open_pr /some/root harness-sync/x 2>&1)
assert_ok "_open_pr returns 0 when gh is unavailable" "$?"
printf '%s\n' "$op_out" | grep -q 'gh pr create'
assert_ok "_open_pr prints the manual gh command when gh is unavailable" "$?"

setup_push_repo() {
  local con
  con=$(mktmpdir)
  git -C "$con" init -q
  git -C "$con" config user.email t@e.com
  git -C "$con" config user.name T
  git -C "$con" config commit.gpgsign false
  mkdir -p "$con/.opencode"
  cat > "$con/.opencode/harness-manifest" <<'EOF'
sync   HARNESS.md
ignore README.md
EOF
  printf 'harness content\n' > "$con/HARNESS.md"
  printf 'project readme\n' > "$con/README.md"
  git -C "$con" add -A
  git -C "$con" commit -q -m "baseline"
  printf '%s' "$con"
}

# --- happy path: managed change → branch + commit + PR seam invoked ---
PUSH=$(setup_push_repo)
printf 'local harness improvement\n' >> "$PUSH/HARNESS.md"
printf 'local readme edit\n' >> "$PUSH/README.md"
PR_MARKER=$(mktmp)
_open_pr() { printf 'opened:%s' "$2" > "$PR_MARKER"; }   # stub the gh boundary
(cd "$PUSH" && cmd_sync_push my-topic) >/dev/null 2>&1
assert_ok "cmd_sync_push exits 0 with a managed change" "$?"
assert_eq "push checks out branch harness-sync/my-topic" "harness-sync/my-topic" \
  "$(git -C "$PUSH" rev-parse --abbrev-ref HEAD)"
assert_eq "push commit subject" "chore(harness): sync push — my-topic" \
  "$(git -C "$PUSH" log -1 --pretty=%s)"
git -C "$PUSH" show HEAD:HARNESS.md | grep -q 'local harness improvement'
assert_ok "push commits the managed file change" "$?"
git -C "$PUSH" status --porcelain | grep -q 'README.md'
assert_ok "push leaves the unmanaged file uncommitted" "$?"
assert_eq "push invokes PR creation with the branch" "opened:harness-sync/my-topic" "$(cat "$PR_MARKER")"

# --- no managed change → refuse, no branch created ---
PUSH2=$(setup_push_repo)
printf 'only an unmanaged edit\n' >> "$PUSH2/README.md"
_open_pr() { :; }
(cd "$PUSH2" && cmd_sync_push empty-topic) >/dev/null 2>&1
assert_nonzero "cmd_sync_push refuses when no managed file changed" "$?"
push2_branch=$(git -C "$PUSH2" rev-parse --abbrev-ref HEAD)
if [ "$push2_branch" = "harness-sync/empty-topic" ]; then push2_branched=yes; else push2_branched=no; fi
assert_eq "push does not create a branch when there is nothing to push" "no" "$push2_branched"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed (%s total)\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
