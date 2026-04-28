#!/usr/bin/env zsh
# test-launcher-autocompact-pct.sh — verify launcher exports
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 only when a 1M-context model is selected.
#
# Rationale: percentage-based threshold means 50% on 200K leaves only 100K headroom.
# Launcher detects [1m] in claude_args and explicitly relaxes PCT for 1M models;
# otherwise leaves PCT to settings.json fallback (currently 70).

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
echo "PCT:${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-UNSET}" >> "$TEST_STUB_FILE"
echo "ARGS:$@" >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$CLAUDE_STUB"

run_mode_pct() {
  local mode="$1" expected_pct="$2"
  local stub_file="$TEST_TEMP/output-$mode.txt"

  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_TEMP:$PATH"
    unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _harness_launcher_run "$TEST_HARNESS" "$mode"
  ) 2>/dev/null || true

  if [[ ! -f "$stub_file" ]]; then
    echo "FAIL: $mode — no stub output"
    return 1
  fi

  local actual_pct
  actual_pct=$(grep "^PCT:" "$stub_file" | head -1 | cut -d: -f2-)

  if [[ "$actual_pct" != "$expected_pct" ]]; then
    echo "FAIL: $mode — expected PCT=$expected_pct, got '$actual_pct'"
    cat "$stub_file"
    return 1
  fi

  echo "PASS: $mode → CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=$expected_pct"
}

# rich = opus[1m] direct → 1M context → PCT=50
run_mode_pct "rich" "50" || exit 1

# 200K-context modes → leave fallback (UNSET in test isolation)
run_mode_pct "fast" "UNSET"  || exit 1
run_mode_pct "base" "UNSET"  || exit 1
run_mode_pct "plan" "UNSET"  || exit 1

echo "✓ All autocompact-pct tests passed"
