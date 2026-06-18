#!/usr/bin/env zsh
# test-launcher-ultracode.sh — verify `ultracode` shortcut mode (hint mode).
#
# ultracode = xhigh + dynamic workflow orchestration, but the orchestration half
# is a SESSION-ONLY Claude Code preset: the CLI rejects 'ultracode' as an
# --effort / env / settings value (allowed: low|medium|high|xhigh|max), so it
# cannot be set at launch. The launcher therefore starts rich (opus[1m] + xhigh)
# and prints a hint telling the user to run /effort → ultracode in-session.
#
# Expected behavior:
#   direct (no provider prefix) → --model opus[1m] --effort xhigh, NEVER
#     --effort ultracode, and a hint is printed to stderr.
#   shared runner: every registered prefix resolves identically
#   kiro ultracode          → rejected (non-zero exit, claude never launched)
#   codex-gateway ultracode → rejected (non-zero exit, claude never launched)
# Rejection must trigger on the `ultracode` token, NOT a health failure, so the
# node-based health probe is stubbed to succeed.
#
# compdef is stubbed before sourcing aliases.zsh: in non-interactive zsh compdef
# is absent, so harness_register's trailing compdef call would 127 under set -e
# (see provider-prefix-launcher-gotchas.md).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() { [[ -n "$TEST_TEMP" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"; }
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
STUB_BIN="$TEST_TEMP/bin"
mkdir -p "$STUB_BIN"

# Stub claude: capture args to a file.
cat > "$STUB_BIN/claude" <<'EOF'
#!/bin/bash
echo "ARGS:$@" >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$STUB_BIN/claude"

# Stub node: health probe always succeeds, so gateway rejection is on the token.
cat > "$STUB_BIN/node" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB_BIN/node"

mk_harness() {  # <dir> <prefix> [with_gateways]
  local dir="$1" prefix="$2" gw="${3:-}"
  mkdir -p "$dir/config/.local"
  cat > "$dir/config/launcher.env" <<EOF
HARNESS_NAME="$prefix harness"
HARNESS_PREFIX="$prefix"
EOF
  if [[ -n "$gw" ]]; then
    cat > "$dir/config/.local/kiro-gateway.env" <<'EOF'
KIRO_GATEWAY_URL="http://127.0.0.1:9/health-stub"
KIRO_GATEWAY_API_KEY="test-key"
EOF
    cat > "$dir/config/.local/codex-gateway.env" <<'EOF'
CODEX_GATEWAY_URL="http://127.0.0.1:9/health-stub"
CODEX_GATEWAY_API_KEY="test-key"
EOF
  fi
}

mk_harness "$TEST_TEMP/th"  "th"
mk_harness "$TEST_TEMP/th2" "th2"
mk_harness "$TEST_TEMP/thg" "thg" gw

extract_model()  { echo "$1" | sed -n 's/.*--model \([^ ]*\).*/\1/p'; }
extract_effort() { echo "$1" | sed -n 's/.*--effort \([^ ]*\).*/\1/p'; }

# Run a registered prefix function; capture claude args, stderr, exit code.
# Sets RUN_RC, RUN_ARGS, RUN_STDERR, RUN_LAUNCHED.
run_prefix() {
  local dir="$1" prefix="$2"; shift 2
  local stub_file="$TEST_TEMP/out-$prefix.txt"
  local err_file="$TEST_TEMP/err-$prefix.txt"
  : > "$stub_file"
  set +e
  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$STUB_BIN:$PATH"
    compdef() { :; }                       # neutralize non-interactive compdef
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    harness_register "$dir"
    "$prefix" "$@"
  ) >/dev/null 2>"$err_file"
  RUN_RC=$?
  set -e
  RUN_ARGS=""
  RUN_LAUNCHED=false
  RUN_STDERR="$(cat "$err_file" 2>/dev/null || true)"
  if [[ -s "$stub_file" ]]; then
    RUN_LAUNCHED=true
    RUN_ARGS="$(grep '^ARGS:' "$stub_file" | head -1 | cut -d: -f2- || true)"
  fi
}

# 1. direct ultracode → --model opus[1m] --effort xhigh, NEVER --effort ultracode
run_prefix "$TEST_TEMP/th" "th" ultracode
[[ "$(extract_model "$RUN_ARGS")" == "opus[1m]" ]] \
  || { echo "FAIL: direct ultracode model — got '$(extract_model "$RUN_ARGS")' ($RUN_ARGS)"; exit 1; }
[[ "$(extract_effort "$RUN_ARGS")" == "xhigh" ]] \
  || { echo "FAIL: direct ultracode effort — expected xhigh, got '$(extract_effort "$RUN_ARGS")' ($RUN_ARGS)"; exit 1; }
[[ "$RUN_ARGS" != *"--effort ultracode"* ]] \
  || { echo "FAIL: ultracode must NOT pass '--effort ultracode' (CLI rejects it): $RUN_ARGS"; exit 1; }
echo "PASS: direct ultracode → --model opus[1m] --effort xhigh (no --effort ultracode)"

# 2. a hint about session-only /effort is surfaced to the user
[[ "$RUN_STDERR" == *"/effort"* ]] \
  || { echo "FAIL: direct ultracode should print a /effort hint, stderr was: '$RUN_STDERR'"; exit 1; }
echo "PASS: ultracode prints a session-only /effort hint"

# 3. shared-runner parity: a second prefix resolves identically
run_prefix "$TEST_TEMP/th2" "th2" ultracode
[[ "$(extract_model "$RUN_ARGS")" == "opus[1m]" && "$(extract_effort "$RUN_ARGS")" == "xhigh" && "$RUN_ARGS" != *"--effort ultracode"* ]] \
  || { echo "FAIL: second-prefix ultracode — got '$RUN_ARGS'"; exit 1; }
echo "PASS: shared-runner parity (th2 ultracode resolves identically)"

# 4. kiro ultracode → rejected (non-zero, claude never launched)
run_prefix "$TEST_TEMP/thg" "thg" kiro ultracode
[[ "$RUN_RC" -ne 0 ]]          || { echo "FAIL: kiro ultracode should exit non-zero (rc=$RUN_RC)"; exit 1; }
[[ "$RUN_LAUNCHED" == false ]] || { echo "FAIL: kiro ultracode must not launch claude ($RUN_ARGS)"; exit 1; }
echo "PASS: kiro ultracode → rejected (no claude launch, non-zero exit)"

# 5. codex-gateway ultracode → rejected (non-zero, claude never launched)
run_prefix "$TEST_TEMP/thg" "thg" codex-gateway ultracode
[[ "$RUN_RC" -ne 0 ]]          || { echo "FAIL: codex-gateway ultracode should exit non-zero (rc=$RUN_RC)"; exit 1; }
[[ "$RUN_LAUNCHED" == false ]] || { echo "FAIL: codex-gateway ultracode must not launch claude ($RUN_ARGS)"; exit 1; }
echo "PASS: codex-gateway ultracode → rejected (no claude launch, non-zero exit)"

echo "✓ All ultracode shortcut tests passed"
exit 0
