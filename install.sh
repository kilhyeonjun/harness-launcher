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

for install_dir in "$SHARE_DIR" "$BIN_DIR"; do
  if [[ -L "$install_dir" ]]; then
    echo "ERROR: refusing symlinked install directory: $install_dir" >&2
    exit 1
  fi
  if [[ -e "$install_dir" && ! -d "$install_dir" ]]; then
    echo "ERROR: install destination is not a directory: $install_dir" >&2
    exit 1
  fi
done

SHARE_INSTALL_FILES=()
for file in "${SHARE_FILES[@]}"; do
  source="$LAUNCHER_DIR/bin/$file"
  destination="$SHARE_DIR/$file"
  if [[ -L "$destination" ]]; then
    echo "ERROR: refusing foreign share symlink: $destination" >&2
    exit 1
  fi
  if [[ -d "$destination" ]]; then
    echo "ERROR: executable destination is a directory: $destination" >&2
    exit 1
  fi
  if [[ -e "$destination" && ! -f "$destination" ]]; then
    echo "ERROR: refusing non-regular share file: $destination" >&2
    exit 1
  fi
  if [[ -e "$destination" ]]; then
    if ! cmp -s "$source" "$destination"; then
      echo "ERROR: refusing to replace existing share file: $destination" >&2
      echo "Move the existing installation aside or use Homebrew for managed upgrades." >&2
      exit 1
    fi
  else
    SHARE_INSTALL_FILES+=("$file")
  fi
done

BIN_INSTALL_FILES=()
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
  else
    BIN_INSTALL_FILES+=("$file")
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
  [[ "$share_dir_existed" == true ]] || rmdir "$SHARE_DIR" 2>/dev/null || true
  [[ "$bin_dir_existed" == true ]] || rmdir "$BIN_DIR" 2>/dev/null || true
  [[ "$prefix_existed" == true ]] || rmdir "$PREFIX" 2>/dev/null || true
}

move_new_file() {
  local source="$1"
  local destination="$2"
  mv -n "$source" "$destination"
  if [[ -e "$source" || -L "$source" ]]; then
    echo "ERROR: install destination appeared during commit: $destination" >&2
    return 1
  fi
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

mkdir -p "$TXN_DIR/share" "$TXN_DIR/bin"
for file in "${SHARE_INSTALL_FILES[@]}"; do
  cp "$LAUNCHER_DIR/bin/$file" "$TXN_DIR/share/$file"
done
for file in "${EXECUTABLE_FILES[@]}"; do
  if [[ -f "$TXN_DIR/share/$file" ]]; then chmod 755 "$TXN_DIR/share/$file"; fi
done
for file in "${BIN_INSTALL_FILES[@]}"; do
  ln -s "../share/harness-launcher/$file" "$TXN_DIR/bin/$file"
done

ROLLBACK_ACTIVE=true
mkdir -p "$SHARE_DIR" "$BIN_DIR"
for file in "${SHARE_INSTALL_FILES[@]}"; do
  move_new_file "$TXN_DIR/share/$file" "$SHARE_DIR/$file"
  INSTALLED_SHARE+=("$file")
done
for file in "${BIN_INSTALL_FILES[@]}"; do
  move_new_file "$TXN_DIR/bin/$file" "$BIN_DIR/$file"
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
