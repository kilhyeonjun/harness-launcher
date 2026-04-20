#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() {
  [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"
TEST_BIN_PRIMARY="$TEST_TEMP/bin-primary"
TEST_BIN_SECONDARY="$TEST_TEMP/bin-secondary"
mkdir -p "$TEST_HARNESS/config" "$TEST_BIN_PRIMARY" "$TEST_BIN_SECONDARY"
cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF

TEST_BASE_PATH="$TEST_BIN_PRIMARY:$TEST_BIN_SECONDARY:/usr/bin:/bin:/usr/sbin:/sbin"

write_claude_stub() {
  cat > "$TEST_BIN_PRIMARY/claude" <<'EOF'
#!/usr/bin/env bash
{
  echo "EXEC:claude $*"
  echo "EFFORT:${CLAUDE_CODE_EFFORT_LEVEL:-}"
  echo "BASE_URL:${ANTHROPIC_BASE_URL:-}"
  echo "AUTH_TOKEN:${ANTHROPIC_AUTH_TOKEN:-}"
  echo "OPUS_MODEL:${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"
  echo "SONNET_MODEL:${ANTHROPIC_DEFAULT_SONNET_MODEL:-}"
  echo "HAIKU_MODEL:${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
} >> "$TEST_STUB_FILE"
exit 0
EOF
  chmod +x "$TEST_BIN_PRIMARY/claude"
}

write_node_stub() {
  cat > "$TEST_BIN_PRIMARY/node" <<'EOF'
#!/usr/bin/env bash
provider_url="${PROBE_PROVIDER_URL:-}"
case "$provider_url" in
  *"kiro.test"*) [[ "${TEST_KIRO_HEALTH:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *"codex.test"*) [[ "${TEST_CODEX_HEALTH:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEST_BIN_PRIMARY/node"
}

run_fallback() {
  local input="$1" out_file="$2" stub_file="$3"
  TEST_STUB_FILE="$stub_file" \
  PATH="$TEST_BASE_PATH" \
  HARNESS_DIR="$TEST_HARNESS" \
  HARNESS_NAME="test harness" \
  bash "$LAUNCHER_DIR/bin/launcher.sh" <<< "$input" > "$out_file" 2>&1
}

run_provider_fallback() {
  local input="$1" out_file="$2" stub_file="$3" kiro_health="$4" codex_health="$5"
  TEST_STUB_FILE="$stub_file" \
  TEST_KIRO_HEALTH="$kiro_health" \
  TEST_CODEX_HEALTH="$codex_health" \
  PATH="$TEST_BASE_PATH" \
  HARNESS_DIR="$TEST_HARNESS" \
  HARNESS_NAME="test harness" \
  bash "$LAUNCHER_DIR/bin/launcher.sh" <<< "$input" > "$out_file" 2>&1
}

assert_stub_file_exists() {
  local stub_file="$1" label="$2"
  if [[ ! -f "$stub_file" ]]; then
    echo "FAIL: $label — no stub output file"
    exit 1
  fi
}

write_claude_stub
write_node_stub
mkdir -p "$TEST_HARNESS/config/.local"
cat > "$TEST_HARNESS/config/.local/kiro-gateway.env" <<'EOF'
KIRO_GATEWAY_URL="https://kiro.test"
KIRO_GATEWAY_API_KEY="kiro-test-key"
EOF
cat > "$TEST_HARNESS/config/.local/codex-gateway.env" <<'EOF'
CODEX_GATEWAY_URL="https://codex.test"
CODEX_GATEWAY_API_KEY="codex-test-key"
CODEX_OPUS_MODEL="gpt-5.4-xhigh"
CODEX_SONNET_MODEL="gpt-4-sonnet"
CODEX_HAIKU_MODEL="gpt-4-haiku"
EOF

NO_HAPPY_OUT="$TEST_TEMP/no-happy.out"
NO_HAPPY_STUB="$TEST_TEMP/no-happy.stub"
run_fallback $'1\n2\n2\n' "$NO_HAPPY_OUT" "$NO_HAPPY_STUB"

assert_stub_file_exists "$NO_HAPPY_STUB" 'no happy fallback'
grep -q 'EXEC:claude --model sonnet' "$NO_HAPPY_STUB" || {
  echo 'FAIL: expected fallback path to launch claude when happy is absent'
  exit 1
}
if grep -q 'Use Happy mobile wrapper\?' "$NO_HAPPY_OUT"; then
  echo 'FAIL: Happy prompt should stay hidden when happy is absent'
  exit 1
fi

echo 'PASS: hides Happy prompt when happy is unavailable'

write_happy_stub() {
  cat > "$TEST_BIN_PRIMARY/happy" <<'EOF'
#!/usr/bin/env bash
{
  echo "EXEC:happy $*"
  echo "EFFORT:${CLAUDE_CODE_EFFORT_LEVEL:-}"
  echo "BASE_URL:${ANTHROPIC_BASE_URL:-}"
  echo "AUTH_TOKEN:${ANTHROPIC_AUTH_TOKEN:-}"
  echo "OPUS_MODEL:${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"
  echo "SONNET_MODEL:${ANTHROPIC_DEFAULT_SONNET_MODEL:-}"
  echo "HAIKU_MODEL:${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
} >> "$TEST_STUB_FILE"
exit 0
EOF
  chmod +x "$TEST_BIN_PRIMARY/happy"
}

write_happy_stub

HAPPY_NO_OUT="$TEST_TEMP/happy-no.out"
HAPPY_NO_STUB="$TEST_TEMP/happy-no.stub"
run_fallback $'1\n2\n2\n1\n' "$HAPPY_NO_OUT" "$HAPPY_NO_STUB"

assert_stub_file_exists "$HAPPY_NO_STUB" 'happy installed fallback no'
[[ "$(grep -c 'Use Happy mobile wrapper\?' "$HAPPY_NO_OUT")" -eq 1 ]] || {
  echo 'FAIL: expected Happy prompt once in fallback path when happy is installed'
  exit 1
}
grep -q 'EXEC:claude --model sonnet' "$HAPPY_NO_STUB" || {
  echo 'FAIL: choosing No should still launch claude'
  exit 1
}

echo 'PASS: fallback menu keeps claude when Happy is declined'

HAPPY_YES_OUT="$TEST_TEMP/happy-yes.out"
HAPPY_YES_STUB="$TEST_TEMP/happy-yes.stub"
run_fallback $'1\n2\n2\n2\n' "$HAPPY_YES_OUT" "$HAPPY_YES_STUB"

assert_stub_file_exists "$HAPPY_YES_STUB" 'happy installed fallback yes'
grep -q 'EXEC:happy --model sonnet' "$HAPPY_YES_STUB" || {
  echo 'FAIL: choosing Yes should launch happy instead of claude'
  exit 1
}
if grep -q 'EXEC:claude ' "$HAPPY_YES_STUB"; then
  echo 'FAIL: choosing Yes should not execute claude'
  exit 1
fi
if [[ "$(grep -c '^EXEC:' "$HAPPY_YES_STUB")" -ne 1 ]]; then
  echo 'FAIL: choosing Yes should execute exactly one launcher target'
  exit 1
fi

echo 'PASS: fallback menu launches happy when selected'

HAPPY_PERMISSION_YES_OUT="$TEST_TEMP/happy-permission-yes.out"
HAPPY_PERMISSION_YES_STUB="$TEST_TEMP/happy-permission-yes.stub"
run_fallback $'1\n2\n1\n3\n2\n2\n' "$HAPPY_PERMISSION_YES_OUT" "$HAPPY_PERMISSION_YES_STUB"

assert_stub_file_exists "$HAPPY_PERMISSION_YES_STUB" 'happy installed permission yes'
grep -q 'EXEC:happy --model sonnet --permission-mode dontAsk' "$HAPPY_PERMISSION_YES_STUB" || {
  echo 'FAIL: permission mode should be preserved when launching happy after Step 6'
  exit 1
}
if grep -q 'EXEC:claude ' "$HAPPY_PERMISSION_YES_STUB"; then
  echo 'FAIL: permission preservation path should not execute claude when Happy is selected'
  exit 1
fi
if [[ "$(grep -c '^EXEC:' "$HAPPY_PERMISSION_YES_STUB")" -ne 1 ]]; then
  echo 'FAIL: permission preservation path should execute exactly one launcher target'
  exit 1
fi

echo 'PASS: permission mode is preserved across Happy selection'

HAPPY_BACK_FROM_PERMISSION_OUT="$TEST_TEMP/happy-back-from-permission.out"
HAPPY_BACK_FROM_PERMISSION_STUB="$TEST_TEMP/happy-back-from-permission.stub"
run_fallback $'1\n2\n1\n2\n9\n4\n2\n' "$HAPPY_BACK_FROM_PERMISSION_OUT" "$HAPPY_BACK_FROM_PERMISSION_STUB"

assert_stub_file_exists "$HAPPY_BACK_FROM_PERMISSION_STUB" 'happy back from permission'
grep -q 'EXEC:happy --model sonnet --permission-mode bypassPermissions' "$HAPPY_BACK_FROM_PERMISSION_STUB" || {
  echo 'FAIL: canceling Happy after Step 6 should return to Permission mode and allow changing it'
  exit 1
}
if grep -q 'dontAsk' "$HAPPY_BACK_FROM_PERMISSION_STUB"; then
  echo 'FAIL: returning to Permission mode should replace the prior permission selection, not accumulate it'
  exit 1
fi

echo 'PASS: Happy cancel returns to Permission mode when entered from Step 6'

HAPPY_CONTINUE_YES_OUT="$TEST_TEMP/happy-continue-yes.out"
HAPPY_CONTINUE_YES_STUB="$TEST_TEMP/happy-continue-yes.stub"
run_fallback $'2\n2\n2\n2\n' "$HAPPY_CONTINUE_YES_OUT" "$HAPPY_CONTINUE_YES_STUB"

assert_stub_file_exists "$HAPPY_CONTINUE_YES_STUB" 'happy continue yes'
grep -q 'EXEC:happy --continue --model sonnet' "$HAPPY_CONTINUE_YES_STUB" || {
  echo 'FAIL: session flag should be preserved when Continue flows through Happy'
  exit 1
}

echo 'PASS: session flag is preserved across Happy selection'

KIRO_HAPPY_OUT="$TEST_TEMP/kiro-happy.out"
KIRO_HAPPY_STUB="$TEST_TEMP/kiro-happy.stub"
run_provider_fallback $'2\n1\n2\n2\n2\n' "$KIRO_HAPPY_OUT" "$KIRO_HAPPY_STUB" 1 0

assert_stub_file_exists "$KIRO_HAPPY_STUB" 'kiro happy path'
grep -q '^EXEC:happy' "$KIRO_HAPPY_STUB" || {
  echo 'FAIL: Kiro Happy path should execute happy'
  exit 1
}
if grep -q '^EXEC:claude' "$KIRO_HAPPY_STUB"; then
  echo 'FAIL: Kiro Happy path should not execute claude'
  exit 1
fi
if grep -q '^EXEC:happy .*--model ' "$KIRO_HAPPY_STUB"; then
  echo 'FAIL: Kiro base Happy path should preserve no-model behavior'
  exit 1
fi
grep -q '^BASE_URL:https://kiro.test$' "$KIRO_HAPPY_STUB" || {
  echo 'FAIL: Kiro Happy path should preserve gateway base URL'
  exit 1
}
grep -q '^AUTH_TOKEN:kiro-test-key$' "$KIRO_HAPPY_STUB" || {
  echo 'FAIL: Kiro Happy path should preserve gateway auth token'
  exit 1
}
grep -q '^EFFORT:high$' "$KIRO_HAPPY_STUB" || {
  echo 'FAIL: Kiro Happy path should preserve effort selection'
  exit 1
}

echo 'PASS: Kiro provider selection is preserved across Happy selection'

CODEX_HAPPY_OUT="$TEST_TEMP/codex-happy.out"
CODEX_HAPPY_STUB="$TEST_TEMP/codex-happy.stub"
run_provider_fallback $'2\n1\n4\n2\n2\n' "$CODEX_HAPPY_OUT" "$CODEX_HAPPY_STUB" 0 1

assert_stub_file_exists "$CODEX_HAPPY_STUB" 'codex happy path'
grep -q '^EXEC:happy --model opus\[1m\]$' "$CODEX_HAPPY_STUB" || {
  echo 'FAIL: Codex Happy path should preserve selected model'
  exit 1
}
grep -q '^EFFORT:max$' "$CODEX_HAPPY_STUB" || {
  echo 'FAIL: Codex Happy path should preserve effort selection'
  exit 1
}
grep -q '^BASE_URL:https://codex.test$' "$CODEX_HAPPY_STUB" || {
  echo 'FAIL: Codex Happy path should preserve gateway base URL'
  exit 1
}
grep -q '^AUTH_TOKEN:codex-test-key$' "$CODEX_HAPPY_STUB" || {
  echo 'FAIL: Codex Happy path should preserve gateway auth token'
  exit 1
}
grep -q '^OPUS_MODEL:gpt-5.4-xhigh$' "$CODEX_HAPPY_STUB" || {
  echo 'FAIL: Codex Happy path should preserve OPUS model env export'
  exit 1
}
grep -q '^SONNET_MODEL:gpt-4-sonnet$' "$CODEX_HAPPY_STUB" || {
  echo 'FAIL: Codex Happy path should preserve SONNET model env export'
  exit 1
}
grep -q '^HAIKU_MODEL:gpt-4-haiku$' "$CODEX_HAPPY_STUB" || {
  echo 'FAIL: Codex Happy path should preserve HAIKU model env export'
  exit 1
}

echo 'PASS: Codex provider selection is preserved across Happy selection'

write_gum_stub() {
  cat > "$TEST_BIN_PRIMARY/gum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GUM_LOG"
args="$*"
case "$args" in
  *"=== test harness ==="*)
    printf '1. New session\n'
    ;;
  *"Select mode"*"⚖️  Base — Sonnet, high effort"*)
    printf '2. ⚖️  Base — Sonnet, high effort\n'
    ;;
  *"Advanced options?"*"2. No (start now)"*)
    printf '2. No (start now)\n'
    ;;
  *"Use Happy mobile wrapper?"*"2. Yes"*)
    printf '2. Yes\n'
    ;;
  *)
    echo "UNEXPECTED_GUM:$args" >> "$TEST_GUM_LOG"
    exit 1
    ;;
