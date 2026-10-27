#!/usr/bin/env zsh
# Isolated launch paths: the usage policy reaches the launched agent (Claude
# --settings env, child-process discard exports, Codex child environment), and
# launch entries reconcile collection.d (P3 end to end). Checkup's environment
# helper is covered separately on noncanonical unit fixtures.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
fail() { print -u2 -r -- "FAIL: $*"; exit 1; }

export HOME="$TMP/home"; mkdir -p "$HOME"
unset HARNESS_AGENT_USAGE_STATE_DIR  # the manifests live under this test HOME
export HARNESS_AGENT_USAGE_TEST_MODE=1 HARNESS_SESSION_STATE_HOME="$HOME/.local/state/harness-launcher"
GUARD="$TMP/guard"
export HARNESS_AGENT_USAGE_GUARD_DIR="$GUARD" HARNESS_AGENT_USAGE_TEST_OWNER_UID="$(id -u)"
export HARNESS_CLAUDE_PLUGIN_MIRROR=0 HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$TMP/no-marketplace"
unset CMUX_WORKSPACE_ID CMUX_TAB_ID CMUX_SURFACE_ID CLAUDE_CONFIG_DIR HARNESS_PYTHON_BIN
unset HARNESS_SESSION_ROOT HARNESS_SESSION_ID HARNESS_SOURCE_ROOT HARNESS_RUN_DIR
mkdir -p "$GUARD/$(id -u)"; chmod 755 "$GUARD" "$GUARD/$(id -u)"; : > "$GUARD/$(id -u)/agent-assertion.jwt"
COLL="$HOME/.agent-usage/collection.d"
PY="$(source "$ROOT/bin/harness-common.sh"; harness_python3_resolve)"

cat > "$TMP/claude" <<'STUB'
#!/bin/bash
{
  printf 'ARGS:%s\n' "$*"
  env | grep -E '^(OTEL_EXPORTER_OTLP_|CLAUDE_CODE_ENABLE_TELEMETRY)' | LC_ALL=C sort
} > "$TEST_STUB_FILE"
STUB
cat > "$TMP/codex" <<'STUB'
#!/bin/bash
case "$1" in --version) echo "codex-cli 0.153.2"; exit 0 ;; esac
{ env | grep -E '^OTEL_EXPORTER_OTLP_' | LC_ALL=C sort; echo "CODEX_HOME=$CODEX_HOME"; } > "$TEST_STUB_FILE"
STUB
chmod +x "$TMP/claude" "$TMP/codex"
export HARNESS_CODEX_BIN="$TMP/codex"

mk() { # <dir> <prefix> <collect>
  mkdir -p "$1/config/.local"
  printf 'HARNESS_NAME="%s"\nHARNESS_PREFIX="%s"\n' "$2" "$2" > "$1/config/launcher.env"
  [[ "$3" != 1 ]] || print -r -- 'HARNESS_AGENT_USAGE_COLLECT="1"' >> "$1/config/launcher.env"
  print -r -- '# fixture' > "$1/CLAUDE.md"
}
mk "$HOME/personal" pers 0; mk "$HOME/company" comp 1
# Exercise installed session machinery rather than launching agents in registered
# canonical roots. The local configuration is intentionally absent from clones.
bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$TMP/runtime"
BIN="$TMP/runtime/share/harness-launcher"
for h in "$HOME/personal" "$HOME/company"; do
  git -C "$h" init -q -b main
  git -C "$h" add config/launcher.env CLAUDE.md
  git -C "$h" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
done
session_fixture() { # <source> -> session exports
  "$BIN/session-isolation.sh" create "$1"
}
personal_session="$(session_fixture "$HOME/personal")"
company_session="$(session_fixture "$HOME/company")"
# Parse the real creator's output as data, not shell code.
for record in "${(@f)personal_session}"; do
  case "$record" in
    HARNESS_SESSION_ID=*) PERSONAL_ID="${record#*=}" ;;
    HARNESS_SESSION_ROOT=*) PERSONAL_ROOT="${record#*=}" ;;
  esac
done
for record in "${(@f)company_session}"; do
  case "$record" in
    HARNESS_SESSION_ID=*) COMPANY_ID="${record#*=}" ;;
    HARNESS_SESSION_ROOT=*) COMPANY_ROOT="${record#*=}" ;;
  esac
done
session_for() {
  case "$1" in
    "$HOME/personal") SESSION_ID="$PERSONAL_ID"; SESSION_ROOT="$PERSONAL_ROOT" ;;
    "$HOME/company") SESSION_ID="$COMPANY_ID"; SESSION_ROOT="$COMPANY_ROOT" ;;
    *) fail "unknown session fixture: $1" ;;
  esac
}

