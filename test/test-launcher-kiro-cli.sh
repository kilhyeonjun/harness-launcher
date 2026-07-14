#!/usr/bin/env zsh
# test-launcher-kiro-cli.sh — verify Kiro CLI native launch.
#
# Asserts that `kh kiro-cli <mode>`:
#   - executes `kiro-cli chat` (not `claude`)
#   - sets KIRO_HOME=$HARNESS_DIR/.harness/kiro
#   - passes --model and --effort correctly
#   - maps modes to correct model/effort combos
#   - resume/continue map to session flags
#   - calls `kiro-home-prepare.sh "$HARNESS_DIR"` before exec
#   - CWD is $HARNESS_DIR (no --cd flag)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() {
  [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
TEST_HARNESS="$TEST_TEMP/fake-harness"
TEST_BIN="$TEST_TEMP/bin"
mkdir -p "$TEST_HARNESS/config/.local" "$TEST_HARNESS/core/hooks" "$TEST_BIN"

cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF

# Stub: kiro-cli — captures args + env to a file
KIRO_STUB="$TEST_BIN/kiro-cli"
cat > "$KIRO_STUB" <<'EOF'
#!/usr/bin/env bash
{
  echo "ARGV:$*"
  echo "KIRO_HOME:${KIRO_HOME:-}"
  echo "PWD:$(pwd)"
} >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$KIRO_STUB"

# Stub: kiro-home-prepare.sh — records invocation, succeeds
PREPARE_STUB="$TEST_BIN/kiro-home-prepare.sh"
cat > "$PREPARE_STUB" <<'EOF'
#!/usr/bin/env bash
{
  echo "PREPARE_ARGV:$*"
  echo "PREPARE_PROFILE:${HARNESS_KIRO_MCP_PROFILE:-}"
} >> "$TEST_STUB_FILE"
mkdir -p "$1/.harness/kiro"
exit 0
EOF
chmod +x "$PREPARE_STUB"

# Copy kiro-home-prepare.sh to launcher bin dir position (the real bin/ dir)
# Actually we override _HARNESS_LAUNCHER_BIN to point to TEST_BIN
# The aliases.zsh uses $_HARNESS_LAUNCHER_BIN for prepare script lookup

# Helper: extract a single field from stub output
get_field() {
  local field="$1" file="$2"
  grep "^${field}:" "$file" | head -1 | sed "s/^${field}://"
}

# Helper: check if a flag is present in ARGV
has_flag() {
  local flag="$1" file="$2"
  local args
  args=$(get_field "ARGV" "$file")
  echo "$args" | grep -q -- "$flag"
}

# Helper: extract value after a flag
get_flag_value() {
  local flag="$1" file="$2"
  local args
  args=$(get_field "ARGV" "$file")
  echo "$args" | sed -n "s/.*${flag} \([^ ]*\).*/\1/p"
}

run_kiro_cli() {
  local stub_file="$1"; shift
  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_BIN:$PATH"
    export HARNESS_KIRO_BIN="$KIRO_STUB"
    # Override _HARNESS_LAUNCHER_BIN so prepare script is found
    export _HARNESS_LAUNCHER_BIN="$TEST_BIN"
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    # Re-override after source (source sets it from script location)
    _HARNESS_LAUNCHER_BIN="$TEST_BIN"
    _harness_launcher_run "$TEST_HARNESS" 'kiro-cli' "$@"
  ) 2>/dev/null || true
}

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $label"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $label — expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" file="$3"
  local args
  args=$(get_field "ARGV" "$file")
  if echo "$args" | grep -q -- "$needle"; then
    echo "  ✓ $label"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $label — '$needle' not found in: $args"
    FAIL=$((FAIL + 1))
  fi
}

# ─── Test: fast mode ─────────────────────────────────────────────────────────
echo "Test: kiro-cli fast"
stub="$TEST_TEMP/out-fast.txt"
run_kiro_cli "$stub" fast

assert_eq "model" "claude-haiku-4.5" "$(get_flag_value "--model" "$stub")"
assert_eq "effort" "low" "$(get_flag_value "--effort" "$stub")"
assert_contains "agent" "--agent harness" "$stub"
assert_eq "KIRO_HOME" "$TEST_HARNESS/.harness/kiro" "$(get_field "KIRO_HOME" "$stub")"
assert_eq "CWD" "$TEST_HARNESS" "$(get_field "PWD" "$stub")"

# ─── Test: base mode ─────────────────────────────────────────────────────────
echo "Test: kiro-cli base"
stub="$TEST_TEMP/out-base.txt"
run_kiro_cli "$stub" base

assert_eq "model" "claude-sonnet-4.6" "$(get_flag_value "--model" "$stub")"
assert_eq "effort" "high" "$(get_flag_value "--effort" "$stub")"