esac
EOF
  chmod +x "$TEST_BIN_PRIMARY/gum"
}

run_gum() {
  local out_file="$1" stub_file="$2"
  if ! command -v script >/dev/null 2>&1; then
    echo 'FAIL: gum path test requires script command'
    exit 1
  fi
  script -q /dev/null bash -c "env TEST_STUB_FILE='$stub_file' TEST_GUM_LOG='$TEST_TEMP/gum.log' TEST_GUM_COUNT_FILE='$TEST_TEMP/gum-count' PATH='$TEST_BASE_PATH' HARNESS_DIR='$TEST_HARNESS' HARNESS_NAME='test harness' bash '$LAUNCHER_DIR/bin/launcher.sh'" > "$out_file" 2>&1
}

write_gum_stub
rm -f "$TEST_TEMP/gum.log" "$TEST_TEMP/gum-count"
GUM_OUT="$TEST_TEMP/gum.out"
GUM_STUB="$TEST_TEMP/gum.stub"
run_gum "$GUM_OUT" "$GUM_STUB"

assert_stub_file_exists "$GUM_STUB" 'gum path'
if [[ ! -f "$TEST_TEMP/gum.log" ]]; then
  echo 'FAIL: gum path — no gum log file'
  exit 1
fi
grep -q 'Use Happy mobile wrapper\?' "$TEST_TEMP/gum.log" || {
  echo 'FAIL: gum path should reach the Happy selection step'
  exit 1
}
grep -q 'EXEC:happy --model sonnet' "$GUM_STUB" || {
  echo 'FAIL: gum path should launch happy when the stub chooses Yes'
  exit 1
}
if grep -q 'EXEC:claude ' "$GUM_STUB"; then
  echo 'FAIL: gum path should not execute claude when Happy is selected'
  exit 1
fi
if [[ "$(grep -c '^EXEC:' "$GUM_STUB")" -ne 1 ]]; then
  echo 'FAIL: gum path should execute exactly one launcher target'
  exit 1
fi

echo 'PASS: gum path also routes through happy when selected'
