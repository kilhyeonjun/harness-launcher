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

TEST_HOME="$TEST_TEMP/home"
mkdir -p "$TEST_HOME"

run_tui() {
  # run_tui <input> <out-file> <stub-file> [extra env as K=V ...]
  # HOME is isolated so the real ~/.claude.json cannot bleed user-scope MCP
  # servers into light-surface assertions.
  local input="$1" out_file="$2" stub_file="$3"; shift 3
  env "$@" \
    TEST_STUB_FILE="$stub_file" \
    PATH="$TEST_BASE_PATH" \
    HOME="$TEST_HOME" \
    HARNESS_CODEX_BIN="${HARNESS_CODEX_BIN_OVERRIDE:-$TEST_TEMP/missing-codex}" \
    HARNESS_DIR="$TEST_HARNESS" \
    HARNESS_NAME="test harness" \
    bash "$LAUNCHER_DIR/bin/launcher.sh" <<< "$input" > "$out_file" 2>&1 || true
}

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "--- output:"; cat "$2"; }; exit 1; }

reset_plan() { rm -f "$TEST_HARNESS/.harness/launcher-last" "$TEST_HARNESS/.harness/launcher-history"; }
HISTORY="$TEST_HARNESS/.harness/launcher-history"

write_stub claude
write_node_stub

# --- 1. base start: session→mode(base)→start -------------------------------
OUT="$TEST_TEMP/1.out"; STUB="$TEST_TEMP/1.stub"; reset_plan
run_tui $'1\n2\n1\n' "$OUT" "$STUB"
grep -q 'EXEC:claude --model sonnet --effort high --exclude-dynamic-system-prompt-sections' "$STUB" \
  || fail 'base mode should exec claude sonnet/high' "$OUT"
[[ -f "$HISTORY" ]] || fail 'launch should save a history entry' "$OUT"
head -1 "$HISTORY" | grep -q 'MODE=base' || fail 'history entry should record MODE=base'
head -1 "$HISTORY" | grep -q 'RUNTIME=claude' || fail 'history entry should record RUNTIME=claude'
echo 'PASS: base mode launches and saves history entry'

# --- 2. mode labels derive from the shared table (B2 regression) ------------
grep -q 'Fast — haiku · low' "$OUT" || fail 'fast label must show the real model (haiku)' "$OUT"
grep -q 'Base — sonnet · high' "$OUT" || fail 'base label must show sonnet · high' "$OUT"
echo 'PASS: mode labels match the shared mode table'

# --- 3. launchpad history row replays identical launch ----------------------
OUT="$TEST_TEMP/3.out"; STUB="$TEST_TEMP/3.stub"
run_tui $'1\n' "$OUT" "$STUB"
grep -q 'EXEC:claude --model sonnet --effort high' "$STUB" || fail 'history row should replay same exec' "$OUT"
[[ "$(grep -c '^EXEC:' "$STUB")" -eq 1 ]] || fail 'history row should exec exactly once' "$OUT"
grep -q '↩ Claude · direct · new · sonnet · high' "$OUT" || fail 'launchpad should list the history row' "$OUT"
grep -q 'New — Claude Code 구성' "$OUT" || fail 'launchpad should offer a New composer entry' "$OUT"
echo 'PASS: launchpad history row replays the previous launch'

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
# final menu with happy: 1 Start / 2 Permission / 3 Chrome / 4 MCP surface / 5 Happy / 6 Back
write_stub happy
OUT="$TEST_TEMP/7.out"; STUB="$TEST_TEMP/7.stub"; reset_plan
run_tui $'1\n2\n5\n1\n' "$OUT" "$STUB"
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
# session New → mode ultracode(5) → final Back(6: Start/Perm/Chrome/MCP/Happy/Back) → mode fast(1) → start
run_tui $'1\n5\n6\n1\n1\n' "$OUT" "$STUB"
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

