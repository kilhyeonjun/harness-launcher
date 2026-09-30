#!/usr/bin/env zsh
# test-launcher-passthrough.sh — verify the `--passthrough` launcher marker.
#
# SDK hosts (Paseo) replace the agent executable with an argv prefix such as
# `harness-auto claude base --passthrough` and append their own arguments.
# Everything after the marker must reach the agent verbatim: no launcher
# keyword capture (`--permission-mode plan` must not become opusplan), and an
# explicit caller --model/--effort/--permission-mode replaces the launcher's
# default instead of being overridden by it.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() {
  [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_TEMP="${TEST_TEMP:A}"
TEST_HARNESS="$TEST_TEMP/fake-harness"
TEST_BIN="$TEST_TEMP/bin"
mkdir -p "$TEST_HARNESS/config" "$TEST_HARNESS/.claude" "$TEST_BIN"
cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF
cat > "$TEST_HARNESS/.mcp.json" <<'EOF'
{"mcpServers":{"fixture":{"type":"stdio","command":"true"}}}
EOF

# Stubs print one argument per line so tests compare exact argv.
cat > "$TEST_BIN/claude" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do printf 'ARG:%s\n' "$arg"; done >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$TEST_BIN/claude"

fail() {
  echo "FAIL: $1" >&2
  [[ -f "${2:-}" ]] && sed 's/^/  /' "$2" >&2
  exit 1
}

run_claude() {  # <stub-file> <launcher args...>
  local stub_file="$1"; shift
  : > "$stub_file"
  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_BIN:$PATH"
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _harness_launcher_run "$TEST_HARNESS" "$@"
  ) </dev/null >/dev/null 2>"$stub_file.err"
}

argv_of() { sed -n 's/^ARG://p' "$1"; }
count_arg() { argv_of "$1" | grep -Fxc -- "$2" || true; }
value_after() { argv_of "$1" | grep -Fx -A1 -- "$2" | sed -n 2p; }
has_arg() { argv_of "$1" | grep -Fxq -- "$2"; }
# The launcher's one --settings merges forced thinking with its launch-record
# hook, so forced thinking is a member of that JSON, not the whole argument.
has_forced_thinking() { argv_of "$1" | grep -Fq -- '"alwaysThinkingEnabled":true,'; }

