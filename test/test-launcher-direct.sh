#!/usr/bin/env zsh
# test-launcher-direct.sh — verify direct Anthropic OAuth mode-mapping (no gateway)
# Modes: fast, base, plan, rich
# Expected behavior:
#   fast  → --model haiku --effort low
#   base  → --model sonnet --effort high
#   plan  → --model opusplan --effort high
#   rich  → --model opus[1m] --effort xhigh

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
  local has_flag=$(extract_has_flag "$args_line")

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

  if [[ "$has_flag" != "true" ]]; then
    echo "FAIL: $mode — expected --exclude-dynamic-system-prompt-sections flag, not found"
    echo "  Full args: $args_line"
    return 1
  fi

  echo "PASS: $mode → --model $expected_model --effort $expected_effort + flag"
  return 0
}

# Run mode tests
run_mode "fast" "haiku" "low"       || exit 1
run_mode "base" "sonnet" "high"     || exit 1
run_mode "plan" "opusplan" "high"   || exit 1
run_mode "rich" "opus[1m]" "xhigh"  || exit 1

# Local MCP overlay: Claude Code should receive local/private MCP config files
# in addition to its normal project .mcp.json auto-discovery. Duplicate server
# names across committed/local config must fail instead of silently overriding.
cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{ "mcpServers": { "committed": { "type": "http", "url": "https://committed.test/mcp" } } }
EOF
cat > "$TEST_HARNESS/.mcp.local.json" <<'EOF'
{ "mcpServers": { "local_private": { "command": "local-private", "args": ["mcp"] } } }
EOF
cat > "$TEST_HARNESS/mcp.local.json" <<'EOF'
{ "mcpServers": { "legacy_local": { "type": "http", "url": "https://legacy-local.test/mcp" } } }
EOF
stub_file="$TEST_TEMP/output-local-mcp.txt"
(
  export TEST_STUB_FILE="$stub_file"
  export PATH="$TEST_TEMP:$PATH"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _harness_launcher_run "$TEST_HARNESS" base
) 2>/dev/null || true
args_line=$(grep "^ARGS:" "$stub_file" | head -1 | cut -d: -f2-)
case "$args_line" in
  *"--mcp-config $TEST_HARNESS/.mcp.local.json $TEST_HARNESS/mcp.local.json"*)
    echo "PASS: Claude launcher appends local MCP overlay files" ;;
  *)
    echo "FAIL: Claude launcher did not append both local MCP overlay files"
    echo "  Full args: $args_line"
    exit 1 ;;
esac

cat > "$TEST_HARNESS/.mcp.local.json" <<'EOF'
{ "mcpServers": { "committed": { "type": "http", "url": "https://local.test/mcp" } } }
EOF
dup_stub_file="$TEST_TEMP/output-duplicate-mcp.txt"
dup_err_file="$TEST_TEMP/output-duplicate-mcp.err"
if (
  export TEST_STUB_FILE="$dup_stub_file"
  export PATH="$TEST_TEMP:$PATH"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _harness_launcher_run "$TEST_HARNESS" base
) 2> "$dup_err_file"; then
  echo "FAIL: duplicate MCP server name across committed/local configs should fail"
  exit 1
fi
grep -q "duplicate MCP server 'committed'" "$dup_err_file" || {
  echo "FAIL: duplicate MCP error message missing"
  cat "$dup_err_file"
  exit 1
}
if [[ -s "$dup_stub_file" ]]; then
  echo "FAIL: claude should not launch when MCP config validation fails"
  cat "$dup_stub_file"
  exit 1
fi
echo "PASS: Claude launcher rejects duplicate MCP server names before launch"

# Light MCP surface shortcut: `<prefix> base light` generates a filtered config
# and launches with --strict-mcp-config; SSH-backed servers are excluded.
cat > "$TEST_HARNESS/.mcp.local.json" <<'EOF'
{ "mcpServers": {
  "ssh_rag": { "command": "bash", "args": ["core/bin/start-ssh-mcp.sh", "rag"] },
  "tunnel_rag": { "type": "http", "url": "http://127.0.0.1:38206/mcp" }
} }
EOF
light_stub_file="$TEST_TEMP/output-light.txt"
mkdir -p "$TEST_TEMP/home"
(
  export TEST_STUB_FILE="$light_stub_file"
  export PATH="$TEST_TEMP:$PATH"
  export HOME="$TEST_TEMP/home"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _harness_launcher_run "$TEST_HARNESS" base light
) 2>/dev/null || true
args_line=$(grep "^ARGS:" "$light_stub_file" | head -1 | cut -d: -f2-)
LIGHT_FILE="$TEST_HARNESS/.harness/claude/mcp-light.json"
case "$args_line" in
  *"--strict-mcp-config --mcp-config $LIGHT_FILE"*) ;;
  *)
    echo "FAIL: light shortcut should pass --strict-mcp-config + generated file"
    echo "  Full args: $args_line"
    exit 1 ;;
esac
case "$args_line" in
  *".mcp.local.json"*)
    echo "FAIL: light shortcut must not also append raw local overlay files"
    echo "  Full args: $args_line"
    exit 1 ;;
esac
grep -q "ssh_rag" "$LIGHT_FILE" && { echo "FAIL: light surface must exclude SSH stdio wrappers"; exit 1; }
grep -q "tunnel_rag" "$LIGHT_FILE" && { echo "FAIL: light surface must exclude 382xx tunnel servers"; exit 1; }
grep -q "committed" "$LIGHT_FILE" || { echo "FAIL: light surface must keep committed non-SSH servers"; exit 1; }
grep -q "legacy_local" "$LIGHT_FILE" || { echo "FAIL: light surface must keep local non-SSH servers"; exit 1; }
echo "PASS: light shortcut filters SSH servers with --strict-mcp-config"

# Light shortcut must fail closed on duplicate server names (no launch).
cat > "$TEST_HARNESS/.mcp.local.json" <<'EOF'
{ "mcpServers": { "committed": { "type": "http", "url": "https://local.test/mcp" } } }
EOF
light_dup_stub="$TEST_TEMP/output-light-dup.txt"
light_dup_err="$TEST_TEMP/output-light-dup.err"
if (
  export TEST_STUB_FILE="$light_dup_stub"
  export PATH="$TEST_TEMP:$PATH"
  export HOME="$TEST_TEMP/home"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _harness_launcher_run "$TEST_HARNESS" base light
) 2> "$light_dup_err"; then
  echo "FAIL: light shortcut must fail on duplicate server names"
  exit 1
fi
grep -q "duplicate MCP server 'committed'" "$light_dup_err" || {
  echo "FAIL: light duplicate error message missing"
  cat "$light_dup_err"
  exit 1
}
if [[ -s "$light_dup_stub" ]]; then
  echo "FAIL: claude must not launch when light generation fails"
  exit 1
fi
echo "PASS: light shortcut fails closed on duplicate server names"

echo "✓ All direct OAuth tests passed"
