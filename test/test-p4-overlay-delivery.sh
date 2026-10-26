#!/usr/bin/env bash
# P4 L02: overlay paths never cross the isolated-session delivery boundary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$TMP/runtime"
ISOLATION="$TMP/runtime/share/harness-launcher/session-isolation.sh"
trap 'rm -rf "$TMP"' EXIT
SOURCE="$TMP/source" STATE="$TMP/state" REMOTE="$TMP/remote.git"
mkdir -p "$SOURCE" "$STATE"
git -C "$SOURCE" init -q -b main
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name test
printf base > "$SOURCE/ordinary.txt"
git -C "$SOURCE" add ordinary.txt
git -C "$SOURCE" commit -qm base
git init --bare -q "$REMOTE"
git -C "$SOURCE" remote add origin "$REMOTE"
git -C "$SOURCE" push -q -u origin main

create() { HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" create "$SOURCE"; }
session_root() { sed -n 's/^HARNESS_SESSION_ROOT=//p'; }
session_id() { sed -n 's/^HARNESS_SESSION_ID=//p'; }

# test_six_chokes_exclude_overlay_and_harness
created="$(create)"; root="$(printf '%s\n' "$created" | session_root)"; id="$(printf '%s\n' "$created" | session_id)"
printf 'overlay/deep/path\0' > "$STATE/sessions/$id/overlay-paths"
mkdir -p "$root/overlay/deep/path" "$root/.harness/codex"
printf overlay > "$root/overlay/deep/path/a.txt"
printf generated > "$root/.harness/codex/AGENTS.md"
printf delivered > "$root/delivered.txt"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$id"
git apply --check "$STATE/sessions/$id/submission.patch"
grep -aq 'delivered.txt' "$STATE/sessions/$id/submission.patch" || { echo 'FAIL: ordinary path missing from submission'; exit 1; }
if grep -aEq '^\+\+\+ b/(overlay/|\.harness/)' "$STATE/sessions/$id/submission.patch"; then
  echo 'FAIL: overlay or generated harness output entered submission'; exit 1
fi
if tr '\0' '\n' < "$STATE/sessions/$id/manifest" | grep -qE 'overlay/|\.harness/'; then
  echo 'FAIL: overlay or generated harness output entered manifest'; exit 1
fi

# test_commit_a_add_A_and_gitignore_negation_cannot_deliver
created="$(create)"; root="$(printf '%s\n' "$created" | session_root)"; id="$(printf '%s\n' "$created" | session_id)"
printf 'Overlay\0' > "$STATE/sessions/$id/overlay-paths"
mkdir -p "$root/Overlay" "$root/.harness"
printf '!Overlay/**\n!.harness/**\n' > "$root/.gitignore"
printf overlay > "$root/Overlay/forced.txt"; printf generated > "$root/.harness/forced.txt"
printf normal > "$root/normal.txt"
git -C "$root" add -Af .
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$id"
if grep -aEq '^\+\+\+ b/(Overlay/|\.harness/)' "$STATE/sessions/$id/submission.patch"; then
  echo 'FAIL: add -A or gitignore negation delivered protected output'; exit 1
fi
grep -aq normal.txt "$STATE/sessions/$id/submission.patch" || { echo 'FAIL: non-overlay add must remain deliverable'; exit 1; }

# test_large_patch_and_names_match_small_pathspec
created="$(create)"; root="$(printf '%s\n' "$created" | session_root)"; id="$(printf '%s\n' "$created" | session_id)"
for number in $(seq 0 4096); do printf 'overlay/%s\0' "$number"; done > "$STATE/sessions/$id/overlay-paths"
mkdir -p "$root/overlay"; printf protected > "$root/overlay/0"; printf normal > "$root/overlimit-normal.txt"
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$id"
grep -aq overlimit-normal.txt "$STATE/sessions/$id/submission.patch" || { echo 'FAIL: over-limit fallback lost non-overlay change'; exit 1; }
if grep -aEq '^\+\+\+ b/overlay/' "$STATE/sessions/$id/submission.patch"; then echo 'FAIL: over-limit fallback delivered overlay'; exit 1; fi

# test_casefold_and_deep_sibling_contract_is_exercised_by_the_helper
python3 "$ROOT/test/test_harness_overlay_paths.py" >/dev/null

# test_nonoverlay_edit_and_rename_still_delivered
created="$(create)"; root="$(printf '%s\n' "$created" | session_root)"; id="$(printf '%s\n' "$created" | session_id)"
printf 'overlay\0' > "$STATE/sessions/$id/overlay-paths"
printf changed > "$root/ordinary.txt"
git -C "$root" mv ordinary.txt renamed.txt
HARNESS_SESSION_STATE_HOME="$STATE" "$ISOLATION" submit "$id"
grep -aq renamed.txt "$STATE/sessions/$id/submission.patch" || { echo 'FAIL: non-overlay rename must remain deliverable'; exit 1; }

echo 'p4-overlay-delivery: all tests passed'
