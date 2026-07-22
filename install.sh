#!/usr/bin/env bash
# harness-launcher standalone installer (Homebrew-free path).
# Usage: clone the repository, then run:
#   HARNESS_LAUNCHER_PREFIX="$HOME/.local" ./install.sh
set -e

LAUNCHER_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${HARNESS_LAUNCHER_PREFIX:-/usr/local}"
SHARE_DIR="$PREFIX/share/harness-launcher"
BIN_DIR="$PREFIX/bin"

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

SHARE_FILES=(
  aliases.zsh
  harness-common.sh
  subagent-model-map.tsv
  launcher.sh
  codex-home-prepare.sh
  codex-surface.py
  codex-surface-warm.py
  codex-hook-adapter.sh
  codex-cmux-title-sync.py
  codex-migrate-to-symlinks.sh
  kiro-home-prepare.sh
  harness-auto
  harness-exec
  harness-profile
  kiro-observability-hook.py
)
EXECUTABLE_FILES=(
  launcher.sh
  codex-home-prepare.sh
  codex-surface.py
  codex-surface-warm.py
  codex-hook-adapter.sh
  codex-cmux-title-sync.py
  codex-migrate-to-symlinks.sh
  kiro-home-prepare.sh
  harness-auto
  harness-exec
  harness-profile
  kiro-observability-hook.py
)
BIN_FILES=(harness-auto harness-exec harness-profile)
MANAGED_MARKER=".harness-launcher-managed"

for managed_dir in "$SHARE_DIR" "$BIN_DIR"; do
  if [[ -L "$managed_dir" ]]; then
    echo "ERROR: refusing symlinked install directory: $managed_dir" >&2
    exit 1
  fi
  if [[ -e "$managed_dir" && ! -d "$managed_dir" ]]; then
    echo "ERROR: install destination is not a directory: $managed_dir" >&2
    exit 1
  fi
done

share_is_managed=false
if [[ -f "$SHARE_DIR/$MANAGED_MARKER" && ! -L "$SHARE_DIR/$MANAGED_MARKER" ]]; then
  share_is_managed=true
elif [[ -f "$SHARE_DIR/launcher.sh" && ! -L "$SHARE_DIR/launcher.sh" && \
        -f "$SHARE_DIR/aliases.zsh" && ! -L "$SHARE_DIR/aliases.zsh" ]]; then
  # Backward-compatible ownership proof for releases before the marker existed.
  share_is_managed=true
fi

for file in "${SHARE_FILES[@]}" "$MANAGED_MARKER"; do
  destination="$SHARE_DIR/$file"
  if [[ -L "$destination" ]]; then
    echo "ERROR: refusing foreign share symlink: $destination" >&2
    exit 1
  fi
  if [[ -d "$destination" ]]; then
    echo "ERROR: executable destination is a directory: $destination" >&2
    exit 1
  fi
  if [[ -e "$destination" && "$share_is_managed" != true ]]; then
    echo "ERROR: refusing foreign share file: $destination" >&2
    exit 1
  fi
done

for file in "${BIN_FILES[@]}"; do
  destination="$BIN_DIR/$file"
  expected="../share/harness-launcher/$file"
  if [[ -d "$destination" && ! -L "$destination" ]]; then
    echo "ERROR: executable destination is a directory: $destination" >&2
    exit 1
  fi
  if [[ -L "$destination" ]]; then
    if [[ "$(readlink "$destination")" != "$expected" ]]; then
      echo "ERROR: refusing foreign bin symlink: $destination" >&2
      exit 1
    fi
  elif [[ -e "$destination" ]]; then
    echo "ERROR: refusing foreign bin file: $destination" >&2
    exit 1
  fi
done

prefix_existed=false
share_dir_existed=false
bin_dir_existed=false
[[ -d "$PREFIX" ]] && prefix_existed=true
[[ -d "$SHARE_DIR" ]] && share_dir_existed=true
[[ -d "$BIN_DIR" ]] && bin_dir_existed=true
mkdir -p "$PREFIX"
TXN_DIR="$(mktemp -d "$PREFIX/.harness-launcher-install.XXXXXX")"
ROLLBACK_ACTIVE=false
INSTALLED_SHARE=()
INSTALLED_BIN=()

rollback_install() {
  local file
  set +e
  for file in "${INSTALLED_BIN[@]}"; do rm -f "$BIN_DIR/$file"; done
  for file in "${INSTALLED_SHARE[@]}"; do rm -f "$SHARE_DIR/$file"; done
  for file in "${SHARE_FILES[@]}" "$MANAGED_MARKER"; do
    [[ -e "$TXN_DIR/backup/share/$file" ]] && mv "$TXN_DIR/backup/share/$file" "$SHARE_DIR/$file"
  done
  for file in "${BIN_FILES[@]}"; do
    [[ -L "$TXN_DIR/backup/bin/$file" ]] && mv "$TXN_DIR/backup/bin/$file" "$BIN_DIR/$file"
  done
  [[ "$share_dir_existed" == true ]] || rmdir "$SHARE_DIR" 2>/dev/null || true
  [[ "$bin_dir_existed" == true ]] || rmdir "$BIN_DIR" 2>/dev/null || true
  [[ "$prefix_existed" == true ]] || rmdir "$PREFIX" 2>/dev/null || true
}

finish_install() {
  local status="$?"
  trap - EXIT
  if [[ "$ROLLBACK_ACTIVE" == true ]]; then rollback_install; fi
  rm -rf "$TXN_DIR"
  [[ "$prefix_existed" == true ]] || rmdir "$PREFIX" 2>/dev/null || true
  exit "$status"
}
trap finish_install EXIT
trap 'exit 130' HUP INT TERM

mkdir -p "$TXN_DIR/share" "$TXN_DIR/bin" "$TXN_DIR/backup/share" "$TXN_DIR/backup/bin"
for file in "${SHARE_FILES[@]}"; do
  cp "$LAUNCHER_DIR/bin/$file" "$TXN_DIR/share/$file"
done
printf 'harness-launcher\n' > "$TXN_DIR/share/$MANAGED_MARKER"
for file in "${EXECUTABLE_FILES[@]}"; do chmod 755 "$TXN_DIR/share/$file"; done
for file in "${BIN_FILES[@]}"; do
  ln -s "../share/harness-launcher/$file" "$TXN_DIR/bin/$file"
done

ROLLBACK_ACTIVE=true
mkdir -p "$SHARE_DIR" "$BIN_DIR"
for file in "${SHARE_FILES[@]}" "$MANAGED_MARKER"; do
  [[ -e "$SHARE_DIR/$file" ]] && mv "$SHARE_DIR/$file" "$TXN_DIR/backup/share/$file"
done
for file in "${BIN_FILES[@]}"; do
  [[ -L "$BIN_DIR/$file" ]] && mv "$BIN_DIR/$file" "$TXN_DIR/backup/bin/$file"
done
for file in "${SHARE_FILES[@]}" "$MANAGED_MARKER"; do
  mv "$TXN_DIR/share/$file" "$SHARE_DIR/$file"
  INSTALLED_SHARE+=("$file")
done
for file in "${BIN_FILES[@]}"; do
  mv "$TXN_DIR/bin/$file" "$BIN_DIR/$file"
  INSTALLED_BIN+=("$file")
done
ROLLBACK_ACTIVE=false

rm -rf "$TXN_DIR"
trap - EXIT HUP INT TERM

echo "Installed to $SHARE_DIR"
echo ""
echo "Add to ~/.zshrc:"
echo "  source \"$SHARE_DIR/aliases.zsh\""
echo "  harness_register <harness-dir>  # per harness"
