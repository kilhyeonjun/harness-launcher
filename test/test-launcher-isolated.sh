#!/usr/bin/env zsh
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HARNESS="$TMP/harness"
STATE="$TMP/state"
mkdir -p "$HARNESS/config/.local"
mkdir -p "$HARNESS/projects/product"
git -C "$HARNESS" init -q -b main
git -C "$HARNESS" config user.email test@example.invalid
git -C "$HARNESS" config user.name test
print -r -- 'HARNESS_NAME="test"' 'HARNESS_PREFIX="test"' > "$HARNESS/config/launcher.env"
print -r -- 'KIRO_GATEWAY_URL="http://127.0.0.1:9999"' > "$HARNESS/config/.local/kiro-gateway.env"
print -r -- '{"mcpServers":{}}' > "$HARNESS/.mcp.local.json"
print -r -- tracked > "$HARNESS/tracked.txt"
git -C "$HARNESS" add config/launcher.env tracked.txt && git -C "$HARNESS" commit -qm initial
print -r -- dirty > "$HARNESS/tracked.txt"

cat > "$TMP/claude" <<'EOF'
#!/usr/bin/env bash
printf 'PWD=%s\nSOURCE=%s\nSESSION=%s\nRUN=%s\nBASE=%s\n' "$PWD" "${HARNESS_SOURCE_ROOT:-}" "${HARNESS_SESSION_ROOT:-}" "${HARNESS_RUN_DIR:-}" "${ANTHROPIC_BASE_URL:-}" > "$ISOLATED_LOG"
if [[ -n "${WAIT_START:-}" ]]; then
  touch "$WAIT_START"
  while [[ ! -e "$WAIT_RELEASE" ]]; do sleep 0.05; done
fi
EOF
chmod +x "$TMP/claude"

(
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ISOLATED_LOG="$TMP/log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" --isolated base
)

root="$(sed -n 's/^SESSION=//p' "$TMP/log")"
[[ -n "$root" && "$(sed -n 's/^PWD=//p' "$TMP/log")" == "$root" ]] || { echo 'FAIL: --isolated must launch root sessions in session root'; exit 1; }
[[ "$(sed -n 's/^SOURCE=//p' "$TMP/log")" == "${HARNESS:A}" ]] || { echo 'FAIL: --isolated must export canonical source root'; exit 1; }
[[ "$(<"$root/tracked.txt")" == tracked ]] || { echo 'FAIL: --isolated must not use canonical dirty files'; exit 1; }
[[ -L "$root/.mcp.local.json" && "$(readlink "$root/.mcp.local.json")" == "${HARNESS:A}/.mcp.local.json" ]] || { echo 'FAIL: isolated session must reference canonical machine-local MCP config'; exit 1; }
first_id="$(basename "$root")"
(
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ISOLATED_LOG="$TMP/resume-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" --isolated-session "$first_id" base
)
[[ "$(sed -n 's/^SESSION=//p' "$TMP/resume-log")" == "$root" ]] || { echo 'FAIL: resume must preserve the UUID workspace identity'; exit 1; }

(
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ISOLATED_LOG="$TMP/product-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" --cwd "$HARNESS/projects/product" --isolated base
)
PRODUCT_REAL="$(cd "$HARNESS/projects/product" && pwd -P)"
[[ "$(sed -n 's/^PWD=//p' "$TMP/product-log")" == "$PRODUCT_REAL" ]] || { echo 'FAIL: --isolated must preserve explicit product cwd'; exit 1; }

(
  export PATH="$TMP:$PATH" ISOLATED_LOG="$TMP/default-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" base
)
[[ -z "$(sed -n 's/^SESSION=//p' "$TMP/default-log")" ]] || { echo 'FAIL: default launch must remain non-isolated'; exit 1; }

(
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE"
  source "$ROOT/bin/aliases.zsh"
  export ISOLATED_LOG="$TMP/leak-isolated-log"
  _harness_launcher_run "$HARNESS" --isolated base
  export ISOLATED_LOG="$TMP/leak-default-log"
  _harness_launcher_run "$HARNESS" base
)
[[ -z "$(sed -n 's/^SESSION=//p' "$TMP/leak-default-log")" ]] || { echo 'FAIL: isolated identity must not leak into the next launch'; exit 1; }

(
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ISOLATED_LOG="$TMP/gateway-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_probe_provider_health() { return 0; }
  _harness_launcher_run "$HARNESS" --isolated kiro base
)
[[ "$(sed -n 's/^BASE=//p' "$TMP/gateway-log")" == 'http://127.0.0.1:9999' ]] || { echo 'FAIL: isolated gateway must read canonical machine-local config'; exit 1; }

WAIT_START="$TMP/wait-start"; WAIT_RELEASE="$TMP/wait-release"
(
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_HEARTBEAT_SECONDS=0.2
  export HARNESS_SESSION_STALE_SECONDS=1 ISOLATED_LOG="$TMP/heartbeat-log" WAIT_START WAIT_RELEASE
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" --isolated base
) & launcher_pid=$!
for _ in {1..100}; do [[ -f "$WAIT_START" ]] && break; sleep 0.05; done
[[ -f "$WAIT_START" ]] || { kill "$launcher_pid" 2>/dev/null || true; echo 'FAIL: heartbeat fixture did not launch runtime'; exit 1; }
sleep 2.2
heartbeat_id="$(basename "$(sed -n 's/^SESSION=//p' "$TMP/heartbeat-log")")"
HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_STALE_SECONDS=1 "$ROOT/bin/session-isolation.sh" list | grep -qx "$heartbeat_id OPEN" || { touch "$WAIT_RELEASE"; wait "$launcher_pid"; echo 'FAIL: live isolated runtime heartbeat must prevent abandonment'; exit 1; }
touch "$WAIT_RELEASE"; wait "$launcher_pid"; sleep 1.2
HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_STALE_SECONDS=1 "$ROOT/bin/session-isolation.sh" list | grep -qx "$heartbeat_id CLOSED" || { echo 'FAIL: clean normal runtime exit must become CLOSED'; exit 1; }

echo 'PASS: --isolated opts root sessions into an isolated repository'
