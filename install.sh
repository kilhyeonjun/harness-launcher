#!/usr/bin/env bash
# harness-launcher standalone installer (brew-free path).
# Usage: curl -fsSL .../install.sh | sh, or run locally after git clone.
set -e

LAUNCHER_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARE_DIR="${HARNESS_LAUNCHER_PREFIX:-/usr/local}/share/harness-launcher"

# All binaries live as siblings of aliases.zsh so that _HARNESS_LAUNCHER_BIN
# (set by aliases.zsh to its own dirname) resolves to launcher.sh and
# codex-home-prepare.sh without an extra subdir.
mkdir -p "$SHARE_DIR"
cp "$LAUNCHER_DIR/bin/aliases.zsh"                "$SHARE_DIR/aliases.zsh"
cp "$LAUNCHER_DIR/bin/launcher.sh"                "$SHARE_DIR/launcher.sh"
cp "$LAUNCHER_DIR/bin/codex-home-prepare.sh"      "$SHARE_DIR/codex-home-prepare.sh"
cp "$LAUNCHER_DIR/bin/codex-migrate-to-symlinks.sh" "$SHARE_DIR/codex-migrate-to-symlinks.sh"
chmod +x "$SHARE_DIR/launcher.sh" "$SHARE_DIR/codex-home-prepare.sh" "$SHARE_DIR/codex-migrate-to-symlinks.sh"

echo "Installed to $SHARE_DIR"
echo ""
echo "Add to ~/.zshrc:"
echo "  source \"$SHARE_DIR/aliases.zsh\""
echo "  harness_register <harness-dir>  # per harness"
