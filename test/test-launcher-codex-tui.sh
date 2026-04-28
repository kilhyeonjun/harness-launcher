#!/usr/bin/env bash
# test-launcher-codex-tui.sh — verify launcher.sh runtime-first TUI flow for Codex CLI.
#
# When both `claude` and `codex` are in PATH, the launcher must:
#   1. Prompt: Select runtime (Claude Code / Codex CLI)
#   2. If Codex selected → Session menu, Mode menu, Safety menu
#   3. exec codex with: subcmd (if any), --cd, -p <profile>, safety flags
#   4. CODEX_HOME=$HARNESS_DIR/.harness/codex
#   5. Always run codex-home-prepare.sh first
#
# When `codex` is missing, the runtime menu must auto-skip → existing Claude flow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() { [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"; }
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"
TEST_BIN="$TEST_TEMP/bin"
mkdir -p "$TEST_HARNESS/config" "$TEST_BIN"

cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF
echo "# fake rules" > "$TEST_HARNESS/CLAUDE.md"

cat > "$TEST_BIN/claude" <<'EOF'
#!/usr/bin/env bash
{
  echo "EXEC:claude"
  echo "ARGS:$*"
} >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$TEST_BIN/claude"

cat > "$TEST_BIN/codex" <<'EOF'
#!/usr/bin/env bash
{
  echo "EXEC:codex"
  echo "ARGS:$*"
  echo "CODEX_HOME:${CODEX_HOME:-}"
} >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$TEST_BIN/codex"

run_tui() {
  local input="$1" stub_file="$2" extra_path="${3:-}"
  local path_value="$TEST_BIN:/usr/bin:/bin"
  [[ -n "$extra_path" ]] && path_value="$extra_path:$path_value"
  TEST_STUB_FILE="$stub_file" \
  PATH="$path_value" \
  HARNESS_DIR="$TEST_HARNESS" \
  HARNESS_NAME="test harness" \
  bash "$LAUNCHER_DIR/bin/launcher.sh" <<< "$input" > "$stub_file.tui.log" 2>&1
}

# Case 1: runtime=Codex, session=New, mode=Base, safety=Default
STUB1="$TEST_TEMP/out1-codex-base.txt"
: > "$STUB1"
run_tui $'2\n1\n2\n1\n' "$STUB1"
grep -q "^EXEC:codex" "$STUB1" || {
  echo "FAIL: case1 — expected codex exec; got:"; cat "$STUB1"; cat "$STUB1.tui.log"; exit 1;
}
grep -qE "^ARGS:.*--cd $TEST_HARNESS" "$STUB1" || {
  echo "FAIL: case1 — missing --cd"; cat "$STUB1"; exit 1;
}
grep -qE "^ARGS:.*-p base" "$STUB1" || {
  echo "FAIL: case1 — missing -p base"; cat "$STUB1"; exit 1;
}
grep -q "^CODEX_HOME:$TEST_HARNESS/.harness/codex\$" "$STUB1" || {
  echo "FAIL: case1 — CODEX_HOME mismatch"; cat "$STUB1"; exit 1;
}
[[ -d "$TEST_HARNESS/.harness/codex" ]] || {
  echo "FAIL: case1 — CODEX_HOME directory not prepared"; exit 1;
}
[[ -L "$TEST_HARNESS/.harness/codex/AGENTS.md" ]] || {
  echo "FAIL: case1 — AGENTS.md symlink not created (prepare not invoked)"; exit 1;
}
echo "PASS: case1 — runtime=Codex base → exec codex --cd ... -p base + CODEX_HOME prepared"

# Case 2: runtime=Codex, session=Continue last, mode=Plan, safety=Default
STUB2="$TEST_TEMP/out2-codex-continue.txt"
: > "$STUB2"
run_tui $'2\n2\n3\n1\n' "$STUB2"
grep -qE "^ARGS:resume( |.*--cd)" "$STUB2" || {
  echo "FAIL: case2 — expected 'resume' as first codex arg"; cat "$STUB2"; exit 1;
}
grep -qE "^ARGS:.*--last" "$STUB2" || {
  echo "FAIL: case2 — expected --last for continue"; cat "$STUB2"; exit 1;
}
grep -qE "^ARGS:.*-p plan" "$STUB2" || {
  echo "FAIL: case2 — expected -p plan"; cat "$STUB2"; exit 1;
}
echo "PASS: case2 — Codex continue + plan → codex resume --last -p plan"

# Case 3: runtime=Codex, safety=Full auto
STUB3="$TEST_TEMP/out3-codex-fullauto.txt"
: > "$STUB3"
run_tui $'2\n1\n2\n2\n' "$STUB3"
grep -qE "^ARGS:.*--full-auto" "$STUB3" || {
  echo "FAIL: case3 — expected --full-auto"; cat "$STUB3"; exit 1;
}
echo "PASS: case3 — Safety=Full auto → --full-auto flag"

# Case 4: only Claude in PATH (no codex) → runtime menu auto-skips, Claude flow runs
NO_CODEX_BIN="$TEST_TEMP/bin-noco"
mkdir -p "$NO_CODEX_BIN"
cp "$TEST_BIN/claude" "$NO_CODEX_BIN/claude"
chmod +x "$NO_CODEX_BIN/claude"

STUB4="$TEST_TEMP/out4-claude-only.txt"
: > "$STUB4"
TEST_STUB_FILE="$STUB4" \
PATH="$NO_CODEX_BIN:/usr/bin:/bin" \
HARNESS_DIR="$TEST_HARNESS" \
HARNESS_NAME="test harness" \
bash "$LAUNCHER_DIR/bin/launcher.sh" <<< $'1\n2\n2\n' >/dev/null 2>&1 || true
grep -q "^EXEC:claude" "$STUB4" || {
  echo "FAIL: case4 — runtime auto-skip didn't reach Claude exec"; cat "$STUB4"; exit 1;
}
echo "PASS: case4 — codex absent → runtime menu auto-skips to Claude flow"

# Case 5: runtime=Claude (with both runtimes available) routes to Claude
STUB5="$TEST_TEMP/out5-claude-via-tui.txt"
: > "$STUB5"
run_tui $'1\n1\n2\n2\n' "$STUB5"
grep -q "^EXEC:claude" "$STUB5" || {
  echo "FAIL: case5 — expected claude exec when runtime=Claude"; cat "$STUB5"; exit 1;
}
if grep -q "^EXEC:codex" "$STUB5"; then
  echo "FAIL: case5 — codex was launched even though runtime=Claude was selected"; cat "$STUB5"; exit 1;
fi
echo "PASS: case5 — runtime=Claude routes to Claude exec"

echo "✓ All codex TUI tests passed"
