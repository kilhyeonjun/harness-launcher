#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../bin/harness-common.sh
. "$ROOT/bin/harness-common.sh"

assert_eligible() {
  if ! harness_claude_bootstrap_eligible "$@"; then
    printf 'FAIL: expected eligible: %s\n' "$*" >&2
    exit 1
  fi
}

assert_ineligible() {
  if harness_claude_bootstrap_eligible "$@"; then
    printf 'FAIL: expected ineligible: %s\n' "$*" >&2
    exit 1
  fi
}

assert_eligible claude direct 1 --model sonnet
assert_ineligible happy direct 1 --model sonnet
assert_ineligible claude codex 1 --model sonnet
assert_ineligible claude direct 0 --model sonnet

HARNESS_CLAUDE_BOOTSTRAP_NAME=0 assert_ineligible claude direct 1 --model sonnet

for args in \
  '-c' '--continue' '-r abc' '-rabc' '--resume abc' '--resume=abc' \
  '--fork-session' '--from-pr 42' '-p hello' '-phello' '--print hello' \
  '--background' '--bg' '--cloud' '--cloud=task' '--remote-control' '--remote-control=session' '--teleport' '--teleport=abc' \
  'attach abc' 'respawn abc' '--bare' '--safe-mode' '--restricted' \
  '--setting-sources user' '--setting-sources=user' \
  '--session-id abc' '--session-id=abc' '-w branch' '-wbranch' \
  '--worktree branch' '--worktree=branch' '--tmux' '--tmux=name' \
  '--environment remote' '--environment=remote' \
  '-n title' '-ntitle' '--name title' '--name=title'
do
  # These fixtures contain no shell metacharacters; word splitting deliberately
  # models the finalized argv shapes accepted by Claude Code.
  # shellcheck disable=SC2086
  assert_ineligible claude direct 1 $args
done

IFS=$'\t' read -r launch_id bootstrap_title < <(harness_claude_bootstrap_values)
[[ "$launch_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || {
  echo "FAIL: invalid bootstrap launch id: $launch_id" >&2
  exit 1
}
[[ "$bootstrap_title" == "Harness startup" ]] || {
  echo "FAIL: unexpected bootstrap title: $bootstrap_title" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/harness/config" "$tmp/bin"
cat > "$tmp/harness/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF
cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'ID=%s\nTITLE=%s\n' "${HARNESS_CLAUDE_TITLE_BOOTSTRAP_ID:-}" "${HARNESS_CLAUDE_TITLE_BOOTSTRAP_VALUE:-}" > "$TEST_CAPTURE"
printf 'ARG=<%s>\n' "$@" >> "$TEST_CAPTURE"
EOF
chmod +x "$tmp/bin/claude"
ROOT="$ROOT" TEST_TMP="$tmp" TEST_CAPTURE="$tmp/capture" zsh -c '
  export PATH="$TEST_TMP/bin:$PATH" TEST_CAPTURE
  source "$ROOT/bin/aliases.zsh"
  harness_claude_bootstrap_eligible() { return 0; }
  _harness_launcher_run "$TEST_TMP/harness" base
  [[ -z "${HARNESS_CLAUDE_TITLE_BOOTSTRAP_ID:-}" ]]
  [[ -z "${HARNESS_CLAUDE_TITLE_BOOTSTRAP_VALUE:-}" ]]
'
grep -Eq '^ID=[0-9a-f-]{36}$' "$tmp/capture"
grep -Fxq 'TITLE=Harness startup' "$tmp/capture"
grep -Fxq 'ARG=<--name>' "$tmp/capture"
grep -Fxq 'ARG=<Harness startup>' "$tmp/capture"

mkdir -p "$tmp/home"
ROOT="$ROOT" TEST_TMP="$tmp" expect <<'EXPECT'
set timeout 10
log_user 0
spawn env -u HARNESS_RUN_DIR -u CMUX_WORKSPACE_ID -u CMUX_TAB_ID -u CMUX_SURFACE_ID HARNESS_DIR=$env(TEST_TMP)/harness HARNESS_NAME=test-harness HOME=$env(TEST_TMP)/home PATH=$env(TEST_TMP)/bin:/usr/bin:/bin TEST_CAPTURE=$env(TEST_TMP)/tui-capture bash $env(ROOT)/bin/launcher.sh
after 200
send "1\r"
after 200
send "2\r"
after 200
send "1\r"
expect eof
catch wait result
exit [lindex $result 3]
EXPECT
grep -Eq '^ID=[0-9a-f-]{36}$' "$tmp/tui-capture"
grep -Fxq 'TITLE=Harness startup' "$tmp/tui-capture"
grep -Fxq 'ARG=<--name>' "$tmp/tui-capture"
grep -Fxq 'ARG=<Harness startup>' "$tmp/tui-capture"

ROOT="$ROOT" TEST_TMP="$tmp" expect <<'EXPECT'
set timeout 5
log_user 0
spawn sh -c ". $env(ROOT)/bin/harness-common.sh; if harness_claude_stdio_is_tty; then echo tty; else echo redirected; fi >$env(TEST_TMP)/tty-result"
expect eof
catch wait result
exit [lindex $result 3]
EXPECT
grep -Fxq 'redirected' "$tmp/tty-result" || {
  echo 'FAIL: redirected stdout must not be classified interactive' >&2
  exit 1
}

echo 'claude-bootstrap-title: all tests passed'
