#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
FAKE_HELPER="$TMP/fake-helper"
BROKER_LOG="$TMP/broker.log"

cleanup() {
  harness_codex_cmux_broker_stop 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$FAKE_HELPER" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$BROKER_LOG"
sleep 30
SH
chmod +x "$FAKE_HELPER"
export BROKER_LOG

# shellcheck source=../bin/harness-common.sh
source "$ROOT/bin/harness-common.sh"

export CODEX_HOME="$TMP/codex-home"
export HARNESS_PREFIX="alpha"
export CMUX_WORKSPACE_ID="workspace:7"
export CMUX_TAB_ID="tab:24"
export CMUX_SURFACE_ID="surface:24"

harness_codex_cmux_broker_start "$FAKE_HELPER"
[[ -n "${CODEX_CMUX_TITLE_REQUEST_FILE:-}" ]] || {
  echo "FAIL: broker request path was not exported"
  exit 1
}
[[ -f "$CODEX_CMUX_TITLE_REQUEST_FILE" ]] || {
  echo "FAIL: broker request file was not created"
  exit 1
}
for _ in $(seq 1 40); do
  [[ -s "$BROKER_LOG" ]] && break
  sleep 0.05
done
grep -q -- "--broker $CODEX_CMUX_TITLE_REQUEST_FILE surface:24 alpha $CODEX_HOME" "$BROKER_LOG" || {
  echo "FAIL: helper did not receive exact broker target"
  cat "$BROKER_LOG"
  exit 1
}
harness_codex_cmux_broker_stop
[[ -z "${CODEX_CMUX_TITLE_REQUEST_FILE:-}" ]] || {
  echo "FAIL: broker request path leaked after cleanup"
  exit 1
}
echo "PASS: launcher starts and cleans an exact cmux title broker"

unset CMUX_SURFACE_ID CMUX_TAB_ID CMUX_WORKSPACE_ID
harness_codex_cmux_broker_start "$FAKE_HELPER"
[[ -z "${CODEX_CMUX_TITLE_REQUEST_FILE:-}" ]] || {
  echo "FAIL: non-cmux launch exported a broker request path"
  exit 1
}
echo "PASS: non-cmux launches skip the broker"

export CMUX_WORKSPACE_ID="workspace:7" CMUX_TAB_ID="tab:24" CMUX_SURFACE_ID="surface:24"
harness_claude_cmux_broker_start "$FAKE_HELPER" "$TMP/fake-harness"
[[ -d "${CLAUDE_CMUX_TITLE_STATE_DIR:-}" && -f "${CLAUDE_CMUX_TITLE_REQUEST_FILE:-}" ]] || {
  echo "FAIL: Claude broker did not export a private state and request file"
  exit 1
}
[[ "${CLAUDE_CMUX_TITLE_HELPER:-}" == "$FAKE_HELPER" ]] || {
  echo "FAIL: Claude hook handoff environment is incomplete"
  exit 1
}
[[ "$(dirname "$CLAUDE_CMUX_TITLE_REQUEST_FILE")" == "$CLAUDE_CMUX_TITLE_STATE_DIR" ]] || {
  echo "FAIL: Claude request is not inside its private launch state"
  exit 1
}
for _ in $(seq 1 40); do
  grep -Fq -- "--claude-broker $CLAUDE_CMUX_TITLE_REQUEST_FILE surface:24 alpha $TMP/fake-harness/.harness/claude" "$BROKER_LOG" && break
  sleep 0.05
done
grep -Fq -- "--claude-broker $CLAUDE_CMUX_TITLE_REQUEST_FILE surface:24 alpha $TMP/fake-harness/.harness/claude" "$BROKER_LOG" || {
  echo "FAIL: Claude helper did not receive exact broker target"
  cat "$BROKER_LOG"
  exit 1
}
CLAUDE_STATE="$CLAUDE_CMUX_TITLE_STATE_DIR"
harness_claude_cmux_broker_stop
[[ ! -e "$CLAUDE_STATE" && -z "${CLAUDE_CMUX_TITLE_REQUEST_FILE:-}" && -z "${CLAUDE_CMUX_TITLE_HELPER:-}" ]] || {
  echo "FAIL: Claude broker state leaked after cleanup"
  exit 1
}
echo "PASS: launcher creates one private Claude broker state per launch"

SENTINEL_DIR="$TMP/sentinel"
mkdir "$SENTINEL_DIR"
printf 'keep' > "$SENTINEL_DIR/keep"
ln -s "$SENTINEL_DIR" "$TMP/poison-root"
export CLAUDE_CMUX_TITLE_STATE_ROOT="$TMP/poison-root"
harness_claude_cmux_broker_start "$FAKE_HELPER" "$TMP/fake-harness"
[[ "$(cat "$SENTINEL_DIR/keep")" == keep && ! -e "$SENTINEL_DIR/launch.poison" ]] || {
  echo "FAIL: poisoned Claude state-root changed its symlink target"
  exit 1
}
unset CLAUDE_CMUX_TITLE_STATE_ROOT
echo "PASS: launcher rejects a symlinked Claude state root without mutating its target"

[[ "$(grep -c 'harness_codex_cmux_broker_start.*codex-cmux-title-sync.py' "$ROOT/bin/aliases.zsh")" -ge 2 ]] || {
  echo "FAIL: direct/raw Codex launcher paths do not start the broker"
  exit 1
}
grep -q 'harness_codex_cmux_broker_start.*codex-cmux-title-sync.py' "$ROOT/bin/launcher.sh" || {
  echo "FAIL: launchpad Codex path does not start the broker"
  exit 1
}
echo "PASS: raw, direct, and launchpad Codex paths start the broker"

grep -q 'harness_claude_cmux_broker_start.*codex-cmux-title-sync.py' "$ROOT/bin/aliases.zsh" || {
  echo "FAIL: direct Claude launcher path does not start the broker"
  exit 1
}
grep -q 'harness_claude_cmux_broker_start.*codex-cmux-title-sync.py' "$ROOT/bin/launcher.sh" || {
  echo "FAIL: launchpad Claude path does not start the broker"
  exit 1
}
echo "PASS: direct and launchpad Claude paths start the broker"
