#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$ROOT/bin/codex-cmux-title-sync.py"
[[ -f "$SYNC" ]] || { echo "FAIL: missing $SYNC"; exit 1; }

TMP="$(mktemp -d)"
FAKE_CODEX_HOME="$TMP/codex-home"
STATE_DIR="$TMP/state"
FAKE_CMUX="$TMP/cmux"
CMUX_LOG="$TMP/cmux.log"
INDEX="$FAKE_CODEX_HOME/session_index.jsonl"
PREFIX="kh"
OWNER_PIDS=()

cleanup() {
  local pid
  for pid in "${OWNER_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$FAKE_CODEX_HOME" "$STATE_DIR"
: > "$CMUX_LOG"
: > "$INDEX"

cat > "$FAKE_CMUX" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["CMUX_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(sys.argv[1:], ensure_ascii=False) + "\n")
PY
chmod +x "$FAKE_CMUX"
export CMUX_LOG

start_owner() {
  sleep 30 &
  OWNER_PID=$!
  OWNER_PIDS+=("$OWNER_PID")
}

stop_owner() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 0.12
}

reset_case() {
  : > "$CMUX_LOG"
  : > "$INDEX"
}

append_name() {
  python3 - "$INDEX" "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({"id": sys.argv[2], "thread_name": sys.argv[3], "updated_at": "now"}) + "\n")
PY
}

run_hook() {
  local session="$1" owner_pid="$2"
  printf '{"hook_event_name":"SessionStart","session_id":"%s"}\n' "$session" |
    HARNESS_PREFIX="$PREFIX" \
    CODEX_HOME="$FAKE_CODEX_HOME" \
    CMUX_SURFACE_ID="surface:42" \
    CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" \
    CODEX_CMUX_TITLE_OWNER_PID="$owner_pid" \
    CODEX_CMUX_TITLE_STATE_DIR="$STATE_DIR" \
    CODEX_CMUX_TITLE_POLL_SECONDS="0.05" \
    python3 "$SYNC"
}

title_count() {
  python3 - "$CMUX_LOG" "$1" <<'PY'
import json
import sys

expected = ["rename-tab", "--surface", "surface:42", sys.argv[2]]
count = 0
with open(sys.argv[1], encoding="utf-8") as stream:
    for line in stream:
        try:
            count += json.loads(line) == expected
        except json.JSONDecodeError:
            pass
print(count)
PY
}

wait_for_title() {
  local expected="$1" count="${2:-1}"
  local i
  for i in $(seq 1 80); do
    [[ "$(title_count "$expected")" -ge "$count" ]] && return 0
    sleep 0.05
  done
  return 1
}

assert_no_calls() {
  [[ ! -s "$CMUX_LOG" ]] || {
    echo "FAIL: unexpected cmux call"
    cat "$CMUX_LOG"
    exit 1
  }
}

reset_case
append_name "resume-session" "resume-name"
start_owner
run_hook "resume-session" "$OWNER_PID"
wait_for_title "resume-name | kh" || { echo "FAIL: pre-existing title was not applied"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: pre-existing matching record renames the exact cmux tab"

reset_case
start_owner
run_hook "live-session" "$OWNER_PID"
append_name "live-session" "renamed-live"
wait_for_title "renamed-live | kh" || { echo "FAIL: later rename was not applied"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: later matching append updates the cmux tab"

reset_case
append_name "other-session" "wrong-name"
start_owner
run_hook "target-session" "$OWNER_PID"
sleep 0.2
assert_no_calls
stop_owner "$OWNER_PID"
echo "PASS: records for another session id are ignored"

reset_case
append_name "malformed-session" "valid-before-malformed"
printf '%s\n' '{broken json' >> "$INDEX"
start_owner
run_hook "malformed-session" "$OWNER_PID"
wait_for_title "valid-before-malformed | kh" || { echo "FAIL: malformed tail hid prior valid record"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: malformed JSON lines do not hide earlier valid records"

reset_case
python3 - "$INDEX" <<'PY'
import json
import sys

with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({
        "id": "control-session",
        "thread_name": "dirty\tname\u007f\u0080",
        "updated_at": "now",
    }) + "\n")
PY
start_owner
run_hook "control-session" "$OWNER_PID"
wait_for_title "dirtyname | kh" || { echo "FAIL: control characters were not removed"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: control characters are removed from cmux arguments"

reset_case
append_name "same-session" "same-name"
start_owner
run_hook "same-session" "$OWNER_PID"
wait_for_title "same-name | kh" || { echo "FAIL: initial identical-name case did not run"; exit 1; }
append_name "same-session" "same-name"
sleep 0.2
[[ "$(title_count "same-name | kh")" -eq 1 ]] || { echo "FAIL: identical title invoked cmux more than once"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: repeated identical thread names are suppressed"

for PREFIX in gp gd; do
  reset_case
  append_name "prefix-$PREFIX" "prefix-name"
  start_owner
  run_hook "prefix-$PREFIX" "$OWNER_PID"
  wait_for_title "prefix-name | $PREFIX" || { echo "FAIL: $PREFIX suffix was not applied"; exit 1; }
  stop_owner "$OWNER_PID"
done
PREFIX="kh"
echo "PASS: gp and gd use their exact short suffixes"

reset_case
start_owner
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  HARNESS_PREFIX="invalid" CODEX_HOME="$FAKE_CODEX_HOME" CMUX_SURFACE_ID="surface:42" \
  CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  env -u CODEX_HOME HARNESS_PREFIX=kh CMUX_SURFACE_ID="surface:42" \
  CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  env -u CMUX_SURFACE_ID HARNESS_PREFIX=kh CODEX_HOME="$FAKE_CODEX_HOME" \
  CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  HARNESS_PREFIX=kh CODEX_HOME="$FAKE_CODEX_HOME" CMUX_SURFACE_ID="surface:42" \
  CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_OWNER_PID=999999999 python3 "$SYNC"
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  HARNESS_PREFIX=kh CODEX_HOME="$FAKE_CODEX_HOME" CMUX_SURFACE_ID="surface:42" \
  CODEX_CMUX_TITLE_CMUX_BIN="$TMP/missing-cmux" CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
sleep 0.15
assert_no_calls
stop_owner "$OWNER_PID"
echo "PASS: unavailable inputs fail open without calling cmux"

reset_case
start_owner
run_hook "owner-session" "$OWNER_PID"
stop_owner "$OWNER_PID"
append_name "owner-session" "too-late"
sleep 0.2
assert_no_calls
echo "PASS: watcher stops when the owning Codex process exits"

reset_case
append_name "duplicate-session" "one-watcher"
start_owner
run_hook "duplicate-session" "$OWNER_PID"
run_hook "duplicate-session" "$OWNER_PID"
wait_for_title "one-watcher | kh" || { echo "FAIL: duplicate watcher case never renamed"; exit 1; }
sleep 0.2
[[ "$(title_count "one-watcher | kh")" -eq 1 ]] || { echo "FAIL: duplicate SessionStart spawned multiple active watchers"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: per-session and surface lock permits one watcher"

echo "✓ All Codex cmux title sync tests passed"
