#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PREFIX="$TMP/prefix"
HARNESS="$TMP/test harness"
WORKTREE="$HARNESS/.worktrees/sample"
STUB_BIN="$TMP/stub-bin"
LOG="$TMP/exec.log"

mkdir -p "$HARNESS/config" "$WORKTREE" "$STUB_BIN"
HARNESS_REAL="$(cd "$HARNESS" && pwd -P)"
WORKTREE_REAL="$(cd "$WORKTREE" && pwd -P)"
cat > "$HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="th"
EOF

HARNESS_LAUNCHER_PREFIX="$PREFIX" "$ROOT/install.sh" >/dev/null

cat > "$PREFIX/share/harness-launcher/codex-home-prepare.sh" <<'EOF'
#!/usr/bin/env bash
set -e
mkdir -p "$1/.harness/codex"
EOF
chmod +x "$PREFIX/share/harness-launcher/codex-home-prepare.sh"

cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
{
  printf 'PWD:%s\n' "$PWD"
  printf 'CODEX_HOME:%s\n' "${CODEX_HOME:-}"
  printf 'ARGV:'
  printf ' <%s>' "$@"
  printf '\n'
} > "$HARNESS_EXEC_TEST_LOG"
EOF
chmod +x "$STUB_BIN/codex"

PATH="$STUB_BIN:/usr/bin:/bin" \
HARNESS_CODEX_BIN="$STUB_BIN/codex" \
HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$TMP/missing-marketplace" \
HARNESS_EXEC_TEST_LOG="$LOG" \
  "$PREFIX/bin/harness-exec" "$HARNESS" --cwd "$WORKTREE" codex base

assert_line() {
  local expected="$1"
  if ! grep -Fqx "$expected" "$LOG"; then
    echo "FAIL: missing log line: $expected" >&2
    sed 's/^/  /' "$LOG" >&2
    exit 1
  fi
}

assert_line "PWD:$WORKTREE_REAL"
assert_line "CODEX_HOME:$HARNESS_REAL/.harness/codex"
if ! grep -Fq "ARGV: <--cd> <$WORKTREE_REAL> <-p> <base>" "$LOG"; then
  echo "FAIL: explicit worktree was not forwarded to Codex" >&2
  sed 's/^/  /' "$LOG" >&2
  exit 1
fi

echo "PASS: harness-exec launches a profile-scoped Codex session in an explicit worktree"

: > "$LOG"
(
  cd "$WORKTREE"
  PATH="$STUB_BIN:/usr/bin:/bin" \
    HARNESS_CODEX_BIN="$STUB_BIN/codex" \
    HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$TMP/missing-marketplace" \
    HARNESS_EXEC_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-exec" "$HARNESS" codex base
)
assert_line "PWD:$WORKTREE_REAL"
if ! grep -Fq "ARGV: <--cd> <$WORKTREE_REAL> <-p> <base>" "$LOG"; then
  echo "FAIL: implicit workspace cwd was not forwarded to Codex" >&2
  sed 's/^/  /' "$LOG" >&2
  exit 1
fi

echo "PASS: harness-exec uses the current workspace when it is inside the harness boundary"

: > "$LOG"
PATH="$STUB_BIN:/usr/bin:/bin" \
  HARNESS_CODEX_BIN="$STUB_BIN/codex" \
  HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$TMP/missing-marketplace" \
  HARNESS_EXEC_TEST_LOG="$LOG" \
  WORKTREE="$WORKTREE" \
  HARNESS="$HARNESS" \
  zsh -c '
    source "'$PREFIX'/share/harness-launcher/aliases.zsh"
    harness_register "$HARNESS"
    cd "$WORKTREE"
    th codex base
  '
assert_line "PWD:$WORKTREE_REAL"
if ! grep -Fq "ARGV: <--cd> <$WORKTREE_REAL> <-p> <base>" "$LOG"; then
  echo "FAIL: registered profile command did not preserve the current workspace" >&2
  sed 's/^/  /' "$LOG" >&2
  exit 1
fi

echo "PASS: registered profile commands use the current workspace"

for session in resume fork; do
  : > "$LOG"
  PATH="$STUB_BIN:/usr/bin:/bin" \
    HARNESS_CODEX_BIN="$STUB_BIN/codex" \
    HARNESS_EXEC_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-exec" "$HARNESS" --cwd "$WORKTREE" codex "$session"
  assert_line "PWD:$WORKTREE_REAL"
  grep -Fq "ARGV: <$session> <--cd> <$WORKTREE_REAL> <-p> <base>" "$LOG" || {
    echo "FAIL: Codex $session did not preserve the explicit worktree" >&2
    sed 's/^/  /' "$LOG" >&2
    exit 1
  }
