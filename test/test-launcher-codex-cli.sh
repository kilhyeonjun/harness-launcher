#!/usr/bin/env zsh
# test-launcher-codex-cli.sh — verify Codex CLI native launch (NOT the gateway).
#
# Asserts that `kh codex <mode>` (and gd/gp counterparts):
#   - executes `codex` (not `claude`)
#   - sets CODEX_HOME=$HARNESS_DIR/.harness/codex
#   - passes -C/--cd $HARNESS_DIR
#   - maps modes to `-p fast|base|plan|rich`
#   - resume/continue map to `codex resume` / `codex resume --last`
#   - calls `codex-home-prepare.sh "$HARNESS_DIR"` before exec

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
mkdir -p "$TEST_HARNESS/config/.local" "$TEST_BIN"

cat > "$TEST_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF

# Stub: codex — captures args + env to a file
CODEX_STUB="$TEST_BIN/codex"
cat > "$CODEX_STUB" <<'EOF'
#!/usr/bin/env bash
{
  echo "ARGV:$*"
  echo "CODEX_HOME:${CODEX_HOME:-}"
  echo "PWD:$PWD"
} >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$CODEX_STUB"

# Stub: codex-home-prepare.sh — records invocation, succeeds
PREPARE_STUB="$TEST_BIN/codex-home-prepare.sh"
cat > "$PREPARE_STUB" <<'EOF'
#!/usr/bin/env bash
echo "PREPARE_ARGV:$*" >> "$TEST_STUB_FILE"
mkdir -p "$1/.harness/codex"
exit 0
EOF
chmod +x "$PREPARE_STUB"

# Helper: extract a single field from stub output
get_field() {
  local field="$1" file="$2"
  grep "^${field}:" "$file" | head -1 | sed "s/^${field}://"
}

run_codex() {
  local stub_file="$1"; shift
  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_BIN:$PATH"
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    # Redirect prepare-script lookup to test bin
    _HARNESS_LAUNCHER_BIN="$TEST_BIN"
    _harness_launcher_run "$TEST_HARNESS" 'codex' "$@"
  ) 2>/dev/null || true
}

run_mode() {
  local mode="$1" expected_profile="$2"
  local stub_file="$TEST_TEMP/output-codex-cli-$mode.txt"
  : > "$stub_file"
  run_codex "$stub_file" "$mode"

  if [[ ! -s "$stub_file" ]]; then
    echo "FAIL: codex CLI $mode — codex stub never invoked"
    return 1
  fi

  local argv codex_home
  argv="$(get_field ARGV "$stub_file")"
  codex_home="$(get_field CODEX_HOME "$stub_file")"

  if ! grep -q "^PREPARE_ARGV:$TEST_HARNESS\$" "$stub_file"; then
    echo "FAIL: codex CLI $mode — codex-home-prepare.sh not called with harness dir"
    echo "  Stub log:"
    sed 's/^/    /' "$stub_file"
    return 1
  fi

  if [[ "$codex_home" != "$TEST_HARNESS/.harness/codex" ]]; then
    echo "FAIL: codex CLI $mode — expected CODEX_HOME=$TEST_HARNESS/.harness/codex, got '$codex_home'"
    return 1
  fi

  case "$argv" in
    *"--cd $TEST_HARNESS"* | *"-C $TEST_HARNESS"*) ;;
    *) echo "FAIL: codex CLI $mode — expected --cd $TEST_HARNESS in argv, got '$argv'"; return 1 ;;
  esac

  case "$argv" in
    *"-p $expected_profile"* | *"--profile $expected_profile"*) ;;
    *) echo "FAIL: codex CLI $mode — expected profile $expected_profile in argv, got '$argv'"; return 1 ;;
  esac

  echo "PASS: codex CLI $mode → -p $expected_profile + --cd $TEST_HARNESS + CODEX_HOME"
  return 0
}

run_session() {
  local input_arg="$1" expected_subcmd="$2" expected_extra="${3:-}"
  local stub_file="$TEST_TEMP/output-codex-cli-session-$input_arg.txt"
  : > "$stub_file"
  run_codex "$stub_file" "$input_arg"

  if [[ ! -s "$stub_file" ]]; then
    echo "FAIL: codex CLI session '$input_arg' — codex stub never invoked"
    return 1
  fi

  local argv
  argv="$(get_field ARGV "$stub_file")"

  case "$argv" in
    "$expected_subcmd "*) ;;
    "$expected_subcmd") ;;
    *) echo "FAIL: codex CLI session '$input_arg' — expected first arg '$expected_subcmd', got '$argv'"; return 1 ;;
  esac

  if [[ -n "$expected_extra" ]]; then
    case "$argv" in
      *"$expected_extra"*) ;;
      *) echo "FAIL: codex CLI session '$input_arg' — expected '$expected_extra' in argv, got '$argv'"; return 1 ;;
    esac
  fi

  echo "PASS: codex CLI '$input_arg' → first-arg '$expected_subcmd'${expected_extra:+ + $expected_extra}"
  return 0
}

# Mode → profile mapping
run_mode "fast" "fast" || exit 1
run_mode "base" "base" || exit 1
run_mode "plan" "plan" || exit 1
run_mode "rich" "rich" || exit 1

# Session shortcuts
run_session "resume"   "resume"           ""        || exit 1
run_session "continue" "resume"           "--last"  || exit 1

echo "✓ All codex CLI native tests passed"
