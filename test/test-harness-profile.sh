#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PREFIX="$TMP/prefix"
HOME_DIR="$TMP/home"
BIN_DIR="$HOME_DIR/.local/bin"
HARNESS="$HOME_DIR/test harness"
WORKTREE="$HARNESS/.worktrees/sample"
STUB_BIN="$TMP/stub-bin"
LOG="$TMP/profile.log"

mkdir -p "$HARNESS/config" "$WORKTREE" "$STUB_BIN" "$BIN_DIR"
cat > "$HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="th"
EOF

bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$PREFIX"

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
  printf 'ARGV:'
  printf ' <%s>' "$@"
  printf '\n'
} > "$HARNESS_PROFILE_TEST_LOG"
EOF
chmod +x "$STUB_BIN/codex"
cp "$STUB_BIN/codex" "$STUB_BIN/claude"

HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$HARNESS"

PROFILE_FILE="$HOME_DIR/.config/harness-launcher/profiles/th"
[[ -f "$PROFILE_FILE" ]] || { echo "FAIL: profile registry was not created" >&2; exit 1; }
[[ "$(cat "$PROFILE_FILE")" == "$(cd "$HARNESS" && pwd -P)" ]] || {
  echo "FAIL: profile registry does not contain the canonical harness path" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$HOME_DIR/.config/harness-launcher")" == "700" ]] || {
  echo "FAIL: profile registry home is not private" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$PROFILE_FILE")" == "600" ]] || {
  echo "FAIL: profile registry entry is not private" >&2
  exit 1
}
[[ -L "$BIN_DIR/th" && -x "$BIN_DIR/th" ]] || {
  echo "FAIL: profile command symlink was not installed" >&2
  exit 1
}
[[ "$(readlink "$BIN_DIR/th")" == "$PREFIX/bin/harness-profile" ]] || {
  echo "FAIL: profile command did not target the stable installed entrypoint" >&2
  exit 1
}

echo "PASS: harness-profile registers an executable profile command"

WORKTREE_REAL="$(cd "$WORKTREE" && pwd -P)"
HARNESS_REAL="$(cd "$HARNESS" && pwd -P)"
# Registered canonical roots and subdirectories may manage native tools, but
# agent execution must refuse even when the entrypoint defaults an outside cwd.
for caller in "$WORKTREE" "$TMP"; do
  for runtime in codex claude; do
    : > "$LOG"
    rc=0
    (
      cd "$caller"
      HOME="$HOME_DIR" PATH="$STUB_BIN:/usr/bin:/bin" \
        HARNESS_CODEX_BIN="$STUB_BIN/codex" HARNESS_PROFILE_TEST_LOG="$LOG" \
        "$BIN_DIR/th" "$runtime" base
    ) >"$TMP/canonical.out" 2>"$TMP/canonical.err" || rc=$?
    [[ "$rc" == 2 && ! -s "$LOG" ]] || {
      echo "FAIL: executable profile command did not refuse canonical $runtime before launch" >&2
      exit 1
    }
    grep -Fq canonical_agent_refused "$TMP/canonical.err"
    grep -Fq -- "--isolated $runtime" "$TMP/canonical.err"
  done
done
echo "PASS: executable profile commands refuse canonical agents with an isolated alternative"

(
  cd "$WORKTREE"
  HOME="$HOME_DIR" PATH="$STUB_BIN:/usr/bin:/bin" HARNESS_PROFILE_TEST_LOG="$LOG" \
    "$BIN_DIR/th" claude-management doctor
)
grep -Fqx "PWD:$WORKTREE_REAL" "$LOG" || {
  echo "FAIL: native management did not use the current workspace" >&2
  exit 1
}
grep -Fqx 'ARGV: <doctor>' "$LOG"
echo "PASS: executable profile management commands use the current workspace"

: > "$LOG"
(
  cd "$WORKTREE"
  HOME="$HOME_DIR" \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    HARNESS_PROFILE_TEST_LOG="$LOG" \
    "$BIN_DIR/th" --cwd "$HARNESS" claude-management doctor
)
grep -Fqx "PWD:$HARNESS_REAL" "$LOG" || {
  echo "FAIL: explicit --cwd did not override the inherited management workspace" >&2
  exit 1
}
grep -Fqx 'ARGV: <doctor>' "$LOG" || {
  echo "FAIL: explicit --cwd changed native management arguments through the profile command" >&2
  exit 1
}
if HOME="$HOME_DIR" "$BIN_DIR/th" --cwd "$TMP" codex base \
  >"$TMP/outside-cwd.out" 2>"$TMP/outside-cwd.err"; then
  echo "FAIL: profile command accepted an explicit cwd outside the harness" >&2
  exit 1
fi
grep -Fq -- '--cwd must stay inside the registered harness' "$TMP/outside-cwd.err"
ln -s "$TMP" "$HARNESS/.worktrees/escape"
if HOME="$HOME_DIR" "$BIN_DIR/th" --cwd "$HARNESS/.worktrees/escape" codex base \
  >"$TMP/symlink-cwd.out" 2>"$TMP/symlink-cwd.err"; then
  echo "FAIL: profile command accepted an explicit symlink escape" >&2
  exit 1
fi

grep -Fq -- '--cwd must stay inside the registered harness' "$TMP/symlink-cwd.err"
echo "PASS: profile commands preserve explicit --cwd precedence and boundary checks"

