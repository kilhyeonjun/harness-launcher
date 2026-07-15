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
TEST_LAUNCHER_BIN="$TEST_TEMP/launcher-bin"
mkdir -p "$TEST_HARNESS/config" "$TEST_BIN" "$TEST_LAUNCHER_BIN"
cp "$LAUNCHER_DIR/bin/launcher.sh" "$TEST_LAUNCHER_BIN/launcher.sh"
cp "$LAUNCHER_DIR/bin/harness-common.sh" "$TEST_LAUNCHER_BIN/harness-common.sh"
cat > "$TEST_LAUNCHER_BIN/codex-home-prepare.sh" <<'EOF'
#!/usr/bin/env bash
set -e
mkdir -p "$1/.harness/codex"
printf '# prepared by test stub\n' > "$1/.harness/codex/AGENTS.md"
echo "PREPARE_MCP_PROFILE:${HARNESS_CODEX_MCP_PROFILE:-<UNSET>}" >> "$TEST_STUB_FILE"
EOF
chmod +x "$TEST_LAUNCHER_BIN/launcher.sh" "$TEST_LAUNCHER_BIN/codex-home-prepare.sh"

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
  echo "MCP_PROFILE:${HARNESS_CODEX_MCP_PROFILE:-<UNSET>}"
} >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$TEST_BIN/codex"

HAPPY_BIN="$TEST_TEMP/bin-happy"
mkdir -p "$HAPPY_BIN"
cat > "$HAPPY_BIN/happy" <<'EOF'
#!/usr/bin/env bash
{
  echo "EXEC:happy"
  echo "ARGS:$*"
  echo "CODEX_HOME:${CODEX_HOME:-}"
} >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$HAPPY_BIN/happy"

# Profile configs drive the drift-proof TUI labels.
mkdir -p "$TEST_HARNESS/.harness/codex"
printf 'model = "gpt-5.6-luna"\nmodel_reasoning_effort = "low"\n' > "$TEST_HARNESS/.harness/codex/fast.config.toml"
printf 'model = "gpt-5.6-terra"\nmodel_reasoning_effort = "medium"\n' > "$TEST_HARNESS/.harness/codex/base.config.toml"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "medium"\n' > "$TEST_HARNESS/.harness/codex/sol.config.toml"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$TEST_HARNESS/.harness/codex/plan.config.toml"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$TEST_HARNESS/.harness/codex/rich.config.toml"

run_tui() {
  local input="$1" stub_file="$2" extra_path="${3:-}"
  rm -f "$TEST_HARNESS/.harness/launcher-last" "$TEST_HARNESS/.harness/launcher-history"
  local path_value="$TEST_BIN:/usr/bin:/bin"
  [[ -n "$extra_path" ]] && path_value="$extra_path:$path_value"
  TEST_STUB_FILE="$stub_file" \
  PATH="$path_value" \
  HARNESS_CODEX_BIN="$TEST_BIN/codex" \
  HARNESS_DIR="$TEST_HARNESS" \
  HARNESS_NAME="test harness" \
  bash "$TEST_LAUNCHER_BIN/launcher.sh" <<< "$input" > "$stub_file.tui.log" 2>&1
}

# Case 1: runtime=Codex, session=New, mode=Base, safety=Default
STUB1="$TEST_TEMP/out1-codex-base.txt"
: > "$STUB1"
run_tui $'2\n1\n2\n1\n1\n' "$STUB1"
grep -q "^EXEC:codex" "$STUB1" || {
  echo "FAIL: case1 — expected codex exec; got:"; cat "$STUB1"; cat "$STUB1.tui.log"; exit 1;
}
grep -qE "^ARGS:.*--cd $TEST_HARNESS" "$STUB1" || {
  echo "FAIL: case1 — missing --cd"; cat "$STUB1"; exit 1;
}
if grep -qE "^ARGS:.*--remote " "$STUB1"; then
  echo "FAIL: case1 — must not use local app-server --remote"; cat "$STUB1"; exit 1;
