#!/usr/bin/env zsh
# test-aliases-register.sh — verifies harness_register defines prefix function
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
