#!/usr/bin/env bash
# test-launch-record.sh — harness-launch-record (SessionStart hook) writes the
# launcher-owned launch record; `harness-launch-record read` reads it back.
# The record is the only source of a restored permission/sandbox grant.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bin/harness-common.sh"
PY="$(harness_python3_resolve)" || exit 1
WRITER="$ROOT/bin/harness-launch-record"
TMP="$(mktemp -d)"
trap 'find "$TMP" -delete' EXIT
STATE="$TMP/state"
SID=0CB4A1F2-1111-4222-8333-444455556666
CID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
XID=019a0ef5-0000-7852-afb3-a6b6559f47b6
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$WRITER" ]] || fail 'writer command is missing'

# rec <agent> <json> [ENV=val ...] : sets OUT and RC
rec() {
  local agent="$1" json="$2"; shift 2
  OUT="$(printf '%s' "$json" | env -i HOME="$HOME" PATH="$PATH" HARNESS_SESSION_STATE_HOME="$STATE" "$@" "$PY" "$WRITER" "$agent" 2>&1)"
  RC=$?
}
event() { printf '{"hook_event_name":"%s","source":"%s","session_id":"%s"}' "$1" "$2" "$3"; }
read_rec() { OUT="$(HARNESS_SESSION_STATE_HOME="$STATE" "$PY" "$WRITER" read "$1" "$2" 2>&1)"; RC=$?; }
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

# --- Claude record ------------------------------------------------------------
rec claude "$(event SessionStart startup $CID)" HARNESS_LAUNCH_PERMISSION=bypassPermissions \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0 HARNESS_SESSION_ID=
[[ $RC == 0 && -z "$OUT" ]] || fail "claude write: rc=$RC out=$OUT"
F="$STATE/launch-records/claude-$CID"
[[ -f "$F" && ! -L "$F" ]] || fail 'claude record missing'
[[ "$(mode_of "$F")" == 600 ]] || fail "record mode $(mode_of "$F")"
grep -qxF 'permission=bypassPermissions' "$F" || fail 'permission not recorded'
grep -qxF 'source_root=/srv/harness' "$F" || fail 'source_root not recorded'
grep -qxF 'isolated=0' "$F" || fail 'isolated not recorded'
read_rec claude "$(printf %s "$CID" | tr a-f A-F)"
[[ "$OUT" == $'permission=bypassPermissions\nsource_root=/srv/harness\nisolated=0' ]] || fail "read back: [$OUT]"

# an isolated launch records its harness session id; resume overwrites
rec claude "$(event SessionStart resume $CID)" HARNESS_LAUNCH_PERMISSION=acceptEdits \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=1 HARNESS_SESSION_ID=$SID
read_rec claude "$CID"
[[ "$OUT" == $'permission=acceptEdits\nsource_root=/srv/harness\nisolated=1\nharness_session_id='"$SID" ]] || fail "isolated read back: [$OUT]"

# --- Codex record ---------------------------------------------------------------
rec codex "$(event SessionStart startup $XID)" HARNESS_LAUNCH_APPROVAL=never HARNESS_LAUNCH_SANDBOX=danger-full-access \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec codex "$XID"
[[ "$OUT" == $'approval=never\nsandbox=danger-full-access\nsource_root=/srv/harness\nisolated=0' ]] || fail "codex read back: [$OUT]"
rec codex "$(event SessionStart startup 01a0ef50-1bec-7852-afb3-a6b6559f47b6)" HARNESS_LAUNCH_BYPASS=1 \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec codex 01a0ef50-1bec-7852-afb3-a6b6559f47b6
[[ "$OUT" == $'bypass=1\nsource_root=/srv/harness\nisolated=0' ]] || fail "codex bypass read back: [$OUT]"

