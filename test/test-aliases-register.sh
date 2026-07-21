#!/usr/bin/env zsh
# test-aliases-register.sh — verifies harness_register defines prefix function
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Initialize completion system
autoload -Uz compinit && compinit -i

# Setup fake harness
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/fake-harness/config"
cat > "$TMP/fake-harness/config/launcher.env" <<'EOF'
HARNESS_NAME="fake harness"
HARNESS_PREFIX="fk"
EOF

# Source aliases and register
source "$LAUNCHER_DIR/bin/aliases.zsh"
harness_register "$TMP/fake-harness"

# Assert: fk function exists
if ! typeset -f fk >/dev/null; then
  echo "FAIL: fk function not defined after harness_register"
  exit 1
fi

# Assert: tab completion registered
if ! (( $+_comps[fk] )); then
  echo "FAIL: fk tab completion not registered"
  exit 1
fi

echo "PASS: harness_register defines fk function + completion"

# Test 2: harness_register overrides pre-existing alias
alias fk='false'  # simulate an existing alias shadowing the prefix
# re-run registration — must override the alias
harness_register "$TMP/fake-harness"
# Verify alias is gone
if alias fk >/dev/null 2>&1; then
  echo "FAIL: alias still present after harness_register"
  exit 1
fi
# Verify function still defined
if ! typeset -f fk >/dev/null; then
  echo "FAIL: fk function missing after alias override"
  exit 1
fi
echo "PASS: harness_register overrides pre-existing alias"

QUOTED_DIR="$TMP/project's harness"
mkdir -p "$QUOTED_DIR/config"
cat > "$QUOTED_DIR/config/launcher.env" <<'ENV'
HARNESS_NAME="Quoted harness"
HARNESS_PREFIX="fq"
ENV
harness_register "$QUOTED_DIR"
(( $+functions[fq] )) || { echo "FAIL: quoted harness path did not register" >&2; exit 1; }

echo "PASS: harness_register quotes legitimate harness paths"

INVALID_DIR="$TMP/invalid-prefix"
mkdir -p "$INVALID_DIR/config"
cat > "$INVALID_DIR/config/launcher.env" <<'ENV'
HARNESS_NAME="Invalid prefix"
HARNESS_PREFIX="bad prefix"
ENV
if harness_register "$INVALID_DIR" >"$TMP/invalid.out" 2>"$TMP/invalid.err"; then
  echo "FAIL: harness_register accepted an invalid function prefix" >&2
  exit 1
fi
grep -Fq 'invalid HARNESS_PREFIX' "$TMP/invalid.err" || {
  echo "FAIL: invalid prefix did not produce a clear error" >&2
  exit 1
}

echo "PASS: harness_register rejects unsafe function prefixes"

NO_EXEC="$TMP/no-exec"
mkdir -p "$NO_EXEC"
cp "$LAUNCHER_DIR/bin/aliases.zsh" "$NO_EXEC/aliases.zsh"
cp "$LAUNCHER_DIR/bin/harness-common.sh" "$NO_EXEC/harness-common.sh"
if zsh -c 'source "$1/aliases.zsh"; harness_register "$2"' zsh \
  "$NO_EXEC" "$TMP/fake-harness" >"$TMP/no-exec.out" 2>"$TMP/no-exec.err"; then
  echo "FAIL: harness_register accepted a missing canonical executable" >&2
  exit 1
fi
grep -Fq 'missing executable' "$TMP/no-exec.err" || {
  echo "FAIL: missing canonical executable did not fail clearly" >&2
  exit 1
}

echo "PASS: harness_register fails closed without harness-exec"
