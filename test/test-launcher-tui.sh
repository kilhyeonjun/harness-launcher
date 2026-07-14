#!/usr/bin/env bash
# TUI v2 flow tests — drives bin/launcher.sh through the no-gum fallback menu.
# Covers: mode table labels, final-menu toggles (permission/chrome/happy),
# session flags, invalid-input reprompt, back navigation, repeat-last replay,
# MCP duplicate validation blocking, HARNESS_KIRO_BIN resolution, gateways.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() {
  [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"
TEST_BIN="$TEST_TEMP/bin"
mkdir -p "$TEST_HARNESS/config" "$TEST_BIN"
cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF

TEST_BASE_PATH="$TEST_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

write_stub() {
  # write_stub <name> — records EXEC line + env snapshot then exits.
  cat > "$TEST_BIN/$1" <<EOF
#!/usr/bin/env bash
{
  echo "EXEC:$1 \$*"
  echo "BASE_URL:\${ANTHROPIC_BASE_URL:-}"
  echo "AUTH_TOKEN:\${ANTHROPIC_AUTH_TOKEN:-}"
  echo "OPUS_MODEL:\${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"
  echo "PCT:\${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}"
} >> "\$TEST_STUB_FILE"
exit 0
EOF
  chmod +x "$TEST_BIN/$1"
}

write_node_stub() {
  cat > "$TEST_BIN/node" <<'EOF'
#!/usr/bin/env bash
provider_url="${PROBE_PROVIDER_URL:-}"
case "$provider_url" in
  *"kiro.test"*) [[ "${TEST_KIRO_HEALTH:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *"codex.test"*) [[ "${TEST_CODEX_HEALTH:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEST_BIN/node"
}

run_tui() {
  # run_tui <input> <out-file> <stub-file> [extra env as K=V ...]
  local input="$1" out_file="$2" stub_file="$3"; shift 3
  env "$@" \
    TEST_STUB_FILE="$stub_file" \
    PATH="$TEST_BASE_PATH" \
    HARNESS_CODEX_BIN="${HARNESS_CODEX_BIN_OVERRIDE:-$TEST_TEMP/missing-codex}" \
    HARNESS_DIR="$TEST_HARNESS" \
    HARNESS_NAME="test harness" \
    bash "$LAUNCHER_DIR/bin/launcher.sh" <<< "$input" > "$out_file" 2>&1 || true
}

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "--- output:"; cat "$2"; }; exit 1; }

reset_plan() { rm -f "$TEST_HARNESS/.harness/launcher-last"; }

write_stub claude
write_node_stub

# --- 1. base start: session→mode(base)→start -------------------------------
OUT="$TEST_TEMP/1.out"; STUB="$TEST_TEMP/1.stub"; reset_plan
run_tui $'1\n2\n1\n' "$OUT" "$STUB"
grep -q 'EXEC:claude --model sonnet --effort high --exclude-dynamic-system-prompt-sections' "$STUB" \
  || fail 'base mode should exec claude sonnet/high' "$OUT"
[[ -f "$TEST_HARNESS/.harness/launcher-last" ]] || fail 'launch should save plan file' "$OUT"
grep -q '^MODE=base' "$TEST_HARNESS/.harness/launcher-last" || fail 'plan file should record MODE=base'
echo 'PASS: base mode launches and saves plan'

# --- 2. mode labels derive from the shared table (B2 regression) ------------
grep -q 'Fast — haiku · low' "$OUT" || fail 'fast label must show the real model (haiku)' "$OUT"
grep -q 'Base — sonnet · high' "$OUT" || fail 'base label must show sonnet · high' "$OUT"
echo 'PASS: mode labels match the shared mode table'

# --- 3. repeat-last replays identical launch --------------------------------
OUT="$TEST_TEMP/3.out"; STUB="$TEST_TEMP/3.stub"
run_tui $'1\n' "$OUT" "$STUB"
grep -q 'EXEC:claude --model sonnet --effort high' "$STUB" || fail 'repeat-last should replay same exec' "$OUT"
[[ "$(grep -c '^EXEC:' "$STUB")" -eq 1 ]] || fail 'repeat-last should exec exactly once' "$OUT"
grep -q 'Repeat last' "$OUT" || fail 'runtime menu should offer Repeat last' "$OUT"
echo 'PASS: repeat-last replays the previous launch'

# --- 4. continue session flag ------------------------------------------------
OUT="$TEST_TEMP/4.out"; STUB="$TEST_TEMP/4.stub"; reset_plan
run_tui $'2\n2\n1\n' "$OUT" "$STUB"
grep -q 'EXEC:claude --continue --model sonnet' "$STUB" || fail 'continue should add --continue' "$OUT"
echo 'PASS: continue session flag preserved'

# --- 5. permission select + replace (no accumulation) ------------------------
OUT="$TEST_TEMP/5.out"; STUB="$TEST_TEMP/5.stub"; reset_plan
# final: 2=Permission → acceptEdits(2); final: 2=Permission → bypassPermissions(4); start
run_tui $'1\n2\n2\n2\n2\n4\n1\n' "$OUT" "$STUB"
grep -q -- '--permission-mode bypassPermissions' "$STUB" || fail 'permission re-selection should apply last choice' "$OUT"
grep -q 'acceptEdits' "$STUB" && fail 'permission re-selection must not accumulate old value' "$OUT"
echo 'PASS: permission mode replaces, never accumulates'

# --- 6. chrome toggle ---------------------------------------------------------
OUT="$TEST_TEMP/6.out"; STUB="$TEST_TEMP/6.stub"; reset_plan
run_tui $'1\n2\n3\n1\n' "$OUT" "$STUB"
grep -q -- '--chrome' "$STUB" || fail 'chrome toggle should add --chrome' "$OUT"
echo 'PASS: chrome toggle adds --chrome'

# --- 7. happy toggle routes exec through happy --------------------------------
write_stub happy
OUT="$TEST_TEMP/7.out"; STUB="$TEST_TEMP/7.stub"; reset_plan
run_tui $'1\n2\n4\n1\n' "$OUT" "$STUB"
grep -q 'EXEC:happy --model sonnet' "$STUB" || fail 'happy toggle should exec happy' "$OUT"
grep -q 'EXEC:claude' "$STUB" && fail 'happy launch must not also exec claude' "$OUT"
[[ "$(grep -c '^EXEC:' "$STUB")" -eq 1 ]] || fail 'happy launch should exec exactly once' "$OUT"
echo 'PASS: happy wrapper launch'

# --- 8. invalid input reprompts instead of exiting (B4) -----------------------
OUT="$TEST_TEMP/8.out"; STUB="$TEST_TEMP/8.stub"; reset_plan
run_tui $'9\nx\n\n1\n2\n1\n' "$OUT" "$STUB"
grep -q 'EXEC:claude --model sonnet' "$STUB" || fail 'invalid input should reprompt, then proceed' "$OUT"
echo 'PASS: fallback menu reprompts on invalid input'

# --- 9. q at first menu exits cleanly with no exec ----------------------------
OUT="$TEST_TEMP/9.out"; STUB="$TEST_TEMP/9.stub"; reset_plan
run_tui $'q\n' "$OUT" "$STUB"
[[ -f "$STUB" ]] && grep -q '^EXEC:' "$STUB" && fail 'q at first menu must not exec anything' "$OUT"
echo 'PASS: q backs out without launching'

# --- 10. ultracode hint does not survive back-navigation (B6) ------------------
OUT="$TEST_TEMP/10.out"; STUB="$TEST_TEMP/10.stub"; reset_plan
# session New → mode ultracode(5) → final Back(5: Start/Perm/Chrome/Happy/Back) → mode fast(1) → start
run_tui $'1\n5\n5\n1\n1\n' "$OUT" "$STUB"
grep -q 'EXEC:claude --model haiku' "$STUB" || fail 'fast after back-nav should exec haiku' "$OUT"
grep -q 'ultracode는 세션 전용' "$OUT" && fail 'ultracode hint must not leak into non-ultracode launch' "$OUT"
echo 'PASS: no ultracode hint residue after back-navigation'

# --- 11. duplicate MCP server blocks launch (B1) -------------------------------
OUT="$TEST_TEMP/11.out"; STUB="$TEST_TEMP/11.stub"; reset_plan
cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{"mcpServers": {"dup": {"command": "x"}}}
EOF
cat > "$TEST_HARNESS/mcp.local.json" <<'EOF'
{"mcpServers": {"dup": {"command": "y"}}}
EOF
run_tui $'1\n2\n1\n' "$OUT" "$STUB"
grep -q "duplicate MCP server 'dup'" "$OUT" || fail 'duplicate MCP should print validation error' "$OUT"
[[ -f "$STUB" ]] && grep -q '^EXEC:' "$STUB" && fail 'duplicate MCP must block the launch' "$OUT"
rm -f "$TEST_HARNESS/.mcp.json" "$TEST_HARNESS/mcp.local.json"
echo 'PASS: duplicate MCP server blocks launch'

# --- 12. local MCP config is passed when valid ---------------------------------
OUT="$TEST_TEMP/12.out"; STUB="$TEST_TEMP/12.stub"; reset_plan
cat > "$TEST_HARNESS/mcp.local.json" <<'EOF'
{"mcpServers": {"only-local": {"command": "x"}}}
EOF
run_tui $'1\n2\n1\n' "$OUT" "$STUB"
grep -q -- "--mcp-config $TEST_HARNESS/mcp.local.json" "$STUB" || fail 'valid local MCP config should be passed' "$OUT"
rm -f "$TEST_HARNESS/mcp.local.json"
echo 'PASS: valid local MCP config forwarded'

# --- 13. HARNESS_KIRO_BIN is honored by the TUI (B5) ----------------------------
mkdir -p "$TEST_TEMP/kirodir"
cat > "$TEST_TEMP/kirodir/my-kiro" <<'EOF'
#!/usr/bin/env bash
echo "EXEC:kiro $*" >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$TEST_TEMP/kirodir/my-kiro"
rm -f "$TEST_BIN/claude" "$TEST_BIN/happy"   # kiro becomes the only runtime
OUT="$TEST_TEMP/13.out"; STUB="$TEST_TEMP/13.stub"; reset_plan
run_tui $'1\n2\n1\n' "$OUT" "$STUB" HARNESS_KIRO_BIN="$TEST_TEMP/kirodir/my-kiro"
grep -q 'EXEC:kiro chat --model claude-sonnet-4.6 --effort high --agent harness' "$STUB" \
  || fail 'HARNESS_KIRO_BIN should surface kiro runtime in the TUI' "$OUT"
write_stub claude
echo 'PASS: HARNESS_KIRO_BIN resolved by TUI'

# --- 14. gateway provider flow (env exports + back-nav to provider) -------------
mkdir -p "$TEST_HARNESS/config/.local"
cat > "$TEST_HARNESS/config/.local/codex-gateway.env" <<'EOF'
CODEX_GATEWAY_URL="https://codex.test"
CODEX_GATEWAY_API_KEY="codex-test-key"
CODEX_OPUS_MODEL="gpt-test-opus"
EOF
OUT="$TEST_TEMP/14.out"; STUB="$TEST_TEMP/14.stub"; reset_plan
# provider: 1=direct 2=Codex gateway → select 2; session 1; mode base(2); start
run_tui $'2\n1\n2\n1\n' "$OUT" "$STUB" TEST_CODEX_HEALTH=1
grep -q 'BASE_URL:https://codex.test' "$STUB" || fail 'gateway launch should export ANTHROPIC_BASE_URL' "$OUT"
grep -q 'AUTH_TOKEN:codex-test-key' "$STUB" || fail 'gateway launch should export ANTHROPIC_AUTH_TOKEN' "$OUT"
grep -q 'OPUS_MODEL:gpt-test-opus' "$STUB" || fail 'codex gateway should export model overrides' "$OUT"
echo 'PASS: codex gateway provider exports env'

# --- 15. q at session returns to provider menu (B7) ------------------------------
OUT="$TEST_TEMP/15.out"; STUB="$TEST_TEMP/15.stub"; reset_plan
# provider 2(codex) → session q → provider 1(direct) → session 1 → base → start
run_tui $'2\nq\n1\n1\n2\n1\n' "$OUT" "$STUB" TEST_CODEX_HEALTH=1
[[ "$(grep -c 'Provider' "$OUT")" -ge 2 ]] || fail 'q at session should return to provider menu' "$OUT"
grep -q 'BASE_URL:$' "$STUB" || fail 'after backing out, direct provider should have no BASE_URL' "$OUT"
rm -rf "$TEST_HARNESS/config/.local"
echo 'PASS: session back-nav returns to provider menu'

# --- 16. plan file alone (no runtimes) → clear no-runtime error, no crash ------
OUT="$TEST_TEMP/16.out"; STUB="$TEST_TEMP/16.stub"
mkdir -p "$TEST_HARNESS/.harness"
printf 'RUNTIME=claude\nSUMMARY=Claude · direct · new · sonnet · high\n' > "$TEST_HARNESS/.harness/launcher-last"
rm -f "$TEST_BIN/claude" "$TEST_BIN/happy"
run_tui $'1\n' "$OUT" "$STUB"
grep -q 'no runtime found' "$OUT" || fail 'plan-only + no runtimes should print the no-runtime error' "$OUT"
grep -q "unknown runtime 'repeat'" "$OUT" && fail 'repeat must never surface as an unknown runtime' "$OUT"
write_stub claude
reset_plan
echo 'PASS: plan-only with zero runtimes fails with a clear error'

echo 'ALL launcher TUI tests passed'