: > "$LOG"
(
  cd "$TMP"
  HOME="$HOME_DIR" \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    HARNESS_PROFILE_TEST_LOG="$LOG" \
    "$BIN_DIR/th" claude-management doctor
)
grep -Fqx "PWD:$HARNESS_REAL" "$LOG" || {
  echo "FAIL: profile management outside the boundary did not preserve the harness-root default" >&2
  sed 's/^/  /' "$LOG" >&2
  exit 1
}
grep -Fqx 'ARGV: <doctor>' "$LOG"

echo "PASS: executable profile management preserves the root default outside the harness"

COLLISION_HARNESS="$HOME_DIR/collision-harness"
mkdir -p "$COLLISION_HARNESS/config"
cat > "$COLLISION_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="collision"
HARNESS_PREFIX="blocked"
EOF
printf 'keep\n' > "$BIN_DIR/blocked"
if HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$COLLISION_HARNESS" \
  >"$TMP/collision.out" 2>"$TMP/collision.err"; then
  echo "FAIL: harness-profile overwrote an existing command" >&2
  exit 1
fi
grep -Fq 'command destination' "$TMP/collision.err"
[[ "$(cat "$BIN_DIR/blocked")" == "keep" ]] || {
  echo "FAIL: harness-profile altered a colliding command" >&2
  exit 1
}
[[ ! -e "$HOME_DIR/.config/harness-launcher/profiles/blocked" ]] || {
  echo "FAIL: failed registration left a profile entry" >&2
  exit 1
}

echo "PASS: harness-profile fails closed on command collisions"

FOREIGN_HARNESS="$HOME_DIR/foreign-harness"
mkdir -p "$FOREIGN_HARNESS/config"
cat > "$FOREIGN_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="foreign"
HARNESS_PREFIX="foreign"
EOF
ln -s "$TMP/foreign-target" "$BIN_DIR/foreign"
if HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$FOREIGN_HARNESS" \
  >"$TMP/foreign.out" 2>"$TMP/foreign.err"; then
  echo "FAIL: harness-profile replaced a foreign command symlink" >&2
  exit 1
fi
[[ "$(readlink "$BIN_DIR/foreign")" == "$TMP/foreign-target" ]] || {
  echo "FAIL: foreign command symlink was altered" >&2
  exit 1
}
[[ ! -e "$HOME_DIR/.config/harness-launcher/profiles/foreign" ]] || {
  echo "FAIL: foreign command collision left a profile entry" >&2
  exit 1
}

REBIND_HARNESS="$HOME_DIR/rebind-harness"
mkdir -p "$REBIND_HARNESS/config"
cat > "$REBIND_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="rebind"
HARNESS_PREFIX="th"
EOF
if HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$REBIND_HARNESS" \
  >"$TMP/rebind.out" 2>"$TMP/rebind.err"; then
  echo "FAIL: harness-profile silently rebound an existing profile" >&2
  exit 1
fi
[[ "$(cat "$PROFILE_FILE")" == "$HARNESS_REAL" ]] || {
  echo "FAIL: existing profile ownership changed after rejected rebind" >&2
  exit 1
}

REGISTRY_LINK_HARNESS="$HOME_DIR/registry-link-harness"
mkdir -p "$REGISTRY_LINK_HARNESS/config"
cat > "$REGISTRY_LINK_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="registry link"
HARNESS_PREFIX="registry_link"
EOF
ln -s "$TMP/foreign-registry" "$HOME_DIR/.config/harness-launcher/profiles/registry_link"
if HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$REGISTRY_LINK_HARNESS" \
  >"$TMP/registry-link.out" 2>"$TMP/registry-link.err"; then
  echo "FAIL: harness-profile replaced a foreign registry symlink" >&2
  exit 1
fi
[[ -L "$HOME_DIR/.config/harness-launcher/profiles/registry_link" ]] || {
  echo "FAIL: foreign registry symlink was altered" >&2
  exit 1
}

echo "PASS: harness-profile preserves command and registry ownership"

HYPHEN_HARNESS="$HOME_DIR/hyphen-harness"
mkdir -p "$HYPHEN_HARNESS/config"
cat > "$HYPHEN_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="hyphen"
HARNESS_PREFIX="hyphen-profile"
EOF
HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$HYPHEN_HARNESS" >/dev/null
[[ -L "$BIN_DIR/hyphen-profile" ]] || {
  echo "FAIL: harness-profile rejected a shell-safe hyphenated prefix" >&2
  exit 1
}

echo "PASS: harness-profile matches shell registration prefix rules"

ATOMIC_HARNESS="$HOME_DIR/atomic-harness"
READONLY_BIN="$HOME_DIR/readonly-bin"
mkdir -p "$ATOMIC_HARNESS/config" "$READONLY_BIN"
cat > "$ATOMIC_HARNESS/config/launcher.env" <<'EOF'
HARNESS_NAME="atomic"
HARNESS_PREFIX="atomic"
EOF
chmod 500 "$READONLY_BIN"
if HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$READONLY_BIN" \
  "$PREFIX/bin/harness-profile" register "$ATOMIC_HARNESS" \
  >"$TMP/atomic.out" 2>"$TMP/atomic.err"; then
  chmod 700 "$READONLY_BIN"
  echo "FAIL: harness-profile reported success after command installation failed" >&2
  exit 1
fi
chmod 700 "$READONLY_BIN"
[[ ! -e "$HOME_DIR/.config/harness-launcher/profiles/atomic" ]] || {
  echo "FAIL: failed command installation left a profile registry entry" >&2
  exit 1
}

echo "PASS: harness-profile rolls back failed command installation"
