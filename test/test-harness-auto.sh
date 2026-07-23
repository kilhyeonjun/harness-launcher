#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PREFIX="$TMP/prefix"
HOME_DIR="$TMP/home"
BIN_DIR="$HOME_DIR/.local/bin"
PROFILE_HOME="$HOME_DIR/.config/harness-launcher"
ALPHA="$HOME_DIR/alpha harness"
GAMMA="$HOME_DIR/gamma harness"
ALPHA_WORKTREE="$ALPHA/.worktrees/project/task"
GAMMA_PROJECT="$GAMMA/projects/service"
LOG="$TMP/auto.log"

mkdir -p "$ALPHA/config" "$GAMMA/config" "$ALPHA_WORKTREE" "$GAMMA_PROJECT" "$BIN_DIR"
cat > "$ALPHA/config/launcher.env" <<'EOF'
HARNESS_NAME="alpha test"
HARNESS_PREFIX="alpha"
EOF
cat > "$GAMMA/config/launcher.env" <<'EOF'
HARNESS_NAME="gamma test"
HARNESS_PREFIX="gamma"
EOF

bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$PREFIX"
HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$ALPHA" >/dev/null
HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$GAMMA" >/dev/null

cat > "$PREFIX/share/harness-launcher/harness-exec" <<'EOF'
#!/usr/bin/env bash
{
  printf 'HARNESS:%s\n' "$1"
  printf 'PWD:%s\n' "$(pwd -P)"
  shift
  printf 'ARGV:'
  printf ' <%s>' "$@"
  printf '\n'
} > "$HARNESS_AUTO_TEST_LOG"
EOF
chmod 755 "$PREFIX/share/harness-launcher/harness-exec"

: > "$LOG"
(
  cd "$ALPHA_WORKTREE"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto" codex base
)
ALPHA_REAL="$(cd "$ALPHA" && pwd -P)"
ALPHA_WORKTREE_REAL="$(cd "$ALPHA_WORKTREE" && pwd -P)"
grep -Fqx "HARNESS:$ALPHA_REAL" "$LOG" || {
  echo "FAIL: harness-auto did not select alpha from the current worktree" >&2
  exit 1
}
grep -Fqx "PWD:$ALPHA_WORKTREE_REAL" "$LOG" || {
  echo "FAIL: harness-auto changed the current worktree" >&2
  exit 1
}
grep -Fqx 'ARGV: <codex> <base>' "$LOG" || {
  echo "FAIL: harness-auto changed launcher argument order" >&2
  exit 1
}

echo "PASS: harness-auto selects alpha from a nested worktree"

: > "$LOG"
(
  cd "$GAMMA_PROJECT"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto" kiro-cli base
)
GAMMA_REAL="$(cd "$GAMMA" && pwd -P)"
GAMMA_PROJECT_REAL="$(cd "$GAMMA_PROJECT" && pwd -P)"
grep -Fqx "HARNESS:$GAMMA_REAL" "$LOG" || {
  echo "FAIL: harness-auto did not select gamma from a source project" >&2
  exit 1
}
grep -Fqx "PWD:$GAMMA_PROJECT_REAL" "$LOG" || {
  echo "FAIL: harness-auto changed the source project directory" >&2
  exit 1
}
grep -Fqx 'ARGV: <kiro-cli> <base>' "$LOG" || {
  echo "FAIL: harness-auto changed Kiro argument order" >&2
  exit 1
}

echo "PASS: harness-auto selects gamma from a source project"

: > "$LOG"
(
  cd "$ALPHA_WORKTREE"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto" claude --resume session-123
)
grep -Fqx "HARNESS:$ALPHA_REAL" "$LOG" || {
  echo "FAIL: harness-auto did not select alpha for Claude" >&2
  exit 1
}
grep -Fqx 'ARGV: <--resume> <session-123>' "$LOG" || {
  echo "FAIL: harness-auto leaked its Claude selector into Claude argv" >&2
  exit 1
}

echo "PASS: harness-auto maps the Claude selector to the direct launcher path"

: > "$LOG"
if (
  cd "$TMP"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto" codex base
) >"$TMP/outside.out" 2>"$TMP/outside.err"; then
  echo "FAIL: harness-auto selected a profile outside all registered boundaries" >&2
  exit 1
