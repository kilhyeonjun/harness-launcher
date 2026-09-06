#!/usr/bin/env zsh
# test-launcher-codex-cli.sh — verify Codex CLI native launch (NOT the gateway).
#
# Asserts that `<prefix> codex <mode>`:
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
TEST_BROKEN_BIN="$TEST_TEMP/broken-bin"
mkdir -p "$TEST_HARNESS/config/.local" "$TEST_BIN" "$TEST_BROKEN_BIN"

source "$LAUNCHER_DIR/bin/harness-common.sh"
TEST_PYTHON_FIXTURE="$(harness_python3_resolve)" || exit $?
ln -s "$TEST_PYTHON_FIXTURE" "$TEST_BIN/harness-python"
cat > "$TEST_BROKEN_BIN/python3" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$TEST_BROKEN_BIN/python3"

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
  echo "MCP_PROFILE:${HARNESS_CODEX_MCP_PROFILE:-<UNSET>}"
  echo "HARNESS_PREFIX:${HARNESS_PREFIX:-<UNSET>}"
  echo "PWD:$PWD"
  echo "MCP_KEY:${HYPERDX_API_KEY:-<UNSET>}"
} >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$CODEX_STUB"

APP_CODEX_STUB="$TEST_BIN/codex-app"
cat > "$APP_CODEX_STUB" <<'EOF'
#!/usr/bin/env bash
echo "app codex stub should not be selected" >&2
exit 99
EOF
chmod +x "$APP_CODEX_STUB"

# Stub: happy — captures args + env to a file
HAPPY_STUB="$TEST_BIN/happy"
cat > "$HAPPY_STUB" <<'EOF'
#!/usr/bin/env bash
{
  echo "HAPPY_ARGV:$*"
  echo "HAPPY_CODEX_HOME:${CODEX_HOME:-}"
  echo "HAPPY_HARNESS_PREFIX:${HARNESS_PREFIX:-<UNSET>}"
} >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$HAPPY_STUB"

# Stub: codex-home-prepare.sh — records invocation, succeeds
PREPARE_STUB="$TEST_BIN/codex-home-prepare.sh"
cat > "$PREPARE_STUB" <<'EOF'
#!/usr/bin/env bash
echo "PREPARE_ARGV:$*" >> "$TEST_STUB_FILE"
echo "PREPARE_MCP_PROFILE:${HARNESS_CODEX_MCP_PROFILE:-<UNSET>}" >> "$TEST_STUB_FILE"
echo "PREPARE_GLOBAL_MCP_ALLOWLIST:${HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST:-<UNSET>}" >> "$TEST_STUB_FILE"
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
    export HARNESS_CODEX_BIN="$CODEX_STUB"
    unset HARNESS_CODEX_MCP_PROFILE
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    # Redirect prepare-script lookup to test bin
    _HARNESS_LAUNCHER_BIN="$TEST_BIN"
    _harness_launcher_run "$TEST_HARNESS" 'codex' "$@"
  ) 2>/dev/null || true
}

run_codex_failure() {
  local output_file="$1"; shift
  (
    export TEST_STUB_FILE="$TEST_TEMP/output-codex-cli-failure-stub.txt"
    export PATH="$TEST_BIN:$PATH"
    export HARNESS_CODEX_BIN="$CODEX_STUB"
    unset HARNESS_CODEX_MCP_PROFILE
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    _HARNESS_LAUNCHER_BIN="$TEST_BIN"
    _harness_launcher_run "$TEST_HARNESS" 'codex' "$@"
  ) >"$output_file" 2>&1
}

