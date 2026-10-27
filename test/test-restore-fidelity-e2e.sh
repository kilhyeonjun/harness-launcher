#!/usr/bin/env zsh
# Registered canonical restores must refuse across the real shell -> harness-auto
# -> harness-exec chain. Model/effort restoration in admissible unregistered
# fixtures remains covered by test-restore-fidelity-{claude,codex}.sh.
set -eu
unset HARNESS_TERMINAL_RUNTIME TERM_PROGRAM HARNESS_HOST_DEFAULT_MODE; unset -m 'HERDR_*' 'ORCA_*' 'CMUX_*' || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PREFIX="$TMP/prefix"; HOME_DIR="$TMP/home"; PROFILE_BIN="$HOME_DIR/.local/bin"
HARNESS="$HOME_DIR/alpha"; PROJECT="$HARNESS/projects/app"; NATIVE_BIN="$TMP/native-bin"
STATE="$TMP/state"; LOG="$TMP/native.log"
mkdir -p "$HARNESS/config" "$PROJECT" "$PROFILE_BIN" "$NATIVE_BIN"
cat > "$HARNESS/config/launcher.env" <<'ENV'
HARNESS_NAME="alpha test"
HARNESS_PREFIX="alpha"
HARNESS_SESSION_ISOLATION_DEFAULT="0"
ENV
bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$PREFIX"
HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$PROFILE_BIN" "$PREFIX/bin/harness-profile" register "$HARNESS" >/dev/null
for runtime in claude codex; do
  cat > "$NATIVE_BIN/$runtime" <<'STUB'
#!/usr/bin/env bash
printf '%s:' "${0##*/}" >> "$HARNESS_TEST_LOG"
printf ' <%s>' "$@" >> "$HARNESS_TEST_LOG"
printf '\n' >> "$HARNESS_TEST_LOG"
STUB
  chmod 755 "$NATIVE_BIN/$runtime"
done
fail() { print -u2 -r -- "FAIL: $*"; exit 1; }
CLAUDE_ID=0b5d1f3e-0000-4000-8000-000000000001
CODEX_ID=01a0ef50-1bec-7852-afb3-a6b6559f47b6
export HOME="$HOME_DIR" PATH="$NATIVE_BIN:/usr/bin:/bin" HARNESS_TEST_LOG="$LOG" HARNESS_SESSION_STATE_HOME="$STATE"
export HARNESS_PROFILE_HOME="$HOME_DIR/.config/harness-launcher"
export HARNESS_CODEX_MCP_PROFILE="" _HARNESS_LAUNCHER_SHELL_AUTO_ENABLED=9
source "$PREFIX/share/harness-launcher/aliases.zsh"
harness_register "$HARNESS"
harness_shell_enable

assert_refusal() {
  local name="$1"; shift
  local rc=0
  : > "$LOG"
  (cd "$PROJECT"; "$@") >"$TMP/$name.out" 2>"$TMP/$name.err" || rc=$?
  [[ "$rc" == 2 ]] || fail "$name returned $rc instead of canonical refusal"
  local err="$(<"$TMP/$name.err")"
  [[ "$err" == *canonical_agent_refused* && "$err" == *'--isolated '* ]] || fail "$name omitted refusal reason or isolated alternative"
  [[ ! -s "$LOG" ]] || fail "$name reached a native runtime"
  [[ ! -e "$STATE" ]] || fail "$name allocated isolation state before refusing"
  print -r -- "PASS: $name refuses canonical restore before native dispatch"
}
# Noninteractive adapters still route through the real launcher boundary; the
# bound runtime policy, not the interactive-only interception, refuses them.
assert_refusal E1-shell-claude claude --resume "$CLAUDE_ID"
assert_refusal E2-shell-codex codex resume "$CODEX_ID"
assert_refusal E3-caller-model claude --resume "$CLAUDE_ID" --model haiku
assert_refusal E4-bound-prefix alpha --resume "$CLAUDE_ID"

# Even a profile defaulting to isolation cannot silently redirect a bare native
# restore from an interactive canonical cwd. Refusal precedes session creation.
HARNESS2="$HOME_DIR/beta"; PROJECT2="$HARNESS2/projects/app"
mkdir -p "$HARNESS2/config" "$PROJECT2"
cat > "$HARNESS2/config/launcher.env" <<'ENV'
HARNESS_NAME="beta test"
HARNESS_PREFIX="beta"
HARNESS_SESSION_ISOLATION_DEFAULT="1"
ENV
HARNESS_PROFILE_BIN_DIR="$PROFILE_BIN" "$PREFIX/bin/harness-profile" register "$HARNESS2" >/dev/null
cat > "$TMP/interactive.zsh" <<'INTERACTIVE'
source "$PREFIX/share/harness-launcher/aliases.zsh"
harness_register "$HARNESS2"
harness_shell_enable
cd "$PROJECT2"
codex resume "$CODEX_ID"
INTERACTIVE
export PREFIX HARNESS2 PROJECT2 CODEX_ID
: > "$LOG"
rc=0
/bin/zsh -fic 'source "$1"' _ "$TMP/interactive.zsh" >"$TMP/E5.out" 2>"$TMP/E5.err" || rc=$?
[[ "$rc" == 2 ]] || fail "E5 returned $rc instead of canonical refusal"
err="$(<"$TMP/E5.err")"
[[ "$err" == *canonical_agent_refused* && "$err" == *'--isolated '* ]] || fail 'E5 omitted refusal reason or isolated alternative'
[[ ! -s "$LOG" && ! -e "$STATE" ]] || fail 'E5 launched a native runtime or created a session'
print 'PASS: E5 interactive isolation-default canonical restore refuses without session allocation'
print 'PASS: canonical restore refusal end to end'
