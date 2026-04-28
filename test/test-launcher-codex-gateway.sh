#!/usr/bin/env zsh
# test-launcher-codex-gateway.sh — verify Claude Code via codex gateway mode-mapping
# (Note: the bare `codex` alias is being repurposed to mean "Codex CLI native";
# this test exercises the legacy gateway path under its disambiguated name.)
# Modes: fast, base, plan, rich
# Expected behavior (codex-gateway, default CODEX_CONTEXT_SUFFIX=""):
#   fast  → --model haiku --effort low
#   base  → --model sonnet --effort high + ANTHROPIC_BASE_URL set
#   plan  → --model opusplan --effort high
#   rich  → --model opus --effort high
# With CODEX_CONTEXT_SUFFIX="[1m]" the base/plan/rich models gain [1m] suffix.
# Also verifies codex-gateway env exports: CODEX_OPUS_MODEL → ANTHROPIC_DEFAULT_OPUS_MODEL

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cleanup on exit
cleanup() {
  [[ -n "$HTTP_PID" ]] && kill $HTTP_PID 2>/dev/null || true
  [[ -n "$TEST_TEMP" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"

# Setup fake harness
mkdir -p "$TEST_HARNESS/config/.local"
cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF

# Start a minimal Python HTTP server for /health endpoint, on an ephemeral port
HTTP_PORT_FILE="$TEST_TEMP/http.port"
PORT_FILE="$HTTP_PORT_FILE" python3 -c '
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
s = HTTPServer(("127.0.0.1", 0), H)
with open(os.environ["PORT_FILE"], "w") as f:
    f.write(str(s.server_port))
s.serve_forever()
' >/dev/null 2>&1 &
HTTP_PID=$!

# Wait for the server to write its bound port
HTTP_PORT=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [[ -s "$HTTP_PORT_FILE" ]]; then
    HTTP_PORT="$(cat "$HTTP_PORT_FILE")"
    break
  fi
  sleep 0.2
done

if [[ -z "$HTTP_PORT" ]]; then
  echo "FAIL: Could not determine HTTP server port"
  exit 1
fi

HTTP_URL="http://127.0.0.1:$HTTP_PORT"

# Setup codex gateway env
write_codex_env() {
  local suffix="${1:-}"
  cat > "$TEST_HARNESS/config/.local/codex-gateway.env" <<EOF
CODEX_GATEWAY_URL="$HTTP_URL"
CODEX_GATEWAY_API_KEY="test-key"
CODEX_OPUS_MODEL="gpt-5.4-xhigh"
CODEX_SONNET_MODEL="gpt-4-sonnet"
CODEX_HAIKU_MODEL="gpt-4-haiku"
CODEX_CONTEXT_SUFFIX="$suffix"
EOF
}
write_codex_env ""

# Setup stub claude
CLAUDE_STUB="$TEST_TEMP/claude"
cat > "$CLAUDE_STUB" <<'EOF'
#!/bin/bash
{
  echo "ARGS:$@"
  echo "EFFORT:${CLAUDE_CODE_EFFORT_LEVEL:-}"
  echo "BASE_URL:${ANTHROPIC_BASE_URL:-}"
  echo "OPUS_MODEL:${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"
  echo "SONNET_MODEL:${ANTHROPIC_DEFAULT_SONNET_MODEL:-}"
  echo "HAIKU_MODEL:${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
} >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$CLAUDE_STUB"

# Helper: extract --model value
extract_model() {
  local args="$1"
  echo "$args" | sed -n 's/.*--model \([^ ]*\).*/\1/p'
}

# Helper: extract --effort value
extract_effort() {
  local args="$1"
  echo "$args" | sed -n 's/.*--effort \([^ ]*\).*/\1/p'
}

# Helper: check if --exclude-dynamic-system-prompt-sections flag is present
extract_has_flag() {
  local args="$1"
  if echo "$args" | grep -q "\--exclude-dynamic-system-prompt-sections"; then
    echo "true"
  else
    echo "false"
  fi
}

# Helper: run a mode and capture output
run_mode() {
  local mode="$1" expected_model="$2" expected_effort="$3"
  local stub_file="$TEST_TEMP/output-codex-$mode.txt"

  # Clean up previous stub file to avoid appended output from prior runs
  rm -f "$stub_file"

  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_TEMP:$PATH"
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _harness_launcher_run "$TEST_HARNESS" 'codex-gateway' "$mode"
  ) 2>/dev/null || true

  if [[ ! -f "$stub_file" ]]; then
    echo "FAIL: codex $mode — no stub output file"
    return 1
  fi

  local args_line=$(grep "^ARGS:" "$stub_file" | head -1 | cut -d: -f2-)
  local base_url_line=$(grep "^BASE_URL:" "$stub_file" | head -1 | cut -d: -f2-)

  local actual_model=$(extract_model "$args_line")
  local actual_effort=$(extract_effort "$args_line")
  local actual_base_url="$base_url_line"
  local has_flag=$(extract_has_flag "$args_line")

  if [[ "$actual_model" != "$expected_model" ]]; then
    echo "FAIL: codex $mode — expected --model $expected_model, got '$actual_model'"
    echo "  Full args: $args_line"
    return 1
  fi

  if [[ "$actual_effort" != "$expected_effort" ]]; then
    echo "FAIL: codex $mode — expected --effort $expected_effort, got '$actual_effort'"
    echo "  Full args: $args_line"
    return 1
  fi

  if [[ "$actual_base_url" != "$HTTP_URL" ]]; then
    echo "FAIL: codex $mode — expected BASE_URL=$HTTP_URL, got '$actual_base_url'"
    return 1
  fi

  if [[ "$has_flag" != "true" ]]; then
    echo "FAIL: codex $mode — expected --exclude-dynamic-system-prompt-sections flag, not found"
    echo "  Full args: $args_line"
    return 1
  fi

  echo "PASS: codex $mode → --model $expected_model --effort $expected_effort + flag"
  return 0
}

# Run mode tests
echo "Default suffix (empty) — should produce plain models"
run_mode "fast" "haiku" "low"     || exit 1
run_mode "base" "sonnet" "high"   || exit 1
run_mode "plan" "opusplan" "high"  || exit 1
run_mode "rich" "opus" "high"      || exit 1

echo ""
echo "Suffix \"[1m]\" — should produce [1m] models"
write_codex_env "[1m]"
run_mode "fast" "haiku" "low"           || exit 1
run_mode "base" "sonnet[1m]" "high"     || exit 1
run_mode "plan" "opusplan[1m]" "high"   || exit 1
run_mode "rich" "opus[1m]" "high"       || exit 1
write_codex_env ""  # restore for env-export test below

# Verify CODEX env exports
echo "Verifying codex env exports..."
(
  export TEST_STUB_FILE="$TEST_TEMP/output-env-check.txt"
  export PATH="$TEST_TEMP:$PATH"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _harness_launcher_run "$TEST_HARNESS" 'codex-gateway' 'base'
) 2>/dev/null || true

if [[ -f "$TEST_TEMP/output-env-check.txt" ]]; then
  opus_model=$(grep "^OPUS_MODEL:" "$TEST_TEMP/output-env-check.txt" | head -1 | cut -d: -f2-)
  if [[ "$opus_model" == "gpt-5.4-xhigh" ]]; then
    echo "PASS: codex exports ANTHROPIC_DEFAULT_OPUS_MODEL from config"
  else
    echo "FAIL: expected OPUS_MODEL=gpt-5.4-xhigh, got '$opus_model'"
    exit 1
  fi
fi

echo "✓ All codex gateway tests passed"