fi
grep -Fq 'no registered harness contains the current directory' "$TMP/outside.err" || {
  echo "FAIL: harness-auto did not explain the unmatched workspace" >&2
  exit 1
}
[[ ! -s "$LOG" ]] || {
  echo "FAIL: harness-auto executed a profile for an unmatched workspace" >&2
  exit 1
}

echo "PASS: harness-auto fails closed outside registered boundaries"

ln -s "$TMP" "$ALPHA/.worktrees/escape"
if (
  cd "$ALPHA/.worktrees/escape"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto" codex base
) >"$TMP/escape.out" 2>"$TMP/escape.err"; then
  echo "FAIL: harness-auto followed a symlink outside the harness boundary" >&2
  exit 1
fi

echo "PASS: harness-auto rejects symlink escapes"

NESTED="$ALPHA/projects/nested-harness"
NESTED_WORKTREE="$NESTED/.worktrees/task"
mkdir -p "$NESTED/config" "$NESTED_WORKTREE"
cat > "$NESTED/config/launcher.env" <<'EOF'
HARNESS_NAME="nested test"
HARNESS_PREFIX="nested"
EOF
HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$NESTED" >/dev/null
: > "$LOG"
(
  cd "$NESTED_WORKTREE"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto" codex base
)
NESTED_REAL="$(cd "$NESTED" && pwd -P)"
grep -Fqx "HARNESS:$NESTED_REAL" "$LOG" || {
  echo "FAIL: harness-auto did not select the longest matching boundary" >&2
  exit 1
}

echo "PASS: harness-auto selects the most specific registered harness"

printf '%s\n' "$ALPHA_REAL" > "$PROFILE_HOME/profiles/alpha-duplicate"
chmod 600 "$PROFILE_HOME/profiles/alpha-duplicate"
if (
  cd "$ALPHA_WORKTREE"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto" codex base
) >"$TMP/ambiguous.out" 2>"$TMP/ambiguous.err"; then
  echo "FAIL: harness-auto accepted duplicate matching registrations" >&2
  exit 1
fi
grep -Fq 'ambiguous registered harness boundary' "$TMP/ambiguous.err" || {
  echo "FAIL: harness-auto did not explain ambiguous registrations" >&2
  exit 1
}
rm "$PROFILE_HOME/profiles/alpha-duplicate"

echo "PASS: harness-auto rejects ambiguous profile registrations"

UNTRUSTED="$HOME_DIR/untrusted-harness"
mkdir -p "$UNTRUSTED/config" "$UNTRUSTED/projects/app"
cat > "$UNTRUSTED/config/launcher.env" <<'EOF'
HARNESS_NAME="untrusted"
HARNESS_PREFIX="untrusted"
EOF
printf '%s\n' "$UNTRUSTED" > "$TMP/untrusted-profile"
ln -s "$TMP/untrusted-profile" "$PROFILE_HOME/profiles/untrusted"
if (
  cd "$UNTRUSTED/projects/app"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto" codex base
) >"$TMP/untrusted.out" 2>"$TMP/untrusted.err"; then
  echo "FAIL: harness-auto followed a symlinked registry entry" >&2
  exit 1
fi

echo "PASS: harness-auto ignores untrusted registry symlinks"

if (
  cd "$ALPHA_WORKTREE"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto"
) >"$TMP/no-args.out" 2>"$TMP/no-args.err"; then
  echo "FAIL: harness-auto accepted a missing agent command" >&2
  exit 1
fi
grep -Fq 'agent command is required' "$TMP/no-args.err" || {
  echo "FAIL: harness-auto did not explain the missing agent command" >&2
  exit 1
}

echo "PASS: harness-auto requires an explicit agent command"

if (
  cd "$ALPHA_WORKTREE"
  HOME="$HOME_DIR" HARNESS_AUTO_TEST_LOG="$LOG" \
    "$PREFIX/bin/harness-auto" unsupported-agent
) >"$TMP/unsupported.out" 2>"$TMP/unsupported.err"; then
  echo "FAIL: harness-auto accepted an unsupported agent selector" >&2
  exit 1
fi
grep -Fq 'unsupported agent: unsupported-agent' "$TMP/unsupported.err" || {
  echo "FAIL: harness-auto did not explain the unsupported agent" >&2
  exit 1
}

echo "PASS: harness-auto rejects unsupported agent selectors"