# Exact subsequence check: the passthrough tokens appear contiguously and in order.
has_sequence() {  # <stub-file> <tokens...>
  local file="$1"; shift
  local -a argv=("${(@f)$(argv_of "$file")}") want=("$@")
  local i j
  for (( i = 1; i + ${#want} - 1 <= ${#argv}; i++ )); do
    for (( j = 1; j <= ${#want}; j++ )); do
      [[ "${argv[i+j-1]}" == "${want[j]}" ]] || continue 2
    done
    return 0
  done
  return 1
}

MCP_FULL="$TEST_HARNESS/.harness/claude/mcp-full.json"
SDK_ARGS=(--output-format stream-json --verbose --input-format stream-json
  --thinking adaptive --effort high --model claude-sonnet-5-5
  --permission-prompt-tool stdio
  --mcp-config '{"mcpServers":{"paseo":{"type":"http","url":"http://127.0.0.1:6767/mcp"}}}'
  --setting-sources=user,project,local --permission-mode plan
  --allow-dangerously-skip-permissions --include-partial-messages)

# C1: the Paseo Agent SDK argv behind `base --passthrough`.
OUT="$TEST_TEMP/c1"
run_claude "$OUT" base --passthrough "${SDK_ARGS[@]}"
[[ -s "$OUT" ]] || fail 'C1 claude was not launched' "$OUT.err"
has_sequence "$OUT" "${SDK_ARGS[@]}" || fail 'C1 passthrough tokens changed or reordered' "$OUT"
[[ "$(count_arg "$OUT" --model)" == 1 ]] || fail 'C1 expected exactly one --model' "$OUT"
[[ "$(value_after "$OUT" --model)" == claude-sonnet-5-5 ]] || fail 'C1 caller model lost' "$OUT"
[[ "$(count_arg "$OUT" --effort)" == 1 ]] || fail 'C1 expected exactly one --effort' "$OUT"
[[ "$(value_after "$OUT" --effort)" == high ]] || fail 'C1 caller effort lost' "$OUT"
[[ "$(count_arg "$OUT" --permission-mode)" == 1 ]] || fail 'C1 expected one --permission-mode' "$OUT"
[[ "$(value_after "$OUT" --permission-mode)" == plan ]] || fail 'C1 permission mode rewritten' "$OUT"
has_arg "$OUT" opusplan && fail 'C1 plan was captured as a launcher keyword' "$OUT"
has_arg "$OUT" --passthrough && fail 'C1 marker was forwarded to claude' "$OUT"
has_forced_thinking "$OUT" && fail 'C1 forced thinking despite caller effort' "$OUT"
has_arg "$OUT" --exclude-dynamic-system-prompt-sections \
  || fail 'C1 harness system-prompt flag missing' "$OUT"
has_sequence "$OUT" --mcp-config "$MCP_FULL" || fail 'C1 harness MCP config missing' "$OUT"
echo 'PASS: C1 SDK argv passes through with caller model/effort/permission-mode'

# C2: keyword-valued options and = forms stay verbatim; no launcher effort.
OUT="$TEST_TEMP/c2"
run_claude "$OUT" rich --passthrough --permission-mode acceptEdits --effort=low
has_sequence "$OUT" --permission-mode acceptEdits || fail 'C2 acceptEdits value rewritten' "$OUT"
[[ "$(count_arg "$OUT" --permission-mode)" == 1 ]] || fail 'C2 duplicated --permission-mode' "$OUT"
has_arg "$OUT" --effort=low || fail 'C2 --effort=low lost' "$OUT"
[[ "$(count_arg "$OUT" --effort)" == 0 ]] || fail 'C2 launcher effort appended over caller' "$OUT"
has_forced_thinking "$OUT" && fail 'C2 forced thinking despite caller effort' "$OUT"
[[ "$(value_after "$OUT" --model)" == 'opus[1m]' ]] || fail 'C2 keyword model default lost' "$OUT"
echo 'PASS: C2 keyword-looking option values are not captured'

# C3: the marker alone launches directly with no launcher model/effort.
OUT="$TEST_TEMP/c3"
run_claude "$OUT" --passthrough --output-format stream-json
[[ -s "$OUT" ]] || fail 'C3 --passthrough without a mode did not launch directly' "$OUT.err"
has_sequence "$OUT" --output-format stream-json || fail 'C3 passthrough lost' "$OUT"
[[ "$(count_arg "$OUT" --model)" == 0 ]] || fail 'C3 unexpected launcher --model' "$OUT"
[[ "$(count_arg "$OUT" --effort)" == 0 ]] || fail 'C3 unexpected launcher --effort' "$OUT"
echo 'PASS: C3 marker implies a direct launch without launcher defaults'

# C4: a keyword permission default yields to the caller.
OUT="$TEST_TEMP/c4"
run_claude "$OUT" bypass --passthrough --permission-mode=plan
has_arg "$OUT" --permission-mode=plan || fail 'C4 caller permission mode lost' "$OUT"
[[ "$(count_arg "$OUT" --permission-mode)" == 0 ]] || fail 'C4 keyword permission mode kept' "$OUT"
has_arg "$OUT" bypassPermissions && fail 'C4 bypass keyword overrode the caller' "$OUT"
echo 'PASS: C4 caller permission mode replaces the keyword default'

# C5: bare launcher keywords after the marker are ordinary arguments.
OUT="$TEST_TEMP/c5"
run_claude "$OUT" base --passthrough resume fast
has_sequence "$OUT" resume fast || fail 'C5 bare words after the marker were captured' "$OUT"
has_arg "$OUT" --resume && fail 'C5 resume became the launcher session flag' "$OUT"
[[ "$(value_after "$OUT" --model)" == sonnet ]] || fail 'C5 base default changed' "$OUT"
echo 'PASS: C5 bare keywords after the marker are forwarded verbatim'

# C6: launcher-owned flags precede passthrough tokens, so a caller `--`
# prompt boundary cannot turn them into prompt text.
OUT="$TEST_TEMP/c6"
run_claude "$OUT" base --passthrough --verbose -- 'prompt text'
argv=("${(@f)$(argv_of "$OUT")}")
[[ "${argv[-2]}" == -- && "${argv[-1]}" == 'prompt text' ]] \
  || fail 'C6 launcher flags were appended after the caller prompt boundary' "$OUT"
has_sequence "$OUT" --mcp-config "$MCP_FULL" || fail 'C6 harness MCP config missing' "$OUT"
echo 'PASS: C6 launcher flags stay ahead of the caller argv'

# C7: without the marker the legacy argv is unchanged.
OUT="$TEST_TEMP/c7"
run_claude "$OUT" base --verbose
# The launcher's one --settings (the launch-record hook) is the only addition.
[[ "$(count_arg "$OUT" --settings)" == 1 ]] || fail 'C7 expected exactly one launcher --settings' "$OUT"
[[ "$(argv_of "$OUT" | awk '$0=="--settings"{skip=2} skip>0{skip--; next} {print}' | tr '\n' ' ')" == "--model sonnet --verbose --effort high --exclude-dynamic-system-prompt-sections --mcp-config $MCP_FULL " ]] \
  || fail 'C7 legacy argv changed' "$OUT"
echo 'PASS: C7 legacy keyword argv is unchanged'

# C8: a plain prompt as the first caller token is not absorbed by the
# variadic harness --mcp-config; the boolean flag closes the launcher block.
OUT="$TEST_TEMP/c8"
run_claude "$OUT" base --passthrough 'prompt text'
has_sequence "$OUT" --mcp-config "$MCP_FULL" --exclude-dynamic-system-prompt-sections 'prompt text' \
  || fail 'C8 harness MCP value list is not closed before the caller prompt' "$OUT"
echo 'PASS: C8 caller prompt is not absorbed by the harness MCP option'

# C9: the same in light mode (legacy MCP surface policy).
LIGHT_HARNESS="$TEST_TEMP/light-harness"
mkdir -p "$LIGHT_HARNESS/config"
cat > "$LIGHT_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="light harness"
HARNESS_PREFIX="light"
HARNESS_MCP_SURFACE_POLICY=""
EOF
cp "$TEST_HARNESS/.mcp.json" "$LIGHT_HARNESS/.mcp.json"
OUT="$TEST_TEMP/c9"
: > "$OUT"
(
  export TEST_STUB_FILE="$OUT"
  export PATH="$TEST_BIN:$PATH"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _harness_launcher_run "$LIGHT_HARNESS" base light --passthrough 'prompt text'
) </dev/null >/dev/null 2>"$OUT.err"
has_sequence "$OUT" --strict-mcp-config --mcp-config "$LIGHT_HARNESS/.harness/claude/mcp-light.json" \
  || fail 'C9 light MCP prefix missing' "$OUT"
has_sequence "$OUT" --exclude-dynamic-system-prompt-sections 'prompt text' \
  || fail 'C9 light launcher block not closed before the caller prompt' "$OUT"
echo 'PASS: C9 light mode keeps the caller prompt last'

# C10: caller xhigh/max without its own thinking control still forces thinking.
OUT="$TEST_TEMP/c10"
run_claude "$OUT" base --passthrough --effort max
has_forced_thinking "$OUT" || fail 'C10 max effort lost forced thinking' "$OUT"
[[ "$(count_arg "$OUT" --effort)" == 1 ]] || fail 'C10 expected only the caller --effort' "$OUT"
OUT="$TEST_TEMP/c10b"
run_claude "$OUT" base --passthrough --effort=xhigh --thinking adaptive
has_forced_thinking "$OUT" && fail 'C10b forced thinking over caller --thinking' "$OUT"
echo 'PASS: C10 forced thinking follows the caller effort and thinking control'

# C11: a launcher session keyword plus a caller session flag is ambiguous.
OUT="$TEST_TEMP/c11"
rc=0
run_claude "$OUT" continue --passthrough --resume=0b5d1f3e-0000-4000-8000-000000000000 || rc=$?
[[ "$rc" == 2 ]] || fail "C11 expected exit 2, got $rc" "$OUT.err"
[[ ! -s "$OUT" ]] || fail 'C11 claude launched despite conflicting session flags' "$OUT"
grep -q 'passthrough' "$OUT.err" || fail 'C11 missing conflict explanation' "$OUT.err"
OUT="$TEST_TEMP/c11b"
run_claude "$OUT" base --passthrough --session-id=0b5d1f3e-0000-4000-8000-000000000000
has_arg "$OUT" --session-id=0b5d1f3e-0000-4000-8000-000000000000 || fail 'C11b caller session id lost' "$OUT"
echo 'PASS: C11 session keyword conflicts fail closed; caller session flags pass'

# C12: only the first marker is consumed.
OUT="$TEST_TEMP/c12"
run_claude "$OUT" base --passthrough --passthrough
[[ "$(count_arg "$OUT" --passthrough)" == 1 ]] || fail 'C12 second marker not forwarded' "$OUT"
echo 'PASS: C12 only the first marker is consumed'

# C13: a management subcommand after the marker (Paseo's `auth status`
# diagnostic) runs natively without launcher flags.
OUT="$TEST_TEMP/c13"
run_claude "$OUT" base --passthrough auth status || fail 'C13 management path failed' "$OUT.err"
[[ "$(argv_of "$OUT" | tr '\n' ' ')" == 'auth status ' ]] || fail 'C13 management argv' "$OUT"
echo 'PASS: C13 management subcommands after the marker run natively'

# C14: only an explicit caller thinking disable drops the launcher xhigh/max.
assert_thinking_disabled() {  # <caller args...>
  OUT="$TEST_TEMP/c14"
  run_claude "$OUT" rich --passthrough "$@"
  [[ "$(count_arg "$OUT" --effort)" == 0 ]] || fail "C14 '$*' kept launcher effort" "$OUT"
  has_forced_thinking "$OUT" && fail "C14 '$*' kept forced thinking" "$OUT"
  return 0
}
assert_thinking_disabled --thinking disabled
assert_thinking_disabled --thinking=disabled
assert_thinking_disabled --max-thinking-tokens 0
assert_thinking_disabled --max-thinking-tokens=0
assert_thinking_disabled --settings '{"alwaysThinkingEnabled":false}'
assert_thinking_disabled '--settings={"fastMode":true,"alwaysThinkingEnabled": false}'
for keep in '--settings {"fastMode":true}' '--thinking adaptive' '--max-thinking-tokens 1024'; do
  OUT="$TEST_TEMP/c14"
  run_claude "$OUT" rich --passthrough ${=keep}
  [[ "$(value_after "$OUT" --effort)" == xhigh ]] || fail "C14 '$keep' dropped launcher effort" "$OUT"
  has_forced_thinking "$OUT" || fail "C14 '$keep' lost forced thinking" "$OUT"
done
OUT="$TEST_TEMP/c14"
run_claude "$OUT" rich --passthrough --thinking disabled --effort high
[[ "$(count_arg "$OUT" --effort)" == 1 && "$(value_after "$OUT" --effort)" == high ]] \
  || fail 'C14 caller effort with thinking disabled' "$OUT"
has_forced_thinking "$OUT" && fail 'C14 forced thinking over a caller disable' "$OUT"
echo 'PASS: C14 only explicit thinking disables drop the launcher xhigh/max'

# C15: a launcher `--` ends keyword parsing and stays after launcher flags.
OUT="$TEST_TEMP/c15"
run_claude "$OUT" base -- continue
argv=("${(@f)$(argv_of "$OUT")}")
[[ "${argv[-2]}" == -- && "${argv[-1]}" == continue ]] || fail 'C15 -- continue is not last' "$OUT"
has_arg "$OUT" --continue && fail 'C15 continue after -- became a session flag' "$OUT"
[[ "$(value_after "$OUT" --effort)" == high ]] || fail 'C15 launcher effort lost' "$OUT"
echo 'PASS: C15 tokens after a launcher -- are prompt text after launcher flags'

# C16: `--` alone implies a direct launch.
OUT="$TEST_TEMP/c16"
run_claude "$OUT" -- 'prompt text'
[[ -s "$OUT" ]] || fail 'C16 -- prompt did not launch claude directly' "$OUT.err"
argv=("${(@f)$(argv_of "$OUT")}")
[[ "${argv[-2]}" == -- && "${argv[-1]}" == 'prompt text' ]] || fail 'C16 prompt is not last' "$OUT"
echo 'PASS: C16 -- implies a direct launch'

# C17: passthrough scans stop at a caller `--`.
OUT="$TEST_TEMP/c17"
run_claude "$OUT" base --passthrough -- --model x --effort max
[[ "$(argv_of "$OUT" | grep -Fx -A1 -- --model | sed -n 2p)" == sonnet ]] || fail 'C17 launcher model dropped' "$OUT"
[[ "$(value_after "$OUT" --effort)" == high ]] || fail 'C17 launcher effort dropped' "$OUT"
has_forced_thinking "$OUT" && fail 'C17 prompt text forced thinking' "$OUT"
argv=("${(@f)$(argv_of "$OUT")}")
[[ "${argv[-5]}" == -- && "${argv[-1]}" == max ]] || fail 'C17 caller prompt is not last' "$OUT"
echo 'PASS: C17 caller -- hides later tokens from passthrough scans'

echo 'PASS: launcher --passthrough contract'