run_raw_codex() {
  local stub_file="$1"; shift
  (
    export TEST_STUB_FILE="$stub_file"
    export PATH="$TEST_BIN:/usr/bin:/bin"
    export HARNESS_CODEX_BIN="$CODEX_STUB"
    compdef() { :; }
    source "$LAUNCHER_DIR/bin/aliases.zsh"
    # Redirect prepare-script lookup to test bin
    _HARNESS_LAUNCHER_BIN="$TEST_BIN"
    harness_register "$TEST_HARNESS"
    codex "$@"
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

  local argv codex_home prepare_mcp_profile codex_mcp_profile harness_prefix
  argv="$(get_field ARGV "$stub_file")"
  codex_home="$(get_field CODEX_HOME "$stub_file")"
  prepare_mcp_profile="$(get_field PREPARE_MCP_PROFILE "$stub_file")"
  codex_mcp_profile="$(get_field MCP_PROFILE "$stub_file")"
  harness_prefix="$(get_field HARNESS_PREFIX "$stub_file")"

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
    *"--remote "*) echo "FAIL: codex CLI $mode — must not use local app-server --remote, got '$argv'"; return 1 ;;
  esac

  case "$argv" in
    *"-p $expected_profile"* | *"--profile $expected_profile"*) ;;
    *) echo "FAIL: codex CLI $mode — expected profile $expected_profile in argv, got '$argv'"; return 1 ;;
  esac

  if [[ "$prepare_mcp_profile" != "<UNSET>" || "$codex_mcp_profile" != "<UNSET>" ]]; then
    echo "FAIL: codex CLI $mode — must preserve the default MCP surface, got prepare='$prepare_mcp_profile' codex='$codex_mcp_profile'"
    return 1
  fi

  if [[ "$harness_prefix" != "test" ]]; then
    echo "FAIL: codex CLI $mode — expected exported HARNESS_PREFIX=test, got '$harness_prefix'"
    return 1
  fi

  echo "PASS: codex CLI $mode → direct TUI + -p $expected_profile + --cd $TEST_HARNESS + CODEX_HOME"
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
  case "$argv" in
    *"--remote "*) echo "FAIL: codex CLI session '$input_arg' — must not use local app-server --remote, got '$argv'"; return 1 ;;
  esac

  echo "PASS: codex CLI '$input_arg' → first-arg '$expected_subcmd'${expected_extra:+ + $expected_extra}"
  return 0
}

# Mode → profile mapping
run_mode "fast" "fast" || exit 1
run_mode "base" "base" || exit 1
run_mode "sol" "sol" || exit 1
run_mode "astra" "astra" || exit 1
run_mode "plan" "plan" || exit 1
run_mode "rich" "rich" || exit 1

# The new selector must not consume a prompt or an option value.
ASTRA_ARGS_STUB="$TEST_TEMP/astra-arguments.txt"
run_codex "$ASTRA_ARGS_STUB" exec astra
case "$(get_field ARGV "$ASTRA_ARGS_STUB")" in
  *'-p base exec astra'*) ;;
  *) echo 'FAIL: exec astra must preserve prompt text'; exit 1 ;;
esac
: > "$ASTRA_ARGS_STUB"
run_codex "$ASTRA_ARGS_STUB" astra --model gpt-5.6-sol -c 'model_reasoning_effort="high"'
case "$(get_field ARGV "$ASTRA_ARGS_STUB")" in
  *'-p astra --model gpt-5.6-sol -c model_reasoning_effort="high"'*) ;;
  *) echo 'FAIL: Astra must preserve native model and effort overrides'; exit 1 ;;
esac
echo 'PASS: Astra prompt and native override arguments'

# The dynamically scoped prefix is exported only for the native launch. It
# must not create a global parameter after the launcher function returns.
(
  export TEST_STUB_FILE="$TEST_TEMP/output-codex-cli-prefix-scope.txt"
  export PATH="$TEST_BIN:$PATH"
  export HARNESS_CODEX_BIN="$CODEX_STUB"
  unset HARNESS_PREFIX
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  _harness_launcher_run "$TEST_HARNESS" codex base
  if (( ${+HARNESS_PREFIX} )); then
    echo "FAIL: codex CLI prefix — HARNESS_PREFIX leaked after launcher return"
    exit 1
  fi
)
echo "PASS: native Codex prefix export remains dynamically scoped"

# `work` is an MCP surface selector, not a Codex model profile. It must select
# the base Codex profile while exporting the exact MCP profile before prepare.
STUB_WORK="$TEST_TEMP/output-codex-cli-work.txt"
: > "$STUB_WORK"
run_codex "$STUB_WORK" "work"
work_argv="$(get_field ARGV "$STUB_WORK")"
work_prepare_mcp_profile="$(get_field PREPARE_MCP_PROFILE "$STUB_WORK")"
work_mcp_profile="$(get_field MCP_PROFILE "$STUB_WORK")"
if ! grep -q "^PREPARE_ARGV:$TEST_HARNESS$" "$STUB_WORK"; then
  echo "FAIL: codex CLI work — codex-home-prepare.sh not called with harness dir"
  sed 's/^/    /' "$STUB_WORK"
  exit 1