# --- 16. history alone (no runtimes) → clear no-runtime error, no crash ------
OUT="$TEST_TEMP/16.out"; STUB="$TEST_TEMP/16.stub"
mkdir -p "$TEST_HARNESS/.harness"
printf 'TS=1\tSUMMARY=Claude · direct · new · sonnet · high\tRUNTIME=claude\tMODE=base\n' > "$HISTORY"
rm -f "$TEST_BIN/claude" "$TEST_BIN/happy"
run_tui $'1\n' "$OUT" "$STUB"
grep -q 'no runtime found' "$OUT" || fail 'history-only + no runtimes should print the no-runtime error' "$OUT"
grep -q 'unknown runtime' "$OUT" && fail 'history must never surface as an unknown runtime' "$OUT"
write_stub claude
reset_plan
echo 'PASS: history-only with zero runtimes fails with a clear error'

# --- 16b. legacy launcher-last migrates into history --------------------------
OUT="$TEST_TEMP/16b.out"; STUB="$TEST_TEMP/16b.stub"; reset_plan
printf 'RUNTIME=claude\nSUMMARY=Claude · direct · new · sonnet · high\nPROVIDER=direct\nSESSION=new\nMODE=base\n' \
  > "$TEST_HARNESS/.harness/launcher-last"
run_tui $'1\n' "$OUT" "$STUB"
[[ -f "$TEST_HARNESS/.harness/launcher-last" ]] && fail 'legacy plan file should be removed after migration' "$OUT"
head -1 "$HISTORY" | grep -q 'MODE=base' || fail 'legacy plan should migrate into history' "$OUT"
grep -q 'EXEC:claude --model sonnet --effort high' "$STUB" || fail 'migrated history row should replay' "$OUT"
echo 'PASS: legacy launcher-last migrates into history and replays'

# --- 17. MCP surface light toggle (claude) --------------------------------------
# no happy stub here → final menu: 1 Start / 2 Permission / 3 Chrome / 4 MCP surface / 5 Back
OUT="$TEST_TEMP/17.out"; STUB="$TEST_TEMP/17.stub"; reset_plan
cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{"mcpServers": {
  "ssh_rag": {"command": "bash", "args": ["core/bin/start-ssh-mcp.sh", "rag"]},
  "tunnel_rag": {"type": "http", "url": "http://127.0.0.1:38206/mcp"},
  "local_service": {"type": "http", "url": "http://localhost:38100/mcp"},
  "normal_http": {"type": "http", "url": "https://x.test/mcp"}
}}
EOF
run_tui $'1\n2\n4\n1\n' "$OUT" "$STUB"
LIGHT_FILE="$TEST_HARNESS/.harness/claude/mcp-light.json"
grep -q -- "--strict-mcp-config --mcp-config $LIGHT_FILE" "$STUB" \
  || fail 'light surface should pass --strict-mcp-config + generated file' "$OUT"
[[ -f "$LIGHT_FILE" ]] || fail 'light surface should generate mcp-light.json' "$OUT"
grep -q 'ssh_rag' "$LIGHT_FILE" && fail 'light surface must exclude SSH stdio wrappers' "$OUT"
grep -q 'tunnel_rag' "$LIGHT_FILE" && fail 'light surface must exclude 382xx tunnel servers' "$OUT"
grep -q 'local_service' "$LIGHT_FILE" || fail 'light surface must keep non-band loopback servers' "$OUT"
grep -q 'normal_http' "$LIGHT_FILE" || fail 'light surface must keep remote https servers' "$OUT"
head -1 "$HISTORY" | grep -q 'MCP_SURFACE=light' \
  || fail 'history entry should record MCP_SURFACE=light'
echo 'PASS: claude light MCP surface filters SSH servers'

