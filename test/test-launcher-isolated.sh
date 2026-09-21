#!/usr/bin/env zsh
set -e

# The launcher test exercises isolation, not the terminal title broker. Keep
# ambient cmux identity from spawning a real broker in the fixture shell.
unset CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SURFACE_ID

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
print -r -- '{"mcpServers":{"local-docs":{"command":"echo","args":["ready"]}}}' > "$HARNESS/.mcp.local.json"
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
) 2>"$TMP/explicit-isolated.err"

root="$(sed -n 's/^SESSION=//p' "$TMP/log")"
[[ -n "$root" && "$(sed -n 's/^PWD=//p' "$TMP/log")" == "$root" ]] || { echo 'FAIL: --isolated must launch root sessions in session root'; exit 1; }
[[ "$(sed -n 's/^SOURCE=//p' "$TMP/log")" == "${HARNESS:A}" ]] || { echo 'FAIL: --isolated must export canonical source root'; exit 1; }
[[ "$(<"$root/tracked.txt")" == tracked ]] || { echo 'FAIL: --isolated must not use canonical dirty files'; exit 1; }
[[ -L "$root/.mcp.local.json" && "$(readlink "$root/.mcp.local.json")" == "${HARNESS:A}/.mcp.local.json" ]] || { echo 'FAIL: isolated session must reference canonical machine-local MCP config'; exit 1; }
first_id="$(basename "$root")"
grep -q "isolated session $first_id; continue: test --isolated-session $first_id resume" "$TMP/explicit-isolated.err" || { echo 'FAIL: explicit isolation must print the UUID continuation command'; exit 1; }
explicit_count="$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if (
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_ISOLATION=1 ISOLATED_LOG="$TMP/ambient-resume-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" resume
); then
  echo 'FAIL: ambient isolation must reject generic resume before cloning'; exit 1
fi
if (
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_ISOLATION=1 ISOLATED_LOG="$TMP/option-resume-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" codex --model gpt-5.6 resume
); then
  echo 'FAIL: option-prefixed Codex resume must be found before cloning'; exit 1
fi
if (
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ISOLATED_LOG="$TMP/new-resume-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" --isolated resume
); then
  echo 'FAIL: --isolated resume must require an exact UUID instead of creating a new root'; exit 1
fi
if (
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ISOLATED_LOG="$TMP/conflicting-control-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" --isolated base --no-isolated
); then
  echo 'FAIL: conflicting isolation controls must be rejected'; exit 1
