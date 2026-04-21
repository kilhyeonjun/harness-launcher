#!/usr/bin/env zsh
# test-launcher-direct.sh — verify direct Anthropic OAuth mode-mapping (no gateway)
# Modes: fast, base, plan, rich
# Expected behavior:
#   fast  → --model haiku --effort low
#   base  → --model sonnet --effort high
#   plan  → --model opusplan --effort high
#   rich  → --model opus[1m] --effort max

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cleanup on exit
cleanup() {
  [[ -n "$TEST_TEMP" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"

# Setup fake harness
mkdir -p "$TEST_HARNESS/config"
cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF

# Setup stub claude that captures args to a file
CLAUDE_STUB="$TEST_TEMP/claude"
cat > "$CLAUDE_STUB" <<'EOF'
#!/bin/bash
# Stub claude: capture all args and env vars to a file
echo "ARGS:$@" >> "$TEST_STUB_FILE"
echo "EFFORT:${CLAUDE_CODE_EFFORT_LEVEL:-}" >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$CLAUDE_STUB"

# Helper: extract --model value from args line
extract_model() {
  local args="$1"
  echo "$args" | sed -n 's/.*--model \([^ ]*\).*/\1/p'
}

# Helper: extract --effort value from args line
extract_effort() {
  local args="$1"
  echo "$args" | sed -n 's/.*--effort \([^ ]*\).*/\1/p'
}

# Helper: run a mode and capture output
run_mode() {
  local mode="$1" expected_model="$2" expected_effort="$3"
  local stub_file="$TEST_TEMP/output-$mode.txt"

  # Run in subshell with stub claude in PATH
  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_TEMP:$PATH"
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _harness_launcher_run "$TEST_HARNESS" "$mode"
  ) 2>/dev/null || true

  if [[ ! -f "$stub_file" ]]; then
    echo "FAIL: $mode — no stub output file"
    return 1
  fi

  local args_line=$(grep "^ARGS:" "$stub_file" | head -1 | cut -d: -f2-)

  # Extract model and effort from args
  local actual_model=$(extract_model "$args_line")
  local actual_effort=$(extract_effort "$args_line")

  if [[ "$actual_model" != "$expected_model" ]]; then
    echo "FAIL: $mode — expected --model $expected_model, got '$actual_model'"
    echo "  Full args: $args_line"
    return 1
  fi

  if [[ "$actual_effort" != "$expected_effort" ]]; then
    echo "FAIL: $mode — expected --effort $expected_effort, got '$actual_effort'"
    echo "  Full args: $args_line"
    return 1
  fi

  echo "PASS: $mode → --model $expected_model --effort $expected_effort"
  return 0
}

# Run mode tests
run_mode "fast" "haiku" "low"       || exit 1
run_mode "base" "sonnet" "high"     || exit 1
run_mode "plan" "opusplan" "high"   || exit 1
run_mode "rich" "opus[1m]" "max"    || exit 1

echo "✓ All direct OAuth tests passed"
