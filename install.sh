#!/usr/bin/env bash
# harness-launcher standalone installer (Homebrew-free path).
# Usage: clone the repository, then run:
#   HARNESS_LAUNCHER_PREFIX="$HOME/.local" ./install.sh
set -e

LAUNCHER_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARE_DIR="${HARNESS_LAUNCHER_PREFIX:-/usr/local}/share/harness-launcher"

select_harness_python3() {
  local candidate
  local -a candidates
  if [[ -n "${HARNESS_PYTHON_BIN:-}" ]]; then
    candidates=("$HARNESS_PYTHON_BIN")
  else
    candidates=(
      "/opt/homebrew/opt/python@3.13/libexec/bin/python3"
      "/usr/local/opt/python@3.13/libexec/bin/python3"
      "/opt/homebrew/bin/python3"
      "/usr/local/bin/python3"
      "$(command -v python3 2>/dev/null || true)"
    )
  fi
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  echo "ERROR: harness-launcher requires Python 3.11 or newer (set HARNESS_PYTHON_BIN)" >&2
  return 1
}

select_harness_python3 >/dev/null || exit 1

# All binaries live as siblings of aliases.zsh so that _HARNESS_LAUNCHER_BIN
# (set by aliases.zsh to its own dirname) resolves to launcher.sh and
# codex-home-prepare.sh without an extra subdir.
mkdir -p "$SHARE_DIR"
cp "$LAUNCHER_DIR/bin/aliases.zsh"                "$SHARE_DIR/aliases.zsh"
cp "$LAUNCHER_DIR/bin/launcher.sh"                "$SHARE_DIR/launcher.sh"
cp "$LAUNCHER_DIR/bin/codex-home-prepare.sh"      "$SHARE_DIR/codex-home-prepare.sh"
cp "$LAUNCHER_DIR/bin/codex-surface.py"           "$SHARE_DIR/codex-surface.py"
cp "$LAUNCHER_DIR/bin/codex-surface-warm.py"      "$SHARE_DIR/codex-surface-warm.py"
cp "$LAUNCHER_DIR/bin/codex-hook-adapter.sh"      "$SHARE_DIR/codex-hook-adapter.sh"
cp "$LAUNCHER_DIR/bin/codex-migrate-to-symlinks.sh" "$SHARE_DIR/codex-migrate-to-symlinks.sh"
cp "$LAUNCHER_DIR/bin/kiro-home-prepare.sh"       "$SHARE_DIR/kiro-home-prepare.sh"
chmod +x \
  "$SHARE_DIR/launcher.sh" \
  "$SHARE_DIR/codex-home-prepare.sh" \
  "$SHARE_DIR/codex-surface.py" \
  "$SHARE_DIR/codex-surface-warm.py" \
  "$SHARE_DIR/codex-hook-adapter.sh" \
  "$SHARE_DIR/codex-migrate-to-symlinks.sh" \
  "$SHARE_DIR/kiro-home-prepare.sh"

echo "Installed to $SHARE_DIR"
echo ""
echo "Add to ~/.zshrc:"
echo "  source \"$SHARE_DIR/aliases.zsh\""
echo "  harness_register <harness-dir>  # per harness"