# --- 18. MCP surface light toggle (kiro) -----------------------------------------
# kiro-only runtime → session 1 → mode base(2) → final: 1 Start / 2 Trust / 3 MCP / 4 Back
rm -f "$TEST_BIN/claude" "$TEST_BIN/happy"
OUT="$TEST_TEMP/18.out"; STUB="$TEST_TEMP/18.stub"; reset_plan
run_tui $'1\n2\n3\n1\n' "$OUT" "$STUB" HARNESS_KIRO_BIN="$TEST_TEMP/kirodir/my-kiro"
grep -q 'EXEC:kiro chat' "$STUB" || fail 'kiro light launch should exec kiro' "$OUT"
KIRO_MCP="$TEST_HARNESS/.harness/kiro/settings/mcp.json"
[[ -f "$KIRO_MCP" ]] || fail 'kiro prepare should generate settings/mcp.json' "$OUT"
grep -q 'ssh_rag' "$KIRO_MCP" && fail 'kiro light surface must exclude SSH stdio wrappers' "$OUT"
grep -q 'tunnel_rag' "$KIRO_MCP" && fail 'kiro light surface must exclude 382xx tunnel servers' "$OUT"
grep -q 'local_service' "$KIRO_MCP" || fail 'kiro light surface must keep non-band loopback servers' "$OUT"
grep -q 'normal_http' "$KIRO_MCP" || fail 'kiro light surface must keep remote https servers' "$OUT"
# full surface run right after must restore the SSH server (no light residue)
OUT="$TEST_TEMP/18b.out"; STUB="$TEST_TEMP/18b.stub"; reset_plan
run_tui $'1\n2\n1\n' "$OUT" "$STUB" HARNESS_KIRO_BIN="$TEST_TEMP/kirodir/my-kiro"
grep -q 'ssh_rag' "$KIRO_MCP" || fail 'full surface must restore SSH servers (light residue)' "$OUT"
rm -f "$TEST_HARNESS/.mcp.json"
write_stub claude
echo 'PASS: kiro light MCP surface filters SSH servers, full restores'

# --- 19. launchpad: dedupe by identity + older-row replay ----------------------
OUT="$TEST_TEMP/19.out"; STUB="$TEST_TEMP/19.stub"; reset_plan
run_tui $'1\n2\n1\n' "$OUT" "$STUB"                       # base → history[1]
OUT="$TEST_TEMP/19b.out"; STUB="$TEST_TEMP/19b.stub"
run_tui $'2\n1\n1\n1\n' "$OUT" "$STUB"                    # New Claude(2) → fast → history now: fast, base
[[ "$(wc -l < "$HISTORY")" -eq 2 ]] || fail 'two distinct configs should produce two history rows' "$OUT"
head -1 "$HISTORY" | grep -q 'MODE=fast' || fail 'newest config should be first in history' "$OUT"
OUT="$TEST_TEMP/19c.out"; STUB="$TEST_TEMP/19c.stub"
run_tui $'2\n' "$OUT" "$STUB"                             # older row (base) replays…
grep -q 'EXEC:claude --model sonnet --effort high' "$STUB" || fail 'older history row should replay base' "$OUT"
[[ "$(wc -l < "$HISTORY")" -eq 2 ]] || fail 'replay must dedupe, not append a third row' "$OUT"
head -1 "$HISTORY" | grep -q 'MODE=base' || fail '…and move to the top of the history' "$OUT"
reset_plan
echo 'PASS: launchpad dedupes by identity and reorders on replay'