fi
case "$work_argv" in
  *"-p base"* | *"--profile base"*) ;;
  *) echo "FAIL: codex CLI work — expected base Codex profile, got '$work_argv'"; exit 1 ;;
esac
if [[ "$work_prepare_mcp_profile" != "work" || "$work_mcp_profile" != "work" ]]; then
  echo "FAIL: codex CLI work — expected HARNESS_CODEX_MCP_PROFILE=work before prepare and Codex, got prepare='$work_prepare_mcp_profile' codex='$work_mcp_profile'"
  sed 's/^/    /' "$STUB_WORK"
  exit 1
fi
echo "PASS: codex CLI work → base profile + work MCP surface before prepare"

# `work` is a surface keyword until free-form args start. `codex exec work`
# keeps 'work' as prompt text because 'exec' lands in codex_args first — the
# launcher must not consume a raw Codex subcommand prompt.
STUB_EXEC_WORK="$TEST_TEMP/output-codex-cli-exec-work.txt"
: > "$STUB_EXEC_WORK"
run_codex "$STUB_EXEC_WORK" exec work
exec_work_argv="$(get_field ARGV "$STUB_EXEC_WORK")"
case "$exec_work_argv" in
  *"exec work"*) ;;
  *) echo "FAIL: codex exec work — prompt 'work' was not preserved, got '$exec_work_argv'"; exit 1 ;;
esac
if [[ "$(get_field MCP_PROFILE "$STUB_EXEC_WORK")" != "<UNSET>" ]]; then
  echo "FAIL: codex exec work — must not activate the work MCP surface"
  exit 1
fi
echo "PASS: codex exec work → prompt preserved without work MCP surface"

# Single-full projects retire the selector only in selector position. Compat
# removes it before prepare/exec; strict rejects before prepare; prompt text is
# preserved after a free-form token and inherited profile state never survives.
printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
  'HARNESS_MCP_SURFACE_POLICY="single-full-compat"' > "$TEST_HARNESS/config/launcher.env"
compat_work_stub="$TEST_TEMP/output-codex-cli-compat-work.txt"
: > "$compat_work_stub"
compat_work_err="$TEST_TEMP/output-codex-cli-compat-work.err"
(
  export TEST_STUB_FILE="$compat_work_stub"
  export PATH="$TEST_BIN:$PATH"
  export HARNESS_CODEX_BIN="$CODEX_STUB"
  unset HARNESS_CODEX_MCP_PROFILE
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  _harness_launcher_run "$TEST_HARNESS" codex work
) 2>"$compat_work_err" || exit 1
grep -Fq 'work MCP surface is deprecated for this project; using full' "$compat_work_err" || {
  echo "FAIL: compat codex work did not warn"; cat "$compat_work_err"; exit 1
}
if [[ "$(get_field PREPARE_MCP_PROFILE "$compat_work_stub")" != "<UNSET>" || "$(get_field MCP_PROFILE "$compat_work_stub")" != "<UNSET>" ]]; then
  echo "FAIL: compat codex work retained MCP profile"; cat "$compat_work_stub"; exit 1
fi
compat_work_argv="$(get_field ARGV "$compat_work_stub")"
case "$compat_work_argv" in *' work'*) echo "FAIL: compat codex selector leaked into argv"; exit 1;; esac
echo "PASS: compat codex work drops selector and MCP profile"

strict_work_out="$TEST_TEMP/output-codex-cli-strict-work.txt"
printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
  'HARNESS_MCP_SURFACE_POLICY="single-full"' > "$TEST_HARNESS/config/launcher.env"
: > "$TEST_TEMP/output-codex-cli-failure-stub.txt"
set +e
run_codex_failure "$strict_work_out" work
strict_work_rc=$?
set -e
[[ "$strict_work_rc" -ne 0 ]] || { echo "FAIL: strict codex work must fail"; exit 1; }
[[ "$strict_work_rc" -eq 2 ]] || { echo "FAIL: strict codex work must exit 2, got $strict_work_rc"; exit 1; }
grep -Fq 'work MCP surface is retired for this project' "$strict_work_out" || {
  echo "FAIL: strict codex work error missing"; cat "$strict_work_out"; exit 1
}
[[ ! -s "$TEST_TEMP/output-codex-cli-failure-stub.txt" ]] || {
  echo "FAIL: strict codex work prepared or launched"; exit 1
}
echo "PASS: strict codex work fails before prepare"