run() { # <harness> <args...>  -> $TMP/out
  local h="$1"; shift
  session_for "$h"
  rm -f "$TMP/out"
  (
    export TEST_STUB_FILE="$TMP/out" PATH="$TMP:$PATH"
    source "$BIN/aliases.zsh"
    harness_register "$HOME/personal" >/dev/null; harness_register "$HOME/company" >/dev/null
    _harness_launcher_run "$h" --isolated-session "$SESSION_ID" "$@"
  ) >/dev/null 2>"$TMP/err" || true
  [[ -f "$TMP/out" ]] || { cat "$TMP/err" >&2; fail "stub not launched: $*"; }
}

# Claude, personal profile: telemetry off for the main process, discard for children
run "$HOME/personal" base
grep -q '^ARGS:.*--settings {.*"env":{"CLAUDE_CODE_ENABLE_TELEMETRY":"0"}' "$TMP/out" || fail "personal Claude launch must carry the --settings env: $(<$TMP/out)"
for v in LOGS METRICS TRACES; do
  grep -qx "OTEL_EXPORTER_OTLP_${v}_ENDPOINT=http://127.0.0.1:9/v1/${(L)v}" "$TMP/out" || fail "discard endpoint for $v missing"
  grep -qx "OTEL_EXPORTER_OTLP_${v}_HEADERS=" "$TMP/out" || fail "empty headers for $v missing"
done
[[ -d "$COLL" && -f "$COLL/harness-launcher-profile-pers.json" ]] || fail 'every launch must reconcile collection.d (personal profile exclusion)'
[[ ! -e "$COLL/harness-launcher-profile-comp.json" ]] || fail 'collecting profile has no exclusion manifest'

# Claude, collecting profile: nothing set
run "$HOME/company" base
grep -q -- '"env"' "$TMP/out" && fail 'collecting Claude launch must not set an env block'
grep -q '^OTEL_EXPORTER_OTLP_' "$TMP/out" && fail 'collecting Claude launch must not export discard endpoints'

# Claude, personal profile on a non-company device or with the local override
rm -rf "$GUARD"
run "$HOME/company" base
grep -q '"CLAUDE_CODE_ENABLE_TELEMETRY":"0"' "$TMP/out" || fail 'non-company device must disable Claude telemetry'
mkdir -p "$GUARD/$(id -u)"; chmod 755 "$GUARD" "$GUARD/$(id -u)"; : > "$GUARD/$(id -u)/agent-assertion.jwt"

# Codex children inherit the discard exports for a personal profile only
run "$HOME/personal" codex
grep -qx 'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://127.0.0.1:9/v1/logs' "$TMP/out" || fail "personal Codex launch must export discard endpoints: $(<$TMP/out)"
run "$HOME/company" codex
grep -q '^OTEL_EXPORTER_OTLP_' "$TMP/out" && fail 'collecting Codex launch must not export discard endpoints'

# ---- H1: a harness-exec launch (fresh shell, empty registry) reconciles the
# sessions of other harnesses by their own source roots
STATE="$HARNESS_SESSION_STATE_HOME"
SIDC="$COMPANY_ID"
mkdir -p "$COMPANY_ROOT/.harness/codex/sessions"
rm -f "$COLL/harness-launcher-$SIDC.json"
rm -f "$TMP/out"
( export TEST_STUB_FILE="$TMP/out" PATH="$TMP:$PATH"; cd "$TMP"; "$TMP/runtime/bin/harness-exec" "$HOME/personal" --isolated base ) >/dev/null 2>"$TMP/err" || true
[[ -f "$TMP/out" ]] || { cat "$TMP/err" >&2; fail 'harness-exec stub not launched'; }
"$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["include"]) == 2, d' "$COLL/harness-launcher-$SIDC.json" 2>/dev/null \
  || fail "a personal harness-exec launch must keep the collecting session included: $(cat "$COLL/harness-launcher-$SIDC.json" 2>/dev/null)"

# ---- M3: launcher.sh Codex (TUI) drops inherited discard exports first
tui() { # <harness> <prefix> <input>
  session_for "$1"
  rm -f "$TMP/out"
  ( export TEST_STUB_FILE="$TMP/out" PATH="$TMP:$PATH" HARNESS_DIR="$SESSION_ROOT" HARNESS_NAME="$2" HARNESS_PREFIX="$2"
    export HARNESS_SOURCE_ROOT="$1" HARNESS_SESSION_ROOT="$SESSION_ROOT" HARNESS_SESSION_ID="$SESSION_ID" HARNESS_RUN_DIR="$SESSION_ROOT"
    bash "$BIN/launcher.sh" <<< "$3" ) >"$TMP/tui.log" 2>&1 || true
  [[ -f "$TMP/out" ]] || { cat "$TMP/tui.log" >&2; fail "launcher.sh stub not launched ($1)"; }
}
(
  # A personal shell exported the discard set; a collecting Codex drops it.
  export OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://127.0.0.1:9/v1/logs OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=http://127.0.0.1:9/v1/metrics
  export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:9/v1/traces OTEL_EXPORTER_OTLP_LOGS_HEADERS= OTEL_EXPORTER_OTLP_METRICS_HEADERS= OTEL_EXPORTER_OTLP_TRACES_HEADERS=
  tui "$HOME/company" comp $'2\n1\n2\n1\n1\n'
  grep -q '^OTEL_EXPORTER_OTLP_' "$TMP/out" && fail "launcher.sh Codex must drop inherited discard exports for a collecting profile: $(<$TMP/out)"
  tui "$HOME/personal" pers $'2\n1\n2\n1\n1\n'
  grep -qx 'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://127.0.0.1:9/v1/logs' "$TMP/out" || fail 'launcher.sh personal Codex keeps the discard set'
  exit 0
) || exit 1

