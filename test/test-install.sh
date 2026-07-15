#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
PREFIX="$TEMP_DIR/prefix"

HARNESS_LAUNCHER_PREFIX="$PREFIX" "$ROOT/install.sh" >"$TEMP_DIR/install.log"
SHARE="$PREFIX/share/harness-launcher"

for file in \
  aliases.zsh \
  harness-common.sh \
  subagent-model-map.tsv \
  launcher.sh \
  codex-home-prepare.sh \
  codex-surface.py \
  codex-surface-warm.py \
  codex-hook-adapter.sh \
  codex-migrate-to-symlinks.sh \
  kiro-home-prepare.sh; do
  [[ -f "$SHARE/$file" ]] || {
    echo "FAIL: source installer did not install $file" >&2
    exit 1
  }
done

for file in \
  launcher.sh \
  codex-home-prepare.sh \
  codex-surface.py \
  codex-surface-warm.py \
  codex-hook-adapter.sh \
  codex-migrate-to-symlinks.sh \
  kiro-home-prepare.sh; do
  [[ -x "$SHARE/$file" ]] || {
    echo "FAIL: source installer did not mark $file executable" >&2
    exit 1
  }
done

grep -q "Installed to $SHARE" "$TEMP_DIR/install.log"

EXPLICIT_PREFIX="$TEMP_DIR/explicit-python-prefix"
GOOD_PYTHON=""
for candidate in \
  /opt/homebrew/opt/python@3.13/libexec/bin/python3 \
  /usr/local/opt/python@3.13/libexec/bin/python3 \
  /opt/homebrew/bin/python3 \
  /usr/local/bin/python3 \
  "$(command -v python3)"; do
  [[ -x "$candidate" ]] || continue
  if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    GOOD_PYTHON="$candidate"
    break
  fi
done
[[ -n "$GOOD_PYTHON" ]] || { echo "FAIL: test requires Python 3.11+" >&2; exit 1; }
PATH="/usr/bin:/bin" \
  HARNESS_PYTHON_BIN="$GOOD_PYTHON" \
  HARNESS_LAUNCHER_PREFIX="$EXPLICIT_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-explicit.log"
[[ -x "$EXPLICIT_PREFIX/share/harness-launcher/codex-surface-warm.py" ]] || {
  echo "FAIL: source installer ignored HARNESS_PYTHON_BIN" >&2
  exit 1
}

BAD_PYTHON="$TEMP_DIR/python-too-old"
printf '#!/bin/sh\nexit 1\n' > "$BAD_PYTHON"
chmod +x "$BAD_PYTHON"
BAD_PREFIX="$TEMP_DIR/bad-python-prefix"
if HARNESS_PYTHON_BIN="$BAD_PYTHON" \
  HARNESS_LAUNCHER_PREFIX="$BAD_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-bad.log" 2>&1; then
  echo "FAIL: source installer accepted Python below 3.11" >&2
  exit 1
fi
[[ ! -e "$BAD_PREFIX" ]] || {
  echo "FAIL: failed Python preflight left a partial installation" >&2
  exit 1
}
echo "PASS: source installer copies every runtime adapter"
