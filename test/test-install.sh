#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PREFIX="$TMP/prefix"
if HARNESS_LAUNCHER_PREFIX="$PREFIX" "$ROOT/install.sh" >"$TMP/install.log" 2>&1; then
  echo "FAIL: disabled source installer returned success" >&2
  exit 1
fi
grep -Fq 'standalone source installation is disabled' "$TMP/install.log" || {
  echo "FAIL: disabled source installer did not explain the Homebrew migration" >&2
  exit 1
}
[[ ! -e "$PREFIX" && ! -L "$PREFIX" ]] || {
  echo "FAIL: disabled source installer created a destination" >&2
  exit 1
}

OUTSIDE="$TMP/outside"
PREFIX_LINK="$TMP/prefix-link"
mkdir -p "$OUTSIDE"
ln -s "$OUTSIDE" "$PREFIX_LINK"
if HARNESS_LAUNCHER_PREFIX="$PREFIX_LINK" "$ROOT/install.sh" >"$TMP/symlink.log" 2>&1; then
  echo "FAIL: disabled source installer returned success for a symlinked prefix" >&2
  exit 1
fi
[[ ! -e "$OUTSIDE/share/harness-launcher/aliases.zsh" ]] || {
  echo "FAIL: disabled source installer wrote through a symlinked prefix" >&2
  exit 1
}

echo "PASS: standalone source installer is disabled and performs no writes"