optin_inherited_stub="$TEST_TEMP/output-codex-cli-optin-inherited.txt"
(
  export TEST_STUB_FILE="$optin_inherited_stub"
  export PATH="$TEST_BIN:$PATH"
  export HARNESS_CODEX_BIN="$CODEX_STUB"
  export HARNESS_CODEX_MCP_PROFILE=work
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  _harness_launcher_run "$TEST_HARNESS" codex base
) 2>/dev/null || exit 1
[[ "$(get_field PREPARE_MCP_PROFILE "$optin_inherited_stub")" == "<UNSET>" && "$(get_field MCP_PROFILE "$optin_inherited_stub")" == "<UNSET>" ]] || {
  echo "FAIL: opt-in codex inherited MCP profile was not cleared"; cat "$optin_inherited_stub"; exit 1
}
echo "PASS: opt-in codex clears inherited MCP profile"

optin_exec_stub="$TEST_TEMP/output-codex-cli-optin-exec-work.txt"
: > "$optin_exec_stub"
run_codex "$optin_exec_stub" exec work
case "$(get_field ARGV "$optin_exec_stub")" in *'exec work'*) ;; *) echo "FAIL: opt-in codex exec lost prompt work"; exit 1;; esac
[[ "$(get_field MCP_PROFILE "$optin_exec_stub")" == "<UNSET>" ]] || { echo "FAIL: opt-in codex exec set MCP profile"; exit 1; }
echo "PASS: opt-in codex exec preserves prompt work"

printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
  'HARNESS_MCP_SURFACE_POLICY="single-full-compat"' > "$TEST_HARNESS/config/launcher.env"
compat_happy_stub="$TEST_TEMP/output-codex-cli-compat-happy-work.txt"
: > "$compat_happy_stub"
run_codex "$compat_happy_stub" happy work
grep -q '^HAPPY_ARGV:codex' "$compat_happy_stub" || { echo "FAIL: compat happy work was rejected"; cat "$compat_happy_stub"; exit 1; }
echo "PASS: compat happy work is not rejected by surface policy"

# Global MCP allowlist comes only from the trusted launcher config, is
# normalized before preparation, and cannot leak between consecutive native
# default/work/raw-exec launches in the same shell.
STUB_GLOBAL_SEQUENCE="$TEST_TEMP/output-codex-cli-global-sequence.txt"
: > "$STUB_GLOBAL_SEQUENCE"
(
  export TEST_STUB_FILE="$STUB_GLOBAL_SEQUENCE"
  export PATH="$TEST_BIN:$PATH"
  export HARNESS_CODEX_BIN="$CODEX_STUB"
  export HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="inherited-only"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"

  printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
    'HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST=" global-one, global-two,global-one "' \
    > "$TEST_HARNESS/config/launcher.env"
  _harness_launcher_run "$TEST_HARNESS" codex base

  printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
    > "$TEST_HARNESS/config/launcher.env"
  _harness_launcher_run "$TEST_HARNESS" codex work

  printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
    'HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST=""' \
    > "$TEST_HARNESS/config/launcher.env"
  _harness_launcher_run "$TEST_HARNESS" codex exec prompt
) 2>/dev/null || exit 1
global_prepare_values=("${(@f)$(sed -n 's/^PREPARE_GLOBAL_MCP_ALLOWLIST://p' "$STUB_GLOBAL_SEQUENCE")}")
[[ "${global_prepare_values[*]}" = "global-one,global-two <UNSET> <UNSET>" ]] || {
  echo "FAIL: native Codex allowlist leaked or was not normalized across consecutive launches"
  cat "$STUB_GLOBAL_SEQUENCE"
  exit 1
}
echo "PASS: native Codex shortcut default/work/raw exec isolate global MCP allowlist"

