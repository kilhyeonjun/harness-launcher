#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$ROOT/bin/codex-cmux-title-sync.py"
TMP="$(mktemp -d)"
STATE="$TMP/launch.test"
TRANSCRIPT="$TMP/transcript.jsonl"
CMUX="$TMP/cmux"
LOG="$TMP/cmux.log"
OWNER_PIDS=()

cleanup() {
  local pid
  for pid in "${OWNER_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$STATE"
chmod 700 "$STATE"
: > "$TRANSCRIPT"
cat > "$CMUX" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *'--json tree'* ]]; then
  if [[ -n "${CMUX_TREE_FAIL_FILE:-}" && -f "$CMUX_TREE_FAIL_FILE" ]]; then rm -f "$CMUX_TREE_FAIL_FILE"; exit 1; fi
  title=''
  [[ -f "$CMUX_CURRENT_TITLE" ]] && title="$(cat "$CMUX_CURRENT_TITLE")"
  if [[ "${CMUX_CALLER_FIRST:-}" == 1 ]]; then printf '{"caller":{"surface_ref":"surface:42"},"pane":{"id":"surface:42","title":"%s"}}\n' "$title"; exit 0; fi
  printf '{"ref":"surface:42","title":"%s"}\n' "$title"
  exit 0
fi
if [[ -n "${CMUX_SLEEP_FILE:-}" && -s "$CMUX_SLEEP_FILE" ]]; then sleep "$(cat "$CMUX_SLEEP_FILE")"; fi
printf '%s\n' "$*" >> "$CMUX_LOG"
printf '%s' "${*: -1}" > "$CMUX_CURRENT_TITLE"
SH
chmod +x "$CMUX"
export CMUX_LOG="$LOG" CMUX_CURRENT_TITLE="$TMP/current-title"

start_owner() { sleep 30 & OWNER_PID=$!; OWNER_PIDS+=("$OWNER_PID"); }
wait_for_title() {
  local expected="$1" i
  for i in $(seq 1 80); do
    grep -Fqx -- "rename-tab --surface surface:42 -- $expected" "$LOG" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}
request() {
  printf '{"hook_event_name":"SessionStart","session_id":"%s","transcript_path":"%s"}\n' "$1" "$TRANSCRIPT" |
    HARNESS_PREFIX=alpha CMUX_SURFACE_ID=surface:42 CMUX_WORKSPACE_ID=workspace:7 \
    CLAUDE_CMUX_TITLE_REQUEST_FILE="$STATE/request.json" CLAUDE_CMUX_TITLE_STATE_DIR="$STATE" \
    CLAUDE_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC" --claude-session-start
}
append() { printf '%s\n' "$1" >> "$TRANSCRIPT"; }

start_owner
: > "$STATE/request.json"
CMUX_TREE_FAIL_FILE="$TMP/tree-fail" CMUX_CALLER_FIRST=1 CMUX_TITLE_STATE_DIR="$STATE/legacy" CMUX_SLEEP_FILE="$TMP/sleep" CMUX_WORKSPACE_ID=workspace:7 CLAUDE_CMUX_TITLE_CMUX_BIN="$CMUX" CLAUDE_CMUX_TITLE_STATE_DIR="$STATE" CLAUDE_CMUX_TITLE_POLL_SECONDS=0.05 \
  python3 "$SYNC" --claude-broker "$STATE/request.json" surface:42 alpha "$TMP/runtime" "$$" &
BROKER_PID=$!
OWNER_PIDS+=("$BROKER_PID")

request session-a
append '{"type":"ai-title","aiTitle":"automatic first","sessionId":"session-a"}'
wait_for_title 'automatic first | alpha' || { echo 'FAIL: ai title not applied'; exit 1; }
append '{"type":"custom-title","customTitle":"manual goal","sessionId":"session-a"}'
wait_for_title 'manual goal | alpha' || { echo 'FAIL: custom title not applied'; exit 1; }
append '{"type":"ai-title","aiTitle":"late automatic must lose","sessionId":"session-a"}'
sleep 0.2
grep -Fq 'late automatic must lose' "$LOG" && { echo 'FAIL: late AI title overwrote manual title'; exit 1; }
echo 'PASS: manual custom title wins over later AI title'

