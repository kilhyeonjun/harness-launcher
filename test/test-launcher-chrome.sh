#!/usr/bin/env zsh
# test-launcher-chrome.sh — verify --chrome/--no-chrome flag passthrough
# Cases:
#   --chrome alone       → claude receives --chrome, no --model
#   --no-chrome alone    → claude receives --no-chrome
#   fast --chrome combo  → claude receives --model haiku --effort low --chrome

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() {
  [[ -n "$TEST_TEMP" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"

mkdir -p "$TEST_HARNESS/config"
cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF

CLAUDE_STUB="$TEST_TEMP/claude"
cat > "$CLAUDE_STUB" <<'EOF'
#!/bin/bash
echo "ARGS:$@" >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$CLAUDE_STUB"

run_case() {
  local label="$1"; shift
  local expected_substring="$1"; shift
  local stub_file="$TEST_TEMP/output-$label.txt"

  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_TEMP:$PATH"
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _harness_launcher_run "$TEST_HARNESS" "$@"
  ) 2>/dev/null || true

  if [[ ! -f "$stub_file" ]]; then
    echo "FAIL: $label — stub not invoked (TUI likely launched instead)"
    return 1
  fi

  local args_line
  args_line=$(grep "^ARGS:" "$stub_file" | head -1 | cut -d: -f2-)

  if ! echo "$args_line" | grep -q -- "$expected_substring"; then
    echo "FAIL: $label — expected args to contain '$expected_substring'"
    echo "  Got: $args_line"
    return 1
  fi

  echo "PASS: $label → $args_line"
  return 0
}

# Forbid case: ensure flag does NOT appear when not requested
forbid_case() {
  local label="$1"; shift
  local forbidden_substring="$1"; shift
  local stub_file="$TEST_TEMP/output-$label.txt"

  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_TEMP:$PATH"
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _harness_launcher_run "$TEST_HARNESS" "$@"
  ) 2>/dev/null || true

  if [[ ! -f "$stub_file" ]]; then
    echo "FAIL: $label — stub not invoked"
    return 1
  fi

  local args_line
  args_line=$(grep "^ARGS:" "$stub_file" | head -1 | cut -d: -f2-)

  if echo "$args_line" | grep -q -- "$forbidden_substring"; then
    echo "FAIL: $label — args unexpectedly contain '$forbidden_substring'"
    echo "  Got: $args_line"
    return 1
  fi

  echo "PASS: $label (no $forbidden_substring leaked) → $args_line"
  return 0
}

run_case    "chrome-alone"     "--chrome"             --chrome           || exit 1
run_case    "no-chrome-alone"  "--no-chrome"          --no-chrome        || exit 1
run_case    "fast-chrome"      "--model haiku"        fast --chrome      || exit 1
run_case    "fast-chrome-flag" "--chrome"             fast --chrome      || exit 1
forbid_case "fast-only"        "--chrome"             fast               || exit 1

echo "✓ All chrome flag tests passed"
