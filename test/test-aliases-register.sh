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
