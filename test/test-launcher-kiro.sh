#!/usr/bin/env zsh
# test-launcher-kiro.sh — verify kiro gateway mode-mapping
# Modes: fast, base, plan, rich
# Expected behavior (kiro):
#   fast  → --model haiku --effort low
#   base  → (no --model, defaults to sonnet 200K) --effort high
#   plan  → --model opusplan --effort high
#   rich  → --model claude-opus-4-6 --effort max
# Also verifies kiro env exports

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

# Start a minimal Python HTTP server for /health endpoint
cd "$TEST_TEMP"
python3 -m http.server 0 --bind 127.0.0.1 >/dev/null 2>&1 &
HTTP_PID=$!
sleep 0.8

# Find the port
HTTP_PORT=""
for port in {8000..8020}; do
  if curl -s --max-time 1 "http://127.0.0.1:$port/" >/dev/null 2>&1; then
    HTTP_PORT="$port"
    break
  fi
done

if [[ -z "$HTTP_PORT" ]]; then
  echo "FAIL: Could not determine HTTP server port"
  exit 1
fi

HTTP_URL="http://127.0.0.1:$HTTP_PORT"

# Setup kiro gateway env
cat > "$TEST_HARNESS/config/.local/kiro-gateway.env" <<EOF
KIRO_GATEWAY_URL="$HTTP_URL"
KIRO_GATEWAY_API_KEY="test-kiro-key"
EOF

# Setup stub claude
CLAUDE_STUB="$TEST_TEMP/claude"
cat > "$CLAUDE_STUB" <<'EOF'
#!/bin/bash
{
  echo "ARGS:$@"
  echo "EFFORT:${CLAUDE_CODE_EFFORT_LEVEL:-}"
  echo "BASE_URL:${ANTHROPIC_BASE_URL:-}"
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

# Helper: run a mode and capture output
run_mode() {
  local mode="$1" expected_model="$2" expect_model_arg="$3" expected_effort="$4"
  local stub_file="$TEST_TEMP/output-kiro-$mode.txt"

  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_TEMP:$PATH"
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _harness_launcher_run "$TEST_HARNESS" 'kiro' "$mode"
  ) 2>/dev/null || true

  if [[ ! -f "$stub_file" ]]; then
    echo "FAIL: kiro $mode — no stub output file"
    return 1
  fi

  local args_line=$(grep "^ARGS:" "$stub_file" | head -1 | cut -d: -f2-)
  local base_url_line=$(grep "^BASE_URL:" "$stub_file" | head -1 | cut -d: -f2-)

  local actual_model=$(extract_model "$args_line")
  local actual_effort=$(extract_effort "$args_line")
  local actual_base_url="$base_url_line"

  if [[ "$expect_model_arg" == "true" ]]; then
    if [[ "$actual_model" != "$expected_model" ]]; then
      echo "FAIL: kiro $mode — expected --model $expected_model, got '$actual_model'"
      echo "  Full args: $args_line"
      return 1
    fi
  else
    # Expect NO --model arg
    if [[ "$actual_model" != "" ]]; then
      echo "FAIL: kiro $mode — expected NO --model arg, got --model $actual_model"
      return 1
    fi
  fi

  if [[ "$actual_effort" != "$expected_effort" ]]; then
    echo "FAIL: kiro $mode — expected --effort $expected_effort, got '$actual_effort'"
    echo "  Full args: $args_line"
    return 1
  fi

  if [[ "$actual_base_url" != "$HTTP_URL" ]]; then
    echo "FAIL: kiro $mode — expected BASE_URL=$HTTP_URL, got '$actual_base_url'"
    return 1
  fi

  if [[ "$expect_model_arg" == "true" ]]; then
    echo "PASS: kiro $mode → --model $expected_model --effort $expected_effort"
  else
    echo "PASS: kiro $mode → (no --model, defaults to sonnet) --effort $expected_effort"
  fi
  return 0
}

# Run mode tests
# kiro base: NO --model arg expected (defaults to sonnet 200K)
run_mode "fast" "haiku" "true" "low"         || exit 1
run_mode "base" "" "false" "high"            || exit 1
run_mode "plan" "opusplan" "true" "high"     || exit 1
run_mode "rich" "claude-opus-4-6" "true" "max" || exit 1

echo "✓ All kiro gateway tests passed"