# --- 20. light + happy are mutually exclusive -----------------------------------
# final menu with happy: 1 Start / 2 Perm / 3 Chrome / 4 MCP / 5 Happy / 6 Back
write_stub happy
cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{"mcpServers": {"ssh_rag": {"command": "bash", "args": ["core/bin/start-ssh-mcp.sh", "rag"]}}}
EOF
OUT="$TEST_TEMP/20.out"; STUB="$TEST_TEMP/20.stub"; reset_plan
# light(4) then happy(5): happy wins, surface reverts to full → happy exec, no strict
run_tui $'1\n2\n4\n5\n1\n' "$OUT" "$STUB"
grep -q 'EXEC:happy' "$STUB" || fail 'happy after light should launch happy' "$OUT"
grep -q -- '--strict-mcp-config' "$STUB" && fail 'happy launch must never carry --strict-mcp-config' "$OUT"
head -1 "$HISTORY" | grep -q 'MCP_SURFACE=full' || fail 'happy toggle should revert surface to full in history' "$OUT"
# happy(5) then light(4): light wins, happy drops → claude exec with strict
OUT="$TEST_TEMP/20b.out"; STUB="$TEST_TEMP/20b.stub"; reset_plan
run_tui $'1\n2\n5\n4\n1\n' "$OUT" "$STUB"
grep -q 'EXEC:claude .*--strict-mcp-config' "$STUB" || fail 'light after happy should launch claude with strict config' "$OUT"
grep -q 'EXEC:happy' "$STUB" && fail 'light after happy must not exec happy' "$OUT"
# replay guard: a hand-edited history row with both set must fail, not launch full
OUT="$TEST_TEMP/20c.out"; STUB="$TEST_TEMP/20c.stub"; reset_plan
printf 'TS=1\tSUMMARY=Claude · direct · new · sonnet · high · mcp-light · happy\tRUNTIME=claude\tPROVIDER=direct\tSESSION=new\tMODE=base\tPERM=default\tMCP_SURFACE=light\tCHROME=0\tHAPPY=1\n' > "$HISTORY"
run_tui $'1\nq\n' "$OUT" "$STUB"
grep -q 'Happy 래퍼는 light MCP surface를 지원하지 않습니다' "$OUT" || fail 'replayed light+happy row must fail with a clear error' "$OUT"
[[ -f "$STUB" ]] && grep -q '^EXEC:' "$STUB" && fail 'replayed light+happy row must not exec anything' "$OUT"
rm -f "$TEST_BIN/happy" "$TEST_HARNESS/.mcp.json"; reset_plan
echo 'PASS: light and happy are mutually exclusive (toggles + replay guard)'

# --- 21. light generation fails on duplicate server names ----------------------
OUT="$TEST_TEMP/21.out"; STUB="$TEST_TEMP/21.stub"; reset_plan
cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{"mcpServers": {"dup": {"command": "x"}}}
EOF
cat > "$TEST_HARNESS/mcp.local.json" <<'EOF'
{"mcpServers": {"dup": {"command": "y"}}}
EOF
run_tui $'1\n2\n4\n1\n' "$OUT" "$STUB"
grep -q "duplicate MCP server 'dup'" "$OUT" || fail 'light surface must fail on duplicate server names' "$OUT"
[[ -f "$STUB" ]] && grep -q '^EXEC:' "$STUB" && fail 'light duplicate failure must block the launch' "$OUT"
rm -f "$TEST_HARNESS/.mcp.json" "$TEST_HARNESS/mcp.local.json"; reset_plan
echo 'PASS: light surface blocks launch on duplicate server names'

# --- 22. hidden history row (uninstalled runtime) must not shift replay mapping --
OUT="$TEST_TEMP/22.out"; STUB="$TEST_TEMP/22.stub"; reset_plan
mkdir -p "$TEST_HARNESS/.harness"
printf 'TS=2\tSUMMARY=Codex · new · base\tRUNTIME=codex\tSESSION=new\tCODEX_PROFILE=base\tCODEX_SURFACE=default\tCODEX_SAFETY=default\n' > "$HISTORY"
printf 'TS=1\tSUMMARY=Claude · direct · new · haiku · low\tRUNTIME=claude\tPROVIDER=direct\tSESSION=new\tMODE=fast\tPERM=default\tMCP_SURFACE=full\tCHROME=0\tHAPPY=0\n' >> "$HISTORY"
# codex is not installed → its row is hidden; option 1 must be the claude fast row
run_tui $'1\n' "$OUT" "$STUB"
grep -q 'Codex · new · base' "$OUT" && fail 'hidden runtime row must not be listed' "$OUT"
grep -q 'EXEC:claude --model haiku --effort low' "$STUB" || fail 'first visible row must replay the claude entry, not the hidden codex one' "$OUT"
reset_plan
echo 'PASS: hidden history rows do not shift replay mapping'

# --- 23. history trimmed to HISTORY_MAX (8) --------------------------------------
OUT="$TEST_TEMP/23.out"; STUB="$TEST_TEMP/23.stub"; reset_plan
mkdir -p "$TEST_HARNESS/.harness"
: > "$HISTORY"
for i in 1 2 3 4 5 6 7 8 9; do
  printf 'TS=%s\tSUMMARY=cfg%s\tRUNTIME=claude\tPROVIDER=direct\tSESSION=new\tMODE=m%s\tPERM=default\tMCP_SURFACE=full\tCHROME=0\tHAPPY=0\n' "$i" "$i" "$i" >> "$HISTORY"