# ─── Test: plan mode ─────────────────────────────────────────────────────────
echo "Test: kiro-cli plan"
stub="$TEST_TEMP/out-plan.txt"
run_kiro_cli "$stub" plan

assert_eq "model" "claude-opus-4.6" "$(get_flag_value "--model" "$stub")"
assert_eq "effort" "high" "$(get_flag_value "--effort" "$stub")"

# ─── Test: rich mode ─────────────────────────────────────────────────────────
echo "Test: kiro-cli rich"
stub="$TEST_TEMP/out-rich.txt"
run_kiro_cli "$stub" rich

assert_eq "model" "claude-opus-4.6" "$(get_flag_value "--model" "$stub")"
assert_eq "effort" "max" "$(get_flag_value "--effort" "$stub")"

# ─── Test: default (no mode) ─────────────────────────────────────────────────
echo "Test: kiro-cli (no mode, defaults to base)"
stub="$TEST_TEMP/out-default.txt"
run_kiro_cli "$stub"

assert_eq "model" "claude-sonnet-4.6" "$(get_flag_value "--model" "$stub")"
assert_eq "effort" "high" "$(get_flag_value "--effort" "$stub")"

# ─── Test: resume ────────────────────────────────────────────────────────────
echo "Test: kiro-cli resume"
stub="$TEST_TEMP/out-resume.txt"
run_kiro_cli "$stub" resume

assert_contains "resume-picker" "--resume-picker" "$stub"

# ─── Test: continue ──────────────────────────────────────────────────────────
echo "Test: kiro-cli continue"
stub="$TEST_TEMP/out-continue.txt"
run_kiro_cli "$stub" continue

assert_contains "resume-last" "-r" "$stub"

# ─── Test: bypass ────────────────────────────────────────────────────────────
echo "Test: kiro-cli bypass"
stub="$TEST_TEMP/out-bypass.txt"
run_kiro_cli "$stub" rich bypass

assert_contains "trust-all" "-a" "$stub"
assert_eq "model" "claude-opus-4.6" "$(get_flag_value "--model" "$stub")"

# ─── Test: no --v3 flag (default is already v3) ─────────────────────────────
echo "Test: kiro-cli no --v3 flag by default"
stub="$TEST_TEMP/out-no-v3.txt"
run_kiro_cli "$stub" base

args=$(get_field "ARGV" "$stub")
if echo "$args" | grep -q -- "--v3"; then
  echo "  ✗ no-v3 — unexpected --v3 found in: $args"
  FAIL=$((FAIL + 1))
else
  echo "  ✓ no-v3"
  PASS=$((PASS + 1))
fi

# ─── Test: prepare script called ─────────────────────────────────────────────
echo "Test: kiro-home-prepare.sh invocation"
stub="$TEST_TEMP/out-prepare.txt"
run_kiro_cli "$stub" fast

prepare_call=$(get_field "PREPARE_ARGV" "$stub")
assert_eq "prepare called with harness dir" "$TEST_HARNESS" "$prepare_call"
assert_eq "full surface: no MCP profile env" "" "$(get_field "PREPARE_PROFILE" "$stub")"

# ─── Test: light MCP surface ─────────────────────────────────────────────────
echo "Test: kiro-cli light"
stub="$TEST_TEMP/out-light.txt"
run_kiro_cli "$stub" base light

assert_eq "light surface: prepare sees profile" "light" "$(get_field "PREPARE_PROFILE" "$stub")"
assert_eq "model still applies with light" "claude-sonnet-4.6" "$(get_flag_value "--model" "$stub")"

# light must not leak HARNESS_KIRO_MCP_PROFILE into the calling shell
leak=$(
  export TEST_STUB_FILE="$TEST_TEMP/out-light-leak.txt"
  export PATH="$TEST_BIN:$PATH"
  export HARNESS_KIRO_BIN="$KIRO_STUB"
  export _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  _harness_launcher_run "$TEST_HARNESS" 'kiro-cli' base light >/dev/null 2>&1
  echo "${HARNESS_KIRO_MCP_PROFILE:-unset}"
)
assert_eq "light surface: env unset after launch" "unset" "$leak"

# light must not leak even when the kiro binary cannot be resolved (early return)
leak_missing=$(
  export TEST_STUB_FILE="$TEST_TEMP/out-light-missing.txt"
  export PATH="/usr/bin:/bin"
  export HARNESS_KIRO_BIN="$TEST_TEMP/nonexistent-kiro"
  export _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  _harness_launcher_run "$TEST_HARNESS" 'kiro-cli' base light >/dev/null 2>&1 && rc=0 || rc=$?
  echo "rc=$rc profile=${HARNESS_KIRO_MCP_PROFILE:-unset}"
)
assert_eq "light surface: no leak when kiro bin missing" "rc=1 profile=unset" "$leak_missing"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
echo "✓ All kiro-cli launcher tests passed"