# work is a surface keyword combinable with any model profile (same UX as the
# claude `light` keyword) — both orders must select the profile AND the surface.
for combo_args in "work rich" "rich work" "work sol" "sol work"; do
  combo_stub="$TEST_TEMP/output-codex-cli-combo-${combo_args// /-}.txt"
  : > "$combo_stub"
  run_codex "$combo_stub" ${(z)combo_args}
  combo_argv="$(get_field ARGV "$combo_stub")"
  combo_profile="${combo_args/work/}"; combo_profile="${combo_profile// /}"
  case "$combo_argv" in
    *"-p $combo_profile"*) ;;
    *) echo "FAIL: codex CLI $combo_args — expected -p $combo_profile, got '$combo_argv'"; exit 1 ;;
  esac
  if [[ "$(get_field MCP_PROFILE "$combo_stub")" != "work" ]]; then
    echo "FAIL: codex CLI $combo_args — expected work MCP surface with the $combo_profile profile"
    exit 1
  fi
done
echo "PASS: codex CLI work combines with any model profile"

# Launcher keywords must not demote work to prompt text — only free-form args
# do. Both orders around safety/session keywords must select the surface.
for kw_combo in "full-auto work" "work full-auto" "continue work" "resume work" "never work"; do
  kw_stub="$TEST_TEMP/output-codex-cli-kw-${kw_combo// /-}.txt"
  : > "$kw_stub"
  run_codex "$kw_stub" ${(z)kw_combo}
  if [[ "$(get_field MCP_PROFILE "$kw_stub")" != "work" ]]; then
    echo "FAIL: codex CLI $kw_combo — work surface must survive launcher keywords (got '$(get_field MCP_PROFILE "$kw_stub")')"
    exit 1
  fi
  kw_argv="$(get_field ARGV "$kw_stub")"
  case "$kw_argv" in
    *" work"*|*"work "*) echo "FAIL: codex CLI $kw_combo — literal 'work' leaked into codex argv: $kw_argv"; exit 1 ;;
  esac
done
echo "PASS: codex CLI work survives safety/session keyword ordering"

# happy + work is the one impossible combination — must fail before prepare.
happy_work_out="$TEST_TEMP/output-codex-cli-happy-work.txt"
: > "$TEST_TEMP/output-codex-cli-failure-stub.txt"
if run_codex_failure "$happy_work_out" happy work; then
  echo "FAIL: codex CLI happy work — must fail"
  exit 1
fi
if [[ -s "$TEST_TEMP/output-codex-cli-failure-stub.txt" ]]; then
  echo "FAIL: codex CLI happy work — must fail before Codex starts"
  exit 1
fi
grep -q 'work MCP surface' "$happy_work_out" || {
  echo "FAIL: codex CLI happy work — expected clear error"; cat "$happy_work_out"; exit 1;
}
echo "PASS: codex CLI happy work fails closed"

# Session shortcuts
run_session "resume"   "resume"           ""        || exit 1
run_session "continue" "resume"           "--last"  || exit 1

# The profile command routes through THIS aliases.zsh path (not launcher.sh), so it
# must export MCP secrets from .claude/settings.local.json `env` — otherwise
# native codex sees e.g. HYPERDX_API_KEY unset and streamable_http bearer auth
# (bearer_token_env_var) cannot resolve. Earlier runs above had no
# settings.local.json, proving the export is a no-op when the file is absent.
mkdir -p "$TEST_HARNESS/.claude"
cat > "$TEST_HARNESS/.claude/settings.local.json" <<'EOF'
{ "env": { "HYPERDX_API_KEY": "secret-from-settings-xyz" } }
EOF
STUB_ENV="$TEST_TEMP/output-codex-cli-env.txt"
: > "$STUB_ENV"
run_codex "$STUB_ENV" "base"
mcp_key="$(get_field MCP_KEY "$STUB_ENV")"
if [[ "$mcp_key" != "secret-from-settings-xyz" ]]; then
  echo "FAIL: codex CLI env — settings.local.json env not exported to codex (got '$mcp_key')"
  sed 's/^/    /' "$STUB_ENV"
  exit 1
fi
echo "PASS: codex CLI base → settings.local.json env exported to codex"

printf '%s\n' \
  'HARNESS_NAME="test harness"' \
  'HARNESS_PREFIX="test"' \
  'HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST=" raw-one,raw-one "' \
  > "$TEST_HARNESS/config/launcher.env"
