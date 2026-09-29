#!/usr/bin/env bash
# test-cmux-orca-guard.sh — the cmux title brokers must not act on stale CMUX_*
# variables inside an Orca terminal, and must be unchanged inside plain cmux.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$ROOT/bin/codex-cmux-title-sync.py"
TMP="$(mktemp -d)"
OWNER_PID=""
cleanup() {
  harness_codex_cmux_broker_stop 2>/dev/null || true
  harness_claude_cmux_broker_stop 2>/dev/null || true
  [[ -z "$OWNER_PID" ]] || kill "$OWNER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

unset ORCA_TERMINAL_HANDLE TERM_PROGRAM
# shellcheck source=../bin/harness-common.sh
source "$ROOT/bin/harness-common.sh"

HELPER="$TMP/helper"
cat > "$HELPER" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BROKER_LOG"
sleep 30
SH
chmod +x "$HELPER"
export BROKER_LOG="$TMP/broker.log"
export CODEX_HOME="$TMP/codex-home" HARNESS_PREFIX=alpha
export CLAUDE_CMUX_TITLE_STATE_ROOT="$TMP/claude-state"
export CMUX_WORKSPACE_ID=workspace:1 CMUX_TAB_ID=tab:1 CMUX_SURFACE_ID=surface:1

wait_log() { for _ in $(seq 1 40); do [[ -s "$BROKER_LOG" ]] && return 0; sleep 0.05; done; return 1; }

# cmux-only environment: both brokers start.
harness_codex_cmux_broker_start "$HELPER"
wait_log || fail 'codex broker must start in cmux-only environment'
harness_codex_cmux_broker_stop
: > "$BROKER_LOG"
harness_claude_cmux_broker_start "$HELPER" "$TMP/harness"
wait_log || fail 'claude broker must start in cmux-only environment'
harness_claude_cmux_broker_stop

# Orca markers with stale CMUX_*: no broker at all.
guard_case() { # <label> <env assignments...>
  local label="$1"; shift
  : > "$BROKER_LOG"
  (
    export "$@"
    harness_codex_cmux_broker_start "$HELPER"
    [[ -z "${CODEX_CMUX_TITLE_REQUEST_FILE:-}" ]] || exit 11
    harness_claude_cmux_broker_start "$HELPER" "$TMP/harness"
    [[ -z "${CLAUDE_CMUX_TITLE_REQUEST_FILE:-}" ]] || exit 12
    sleep 0.3
    harness_codex_cmux_broker_stop; harness_claude_cmux_broker_stop
  ) || fail "$label: broker exported a request file"
  [[ ! -s "$BROKER_LOG" ]] || fail "$label: broker helper was invoked"
}
guard_case 'ORCA_TERMINAL_HANDLE' ORCA_TERMINAL_HANDLE=term_1
guard_case 'TERM_PROGRAM=Orca' TERM_PROGRAM=Orca

# session_start hook: no request written under Orca; written under cmux only.
sleep 30 & OWNER_PID=$!
mkdir -p "$TMP/state" && chmod 700 "$TMP/state"
run_hook() { # <request> <extra env...>
  local req="$1"; shift
  printf '%s\n' '{"hook_event_name":"SessionStart","session_id":"s-1"}' |
    env "$@" HARNESS_PREFIX=alpha CODEX_HOME="$CODEX_HOME" CMUX_SURFACE_ID=surface:1 \
      CODEX_CMUX_TITLE_REQUEST_FILE="$req" CODEX_CMUX_TITLE_STATE_DIR="$TMP/state" \
      CODEX_CMUX_TITLE_OWNER_PID="$OWNER_PID" python3 "$SYNC"
}
: > "$TMP/state/req-cmux"; chmod 600 "$TMP/state/req-cmux"
run_hook "$TMP/state/req-cmux" FOO=1
[[ -s "$TMP/state/req-cmux" ]] || fail 'session_start must write a broker request under cmux'
: > "$TMP/state/req-orca"; chmod 600 "$TMP/state/req-orca"
run_hook "$TMP/state/req-orca" ORCA_TERMINAL_HANDLE=term_1
[[ ! -s "$TMP/state/req-orca" ]] || fail 'session_start must return 0 without acting under Orca'

echo 'PASS: test-cmux-orca-guard'