done

echo "PASS: Codex resume and fork preserve the explicit worktree"

if "$PREFIX/bin/harness-exec" "$HARNESS" --cwd >"$TMP/missing-cwd.out" 2>"$TMP/missing-cwd.err"; then
  echo "FAIL: harness-exec accepted --cwd without a directory" >&2
  exit 1
fi
grep -Fq -- '--cwd requires a directory' "$TMP/missing-cwd.err" || {
  echo "FAIL: missing --cwd value did not produce a clear error" >&2
  sed 's/^/  /' "$TMP/missing-cwd.err" >&2
  exit 1
}

echo "PASS: harness-exec rejects a missing --cwd value clearly"

INVALID_HARNESS="$TMP/not-a-harness"
mkdir -p "$INVALID_HARNESS"
if "$PREFIX/bin/harness-exec" "$INVALID_HARNESS" codex base >"$TMP/invalid.out" 2>"$TMP/invalid.err"; then
  echo "FAIL: harness-exec accepted a directory without config/launcher.env" >&2
  exit 1
fi
grep -Fq 'invalid harness directory' "$TMP/invalid.err"

echo "PASS: harness-exec requires a trusted launcher.env boundary"

OUTSIDE="$TMP/outside-worktree"
mkdir -p "$OUTSIDE"
: > "$LOG"
if PATH="$STUB_BIN:/usr/bin:/bin" \
  HARNESS_CODEX_BIN="$STUB_BIN/codex" \
  HARNESS_EXEC_TEST_LOG="$LOG" \
  "$PREFIX/bin/harness-exec" "$HARNESS" --cwd "$OUTSIDE" codex base \
  >"$TMP/outside.out" 2>"$TMP/outside.err"; then
  echo "FAIL: harness-exec accepted a cwd outside the registered harness" >&2
  exit 1
fi
[[ ! -s "$LOG" ]] || {
  echo "FAIL: outside cwd rejection launched Codex" >&2
  exit 1
}
grep -Fq -- '--cwd must stay inside the registered harness' "$TMP/outside.err"

echo "PASS: harness-exec rejects worktrees outside the profile boundary"

SYMLINK_ESCAPE="$HARNESS/.worktrees/escape"
ln -s "$OUTSIDE" "$SYMLINK_ESCAPE"
: > "$LOG"
if PATH="$STUB_BIN:/usr/bin:/bin" \
  HARNESS_CODEX_BIN="$STUB_BIN/codex" \
  HARNESS_EXEC_TEST_LOG="$LOG" \
  "$PREFIX/bin/harness-exec" "$HARNESS" --cwd "$SYMLINK_ESCAPE" codex base \
  >"$TMP/symlink.out" 2>"$TMP/symlink.err"; then
  echo "FAIL: harness-exec accepted a symlink escape" >&2
  exit 1
fi
[[ ! -s "$LOG" ]] || {
  echo "FAIL: symlink escape launched Codex" >&2
  exit 1
}
grep -Fq -- '--cwd must stay inside the registered harness' "$TMP/symlink.err"

echo "PASS: harness-exec rejects symlink escapes from the profile boundary"

CLAUDE_LOG="$TMP/claude.log"
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"
cat > "$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
{
  printf 'PWD:%s\n' "$PWD"
  printf 'ARGV:'
  printf ' <%s>' "$@"
  printf '\n'
} > "$HARNESS_EXEC_CLAUDE_LOG"
EOF
chmod +x "$STUB_BIN/claude"
PATH="$STUB_BIN:/usr/bin:/bin" \
HOME="$FAKE_HOME" \
HARNESS_EXEC_CLAUDE_LOG="$CLAUDE_LOG" \
  "$PREFIX/bin/harness-exec" "$HARNESS" --cwd "$WORKTREE" base

if ! grep -Fqx "PWD:$WORKTREE_REAL" "$CLAUDE_LOG"; then
  echo "FAIL: Claude did not start in the explicit worktree" >&2
  sed 's/^/  /' "$CLAUDE_LOG" >&2
  exit 1
fi

echo "PASS: harness-exec launches Claude in the explicit worktree"

PROFILE_HOME="$TMP/profile-home"
PROFILE_BIN="$TMP/profile-bin"
HARNESS_PROFILE_HOME="$PROFILE_HOME" HARNESS_PROFILE_BIN_DIR="$PROFILE_BIN" \
  "$PREFIX/bin/harness-profile" register "$HARNESS" >/dev/null