done
# 9 hist rows + New Claude at 10 → compose a 10th distinct config (base)
run_tui $'10\n1\n2\n1\n' "$OUT" "$STUB"
grep -q 'EXEC:claude --model sonnet' "$STUB" || fail 'composer must still launch with 9 history rows' "$OUT"
[[ "$(wc -l < "$HISTORY")" -eq 8 ]] || fail "10th distinct config must trim history to 8 (got $(wc -l < "$HISTORY"))"
head -1 "$HISTORY" | grep -q 'MODE=base' || fail 'newest config must be first after trimming'
grep -q 'SUMMARY=cfg7' "$HISTORY" || fail 'entry 7 must survive trimming'
grep -q 'SUMMARY=cfg8\|SUMMARY=cfg9' "$HISTORY" && fail 'oldest entries must be trimmed away'
reset_plan
echo 'PASS: history trimmed to HISTORY_MAX'

# --- 24. legacy plan is deleted, not merged, when history already exists ---------
OUT="$TEST_TEMP/24.out"; STUB="$TEST_TEMP/24.stub"; reset_plan
printf 'TS=1\tSUMMARY=Claude · direct · new · sonnet · high\tRUNTIME=claude\tPROVIDER=direct\tSESSION=new\tMODE=base\tPERM=default\tMCP_SURFACE=full\tCHROME=0\tHAPPY=0\n' > "$HISTORY"
printf 'RUNTIME=claude\nSUMMARY=LEGACYMARK\nPROVIDER=direct\nSESSION=new\nMODE=rich\n' > "$TEST_HARNESS/.harness/launcher-last"
run_tui $'1\n' "$OUT" "$STUB"
[[ -f "$TEST_HARNESS/.harness/launcher-last" ]] && fail 'legacy plan must be deleted even when history exists' "$OUT"
grep -q 'LEGACYMARK' "$HISTORY" && fail 'legacy plan must NOT be merged into an existing history' "$OUT"
grep -q 'EXEC:claude --model sonnet' "$STUB" || fail 'existing history must stay replayable' "$OUT"
reset_plan
echo 'PASS: legacy plan deleted without merging into existing history'

# --- 25. user-scope MCP servers survive the light surface -------------------------
OUT="$TEST_TEMP/25.out"; STUB="$TEST_TEMP/25.stub"; reset_plan
cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{"mcpServers": {
  "ssh_rag": {"command": "bash", "args": ["core/bin/start-ssh-mcp.sh", "rag"]},
  "shared_name": {"type": "http", "url": "https://harness.test/mcp"}
}}
EOF
cat > "$TEST_HOME/.claude.json" <<'EOF'
{"mcpServers": {
  "user_tool": {"command": "/usr/local/bin/user-tool", "args": ["mcp"]},
  "user_tunnel": {"type": "http", "url": "http://127.0.0.1:38250"},
  "shared_name": {"type": "http", "url": "https://user.test/mcp"}
}, "projects": {}}
EOF
run_tui $'1\n2\n4\n1\n' "$OUT" "$STUB"
grep -q 'user_tool' "$LIGHT_FILE" || fail 'light surface must carry non-SSH user-scope servers' "$OUT"
grep -q 'user_tunnel' "$LIGHT_FILE" && fail 'SSH-tunnel-band user-scope servers must be dropped (path-less URL too)' "$OUT"
grep -q 'harness.test' "$LIGHT_FILE" || fail 'harness scope must win user-scope name collisions' "$OUT"
grep -q 'user.test' "$LIGHT_FILE" && fail 'user-scope duplicate of a harness server must not override it' "$OUT"
rm -f "$TEST_HARNESS/.mcp.json" "$TEST_HOME/.claude.json"; reset_plan
echo 'PASS: user-scope servers merge into the light surface (harness wins collisions)'

echo 'ALL launcher TUI tests passed'