# --- silent no-ops ---------------------------------------------------------------
before="$(ls "$STATE/launch-records" | wc -l | tr -d ' ')"
noop() { # <label> <agent> <json> [ENV...]
  local label="$1"; shift
  rec "$@"
  [[ $RC == 0 && -z "$OUT" ]] || fail "$label: rc=$RC out=$OUT"
  [[ "$(ls "$STATE/launch-records" | wc -l | tr -d ' ')" == "$before" ]] || fail "$label: wrote a record"
}
G=(HARNESS_LAUNCH_PERMISSION=plan HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0)
noop 'wrong event' claude "$(event Stop startup 11111111-2222-4333-8444-555555555555)" "${G[@]}"
noop 'bad source' claude "$(event SessionStart weird 11111111-2222-4333-8444-555555555555)" "${G[@]}"
noop 'bad id' claude "$(event SessionStart startup ../../etc/passwd)" "${G[@]}"
noop 'bad agent' evil "$(event SessionStart startup 11111111-2222-4333-8444-555555555555)" "${G[@]}"
noop 'not json' claude 'nope' "${G[@]}"
noop 'no source root' claude "$(event SessionStart startup 11111111-2222-4333-8444-555555555555)" HARNESS_LAUNCH_PERMISSION=plan
noop 'relative source root' claude "$(event SessionStart startup 11111111-2222-4333-8444-555555555555)" HARNESS_LAUNCH_PERMISSION=plan HARNESS_LAUNCH_SOURCE_ROOT=rel HARNESS_LAUNCH_ISOLATED=0

# an out-of-vocabulary grant is dropped, not written
rec claude "$(event SessionStart startup 22222222-2222-4333-8444-555555555555)" HARNESS_LAUNCH_PERMISSION='bypassPermissions;rm' \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec claude 22222222-2222-4333-8444-555555555555
[[ "$OUT" == $'source_root=/srv/harness\nisolated=0' ]] || fail "unknown grant kept: [$OUT]"

# --- hardening --------------------------------------------------------------------
# a symlink at the record path is replaced, never followed
VICTIM="$TMP/victim"; echo keep > "$VICTIM"
ln -s "$VICTIM" "$STATE/launch-records/claude-33333333-2222-4333-8444-555555555555"
rec claude "$(event SessionStart startup 33333333-2222-4333-8444-555555555555)" "${G[@]}"
[[ "$(cat "$VICTIM")" == keep ]] || fail 'writer followed a symlink'
# a symlinked records directory is refused
rm -rf "$STATE/launch-records"; mkdir "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$STATE/launch-records"
rec claude "$(event SessionStart startup 44444444-2222-4333-8444-555555555555)" "${G[@]}"
[[ -z "$(ls "$TMP/elsewhere")" ]] || fail 'writer wrote through a symlinked directory'
rm "$STATE/launch-records"
# reader refuses a symlink, a FIFO and an oversized file
mkdir -p "$STATE/launch-records"
ln -s "$VICTIM" "$STATE/launch-records/claude-55555555-2222-4333-8444-555555555555"
read_rec claude 55555555-2222-4333-8444-555555555555; [[ $RC == 0 && -z "$OUT" ]] || fail "reader followed a symlink: [$OUT]"
mkfifo "$STATE/launch-records/claude-66666666-2222-4333-8444-555555555555"
read_rec claude 66666666-2222-4333-8444-555555555555; [[ $RC == 0 && -z "$OUT" ]] || fail "reader opened a fifo: [$OUT]"
read_rec claude not-a-uuid; [[ $RC == 0 && -z "$OUT" ]] || fail 'reader accepted a bad id'
read_rec bogus "$CID"; [[ $RC == 0 && -z "$OUT" ]] || fail 'reader accepted a bad agent'
# a record edited by hand keeps only valid keys and values
printf 'permission=bypassPermissions\npermission=plan\nevil=1\nsandbox=rm -rf\nsource_root=/a\nisolated=2\n' \
  > "$STATE/launch-records/claude-77777777-2222-4333-8444-555555555555"
read_rec claude 77777777-2222-4333-8444-555555555555
[[ "$OUT" == $'permission=plan\nsource_root=/a' ]] || fail "tampered record not filtered: [$OUT]"

echo 'PASS: launch record'