STUB_RAW="$TEST_TEMP/output-raw-codex-wrapper.txt"
: > "$STUB_RAW"
run_raw_codex "$STUB_RAW" --cd "$TEST_HARNESS" -p rich exec smoke
raw_argv="$(get_field ARGV "$STUB_RAW")"
raw_codex_home="$(get_field CODEX_HOME "$STUB_RAW")"
raw_mcp_key="$(get_field MCP_KEY "$STUB_RAW")"
raw_harness="${TEST_HARNESS:A}"
if ! grep -q "^PREPARE_ARGV:$raw_harness\$" "$STUB_RAW"; then
  echo "FAIL: raw codex wrapper — codex-home-prepare.sh not called for registered --cd harness"
  sed 's/^/    /' "$STUB_RAW"
  exit 1
fi
if [[ "$raw_codex_home" != "$raw_harness/.harness/codex" ]]; then
  echo "FAIL: raw codex wrapper — expected CODEX_HOME=$raw_harness/.harness/codex, got '$raw_codex_home'"
  sed 's/^/    /' "$STUB_RAW"
  exit 1
fi
case "$raw_argv" in
  *"--cd $TEST_HARNESS"*"-p rich"*"exec smoke"*) ;;
  *) echo "FAIL: raw codex wrapper — argv not preserved, got '$raw_argv'"; exit 1 ;;
esac
if [[ "$raw_mcp_key" != "secret-from-settings-xyz" ]]; then
  echo "FAIL: raw codex wrapper — settings.local.json env not exported (got '$raw_mcp_key')"
  sed 's/^/    /' "$STUB_RAW"
  exit 1
fi
if [[ "$(get_field PREPARE_GLOBAL_MCP_ALLOWLIST "$STUB_RAW")" != "raw-one" ]]; then
  echo "FAIL: raw codex wrapper — global MCP allowlist was not normalized before prepare"
  sed 's/^/    /' "$STUB_RAW"
  exit 1
fi
echo "PASS: raw codex --cd registered harness → prepare + CODEX_HOME + env export"

# The direct wrapper must also reset its dynamic launcher.env scope for every
# call. Keep one sourced shell to prove an inherited caller value and a prior
# configured value cannot reach later omitted or explicitly empty launches.
STUB_RAW_SEQUENCE="$TEST_TEMP/output-raw-codex-wrapper-sequence.txt"
: > "$STUB_RAW_SEQUENCE"
(
  export TEST_STUB_FILE="$STUB_RAW_SEQUENCE"
  export PATH="$TEST_BIN:/usr/bin:/bin"
  export HARNESS_CODEX_BIN="$CODEX_STUB"
  export HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="inherited-only"
  compdef() { :; }
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"

  printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
    'HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST=" direct-one, direct-two,direct-one "' \
    > "$TEST_HARNESS/config/launcher.env"
  codex --cd "$TEST_HARNESS" --version

  printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
    > "$TEST_HARNESS/config/launcher.env"
  codex --cd "$TEST_HARNESS" --version

  printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
    'HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST=""' \
    > "$TEST_HARNESS/config/launcher.env"
  codex --cd "$TEST_HARNESS" --version
) 2>/dev/null || exit 1
raw_prepare_values=("${(@f)$(sed -n 's/^PREPARE_GLOBAL_MCP_ALLOWLIST://p' "$STUB_RAW_SEQUENCE")}")
[[ "${raw_prepare_values[*]}" = "direct-one,direct-two <UNSET> <UNSET>" ]] || {
  echo "FAIL: direct codex wrapper global MCP allowlist leaked across launches"
  cat "$STUB_RAW_SEQUENCE"
  exit 1
}
echo "PASS: direct codex --cd wrapper isolates global MCP allowlist across launches"