fi
[[ "$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq "$explicit_count" ]] || { echo 'FAIL: rejected isolation controls must not create a session'; exit 1; }
[[ ! -e "$TMP/ambient-resume-log" && ! -e "$TMP/option-resume-log" ]] || { echo 'FAIL: rejected continuations must not launch a runtime'; exit 1; }
(
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ISOLATED_LOG="$TMP/resume-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" --isolated-session "$first_id" base
)
[[ "$(sed -n 's/^SESSION=//p' "$TMP/resume-log")" == "$root" ]] || { echo 'FAIL: resume must preserve the UUID workspace identity'; exit 1; }

LEASE_START="$TMP/lease-start"; LEASE_RELEASE="$TMP/lease-release"
(
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ISOLATED_LOG="$TMP/lease-owner-log"
  export WAIT_START="$LEASE_START" WAIT_RELEASE="$LEASE_RELEASE"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" --isolated-session "$first_id" base
) & lease_owner_pid=$!
for _ in {1..300}; do [[ -f "$LEASE_START" ]] && break; sleep 0.05; done
[[ -f "$LEASE_START" ]] || { kill "$lease_owner_pid" 2>/dev/null || true; echo 'FAIL: lease owner did not enter the runtime'; exit 1; }
if (
  export PATH="$TMP:$PATH" HARNESS_SESSION_STATE_HOME="$STATE" ISOLATED_LOG="$TMP/lease-contender-log"
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run "$HARNESS" --isolated-session "$first_id" base
); then
  touch "$LEASE_RELEASE"; wait "$lease_owner_pid"
  echo 'FAIL: a second launcher must not own the same UUID concurrently'; exit 1
fi
[[ ! -e "$TMP/lease-contender-log" ]] || { touch "$LEASE_RELEASE"; wait "$lease_owner_pid"; echo 'FAIL: rejected lease contender must not launch Claude'; exit 1; }
touch "$LEASE_RELEASE"; wait "$lease_owner_pid"

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

# Profile canary defaults only fresh interactive Claude/Codex routes into an
# isolated root. Explicit rollback and continuation classification happen
# before any session record or worktree is created.
print -r -- 'HARNESS_SESSION_ISOLATION_DEFAULT="1"' >> "$HARNESS/config/launcher.env"
run_tty() {
  local log="$1"; shift
  ROOT="$ROOT" HARNESS="$HARNESS" STATE="$STATE" TMP="$TMP" ISOLATED_LOG="$log" TEST_ARGS="${(j: :)${(q)@}}" AMBIENT_ISOLATION="${TEST_AMBIENT_ISOLATION-}" expect <<'EXPECT'
set timeout 15
log_user 0
spawn env ROOT=$env(ROOT) HARNESS=$env(HARNESS) STATE=$env(STATE) TMP=$env(TMP) ISOLATED_LOG=$env(ISOLATED_LOG) TEST_ARGS=$env(TEST_ARGS) HARNESS_SESSION_ISOLATION=$env(AMBIENT_ISOLATION) PATH=$env(TMP):/usr/bin:/bin zsh -c {
  export PATH="$TMP:/usr/bin:/bin" HARNESS_SESSION_STATE_HOME="$STATE"
  unset CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SURFACE_ID
  source "$ROOT/bin/aliases.zsh"
  eval "set -- $TEST_ARGS"
  _harness_launcher_run "$HARNESS" "$@"
}
expect eof
catch wait result
exit [lindex $result 3]
EXPECT
}

before_count=$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if TEST_AMBIENT_ISOLATION=0 run_tty "$TMP/ambient-zero-resume-log" resume; then
  echo 'FAIL: ambient zero must not replace the explicit --no-isolated rollback'; exit 1
fi
[[ ! -e "$TMP/ambient-zero-resume-log" ]] || { echo 'FAIL: ambient-zero continuation rejection must not launch Claude'; exit 1; }
[[ "$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq "$before_count" ]] || { echo 'FAIL: ambient-zero continuation rejection must not allocate a session'; exit 1; }
run_tty "$TMP/profile-default-log" base
profile_root="$(sed -n 's/^SESSION=//p' "$TMP/profile-default-log")"
[[ -n "$profile_root" && "$profile_root" != "${HARNESS:A}" ]] || { echo 'FAIL: profile default must isolate a fresh interactive Claude launch'; exit 1; }
after_default_count=$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[[ "$after_default_count" -eq $((before_count + 1)) ]] || { echo 'FAIL: profile default must create exactly one session'; exit 1; }

run_tty "$TMP/no-isolated-log" --no-isolated base
[[ -z "$(sed -n 's/^SESSION=//p' "$TMP/no-isolated-log")" ]] || { echo 'FAIL: --no-isolated must override profile default'; exit 1; }
[[ "$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq "$after_default_count" ]] || { echo 'FAIL: --no-isolated must not create a session'; exit 1; }

if run_tty "$TMP/rejected-resume-log" base resume; then
  echo 'FAIL: generic resume must not silently switch an isolated profile to canonical state'
  exit 1
fi
[[ ! -e "$TMP/rejected-resume-log" ]] || { echo 'FAIL: rejected resume must not launch Claude'; exit 1; }
[[ "$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq "$after_default_count" ]] || { echo 'FAIL: rejected resume must not create a session'; exit 1; }

run_tty "$TMP/print-log" base -p 'batch task'
[[ -z "$(sed -n 's/^SESSION=//p' "$TMP/print-log")" ]] || { echo 'FAIL: print mode must remain legacy under profile default'; exit 1; }
[[ "$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq "$after_default_count" ]] || { echo 'FAIL: print mode must not create a session'; exit 1; }

ROOT="$ROOT" HARNESS="$HARNESS" STATE="$STATE" TMP="$TMP" CODEX_LOG="$TMP/codex-default-log" expect <<'EXPECT'
set timeout 15
log_user 0
spawn env ROOT=$env(ROOT) HARNESS=$env(HARNESS) STATE=$env(STATE) TMP=$env(TMP) CODEX_LOG=$env(CODEX_LOG) PATH=$env(TMP):/usr/bin:/bin zsh -c {
  export PATH="$TMP:/usr/bin:/bin" HARNESS_SESSION_STATE_HOME="$STATE"
  unset CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SURFACE_ID
  source "$ROOT/bin/aliases.zsh"
  _harness_launcher_run_codex_cli() {
    printf 'SOURCE=%s\nSESSION=%s\n' "${HARNESS_SOURCE_ROOT:-}" "${HARNESS_SESSION_ROOT:-}" > "$CODEX_LOG"
  }
  _harness_launcher_run "$HARNESS" codex base
}
expect eof
catch wait result
exit [lindex $result 3]
EXPECT
[[ -n "$(sed -n 's/^SESSION=//p' "$TMP/codex-default-log")" ]] || { echo 'FAIL: profile default must isolate a fresh interactive Codex launch'; exit 1; }
[[ "$(find "$STATE/sessions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq $((after_default_count + 1)) ]] || { echo 'FAIL: Codex profile default must create exactly one session'; exit 1; }

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
for _ in {1..300}; do [[ -f "$WAIT_START" ]] && break; sleep 0.05; done
[[ -f "$WAIT_START" ]] || { touch "$WAIT_RELEASE"; wait "$launcher_pid" 2>/dev/null || true; echo 'FAIL: heartbeat fixture did not launch runtime'; exit 1; }
sleep 2.2
heartbeat_id="$(basename "$(sed -n 's/^SESSION=//p' "$TMP/heartbeat-log")")"
HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_STALE_SECONDS=1 "$ROOT/bin/session-isolation.sh" list | grep -qx "$heartbeat_id OPEN" || { touch "$WAIT_RELEASE"; wait "$launcher_pid"; echo 'FAIL: live isolated runtime heartbeat must prevent abandonment'; exit 1; }
touch "$WAIT_RELEASE"; wait "$launcher_pid"; sleep 1.2
HARNESS_SESSION_STATE_HOME="$STATE" HARNESS_SESSION_STALE_SECONDS=1 "$ROOT/bin/session-isolation.sh" list | grep -qx "$heartbeat_id CLOSED" || { echo 'FAIL: clean normal runtime exit must become CLOSED'; exit 1; }

echo 'PASS: --isolated opts root sessions into an isolated repository'