: > "$CLAUDE_LOG"
(
  cd "$WORKTREE"
  PATH="$STUB_BIN:/usr/bin:/bin" \
  HOME="$FAKE_HOME" \
  HARNESS_PROFILE_HOME="$PROFILE_HOME" \
  HARNESS_EXEC_CLAUDE_LOG="$CLAUDE_LOG" \
    "$PREFIX/bin/harness-auto" claude base resume acceptEdits 'orca prompt'
)
if ! grep -Fqx "PWD:$WORKTREE_REAL" "$CLAUDE_LOG"; then
  echo "FAIL: harness-auto did not launch Claude in the selected worktree" >&2
  sed 's/^/  /' "$CLAUDE_LOG" >&2
  exit 1
fi
grep -Fq 'ARGV: <--resume>' "$CLAUDE_LOG" || {
  echo "FAIL: harness-auto did not preserve the Claude resume selector" >&2
  sed 's/^/  /' "$CLAUDE_LOG" >&2
  exit 1
}
grep -Fq '<--permission-mode> <acceptEdits>' "$CLAUDE_LOG" || {
  echo "FAIL: harness-auto did not preserve the Claude permission selector" >&2
  sed 's/^/  /' "$CLAUDE_LOG" >&2
  exit 1
}
grep -Fq '<orca prompt>' "$CLAUDE_LOG" || {
  echo "FAIL: harness-auto did not preserve the Claude prompt" >&2
  sed 's/^/  /' "$CLAUDE_LOG" >&2
  exit 1
}

echo "PASS: harness-auto launches Claude through the real shared policy path"

KIRO_LOG="$TMP/kiro.log"
cat > "$PREFIX/share/harness-launcher/kiro-home-prepare.sh" <<'EOF'
#!/usr/bin/env bash
set -e
mkdir -p "$1/.harness/kiro"
EOF
chmod +x "$PREFIX/share/harness-launcher/kiro-home-prepare.sh"
cat > "$STUB_BIN/kiro-cli" <<'EOF'
#!/usr/bin/env bash
{
  printf 'PWD:%s\n' "$PWD"
  printf 'KIRO_HOME:%s\n' "${KIRO_HOME:-}"
  printf 'ARGV:'
  printf ' <%s>' "$@"
  printf '\n'
} > "$HARNESS_EXEC_KIRO_LOG"
EOF
chmod +x "$STUB_BIN/kiro-cli"
PATH="$STUB_BIN:/usr/bin:/bin" \
HOME="$FAKE_HOME" \
HARNESS_KIRO_BIN="$STUB_BIN/kiro-cli" \
HARNESS_EXEC_KIRO_LOG="$KIRO_LOG" \
  "$PREFIX/bin/harness-exec" "$HARNESS" --cwd "$WORKTREE" kiro-cli base

if ! grep -Fqx "PWD:$WORKTREE_REAL" "$KIRO_LOG"; then
  echo "FAIL: Kiro did not start in the explicit worktree" >&2
  sed 's/^/  /' "$KIRO_LOG" >&2
  exit 1
fi
grep -Fqx "KIRO_HOME:$HARNESS_REAL/.harness/kiro" "$KIRO_LOG"

echo "PASS: harness-exec launches Kiro in the explicit worktree"

TUI_LOG="$TMP/tui.log"
cat > "$PREFIX/share/harness-launcher/launcher.sh" <<'EOF'
#!/usr/bin/env bash
{
  printf 'HARNESS_DIR:%s\n' "${HARNESS_DIR:-}"
  printf 'HARNESS_RUN_DIR:%s\n' "${HARNESS_RUN_DIR:-}"
} > "$HARNESS_EXEC_TUI_LOG"
EOF
chmod +x "$PREFIX/share/harness-launcher/launcher.sh"
HOME="$FAKE_HOME" HARNESS_EXEC_TUI_LOG="$TUI_LOG" \
  "$PREFIX/bin/harness-exec" "$HARNESS" --cwd "$WORKTREE"

if ! grep -Fqx "HARNESS_RUN_DIR:$WORKTREE_REAL" "$TUI_LOG"; then
  echo "FAIL: launchpad did not receive the explicit worktree" >&2
  sed 's/^/  /' "$TUI_LOG" >&2
  exit 1
fi

echo "PASS: harness-exec forwards the explicit worktree to the launchpad"
