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
  codex-cmux-title-sync.py \
  codex-migrate-to-symlinks.sh \
  kiro-home-prepare.sh \
  harness-exec \
  harness-profile \
  kiro-observability-hook.py; do
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
  codex-cmux-title-sync.py \
  codex-migrate-to-symlinks.sh \
  kiro-home-prepare.sh \
  harness-exec \
  harness-profile \
  kiro-observability-hook.py; do
  [[ -x "$SHARE/$file" ]] || {
    echo "FAIL: source installer did not mark $file executable" >&2
    exit 1
  }
done

[[ -L "$PREFIX/bin/harness-exec" && -x "$PREFIX/bin/harness-exec" ]] || {
  echo "FAIL: source installer did not expose harness-exec as an executable symlink" >&2
  exit 1
}
[[ "$(readlink "$PREFIX/bin/harness-exec")" == "../share/harness-launcher/harness-exec" ]] || {
  echo "FAIL: harness-exec symlink points at the wrong installed asset" >&2
  exit 1
}

[[ -L "$PREFIX/bin/harness-profile" && -x "$PREFIX/bin/harness-profile" ]] || {
  echo "FAIL: source installer did not expose harness-profile as an executable symlink" >&2
  exit 1
}
[[ "$(readlink "$PREFIX/bin/harness-profile")" == "../share/harness-launcher/harness-profile" ]] || {
  echo "FAIL: harness-profile symlink points at the wrong installed asset" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$PREFIX/share/harness-launcher/harness-profile")" == "755" ]] || {
  echo "FAIL: installed harness-profile is not world-readable and executable" >&2
  exit 1
}

grep -q "Installed to $SHARE" "$TEMP_DIR/install.log"

COLLISION_PREFIX="$TEMP_DIR/collision-prefix"
mkdir -p "$COLLISION_PREFIX/bin/harness-exec"
if HARNESS_LAUNCHER_PREFIX="$COLLISION_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-collision.log" 2>&1; then
  echo "FAIL: source installer accepted a directory at bin/harness-exec" >&2
  exit 1
fi
grep -Fq 'destination is a directory' "$TEMP_DIR/install-collision.log" || {
  echo "FAIL: directory collision did not produce a clear error" >&2
  exit 1
}
[[ -d "$COLLISION_PREFIX/bin/harness-exec" ]] || {
  echo "FAIL: installer altered the colliding directory" >&2
  exit 1
}

SHARE_COLLISION_PREFIX="$TEMP_DIR/share-collision-prefix"
mkdir -p "$SHARE_COLLISION_PREFIX/share/harness-launcher/harness-exec"
if HARNESS_LAUNCHER_PREFIX="$SHARE_COLLISION_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-share-collision.log" 2>&1; then
  echo "FAIL: source installer accepted a directory at share/harness-launcher/harness-exec" >&2
  exit 1
fi
grep -Fq 'destination is a directory' "$TEMP_DIR/install-share-collision.log" || {
  echo "FAIL: share directory collision did not produce a clear error" >&2
  exit 1
}
[[ -d "$SHARE_COLLISION_PREFIX/share/harness-launcher/harness-exec" ]] || {
  echo "FAIL: installer altered the colliding share directory" >&2
  exit 1
}

PROFILE_COLLISION_PREFIX="$TEMP_DIR/profile-collision-prefix"
mkdir -p "$PROFILE_COLLISION_PREFIX/bin/harness-profile"
if HARNESS_LAUNCHER_PREFIX="$PROFILE_COLLISION_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-profile-collision.log" 2>&1; then
  echo "FAIL: source installer accepted a directory at bin/harness-profile" >&2
  exit 1
fi
grep -Fq 'destination is a directory' "$TEMP_DIR/install-profile-collision.log" || {
  echo "FAIL: profile directory collision did not produce a clear error" >&2
  exit 1
}
[[ -d "$PROFILE_COLLISION_PREFIX/bin/harness-profile" ]] || {
  echo "FAIL: installer altered the colliding profile directory" >&2
  exit 1
}

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