# A second SessionStart in the same launcher must replace the exact-session
# assignment (/clear, TUI resume, and fork all create this shape).
request session-b
append '{"type":"ai-title","aiTitle":"resumed goal","sessionId":"session-b"}'
wait_for_title 'resumed goal | alpha' || { echo 'FAIL: repeated SessionStart did not hand off new session'; exit 1; }
echo 'PASS: repeated SessionStart replaces the watched session'

python3 - "$STATE/active.json" "$BROKER_PID" "$OWNER_PID" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    status = json.load(stream)
for field, expected in {'uid': os.getuid(), 'broker_pid': int(sys.argv[2]), 'owner_pid': int(sys.argv[3]), 'session_id': 'session-b', 'surface': 'surface:42', 'workspace': 'workspace:7'}.items():
    if status.get(field) != expected:
        raise SystemExit(f'active status {field}: {status.get(field)!r}')
if not isinstance(status.get('heartbeat_unix'), int):
    raise SystemExit('missing heartbeat')
PY
echo 'PASS: broker writes exact live ownership acknowledgement'

printf '3.2\n' > "$TMP/sleep"
request session-c
append '{"type":"ai-title","aiTitle":"slow title","sessionId":"session-c"}'
sleep 3.05
python3 - "$STATE/active.json" <<'PY'
import json, sys, time
with open(sys.argv[1], encoding='utf-8') as stream: status = json.load(stream)
if time.time() - status['heartbeat_unix'] > 2:
    raise SystemExit('heartbeat became stale during cmux rename')
PY
wait_for_title 'slow title | alpha' || { echo 'FAIL: slow title not applied'; exit 1; }
rm -f "$TMP/sleep"
echo 'PASS: acknowledgement stays live during a slow cmux rename'

printf '%s' 'external tab name' > "$TMP/current-title"
append '{"type":"custom-title","customTitle":"must not overwrite manual cmux","sessionId":"session-c"}'
sleep 0.2
grep -Fq 'must not overwrite manual cmux' "$LOG" && { echo 'FAIL: native title overwrote manual cmux title'; exit 1; }
echo 'PASS: a manual cmux rename freezes later native updates'

request session-d
append '{"type":"ai-title","aiTitle":"must preserve existing tab","sessionId":"session-d"}'
sleep 0.2
grep -Fq 'must preserve existing tab' "$LOG" && { echo 'FAIL: first session assignment overwrote manual cmux title'; exit 1; }
echo 'PASS: first session assignment preserves an existing manual cmux title'

printf '%s' 'raw native title' > "$TMP/current-title"
request session-e
append '{"type":"ai-title","aiTitle":"raw native title","sessionId":"session-e"}'
wait_for_title 'raw native title | alpha' || { echo 'FAIL: raw native title was not claimed'; exit 1; }
printf '%s' '✳ spinner title' > "$TMP/current-title"
request session-f
append '{"type":"ai-title","aiTitle":"spinner title","sessionId":"session-f"}'
wait_for_title 'spinner title | alpha' || { echo 'FAIL: spinner native title was not claimed'; exit 1; }
echo 'PASS: caller metadata, raw native, and spinner first titles are claimed'

printf '%s' '/private/shell/path' > "$TMP/current-title"
request session-g
append '{"type":"ai-title","aiTitle":"after clear","sessionId":"session-g"}'
sleep 0.15
grep -Fq 'after clear | alpha' "$LOG" && { echo 'FAIL: shell cwd froze or renamed before native OSC'; exit 1; }
printf '%s' 'after clear' > "$TMP/current-title"
wait_for_title 'after clear | alpha' || { echo 'FAIL: native title after clear was not retried'; exit 1; }
touch "$TMP/tree-fail"
append '{"type":"custom-title","customTitle":"after transient query","sessionId":"session-g"}'
wait_for_title 'after transient query | alpha' || { echo 'FAIL: transient tree error did not recover'; exit 1; }
echo 'PASS: shell cwd and transient tree query retry without freezing'
