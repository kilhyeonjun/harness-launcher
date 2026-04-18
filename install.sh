#!/usr/bin/env bash
# harness-launcher standalone installer (brew-free path).
# Usage: curl -fsSL .../install.sh | sh, or run locally after git clone.
set -e

LAUNCHER_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARE_DIR="${HARNESS_LAUNCHER_PREFIX:-/usr/local}/share/harness-launcher"

mkdir -p "$SHARE_DIR/bin"
cp "$LAUNCHER_DIR/bin/aliases.zsh" "$SHARE_DIR/aliases.zsh"
cp "$LAUNCHER_DIR/bin/launcher.sh" "$SHARE_DIR/bin/launcher.sh"
chmod +x "$SHARE_DIR/bin/launcher.sh"

echo "Installed to $SHARE_DIR"
echo ""
echo "Add to ~/.zshrc:"
echo "  source \"$SHARE_DIR/aliases.zsh\""
echo "  harness_register <harness-dir>  # per harness"