fi
grep -qE "^ARGS:.*-p base" "$STUB1" || {
  echo "FAIL: case1 — missing -p base"; cat "$STUB1"; exit 1;
}
grep -q "^CODEX_HOME:$TEST_HARNESS/.harness/codex\$" "$STUB1" || {
  echo "FAIL: case1 — CODEX_HOME mismatch"; cat "$STUB1"; exit 1;
}
grep -q '^PREPARE_MCP_PROFILE:<UNSET>$' "$STUB1" || {
  echo "FAIL: case1 — default MCP surface leaked into Codex preparation"; cat "$STUB1"; exit 1;
}
grep -q '^MCP_PROFILE:<UNSET>$' "$STUB1" || {
  echo "FAIL: case1 — default MCP surface leaked into Codex execution"; cat "$STUB1"; exit 1;
}
[[ -d "$TEST_HARNESS/.harness/codex" ]] || {
  echo "FAIL: case1 — CODEX_HOME directory not prepared"; exit 1;
}
[[ -e "$TEST_HARNESS/.harness/codex/AGENTS.md" ]] || {
  echo "FAIL: case1 — AGENTS.md not created (prepare not invoked)"; exit 1;
}
echo "PASS: case1 — runtime=Codex base → direct TUI + codex --cd ... -p base + CODEX_HOME prepared"
for expected in \
  "fast — Quick · shallow — gpt-5.6-luna · low" \
  "base — Everyday · Recommended — gpt-5.6-terra · medium" \
  "sol — Stronger · slower — gpt-5.6-sol · medium" \
  "plan — Planning · deep — gpt-5.6-sol · high" \
  "rich — Deep · slowest — gpt-5.6-sol · high"; do
  grep -Fq "$expected" "$STUB1.tui.log" || {
    echo "FAIL: Codex profile intent label missing: $expected"
    cat "$STUB1.tui.log"
    exit 1
  }
done
echo "PASS: Codex TUI mode labels match GPT-5.6 routing"

# Case 1b: runtime=Codex, base mode, work via the final-menu MCP surface toggle
# (same UX as the claude/kiro light toggle). The surface must be selected
# before Codex home preparation and execution.
# final menu: 1 Start / 2 MCP surface / [3 Happy] / Back
STUB1B="$TEST_TEMP/out1b-codex-work-surface.txt"
: > "$STUB1B"
run_tui $'2\n1\n2\n1\n2\n1\n' "$STUB1B"
grep -q '^EXEC:codex' "$STUB1B" || {
  echo "FAIL: case1b — expected codex exec; got:"; cat "$STUB1B"; cat "$STUB1B.tui.log"; exit 1;
}
grep -q '^MCP_PROFILE:work$' "$STUB1B" || {
  echo "FAIL: case1b — expected work MCP surface before Codex exec"; cat "$STUB1B"; cat "$STUB1B.tui.log"; exit 1;
}
grep -q '^PREPARE_MCP_PROFILE:work$' "$STUB1B" || {
  echo "FAIL: case1b — expected work MCP surface before Codex preparation"; cat "$STUB1B"; cat "$STUB1B.tui.log"; exit 1;
}
grep -q 'MCP surface: work' "$STUB1B.tui.log" || {
  echo "FAIL: case1b — MCP surface toggle was not shown as work"; cat "$STUB1B.tui.log"; exit 1;
}
grep -q 'work — base' "$STUB1B.tui.log" && {
  echo "FAIL: case1b — work must no longer be a Profile menu entry"; cat "$STUB1B.tui.log"; exit 1;
}
echo "PASS: case1b — Codex work MCP surface toggle exports before execution"

# Case 1c: work surface combines with a non-base profile (rich), like claude light.
STUB1C="$TEST_TEMP/out1c-codex-work-rich.txt"
: > "$STUB1C"
run_tui $'2\n1\n5\n1\n2\n1\n' "$STUB1C"
grep -qE "^ARGS:.*-p rich" "$STUB1C" || {
  echo "FAIL: case1c — expected -p rich with work surface"; cat "$STUB1C"; exit 1;
}
grep -q '^MCP_PROFILE:work$' "$STUB1C" || {
  echo "FAIL: case1c — work surface must combine with rich profile"; cat "$STUB1C"; cat "$STUB1C.tui.log"; exit 1;
}
echo "PASS: case1c — work MCP surface combines with any profile"

# Case 2: runtime=Codex, session=Continue last, mode=Plan, safety=Default
STUB2="$TEST_TEMP/out2-codex-continue.txt"
: > "$STUB2"
run_tui $'2\n2\n4\n1\n1\n' "$STUB2"
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
run_tui $'2\n1\n2\n2\n1\n' "$STUB3"
grep -qE "^ARGS:.*--full-auto" "$STUB3" || {
  echo "FAIL: case3 — expected --full-auto"; cat "$STUB3"; exit 1;
}
echo "PASS: case3 — Safety=Full auto → --full-auto flag"

