#!/usr/bin/env bash
# test-launch-record.sh — harness-launch-record (SessionStart hook) writes the
# launcher-owned launch record; `harness-launch-record read` reads it back.
# The record is the only source of a restored permission/sandbox grant.
#   claude: the grant, source root and isolation are ARGUMENTS of the hook
#           command (the environment is writable through settings.local.json
#           and is ignored).
#   codex:  the hooks.json row is static, so the launcher's environment is used.
#   nested: a launch inside an agent may keep or lower a grant, never raise it.
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

# rec <agent> <json> [ENV=val ...] [-- args...] : sets OUT and RC
rec() {
  local agent="$1" json="$2"; shift 2
  local -a envs=() args=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  [[ $# -eq 0 ]] || shift
  args=("$@")
  OUT="$(printf '%s' "$json" | env -i HOME="$HOME" PATH="$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ${envs[@]+"${envs[@]}"} "$PY" "$WRITER" "$agent" ${args[@]+"${args[@]}"} 2>&1)"
  RC=$?
}
event() { printf '{"hook_event_name":"%s","source":"%s","session_id":"%s"}' "$1" "$2" "$3"; }
read_rec() { OUT="$(HARNESS_SESSION_STATE_HOME="$STATE" "$PY" "$WRITER" read "$1" "$2" 2>&1)"; RC=$?; }
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
LAUNCH=(--source-root /srv/harness --isolated 0)

# --- Claude record (arguments) -------------------------------------------------
rec claude "$(event SessionStart startup $CID)" -- "${LAUNCH[@]}" --permission bypassPermissions
[[ $RC == 0 && -z "$OUT" ]] || fail "claude write: rc=$RC out=$OUT"
F="$STATE/launch-records/claude-$CID"
[[ -f "$F" && ! -L "$F" ]] || fail 'claude record missing'
[[ "$(mode_of "$F")" == 600 ]] || fail "record mode $(mode_of "$F")"
read_rec claude "$(printf %s "$CID" | tr a-f A-F)"
[[ "$OUT" == $'permission=bypassPermissions\nsource_root=/srv/harness\nisolated=0' ]] || fail "read back: [$OUT]"

# M2: the Claude environment is ignored (settings.local.json can write it).
ENVFORGE=(HARNESS_LAUNCH_PERMISSION=bypassPermissions HARNESS_LAUNCH_SOURCE_ROOT=/evil HARNESS_LAUNCH_ISOLATED=1 HARNESS_SESSION_ID=$SID)
rec claude "$(event SessionStart startup 12121212-2222-4333-8444-555555555555)" "${ENVFORGE[@]}" -- "${LAUNCH[@]}" --permission plan
read_rec claude 12121212-2222-4333-8444-555555555555
[[ "$OUT" == $'permission=plan\nsource_root=/srv/harness\nisolated=0' ]] || fail "M2 claude used the environment over its arguments: [$OUT]"
rec claude "$(event SessionStart startup 13131313-2222-4333-8444-555555555555)" "${ENVFORGE[@]}" -- "${LAUNCH[@]}"
read_rec claude 13131313-2222-4333-8444-555555555555
[[ "$OUT" == $'source_root=/srv/harness\nisolated=0' ]] || fail "M2 claude grant came from the environment: [$OUT]"
rec claude "$(event SessionStart startup 14141414-2222-4333-8444-555555555555)" "${ENVFORGE[@]}"
[[ ! -e "$STATE/launch-records/claude-14141414-2222-4333-8444-555555555555" ]] || fail 'M2 claude wrote a record from the environment alone'

# an isolated launch records its harness session id
rec claude "$(event SessionStart resume $CID)" -- --source-root /srv/harness --isolated 1 --harness-session-id $SID --permission acceptEdits
read_rec claude "$CID"
[[ "$OUT" == $'permission=acceptEdits\nsource_root=/srv/harness\nisolated=1\nharness_session_id='"$SID" ]] || fail "isolated read back: [$OUT]"

# --- Codex record (environment) -------------------------------------------------
rec codex "$(event SessionStart startup $XID)" HARNESS_LAUNCH_APPROVAL=never HARNESS_LAUNCH_SANDBOX=danger-full-access \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec codex "$XID"
[[ "$OUT" == $'approval=never\nsandbox=danger-full-access\nsource_root=/srv/harness\nisolated=0' ]] || fail "codex read back: [$OUT]"
rec codex "$(event SessionStart startup 01a0ef50-1bec-7852-afb3-a6b6559f47b6)" HARNESS_LAUNCH_BYPASS=1 \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec codex 01a0ef50-1bec-7852-afb3-a6b6559f47b6
[[ "$OUT" == $'bypass=1\nsource_root=/srv/harness\nisolated=0' ]] || fail "codex bypass read back: [$OUT]"
# M3: the launched profile is recorded (fixed vocabulary only)
rec codex "$(event SessionStart startup 01a0ef50-1bec-7852-afb3-a6b6559f47b7)" HARNESS_LAUNCH_PROFILE=plan \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec codex 01a0ef50-1bec-7852-afb3-a6b6559f47b7
[[ "$OUT" == $'profile=plan\nsource_root=/srv/harness\nisolated=0' ]] || fail "M3 profile not recorded: [$OUT]"
rec codex "$(event SessionStart startup 01a0ef50-1bec-7852-afb3-a6b6559f47b8)" 'HARNESS_LAUNCH_PROFILE=../evil' \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec codex 01a0ef50-1bec-7852-afb3-a6b6559f47b8
[[ "$OUT" == $'source_root=/srv/harness\nisolated=0' ]] || fail "M3 unknown profile kept: [$OUT]"

# --- silent no-ops ---------------------------------------------------------------
before="$(ls "$STATE/launch-records" | wc -l | tr -d ' ')"
noop() { # <label> <agent> <json> [ENV...] [-- args]
  local label="$1"; shift
  rec "$@"
  [[ $RC == 0 && -z "$OUT" ]] || fail "$label: rc=$RC out=$OUT"
  [[ "$(ls "$STATE/launch-records" | wc -l | tr -d ' ')" == "$before" ]] || fail "$label: wrote a record"
}
U=11111111-2222-4333-8444-555555555555
noop 'wrong event' claude "$(event Stop startup $U)" -- "${LAUNCH[@]}" --permission plan
noop 'bad source' claude "$(event SessionStart weird $U)" -- "${LAUNCH[@]}" --permission plan
noop 'bad id' claude "$(event SessionStart startup ../../etc/passwd)" -- "${LAUNCH[@]}" --permission plan
noop 'bad agent' evil "$(event SessionStart startup $U)" -- "${LAUNCH[@]}"
noop 'not json' claude 'nope' -- "${LAUNCH[@]}"
noop 'no source root' claude "$(event SessionStart startup $U)" -- --isolated 0 --permission plan
noop 'relative source root' claude "$(event SessionStart startup $U)" -- --source-root rel --isolated 0
noop 'unknown flag' claude "$(event SessionStart startup $U)" -- "${LAUNCH[@]}" --bogus 1

# an out-of-vocabulary grant is dropped, not written
rec claude "$(event SessionStart startup 22222222-2222-4333-8444-555555555555)" -- "${LAUNCH[@]}" --permission 'bypassPermissions;rm'
read_rec claude 22222222-2222-4333-8444-555555555555
[[ "$OUT" == $'source_root=/srv/harness\nisolated=0' ]] || fail "unknown grant kept: [$OUT]"

# --- M1: nested launches never raise a record ---------------------------------------
N=(--source-root /srv/harness --isolated 0 --nested 1)
NID=33333333-aaaa-4bbb-8ccc-000000000001
# no record yet: a nested launch creates one without a grant
rec claude "$(event SessionStart startup $NID)" -- "${N[@]}" --permission bypassPermissions
read_rec claude $NID
[[ "$OUT" == $'source_root=/srv/harness\nisolated=0' ]] || fail "M1 nested created a record with a grant: [$OUT]"
# existing plan: nested bypass cannot raise it; a top-level launch can
NID=33333333-aaaa-4bbb-8ccc-000000000002
rec claude "$(event SessionStart startup $NID)" -- "${LAUNCH[@]}" --permission plan
rec claude "$(event SessionStart resume $NID)" -- "${N[@]}" --permission bypassPermissions
read_rec claude $NID
[[ "$OUT" == $'permission=plan\nsource_root=/srv/harness\nisolated=0' ]] || fail "M1 nested raised plan to bypass: [$OUT]"
rec claude "$(event SessionStart resume $NID)" -- "${N[@]}"
read_rec claude $NID
[[ "$OUT" == $'permission=plan\nsource_root=/srv/harness\nisolated=0' ]] || fail "M1 nested launch without a grant dropped the record's grant: [$OUT]"
rec claude "$(event SessionStart resume $NID)" -- "${LAUNCH[@]}" --permission bypassPermissions
read_rec claude $NID
[[ "$OUT" == $'permission=bypassPermissions\nsource_root=/srv/harness\nisolated=0' ]] || fail "M1 top-level relaunch could not raise: [$OUT]"
# existing bypass: nested keeps or lowers, never raises
rec claude "$(event SessionStart resume $NID)" -- "${N[@]}" --permission bypassPermissions
read_rec claude $NID
[[ "$OUT" == $'permission=bypassPermissions\nsource_root=/srv/harness\nisolated=0' ]] || fail "M1 nested changed an equal grant: [$OUT]"
rec claude "$(event SessionStart resume $NID)" -- "${N[@]}" --permission acceptEdits
read_rec claude $NID
[[ "$OUT" == $'permission=acceptEdits\nsource_root=/srv/harness\nisolated=0' ]] || fail "M1 nested could not lower: [$OUT]"
# a nested launch cannot rewrite where the session lives
rec claude "$(event SessionStart resume $NID)" -- --source-root /elsewhere --isolated 1 --nested 1
read_rec claude $NID
[[ "$OUT" == *'source_root=/srv/harness'* && "$OUT" == *'isolated=0'* ]] || fail "M1 nested rewrote root/isolation: [$OUT]"
# Codex: same rule through the environment
XN=01a0ef50-1bec-7852-afb3-a6b6559f4700
rec codex "$(event SessionStart startup $XN)" HARNESS_LAUNCH_SANDBOX=read-only HARNESS_LAUNCH_APPROVAL=on-request \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
rec codex "$(event SessionStart resume $XN)" HARNESS_LAUNCH_BYPASS=1 HARNESS_LAUNCH_NESTED=1 \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec codex $XN
[[ "$OUT" == $'approval=on-request\nsandbox=read-only\nsource_root=/srv/harness\nisolated=0' ]] || fail "M1 nested codex raised the record: [$OUT]"
rec codex "$(event SessionStart resume $XN)" HARNESS_LAUNCH_SANDBOX=danger-full-access HARNESS_LAUNCH_NESTED=1 \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec codex $XN
[[ "$OUT" == *'sandbox=read-only'* ]] || fail "M1 nested codex raised the sandbox: [$OUT]"
rec codex "$(event SessionStart resume $XN)" HARNESS_LAUNCH_BYPASS=1 \
  HARNESS_LAUNCH_SOURCE_ROOT=/srv/harness HARNESS_LAUNCH_ISOLATED=0
read_rec codex $XN
[[ "$OUT" == *'bypass=1'* ]] || fail "M1 top-level codex relaunch could not raise: [$OUT]"

# --- hardening --------------------------------------------------------------------
# a symlink at the record path is replaced, never followed
VICTIM="$TMP/victim"; echo keep > "$VICTIM"
ln -s "$VICTIM" "$STATE/launch-records/claude-33333333-2222-4333-8444-555555555555"
rec claude "$(event SessionStart startup 33333333-2222-4333-8444-555555555555)" -- "${LAUNCH[@]}" --permission plan
[[ "$(cat "$VICTIM")" == keep ]] || fail 'writer followed a symlink'
# a symlinked records directory is refused by the writer and by the reader
rec claude "$(event SessionStart startup 44444444-2222-4333-8444-555555555555)" -- "${LAUNCH[@]}" --permission plan
cp "$STATE/launch-records/claude-44444444-2222-4333-8444-555555555555" "$TMP/good-record"
mv "$STATE/launch-records" "$TMP/real-records"; mkdir "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$STATE/launch-records"
rec claude "$(event SessionStart startup 55555555-2222-4333-8444-555555555555)" -- "${LAUNCH[@]}" --permission plan
[[ -z "$(ls "$TMP/elsewhere")" ]] || fail 'writer wrote through a symlinked directory'
cp "$TMP/good-record" "$TMP/elsewhere/claude-44444444-2222-4333-8444-555555555555"
read_rec claude 44444444-2222-4333-8444-555555555555
[[ $RC == 0 && -z "$OUT" ]] || fail "L6 reader followed a symlinked directory: [$OUT]"
rm "$STATE/launch-records"; mv "$TMP/real-records" "$STATE/launch-records"
# reader refuses a symlink, a FIFO, a hard-linked file and an oversized file
ln -s "$VICTIM" "$STATE/launch-records/claude-66666666-2222-4333-8444-555555555555"
read_rec claude 66666666-2222-4333-8444-555555555555; [[ $RC == 0 && -z "$OUT" ]] || fail "reader followed a symlink: [$OUT]"
mkfifo "$STATE/launch-records/claude-77777777-2222-4333-8444-555555555555"
read_rec claude 77777777-2222-4333-8444-555555555555; [[ $RC == 0 && -z "$OUT" ]] || fail "reader opened a fifo: [$OUT]"
ln "$STATE/launch-records/claude-44444444-2222-4333-8444-555555555555" "$TMP/second-name"
read_rec claude 44444444-2222-4333-8444-555555555555; [[ $RC == 0 && -z "$OUT" ]] || fail "L6 reader accepted a hard-linked record: [$OUT]"
find "$TMP/second-name" -delete
read_rec claude 44444444-2222-4333-8444-555555555555; [[ "$OUT" == *permission=plan* ]] || fail "L6 reader rejected a normal record: [$OUT]"
read_rec claude not-a-uuid; [[ $RC == 0 && -z "$OUT" ]] || fail 'reader accepted a bad id'
read_rec bogus "$CID"; [[ $RC == 0 && -z "$OUT" ]] || fail 'reader accepted a bad agent'
# a record edited by hand keeps only valid keys and values
printf 'permission=bypassPermissions\npermission=plan\nevil=1\nsandbox=rm -rf\nsource_root=/a\nisolated=2\n' \
  > "$STATE/launch-records/claude-88888888-2222-4333-8444-555555555555"
read_rec claude 88888888-2222-4333-8444-555555555555
[[ "$OUT" == $'permission=plan\nsource_root=/a' ]] || fail "tampered record not filtered: [$OUT]"

echo 'PASS: launch record'
