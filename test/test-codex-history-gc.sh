#!/usr/bin/env bash
# Real GC must not erase unsupported Native artifacts or an unverified old tomb.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SOURCE="$TMP/source"; STATE="$TMP/state"
cleanup() {
  local path
  for path in "$STATE/worktrees"/* "$STATE/worktrees"/.retired-* "$STATE/worktrees"/.archiving-*; do
    [[ -e "$path" ]] || continue
    chmod u+rwx "$path" "$path/.harness" "$path/.harness/codex" 2>/dev/null || true
  done
  chmod -R u+rwx "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$SOURCE/config"
git -C "$SOURCE" init -q -b main
git -C "$SOURCE" config user.email test@example.invalid
git -C "$SOURCE" config user.name test
printf '%s\n' 'HARNESS_NAME="test"' 'HARNESS_PREFIX="test"' > "$SOURCE/config/launcher.env"
git -C "$SOURCE" add config/launcher.env
git -C "$SOURCE" commit -qm fixture
out="$(HARNESS_SESSION_STATE_HOME="$STATE" "$ROOT/bin/session-isolation.sh" create "$SOURCE")"
id="$(printf '%s\n' "$out" | sed -n 's/^HARNESS_SESSION_ID=//p')"
work="$(printf '%s\n' "$out" | sed -n 's/^HARNESS_SESSION_ROOT=//p')"
mkdir -p "$work/.harness/codex/sessions/2026/10/10"
printf '%s\n' 'retained native conversation sentinel' > "$work/.harness/codex/sessions/2026/10/10/rollout-sentinel.jsonl"
printf '%s\n' 'unknown must hold retirement' > "$work/.harness/codex/future-native-format.bin"
HARNESS_SESSION_STATE_HOME="$STATE" "$ROOT/bin/session-isolation.sh" transition "$id" CLOSED
HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_RETENTION_SECONDS=0 "$ROOT/bin/session-isolation.sh" gc
[[ -f "$work/.harness/codex/future-native-format.bin" ]] || { echo 'FAIL: GC erased Native history before verified archive/restore'; exit 1; }
tomb="$STATE/worktrees/.retired-22222222-2222-4222-8222-222222222222-42"
mkdir -p "$tomb/.harness/codex/sessions"
printf '%s\n' 'unverified recovery sentinel' > "$tomb/.harness/codex/sessions/native.jsonl"
HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_RETENTION_SECONDS=0 "$ROOT/bin/session-isolation.sh" gc
[[ -f "$tomb/.harness/codex/sessions/native.jsonl" ]] || { echo 'FAIL: GC deleted an unverified old tomb'; exit 1; }

# Unreadable Native ancestors are a HOLD, not evidence that Native is absent.
# Restore permissions in every branch so the fixture cleanup itself remains safe.
for denied in "$work" "$work/.harness" "$work/.harness/codex"; do
  record="$STATE/sessions/$id"
  record_before="$(shasum -a 256 "$record/source-root" "$record/session-root" "$record/root-inode" "$record/journal" | shasum -a 256 | awk '{print $1}')"
  root_inode_before="$(stat -f '%d %i' "$work")"
  gitfile_before="$(git -C "$work" rev-parse HEAD):$(git -C "$work" config --get remote.origin.url || true)"
  git_metadata_before="$(shasum -a 256 "$work/.git/HEAD" "$work/.git/config" | shasum -a 256 | awk '{print $1}')"
  native_before="$(shasum -a 256 "$work/.harness/codex/future-native-format.bin" | awk '{print $1}')"
  tombs_before="$(find "$STATE/worktrees" -maxdepth 1 \( -name ".retired-$id-*" -o -name ".archiving-$id-*" \) -print | wc -l | tr -d ' ')"
  chmod 000 "$denied"
  HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_RETENTION_SECONDS=0 "$ROOT/bin/session-isolation.sh" gc || true
  chmod u+rwx "$denied" 2>/dev/null || true
  [[ -d "$work" && -f "$work/.harness/codex/future-native-format.bin" ]] || { echo "FAIL: GC retired unreadable Native ancestor $denied"; exit 1; }
  tombs_after="$(find "$STATE/worktrees" -maxdepth 1 \( -name ".retired-$id-*" -o -name ".archiving-$id-*" \) -print | wc -l | tr -d ' ')"
  [[ "$tombs_after" == "$tombs_before" ]] || { echo "FAIL: GC staged unreadable Native root $denied"; exit 1; }
  [[ "$(stat -f '%d %i' "$work")" == "$root_inode_before" ]] || { echo "FAIL: GC changed unreadable root inode $denied"; exit 1; }
  [[ "$(git -C "$work" rev-parse HEAD):$(git -C "$work" config --get remote.origin.url || true)" == "$gitfile_before" ]] || { echo "FAIL: GC rewrote Git binding while Native was unreadable"; exit 1; }
  [[ "$(shasum -a 256 "$work/.git/HEAD" "$work/.git/config" | shasum -a 256 | awk '{print $1}')" == "$git_metadata_before" ]] || { echo "FAIL: GC rewrote Git metadata while Native was unreadable"; exit 1; }
  [[ "$(shasum -a 256 "$work/.harness/codex/future-native-format.bin" | awk '{print $1}')" == "$native_before" ]] || { echo "FAIL: GC rewrote unreadable Native bytes"; exit 1; }
  record_after="$(shasum -a 256 "$record/source-root" "$record/session-root" "$record/root-inode" "$record/journal" | shasum -a 256 | awk '{print $1}')"
  [[ "$record_after" == "$record_before" ]] || { echo "FAIL: GC rewrote record while Native ancestor was unreadable"; exit 1; }
  [[ ! -d "$STATE/native-history/snapshots" ]] || { echo "FAIL: GC archived unreadable Native ancestor $denied"; exit 1; }
done

locked_tomb="$STATE/worktrees/.retired-33333333-3333-4333-8333-333333333333-77"
mkdir -p "$locked_tomb/.harness/codex/sessions"
printf '%s\n' 'unreadable tomb native sentinel' > "$locked_tomb/.harness/codex/sessions/native.jsonl"
mkdir -p "$locked_tomb/.git"
printf '%s\n' 'tomb git metadata sentinel' > "$locked_tomb/.git/config"
locked_before="$(find "$locked_tomb" -type f -exec shasum -a 256 {} + | shasum -a 256 | awk '{print $1}')"
locked_inode_before="$(stat -f '%d %i' "$locked_tomb")"
chmod 000 "$locked_tomb/.harness"
HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_RETENTION_SECONDS=0 "$ROOT/bin/session-isolation.sh" gc || true
chmod u+rwx "$locked_tomb/.harness"
[[ -f "$locked_tomb/.harness/codex/sessions/native.jsonl" ]] || { echo 'FAIL: GC deleted tomb whose Native ancestor was unreadable'; exit 1; }
[[ "$(stat -f '%d %i' "$locked_tomb")" == "$locked_inode_before" ]] || { echo 'FAIL: GC changed unreadable tomb inode'; exit 1; }
[[ "$(find "$locked_tomb" -type f -exec shasum -a 256 {} + | shasum -a 256 | awk '{print $1}')" == "$locked_before" ]] || { echo 'FAIL: GC changed unreadable tomb tree'; exit 1; }
echo 'PASS: unknown Native data and unverified old tomb retained by real GC'
