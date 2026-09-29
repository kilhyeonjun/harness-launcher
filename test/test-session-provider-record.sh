#!/usr/bin/env bash
# test-session-provider-record.sh — harness-session-provider-record appends
# `claude <uuid>` to the isolated session's provider-sessions only for valid
# Claude SessionStart events, and is otherwise silent with exit 0.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REC="$ROOT/bin/harness-session-provider-record"
TMP="$(mktemp -d)"
trap 'find "$TMP" -delete' EXIT
STATE="$TMP/state"
SID=0CB4A1F2-1111-4222-8333-444455556666
NEWID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
mkdir -p "$STATE/sessions/$SID"
fail() { echo "FAIL: $*" >&2; exit 1; }

# rec <json> [ENV=val ...] : sets OUT and RC
rec() {
  local json="$1"; shift
  OUT="$(printf '%s' "$json" | env -i HOME="$HOME" PATH="$PATH" HARNESS_SESSION_STATE_HOME="$STATE" "$@" python3 "$REC" 2>&1)"
  RC=$?
}
event() { printf '{"hook_event_name":"%s","source":"%s","session_id":"%s"}' "$1" "$2" "$3"; }
file="$STATE/sessions/$SID/provider-sessions"

expect_silent_noop() { # <label>
  [[ $RC == 0 ]] || fail "$1: exit $RC"
  [[ -z "$OUT" ]] || fail "$1: printed output: $OUT"
  [[ ! -e "$file" ]] || fail "$1: wrote provider-sessions"
}

[[ -f "$REC" ]] || fail 'recorder command is missing'

# valid clear event appends one line
rec "$(event SessionStart clear $NEWID)" HARNESS_SESSION_ID=$SID
[[ $RC == 0 && -z "$OUT" ]] || fail "valid event: rc=$RC out=$OUT"
[[ "$(cat "$file")" == "claude $NEWID" ]] || fail 'valid clear event did not append the line'
# identical line is not duplicated
rec "$(event SessionStart resume $NEWID)" HARNESS_SESSION_ID=$SID
[[ "$(wc -l < "$file" | tr -d ' ')" == 1 ]] || fail 'duplicate line appended'
# every allowed source appends its own distinct id
n=0
for src in startup resume clear compact fork; do
  n=$((n+1)); id="bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeee0$n"
  rec "$(event SessionStart $src $id)" HARNESS_SESSION_ID=$SID
  [[ $RC == 0 && -z "$OUT" ]] || fail "source $src: rc=$RC out=$OUT"
  grep -qxF "claude $id" "$file" || fail "source $src not recorded"
done
[[ "$(wc -l < "$file" | tr -d ' ')" == 6 ]] || fail 'expected NEWID plus one line per source'
find "$STATE" -name provider-sessions -delete

rec "$(event SessionStart clear not-a-uuid)" HARNESS_SESSION_ID=$SID; expect_silent_noop 'non-UUID id'
rec "$(event SessionStart clear $NEWID)"; expect_silent_noop 'HARNESS_SESSION_ID unset'
mkdir -p "$STATE/evil"
rec "$(event SessionStart clear $NEWID)" HARNESS_SESSION_ID=../evil; expect_silent_noop 'non-UUID HARNESS_SESSION_ID'
[[ ! -e "$STATE/evil/provider-sessions" ]] || fail 'traversal id wrote outside sessions'
rec "$(event SessionStart clear "$NEWID\\n")" HARNESS_SESSION_ID=$SID; expect_silent_noop 'session_id with trailing newline'
rec "$(event SessionStart clear $NEWID)" HARNESS_SESSION_ID="$SID"$'\n'; expect_silent_noop 'HARNESS_SESSION_ID with trailing newline'
rec "$(event SessionStart bogus $NEWID)" HARNESS_SESSION_ID=$SID; expect_silent_noop 'unknown source'
rec "$(event PreToolUse clear $NEWID)" HARNESS_SESSION_ID=$SID; expect_silent_noop 'other hook event'
rec '{not json' HARNESS_SESSION_ID=$SID; expect_silent_noop 'malformed JSON'
rec '' HARNESS_SESSION_ID=$SID; expect_silent_noop 'empty stdin'

MISSING=11111111-1111-4111-8111-111111111111
rec "$(event SessionStart clear $NEWID)" HARNESS_SESSION_ID=$MISSING
[[ $RC == 0 && -z "$OUT" ]] || fail 'missing dir not silent'
[[ ! -e "$STATE/sessions/$MISSING" ]] || fail 'missing dir was created'

LINK=22222222-2222-4222-8222-222222222222
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$STATE/sessions/$LINK"
rec "$(event SessionStart clear $NEWID)" HARNESS_SESSION_ID=$LINK
[[ $RC == 0 && -z "$OUT" ]] || fail 'symlinked dir not silent'
[[ ! -e "$TMP/elsewhere/provider-sessions" ]] || fail 'wrote through symlinked session dir'

# symlinked provider-sessions is not written through
: > "$TMP/target"
ln -s "$TMP/target" "$file"
rec "$(event SessionStart clear $NEWID)" HARNESS_SESSION_ID=$SID
[[ $RC == 0 && -z "$OUT" ]] || fail 'symlinked file not silent'
[[ ! -s "$TMP/target" ]] || fail 'wrote through symlinked provider-sessions'
find "$STATE/sessions/$SID" -name provider-sessions -delete

# FIFO at provider-sessions: must not block, must write nothing
mkfifo "$file"
start=$SECONDS
printf '%s' "$(event SessionStart clear $NEWID)" | env -i HOME="$HOME" PATH="$PATH" HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_ID=$SID \
  python3 -c 'import subprocess,sys; sys.exit(subprocess.run([sys.argv[1]],input=sys.stdin.buffer.read(),timeout=5).returncode)' "$REC" || fail 'FIFO case blocked or failed'
(( SECONDS - start < 4 )) || fail 'FIFO case was not prompt'
find "$STATE/sessions/$SID" -name provider-sessions -type p -delete

# non-UTF-8 bytes in an existing file do not stop later records
printf 'junk \377\376\n' > "$file"
rec "$(event SessionStart clear $NEWID)" HARNESS_SESSION_ID=$SID
[[ $RC == 0 && -z "$OUT" ]] || fail 'non-UTF-8 file not silent'
grep -aqxF "claude $NEWID" "$file" || fail 'record lost after non-UTF-8 content'
find "$STATE/sessions/$SID" -name provider-sessions -delete

echo 'PASS: test-session-provider-record'