# An opt-in raw launch may hide the inherited work surface from prepare/Codex,
# but it must not unset the caller's exported parameter. Keep both launches in
# one real Zsh process: the following legacy launch must still inherit `work`.
STUB_RAW_PROFILE_SCOPE="$TEST_TEMP/output-raw-codex-wrapper-profile-scope.txt"
: > "$STUB_RAW_PROFILE_SCOPE"
(
  export TEST_STUB_FILE="$STUB_RAW_PROFILE_SCOPE"
  export PATH="$TEST_BIN:/usr/bin:/bin"
  export HARNESS_CODEX_BIN="$CODEX_STUB"
  export HARNESS_CODEX_MCP_PROFILE=work
  compdef() { :; }
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"

  printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
    'HARNESS_MCP_SURFACE_POLICY="single-full"' \
    > "$TEST_HARNESS/config/launcher.env"
  codex --cd "$TEST_HARNESS" --version
  print -r -- "PARENT_MCP_PROFILE:${HARNESS_CODEX_MCP_PROFILE-<UNSET>}" >> "$STUB_RAW_PROFILE_SCOPE"
  print -r -- "PARENT_MCP_PROFILE_TYPE:${(t)HARNESS_CODEX_MCP_PROFILE}" >> "$STUB_RAW_PROFILE_SCOPE"

  printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
    > "$TEST_HARNESS/config/launcher.env"
  codex --cd "$TEST_HARNESS" --version
) 2>/dev/null || exit 1
raw_profile_prepare_values=("${(@f)$(sed -n 's/^PREPARE_MCP_PROFILE://p' "$STUB_RAW_PROFILE_SCOPE")}")
raw_profile_codex_values=("${(@f)$(sed -n 's/^MCP_PROFILE://p' "$STUB_RAW_PROFILE_SCOPE")}")
[[ "${raw_profile_prepare_values[*]}" = "<UNSET> work" && "${raw_profile_codex_values[*]}" = "<UNSET> work" ]] || {
  echo "FAIL: opt-in raw codex did not isolate the child profile before a legacy invocation"
  cat "$STUB_RAW_PROFILE_SCOPE"
  exit 1
}
grep -Fqx 'PARENT_MCP_PROFILE:work' "$STUB_RAW_PROFILE_SCOPE" || {
  echo "FAIL: opt-in raw codex changed the parent profile value"
  cat "$STUB_RAW_PROFILE_SCOPE"
  exit 1
}
grep -Fqx 'PARENT_MCP_PROFILE_TYPE:scalar-export' "$STUB_RAW_PROFILE_SCOPE" || {
  echo "FAIL: opt-in raw codex changed the parent profile export state"
  cat "$STUB_RAW_PROFILE_SCOPE"
  exit 1
}
echo "PASS: opt-in raw codex isolates child profile and preserves parent value/export for legacy reuse"

# The allowlist normalizer must use the shared Python resolver. With python3
# deliberately broken on PATH, both shortcut and direct wrapper launches still
# reach prepare through the explicit supported interpreter.
printf '%s\n' 'HARNESS_NAME="test harness"' 'HARNESS_PREFIX="test"' \
  'HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST=" fixture-one,fixture-one "' \
  > "$TEST_HARNESS/config/launcher.env"
STUB_PYTHON_FIXTURE="$TEST_TEMP/output-codex-python-fixture.txt"
: > "$STUB_PYTHON_FIXTURE"
(
  export TEST_STUB_FILE="$STUB_PYTHON_FIXTURE"
  export PATH="$TEST_BROKEN_BIN:$TEST_BIN:/usr/bin:/bin"
  export HARNESS_CODEX_BIN="$CODEX_STUB"
  export HARNESS_PYTHON_BIN="$TEST_BIN/harness-python"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  _harness_launcher_run "$TEST_HARNESS" codex base
  codex --cd "$TEST_HARNESS" --version
) 2>/dev/null || {
  echo "FAIL: configured allowlist did not use HARNESS_PYTHON_BIN"
  cat "$STUB_PYTHON_FIXTURE"
  exit 1
}
fixture_prepare_values=("${(@f)$(sed -n 's/^PREPARE_GLOBAL_MCP_ALLOWLIST://p' "$STUB_PYTHON_FIXTURE")}")
[[ "${fixture_prepare_values[*]}" = "fixture-one fixture-one" ]] || {
  echo "FAIL: alias/direct prepare did not receive normalized fixture allowlist"
  cat "$STUB_PYTHON_FIXTURE"
  exit 1
}

