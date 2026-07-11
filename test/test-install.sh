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
  launcher.sh \
  codex-home-prepare.sh \
  codex-surface.py \
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
  codex-hook-adapter.sh \
  codex-migrate-to-symlinks.sh \
  kiro-home-prepare.sh; do
  [[ -x "$SHARE/$file" ]] || {
    echo "FAIL: source installer did not mark $file executable" >&2
    exit 1
  }
done

grep -q "Installed to $SHARE" "$TEMP_DIR/install.log"
echo "PASS: source installer copies every runtime adapter"