# Case 3b: runtime=Codex, Happy=yes → exec happy codex with same Codex args
# final menu with happy visible: 1 Start / 2 MCP surface / 3 Happy / 4 Back
STUB3B="$TEST_TEMP/out3b-codex-happy.txt"
: > "$STUB3B"
run_tui $'2\n1\n2\n1\n3\n1\n' "$STUB3B" "$HAPPY_BIN"
grep -q "^EXEC:happy" "$STUB3B" || {
  echo "FAIL: case3b — expected happy exec; got:"; cat "$STUB3B"; cat "$STUB3B.tui.log"; exit 1;
}
grep -qE "^ARGS:codex$" "$STUB3B" || {
  echo "FAIL: case3b — expected happy codex without unsupported Codex CLI args"; cat "$STUB3B"; exit 1;
}
grep -q "^CODEX_HOME:$TEST_HARNESS/.harness/codex\$" "$STUB3B" || {
  echo "FAIL: case3b — CODEX_HOME mismatch"; cat "$STUB3B"; exit 1;
}
echo "PASS: case3b — runtime=Codex + Happy=yes → exec happy codex"

# Case 3c: Happy installed, but non-base Codex mode must not offer Happy prompt
STUB3C="$TEST_TEMP/out3c-codex-rich-happy-installed.txt"
: > "$STUB3C"
run_tui $'2\n1\n5\n1\n1\n' "$STUB3C" "$HAPPY_BIN"
grep -q "^EXEC:codex" "$STUB3C" || {
  echo "FAIL: case3c — expected native codex exec; got:"; cat "$STUB3C"; cat "$STUB3C.tui.log"; exit 1;
}
grep -qE "^ARGS:.*-p rich" "$STUB3C" || {
  echo "FAIL: case3c — expected native codex rich profile"; cat "$STUB3C"; exit 1;
}
if grep -q "^EXEC:happy" "$STUB3C"; then
  echo "FAIL: case3c — Happy prompt/path should be skipped for non-base Codex profile"; cat "$STUB3C"; exit 1;
fi
echo "PASS: case3c — Happy installed + Codex rich skips Happy prompt and runs native Codex"

# Case 4: only Claude in PATH (no codex) → runtime menu auto-skips, Claude flow runs
NO_CODEX_BIN="$TEST_TEMP/bin-noco"
mkdir -p "$NO_CODEX_BIN"
cp "$TEST_BIN/claude" "$NO_CODEX_BIN/claude"
chmod +x "$NO_CODEX_BIN/claude"

STUB4="$TEST_TEMP/out4-claude-only.txt"
: > "$STUB4"
rm -f "$TEST_HARNESS/.harness/launcher-last" "$TEST_HARNESS/.harness/launcher-history"
TEST_STUB_FILE="$STUB4" \
PATH="$NO_CODEX_BIN:/usr/bin:/bin" \
HARNESS_CODEX_BIN="$TEST_TEMP/missing-codex" \
HARNESS_DIR="$TEST_HARNESS" \
HARNESS_NAME="test harness" \
bash "$TEST_LAUNCHER_BIN/launcher.sh" <<< $'1\n2\n1\n' >/dev/null 2>&1 || true
grep -q "^EXEC:claude" "$STUB4" || {
  echo "FAIL: case4 — runtime auto-skip didn't reach Claude exec"; cat "$STUB4"; exit 1;
}
echo "PASS: case4 — codex absent → runtime menu auto-skips to Claude flow"

# Case 5: runtime=Claude (with both runtimes available) routes to Claude
STUB5="$TEST_TEMP/out5-claude-via-tui.txt"
: > "$STUB5"
run_tui $'1\n1\n2\n1\n' "$STUB5"
grep -q "^EXEC:claude" "$STUB5" || {
  echo "FAIL: case5 — expected claude exec when runtime=Claude"; cat "$STUB5"; exit 1;
}
if grep -q "^EXEC:codex" "$STUB5"; then
  echo "FAIL: case5 — codex was launched even though runtime=Claude was selected"; cat "$STUB5"; exit 1;
fi
echo "PASS: case5 — runtime=Claude routes to Claude exec"

