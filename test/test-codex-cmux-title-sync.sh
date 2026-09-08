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
CMUX_ATTEMPT_LOG="$TMP/cmux-attempt.log"
INDEX="$FAKE_CODEX_HOME/session_index.jsonl"
PREFIX="alpha"
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
: > "$CMUX_ATTEMPT_LOG"
: > "$INDEX"

cat > "$FAKE_CMUX" <<'PY'
#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time

delay = float(os.environ.get("CMUX_SLEEP_SECONDS", "0"))
if delay:
    time.sleep(delay)
if os.environ.get("CMUX_REQUIRE_LIVE_GRANDPARENT") == "1":
    parent = os.getppid()
    grandparent = subprocess.run(
        ["ps", "-p", str(parent), "-o", "ppid="],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    if grandparent == "1":
        raise SystemExit(9)

with open(os.environ["CMUX_ATTEMPT_LOG"], "a", encoding="utf-8") as stream:
    stream.write("attempt\n")
failure_path = os.environ.get("CMUX_FAIL_REMAINING_FILE")
if failure_path:
    with open(failure_path, encoding="utf-8") as stream:
        remaining = int(stream.read().strip())
    if remaining:
        with open(failure_path, "w", encoding="utf-8") as stream:
            stream.write(str(remaining - 1))
        raise SystemExit(7)

with open(os.environ["CMUX_LOG"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(sys.argv[1:], ensure_ascii=False) + "\n")
PY
chmod +x "$FAKE_CMUX"
export CMUX_LOG CMUX_ATTEMPT_LOG

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
  : > "$CMUX_ATTEMPT_LOG"
  : > "$INDEX"
  rm -f "$STATE_DIR"/*.status.json
  unset CMUX_FAIL_REMAINING_FILE
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
    env -u CODEX_CMUX_TITLE_REQUEST_FILE HARNESS_PREFIX="$PREFIX" \
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

attempt_count() {
  wc -l < "$CMUX_ATTEMPT_LOG" | tr -d ' '
}

wait_for_attempts() {
  local expected="$1" i
  for i in $(seq 1 100); do
    [[ "$(attempt_count)" -ge "$expected" ]] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_title() {
  local expected="$1" count="${2:-1}"
  local i
  for i in $(seq 1 160); do
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
wait_for_title "resume-name | alpha" || { echo "FAIL: pre-existing title was not applied"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: pre-existing matching record renames the exact cmux tab"

reset_case
start_owner
run_hook "live-session" "$OWNER_PID"
append_name "live-session" "renamed-live"
wait_for_title "renamed-live | alpha" || { echo "FAIL: later rename was not applied"; exit 1; }
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
wait_for_title "valid-before-malformed | alpha" || { echo "FAIL: malformed tail hid prior valid record"; exit 1; }
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
wait_for_title "dirtyname | alpha" || { echo "FAIL: control characters were not removed"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: control characters are removed from cmux arguments"

reset_case
append_name "same-session" "same-name"
start_owner
run_hook "same-session" "$OWNER_PID"
wait_for_title "same-name | alpha" || { echo "FAIL: initial identical-name case did not run"; exit 1; }
append_name "same-session" "same-name"
sleep 0.2
[[ "$(title_count "same-name | alpha")" -eq 1 ]] || { echo "FAIL: identical title invoked cmux more than once"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: repeated identical thread names are suppressed"

for PREFIX in beta team-one; do
  reset_case
  append_name "prefix-$PREFIX" "prefix-name"
  start_owner
  run_hook "prefix-$PREFIX" "$OWNER_PID"
  wait_for_title "prefix-name | $PREFIX" || { echo "FAIL: $PREFIX suffix was not applied"; exit 1; }
  stop_owner "$OWNER_PID"
done
PREFIX="alpha"
echo "PASS: arbitrary valid profile prefixes use their exact suffixes"

reset_case
start_owner
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  HARNESS_PREFIX="invalid prefix" CODEX_HOME="$FAKE_CODEX_HOME" CMUX_SURFACE_ID="surface:42" \
  CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  env -u CODEX_HOME HARNESS_PREFIX=alpha CMUX_SURFACE_ID="surface:42" \
  CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  env -u CMUX_SURFACE_ID HARNESS_PREFIX=alpha CODEX_HOME="$FAKE_CODEX_HOME" \
  CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  HARNESS_PREFIX=alpha CODEX_HOME="$FAKE_CODEX_HOME" CMUX_SURFACE_ID="surface:42" \
  CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_OWNER_PID=999999999 python3 "$SYNC"
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"invalid-case"}' |
  HARNESS_PREFIX=alpha CODEX_HOME="$FAKE_CODEX_HOME" CMUX_SURFACE_ID="surface:42" \
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
wait_for_title "one-watcher | alpha" || { echo "FAIL: duplicate watcher case never renamed"; exit 1; }
sleep 0.2
[[ "$(title_count "one-watcher | alpha")" -eq 1 ]] || { echo "FAIL: duplicate SessionStart spawned multiple active watchers"; exit 1; }
stop_owner "$OWNER_PID"
echo "PASS: per-session and surface lock permits one watcher"

reset_case
append_name "slow-cmux-session" "slow-cmux"
start_owner
export CMUX_SLEEP_SECONDS=2.2
run_hook "slow-cmux-session" "$OWNER_PID"
if ! wait_for_title "slow-cmux | alpha"; then
  unset CMUX_SLEEP_SECONDS
  echo "FAIL: a healthy cmux round trip over two seconds was timed out"
  exit 1
fi
unset CMUX_SLEEP_SECONDS
stop_owner "$OWNER_PID"
echo "PASS: healthy cmux round trips over two seconds are allowed"

reset_case
append_name "retry-session" "eventual-title"
FAIL_REMAINING="$TMP/retry-failures"
printf '%s\n' 2 > "$FAIL_REMAINING"
export CMUX_FAIL_REMAINING_FILE="$FAIL_REMAINING"
start_owner
run_hook "retry-session" "$OWNER_PID"
wait_for_title "eventual-title | alpha" || {
  echo "FAIL: watcher did not recover after two transient rename failures"
  exit 1
}
[[ "$(attempt_count)" -eq 3 ]] || {
  echo "FAIL: transient failure recovery made $(attempt_count) attempts instead of three"
  exit 1
}
STATUS_FILE="$(find "$STATE_DIR" -name '*.status.json' -type f -print -quit)"
python3 - "$STATUS_FILE" "$OWNER_PID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    status = json.load(stream)
expected = {
    "owner_pid": int(sys.argv[2]),
    "attempt": 3,
    "state": "recovered",
    "error_category": "rename_failed",
}
if status != expected:
    raise SystemExit(f"unexpected diagnostic: {status!r}")
PY
unset CMUX_FAIL_REMAINING_FILE
stop_owner "$OWNER_PID"
echo "PASS: watcher retries two transient rename failures before succeeding"

reset_case
append_name "retry-owner-stop-session" "never-renamed"
FAIL_REMAINING="$TMP/owner-stop-failures"
printf '%s\n' 10 > "$FAIL_REMAINING"
export CMUX_FAIL_REMAINING_FILE="$FAIL_REMAINING"
start_owner
run_hook "retry-owner-stop-session" "$OWNER_PID"
wait_for_attempts 1 || { echo "FAIL: retry owner-stop case never made its first attempt"; exit 1; }
stop_owner "$OWNER_PID"
sleep 0.6
[[ "$(attempt_count)" -eq 1 ]] || { echo "FAIL: retry backoff continued after its owner exited"; exit 1; }
unset CMUX_FAIL_REMAINING_FILE
echo "PASS: retry backoff stops promptly when its owner exits"

reset_case
append_name "exhausted-session" "never-renamed"
FAIL_REMAINING="$TMP/exhausted-failures"
printf '%s\n' 10 > "$FAIL_REMAINING"
export CMUX_FAIL_REMAINING_FILE="$FAIL_REMAINING"
start_owner
request_file="$STATE_DIR/exhausted-request"
: > "$request_file"
env CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_STATE_DIR="$STATE_DIR" CODEX_CMUX_TITLE_POLL_SECONDS="0.05" python3 "$SYNC" --broker "$request_file" "surface:42" "$PREFIX" "$FAKE_CODEX_HOME" "$$" &
BROKER_PID=$!
OWNER_PIDS+=("$BROKER_PID")
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"exhausted-session"}' |
  env HARNESS_PREFIX="$PREFIX" CODEX_HOME="$FAKE_CODEX_HOME" CMUX_SURFACE_ID="surface:42" CODEX_CMUX_TITLE_REQUEST_FILE="$request_file" CODEX_CMUX_TITLE_STATE_DIR="$STATE_DIR" CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
wait_for_attempts 3 || { echo "FAIL: persistent failure did not make three bounded attempts"; exit 1; }
sleep 0.2
[[ "$(attempt_count)" -eq 3 ]] || { echo "FAIL: persistent failure retried beyond three attempts"; exit 1; }
wait "$BROKER_PID"
STATUS_FILE="$request_file.status.json"
python3 - "$STATUS_FILE" "$OWNER_PID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    status = json.load(stream)
expected = {
    "owner_pid": int(sys.argv[2]),
    "attempt": 3,
    "state": "exhausted",
    "error_category": "rename_failed",
}
if status != expected:
    raise SystemExit(f"unexpected diagnostic: {status!r}")
PY
[[ ! -e "$request_file" ]] || { echo "FAIL: exhausted broker left its request file behind"; exit 1; }
unset CMUX_FAIL_REMAINING_FILE
stop_owner "$OWNER_PID"
echo "PASS: persistent broker failure records a bounded safe diagnostic"

reset_case
append_name "broker-session" "broker-name"
start_owner
request_file="$STATE_DIR/broker-request"
: > "$request_file"
export CMUX_REQUIRE_LIVE_GRANDPARENT=1
env CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_STATE_DIR="$STATE_DIR" CODEX_CMUX_TITLE_POLL_SECONDS="0.05" python3 "$SYNC" --broker "$request_file" "surface:42" "$PREFIX" "$FAKE_CODEX_HOME" "$$" &
BROKER_PID=$!
OWNER_PIDS+=("$BROKER_PID")
printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"broker-session"}' |
  env HARNESS_PREFIX="$PREFIX" CODEX_HOME="$FAKE_CODEX_HOME" CMUX_SURFACE_ID="surface:42" CODEX_CMUX_TITLE_REQUEST_FILE="$request_file" CODEX_CMUX_TITLE_STATE_DIR="$STATE_DIR" CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
wait_for_title "broker-name | alpha" || {
  unset CMUX_REQUIRE_LIVE_GRANDPARENT
  echo "FAIL: launcher-anchored broker did not preserve cmux caller ancestry"
  exit 1
}
unset CMUX_REQUIRE_LIVE_GRANDPARENT
stop_owner "$OWNER_PID"
wait "$BROKER_PID"
[[ ! -e "$request_file" ]] || {
  echo "FAIL: completed broker left its request file behind"
  exit 1
}
echo "PASS: launcher-anchored broker preserves cmux caller ancestry"

unowned_request="$TMP/unowned-request"
printf '%s\n' "sentinel" > "$unowned_request"
env CODEX_CMUX_TITLE_CMUX_BIN="$FAKE_CMUX" CODEX_CMUX_TITLE_STATE_DIR="$STATE_DIR" python3 "$SYNC" --broker "$unowned_request" "surface:42" "$PREFIX" "$FAKE_CODEX_HOME" "$$"
[[ "$(cat "$unowned_request")" == "sentinel" ]] || {
  echo "FAIL: broker removed a request file outside its owned state directory"
  exit 1
}
echo "PASS: broker cleanup is confined to its owned state directory"

echo "✓ All Codex cmux title sync tests passed"