# ---- H4: Codex with local observability on and an inactive policy: Claude
# children point at the loopback collector with empty signal headers
# Observability is workspace-local; create it in the real isolated fixture,
# whose config/.local is deliberately not imported from its canonical source.
mkdir -p "$PERSONAL_ROOT/config/.local"
print -r -- $'HARNESS_OBSERVABILITY_ENABLED=1\nHARNESS_OTLP_HTTP_ENDPOINT=http://127.0.0.1:4318' > "$PERSONAL_ROOT/config/.local/observability.env"
chmod 600 "$PERSONAL_ROOT/config/.local/observability.env"
check_loopback() { # <label>
  local v
  for v in LOGS METRICS TRACES; do
    grep -qx "OTEL_EXPORTER_OTLP_${v}_ENDPOINT=http://127.0.0.1:4318/v1/${(L)v}" "$TMP/out" || fail "$1: loopback $v endpoint missing: $(<$TMP/out)"
    grep -qx "OTEL_EXPORTER_OTLP_${v}_HEADERS=" "$TMP/out" || fail "$1: empty $v headers missing"
  done
}
run "$HOME/personal" codex
check_loopback 'shortcut Codex'
tui "$HOME/personal" pers $'2\n1\n2\n1\n1\n'
check_loopback 'launcher.sh Codex'
rm -f "$TMP/out"
(
  export TEST_STUB_FILE="$TMP/out" PATH="$TMP:$PATH"
  export HARNESS_SOURCE_ROOT="$HOME/personal" HARNESS_SESSION_ROOT="$PERSONAL_ROOT" HARNESS_SESSION_ID="$PERSONAL_ID" HARNESS_RUN_DIR="$PERSONAL_ROOT"
  source "$BIN/aliases.zsh"
  _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED=0
  codex --cd "$PERSONAL_ROOT"
) >/dev/null 2>"$TMP/err" || true
[[ -f "$TMP/out" ]] || { cat "$TMP/err" >&2; fail 'codex wrapper stub not launched'; }
check_loopback 'codex wrapper'
rm -f "$PERSONAL_ROOT/config/.local/observability.env"

# ---- H3: checkup prompt-audit carries the policy in its own --settings.
# Checkup has no isolated public route. Canonical refusal is covered by the
# boundary tests; exercise only its environment helper on noncanonical roots,
# without unregistering or bypassing the registered canonical profiles.
mk "$TMP/checkup-personal" auditpers 0
mk "$TMP/checkup-company" auditcomp 1
checkup_env() { # <noncanonical fixture>
  rm -f "$TMP/out"
  (
    export TEST_STUB_FILE="$TMP/out" PATH="$TMP:$PATH"
    source "$BIN/aliases.zsh"
    harness_register "$HOME/personal" >/dev/null; harness_register "$HOME/company" >/dev/null
    source "$1/config/launcher.env"
    _harness_launcher_run_checkup "$1" prompt-audit
  ) >/dev/null 2>"$TMP/err" || true
  [[ -f "$TMP/out" ]] || { cat "$TMP/err" >&2; fail 'checkup environment helper stub not launched'; }
}
checkup_env "$TMP/checkup-personal"
grep -Eq '^ARGS:.*--settings \{.*"env": ?\{"CLAUDE_CODE_ENABLE_TELEMETRY": ?"0"\}' "$TMP/out" || fail "personal prompt-audit must disable telemetry in its --settings env: $(<$TMP/out)"
grep -qx 'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://127.0.0.1:9/v1/logs' "$TMP/out" || fail 'personal prompt-audit children get the discard set'
checkup_env "$TMP/checkup-company"
grep -q '"env"' "$TMP/out" && fail 'collecting prompt-audit must not set an env block'
grep -q '^OTEL_EXPORTER_OTLP_' "$TMP/out" && fail 'collecting prompt-audit must not export discard endpoints'

print 'PASS: launch paths carry the usage policy (settings env, discard exports, reconcile)'