# Case 6: Happy toggled on, then Back → safety changed to full-auto.
# Compatibility is broken, so the hidden toggle must auto-clear and Start
# must launch native codex with --full-auto (not fail into plan_reset).
STUB6="$TEST_TEMP/out6-happy-residue.txt"
: > "$STUB6"
# final(compatible): Happy=3, Back=4 → safety full-auto=2 → final(incompatible): Start=1
run_tui $'2\n1\n2\n1\n3\n4\n2\n1\n' "$STUB6" "$HAPPY_BIN"
grep -q "^EXEC:codex" "$STUB6" || {
  echo "FAIL: case6 — expected native codex exec after happy auto-clear"; cat "$STUB6"; cat "$STUB6.tui.log"; exit 1;
}
grep -qE "^ARGS:.*--full-auto" "$STUB6" || {
  echo "FAIL: case6 — expected --full-auto"; cat "$STUB6"; exit 1;
}
if grep -q "^EXEC:happy" "$STUB6"; then
  echo "FAIL: case6 — happy must auto-clear when compatibility breaks"; cat "$STUB6"; exit 1;
fi
if grep -q "시작 실패" "$STUB6.tui.log"; then
  echo "FAIL: case6 — start must succeed, not fail into plan reset"; cat "$STUB6.tui.log"; exit 1;
fi
echo "PASS: case6 — stale Happy toggle auto-clears when compatibility breaks"

# Case 6b: Happy on, then work toggle → happy must drop; codex runs with work.
STUB6B="$TEST_TEMP/out6b-happy-work-exclusive.txt"
: > "$STUB6B"
# final: Happy on(3) → MCP surface work(2) → Start(1)
run_tui $'2\n1\n2\n1\n3\n2\n1\n' "$STUB6B" "$HAPPY_BIN"
grep -q "^EXEC:codex" "$STUB6B" || {
  echo "FAIL: case6b — expected native codex exec after work toggle drops happy"; cat "$STUB6B"; cat "$STUB6B.tui.log"; exit 1;
}
grep -q '^MCP_PROFILE:work$' "$STUB6B" || {
  echo "FAIL: case6b — expected work surface"; cat "$STUB6B"; exit 1;
}
if grep -q "^EXEC:happy" "$STUB6B"; then
  echo "FAIL: case6b — happy must not survive the work toggle"; cat "$STUB6B"; exit 1;
fi
echo "PASS: case6b — work toggle drops Happy (mutually exclusive)"

# Case 7: replaying a 0.12.0-era work history row (CODEX_SURFACE=work written
# by the removed Profile-menu flow) must still launch with the work surface.
# run_tui wipes the history, so drive the launcher directly with a seeded row.
STUB7="$TEST_TEMP/out7-legacy-work-history.txt"
: > "$STUB7"
mkdir -p "$TEST_HARNESS/.harness"
printf 'TS=1\tSUMMARY=Codex · new · base · work-MCP\tRUNTIME=codex\tSESSION=new\tMODE=\tPERM=default\tMCP_SURFACE=full\tCHROME=0\tHAPPY=0\tCODEX_PROFILE=base\tCODEX_SURFACE=work\tCODEX_SAFETY=default\tKIRO_TRUST=0\n' \
  > "$TEST_HARNESS/.harness/launcher-history"
# launchpad: New Claude(1), New Codex(2), hist row(3)
TEST_STUB_FILE="$STUB7" \
PATH="$TEST_BIN:/usr/bin:/bin" \
HARNESS_CODEX_BIN="$TEST_BIN/codex" \
HARNESS_DIR="$TEST_HARNESS" \
HARNESS_NAME="test harness" \
bash "$TEST_LAUNCHER_BIN/launcher.sh" <<< $'3\n' > "$STUB7.tui.log" 2>&1 || true
grep -q '^PREPARE_MCP_PROFILE:work$' "$STUB7" || {
  echo "FAIL: case7 — 0.12-era work history row must prepare with work surface"; cat "$STUB7"; cat "$STUB7.tui.log"; exit 1;
}
grep -q '^MCP_PROFILE:work$' "$STUB7" || {
  echo "FAIL: case7 — 0.12-era work history row must exec with work surface"; cat "$STUB7"; exit 1;
}
grep -qE "^ARGS:.*-p base" "$STUB7" || {
  echo "FAIL: case7 — expected -p base from the replayed row"; cat "$STUB7"; exit 1;
}
rm -f "$TEST_HARNESS/.harness/launcher-history"
echo "PASS: case7 — 0.12-era CODEX_SURFACE=work history row replays correctly"

echo "✓ All codex TUI tests passed"