STUB_PYTHON_INVALID="$TEST_TEMP/output-codex-python-invalid.txt"
: > "$STUB_PYTHON_INVALID"
(
  export TEST_STUB_FILE="$STUB_PYTHON_INVALID"
  export PATH="$TEST_BROKEN_BIN:$TEST_BIN:/usr/bin:/bin"
  export HARNESS_CODEX_BIN="$CODEX_STUB"
  export HARNESS_PYTHON_BIN="$TEST_BIN/not-an-interpreter"
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_LAUNCHER_BIN="$TEST_BIN"
  if _harness_launcher_run "$TEST_HARNESS" codex base; then exit 1; fi
  if codex --cd "$TEST_HARNESS" --version; then exit 1; fi
  exit 0
) 2>/dev/null || { echo "FAIL: invalid HARNESS_PYTHON_BIN reached a native Codex launch"; exit 1; }
[[ ! -s "$STUB_PYTHON_INVALID" ]] || {
  echo "FAIL: invalid HARNESS_PYTHON_BIN reached prepare or Codex"
  cat "$STUB_PYTHON_INVALID"
  exit 1
}
echo "PASS: alias/direct global MCP normalization honors and validates HARNESS_PYTHON_BIN"

(
  export PATH="$TEST_BIN:/usr/bin:/bin"
  unset HARNESS_CODEX_BIN
  unset HARNESS_CODEX_ALLOW_APP_FALLBACK
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_CODEX_APP_BIN="$APP_CODEX_STUB"
  selected="$(_harness_launcher_codex_bin)"
  if [[ "$selected" != "$CODEX_STUB" ]]; then
    echo "FAIL: codex bin selection — expected PATH codex before app bundle, got '$selected'"
    exit 1
  fi
)
echo "PASS: codex bin selection → PATH codex preferred before app bundle"

(
  export PATH="/usr/bin:/bin"
  unset HARNESS_CODEX_BIN
  unset HARNESS_CODEX_ALLOW_APP_FALLBACK
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_CODEX_APP_BIN="$APP_CODEX_STUB"
  if selected="$(_harness_launcher_codex_bin)"; then
    echo "FAIL: codex bin selection — app bundle fallback should be opt-in, got '$selected'"
    exit 1
  fi
)
echo "PASS: codex bin selection → app bundle fallback disabled by default"

(
  export PATH="/usr/bin:/bin"
  unset HARNESS_CODEX_BIN
  export HARNESS_CODEX_ALLOW_APP_FALLBACK=1
  source "$LAUNCHER_DIR/bin/aliases.zsh"
  _HARNESS_CODEX_APP_BIN="$APP_CODEX_STUB"
  selected="$(_harness_launcher_codex_bin)"
  if [[ "$selected" != "$APP_CODEX_STUB" ]]; then
    echo "FAIL: codex bin selection — expected opt-in app bundle fallback, got '$selected'"
    exit 1
  fi
)
echo "PASS: codex bin selection → app bundle fallback works when explicitly enabled"

STUB_HAPPY="$TEST_TEMP/output-codex-cli-happy.txt"
: > "$STUB_HAPPY"
run_codex "$STUB_HAPPY" "happy"
happy_argv="$(get_field HAPPY_ARGV "$STUB_HAPPY")"
happy_codex_home="$(get_field HAPPY_CODEX_HOME "$STUB_HAPPY")"
happy_harness_prefix="$(get_field HAPPY_HARNESS_PREFIX "$STUB_HAPPY")"

[[ "$happy_argv" == "codex" ]] || {
  echo "FAIL: codex CLI happy — expected happy argv 'codex', got '$happy_argv'"; exit 1;
}
if [[ "$happy_codex_home" != "$TEST_HARNESS/.harness/codex" ]]; then
  echo "FAIL: codex CLI happy — expected CODEX_HOME=$TEST_HARNESS/.harness/codex, got '$happy_codex_home'"
  exit 1
fi
if [[ "$happy_harness_prefix" != "test" ]]; then
  echo "FAIL: codex CLI happy — expected exported HARNESS_PREFIX=test, got '$happy_harness_prefix'"
  exit 1
fi
echo "PASS: codex CLI happy → happy codex + CODEX_HOME"

STUB_HAPPY_RESUME="$TEST_TEMP/output-codex-cli-happy-resume.txt"
: > "$STUB_HAPPY_RESUME"
run_codex "$STUB_HAPPY_RESUME" "happy" "continue"
if grep -q "^HAPPY_ARGV:" "$STUB_HAPPY_RESUME"; then
  echo "FAIL: codex CLI happy continue — must not launch unsupported Happy Codex resume mapping"
  cat "$STUB_HAPPY_RESUME"
  exit 1
fi
echo "PASS: codex CLI happy continue blocked (Happy Codex cannot map codex resume --last)"

echo "✓ All codex CLI native tests passed"
