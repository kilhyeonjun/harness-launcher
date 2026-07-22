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
  harness-auto \
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
  harness-auto \
  harness-exec \
  harness-profile \
  kiro-observability-hook.py; do
  [[ -x "$SHARE/$file" ]] || {
    echo "FAIL: source installer did not mark $file executable" >&2
    exit 1
  }
done

[[ -L "$PREFIX/bin/harness-auto" && -x "$PREFIX/bin/harness-auto" ]] || {
  echo "FAIL: source installer did not expose harness-auto as an executable symlink" >&2
  exit 1
}
[[ "$(readlink "$PREFIX/bin/harness-auto")" == "../share/harness-launcher/harness-auto" ]] || {
  echo "FAIL: harness-auto symlink points at the wrong installed asset" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$PREFIX/share/harness-launcher/harness-auto")" == "755" ]] || {
  echo "FAIL: installed harness-auto is not world-readable and executable" >&2
  exit 1
}

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

REINSTALL_IDENTITY="$(stat -f '%i:%Lp' "$SHARE/harness-auto")"
printf 'legacy-marker-must-be-ignored\n' > "$SHARE/.harness-launcher-managed"
HARNESS_LAUNCHER_PREFIX="$PREFIX" "$ROOT/install.sh" >"$TEMP_DIR/reinstall.log"
cmp -s "$ROOT/bin/harness-auto" "$SHARE/harness-auto" || {
  echo "FAIL: source installer changed an identical existing asset" >&2
  exit 1
}
[[ "$(stat -f '%i:%Lp' "$SHARE/harness-auto")" == "$REINSTALL_IDENTITY" ]] || {
  echo "FAIL: source installer replaced an identical existing asset" >&2
  exit 1
}
[[ "$(<"$SHARE/.harness-launcher-managed")" == "legacy-marker-must-be-ignored" ]] || {
  echo "FAIL: source installer trusted or changed a legacy marker" >&2
  exit 1
}

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

FOREIGN_BIN_PREFIX="$TEMP_DIR/foreign-bin-prefix"
mkdir -p "$FOREIGN_BIN_PREFIX/bin"
printf 'KEEP-REGULAR\n' > "$FOREIGN_BIN_PREFIX/bin/harness-auto"
chmod 600 "$FOREIGN_BIN_PREFIX/bin/harness-auto"
if HARNESS_LAUNCHER_PREFIX="$FOREIGN_BIN_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-foreign-bin.log" 2>&1; then
  echo "FAIL: source installer replaced a foreign bin file" >&2
  exit 1
fi
[[ "$(<"$FOREIGN_BIN_PREFIX/bin/harness-auto")" == "KEEP-REGULAR" ]] || {
  echo "FAIL: installer changed a foreign bin file" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$FOREIGN_BIN_PREFIX/bin/harness-auto")" == "600" ]] || {
  echo "FAIL: installer changed a foreign bin file mode" >&2
  exit 1
}

FOREIGN_LINK_PREFIX="$TEMP_DIR/foreign-link-prefix"
mkdir -p "$FOREIGN_LINK_PREFIX/bin"
printf 'KEEP-LINK-TARGET\n' > "$FOREIGN_LINK_PREFIX/target"
chmod 600 "$FOREIGN_LINK_PREFIX/target"
ln -s "$FOREIGN_LINK_PREFIX/target" "$FOREIGN_LINK_PREFIX/bin/harness-auto"
if HARNESS_LAUNCHER_PREFIX="$FOREIGN_LINK_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-foreign-link.log" 2>&1; then
  echo "FAIL: source installer replaced a foreign bin symlink" >&2
  exit 1
fi
[[ "$(readlink "$FOREIGN_LINK_PREFIX/bin/harness-auto")" == "$FOREIGN_LINK_PREFIX/target" ]] || {
  echo "FAIL: installer changed a foreign bin symlink" >&2
  exit 1
}
[[ "$(<"$FOREIGN_LINK_PREFIX/target")" == "KEEP-LINK-TARGET" ]] || {
  echo "FAIL: installer changed a foreign bin symlink target" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$FOREIGN_LINK_PREFIX/target")" == "600" ]] || {
  echo "FAIL: installer changed a foreign bin symlink target mode" >&2
  exit 1
}

FOREIGN_SHARE_PREFIX="$TEMP_DIR/foreign-share-prefix"
mkdir -p "$FOREIGN_SHARE_PREFIX/share" "$FOREIGN_SHARE_PREFIX/external-share"
ln -s "$FOREIGN_SHARE_PREFIX/external-share" "$FOREIGN_SHARE_PREFIX/share/harness-launcher"
if HARNESS_LAUNCHER_PREFIX="$FOREIGN_SHARE_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-foreign-share-dir.log" 2>&1; then
  echo "FAIL: source installer accepted a symlinked share directory" >&2
  exit 1
fi
[[ ! -e "$FOREIGN_SHARE_PREFIX/external-share/aliases.zsh" ]] || {
  echo "FAIL: installer wrote through a symlinked share directory" >&2
  exit 1
}
rm "$FOREIGN_SHARE_PREFIX/share/harness-launcher"
mkdir -p "$FOREIGN_SHARE_PREFIX/share/harness-launcher"
printf 'KEEP-SHARE-TARGET\n' > "$FOREIGN_SHARE_PREFIX/target"
chmod 600 "$FOREIGN_SHARE_PREFIX/target"
ln -s "$FOREIGN_SHARE_PREFIX/target" "$FOREIGN_SHARE_PREFIX/share/harness-launcher/harness-auto"
if HARNESS_LAUNCHER_PREFIX="$FOREIGN_SHARE_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-foreign-share.log" 2>&1; then
  echo "FAIL: source installer followed a foreign share symlink" >&2
  exit 1
fi
[[ "$(readlink "$FOREIGN_SHARE_PREFIX/share/harness-launcher/harness-auto")" == "$FOREIGN_SHARE_PREFIX/target" ]] || {
  echo "FAIL: installer changed a foreign share symlink" >&2
  exit 1
}
[[ "$(<"$FOREIGN_SHARE_PREFIX/target")" == "KEEP-SHARE-TARGET" ]] || {
  echo "FAIL: installer changed a foreign share symlink target" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$FOREIGN_SHARE_PREFIX/target")" == "600" ]] || {
  echo "FAIL: installer changed a foreign share symlink target mode" >&2
  exit 1
}

FOREIGN_SHARE_FILE_PREFIX="$TEMP_DIR/foreign-share-file-prefix"
mkdir -p "$FOREIGN_SHARE_FILE_PREFIX/share/harness-launcher"
printf 'KEEP-SHARE-FILE\n' > "$FOREIGN_SHARE_FILE_PREFIX/share/harness-launcher/harness-auto"
chmod 600 "$FOREIGN_SHARE_FILE_PREFIX/share/harness-launcher/harness-auto"
if HARNESS_LAUNCHER_PREFIX="$FOREIGN_SHARE_FILE_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-foreign-share-file.log" 2>&1; then
  echo "FAIL: source installer replaced a foreign share file" >&2
  exit 1
fi
[[ "$(<"$FOREIGN_SHARE_FILE_PREFIX/share/harness-launcher/harness-auto")" == "KEEP-SHARE-FILE" ]] || {
  echo "FAIL: installer changed a foreign share file" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$FOREIGN_SHARE_FILE_PREFIX/share/harness-launcher/harness-auto")" == "600" ]] || {
  echo "FAIL: installer changed a foreign share file mode" >&2
  exit 1
}

IDENTICAL_SHARE_PREFIX="$TEMP_DIR/identical-share-prefix"
mkdir -p "$IDENTICAL_SHARE_PREFIX/share/harness-launcher"
cp "$ROOT/bin/harness-auto" "$IDENTICAL_SHARE_PREFIX/share/harness-launcher/harness-auto"
chmod 600 "$IDENTICAL_SHARE_PREFIX/share/harness-launcher/harness-auto"
IDENTICAL_SHARE_ID="$(stat -f '%i:%Lp' "$IDENTICAL_SHARE_PREFIX/share/harness-launcher/harness-auto")"
HARNESS_LAUNCHER_PREFIX="$IDENTICAL_SHARE_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-identical-share.log"
[[ "$(stat -f '%i:%Lp' "$IDENTICAL_SHARE_PREFIX/share/harness-launcher/harness-auto")" == "$IDENTICAL_SHARE_ID" ]] || {
  echo "FAIL: installer replaced or chmodded an identical existing share file" >&2
  exit 1
}

FORGED_MARKER_PREFIX="$TEMP_DIR/forged-marker-prefix"
mkdir -p "$FORGED_MARKER_PREFIX/share/harness-launcher"
printf 'harness-launcher\n' > "$FORGED_MARKER_PREFIX/share/harness-launcher/.harness-launcher-managed"
printf 'FORGED-MARKER-FOREIGN\n' > "$FORGED_MARKER_PREFIX/share/harness-launcher/harness-auto"
chmod 600 "$FORGED_MARKER_PREFIX/share/harness-launcher/harness-auto"
if HARNESS_LAUNCHER_PREFIX="$FORGED_MARKER_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-forged-marker.log" 2>&1; then
  echo "FAIL: source installer trusted a forgeable ownership marker" >&2
  exit 1
fi
[[ "$(<"$FORGED_MARKER_PREFIX/share/harness-launcher/harness-auto")" == "FORGED-MARKER-FOREIGN" ]] || {
  echo "FAIL: forged marker allowed foreign share content loss" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$FORGED_MARKER_PREFIX/share/harness-launcher/harness-auto")" == "600" ]] || {
  echo "FAIL: forged marker allowed foreign share mode loss" >&2
  exit 1
}

FORGED_LEGACY_PREFIX="$TEMP_DIR/forged-legacy-prefix"
mkdir -p "$FORGED_LEGACY_PREFIX/share/harness-launcher"
printf 'FOREIGN-LAUNCHER\n' > "$FORGED_LEGACY_PREFIX/share/harness-launcher/launcher.sh"
printf 'FOREIGN-ALIASES\n' > "$FORGED_LEGACY_PREFIX/share/harness-launcher/aliases.zsh"
printf 'FORGED-LEGACY-FOREIGN\n' > "$FORGED_LEGACY_PREFIX/share/harness-launcher/harness-auto"
chmod 600 "$FORGED_LEGACY_PREFIX/share/harness-launcher/harness-auto"
if HARNESS_LAUNCHER_PREFIX="$FORGED_LEGACY_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-forged-legacy.log" 2>&1; then
  echo "FAIL: source installer trusted forgeable legacy filenames" >&2
  exit 1
fi
[[ "$(<"$FORGED_LEGACY_PREFIX/share/harness-launcher/harness-auto")" == "FORGED-LEGACY-FOREIGN" ]] || {
  echo "FAIL: forged legacy proof allowed foreign share content loss" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$FORGED_LEGACY_PREFIX/share/harness-launcher/harness-auto")" == "600" ]] || {
  echo "FAIL: forged legacy proof allowed foreign share mode loss" >&2
  exit 1
}

ROLLBACK_PREFIX="$TEMP_DIR/rollback-prefix"
HARNESS_LAUNCHER_PREFIX="$ROLLBACK_PREFIX" "$ROOT/install.sh" >"$TEMP_DIR/install-rollback-seed.log"
rm "$ROLLBACK_PREFIX/share/harness-launcher/harness-auto" "$ROLLBACK_PREFIX/bin/harness-auto"
chmod 500 "$ROLLBACK_PREFIX/bin"
if HARNESS_LAUNCHER_PREFIX="$ROLLBACK_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-rollback.log" 2>&1; then
  chmod 755 "$ROLLBACK_PREFIX/bin"
  echo "FAIL: source installer unexpectedly committed through an unwritable bin" >&2
  exit 1
fi
chmod 755 "$ROLLBACK_PREFIX/bin"
[[ ! -e "$ROLLBACK_PREFIX/share/harness-launcher/harness-auto" ]] || {
  echo "FAIL: late installer failure left a new share asset" >&2
  exit 1
}
[[ ! -e "$ROLLBACK_PREFIX/bin/harness-auto" && ! -L "$ROLLBACK_PREFIX/bin/harness-auto" ]] || {
  echo "FAIL: late installer failure left a new bin entrypoint" >&2
  exit 1
}
[[ "$(readlink "$ROLLBACK_PREFIX/bin/harness-exec")" == "../share/harness-launcher/harness-exec" ]] || {
  echo "FAIL: late installer failure altered an existing bin entrypoint" >&2
  exit 1
}

COMMIT_ROLLBACK_PREFIX="$TEMP_DIR/commit-rollback-prefix"
HARNESS_LAUNCHER_PREFIX="$COMMIT_ROLLBACK_PREFIX" "$ROOT/install.sh" >"$TEMP_DIR/install-commit-seed.log"
rm "$COMMIT_ROLLBACK_PREFIX/share/harness-launcher/harness-auto" "$COMMIT_ROLLBACK_PREFIX/bin/harness-exec"
FAKE_BIN="$TEMP_DIR/fail-mv-bin"
FAIL_ONCE="$TEMP_DIR/fail-mv-once"
mkdir -p "$FAKE_BIN"
printf '%s\n' '#!/bin/sh' 'for last do :; done' 'if [ "$last" = "$HARNESS_FAIL_DEST" ] && [ ! -e "$HARNESS_FAIL_ONCE" ]; then : > "$HARNESS_FAIL_ONCE"; exit 73; fi' 'exec /bin/mv "$@"' > "$FAKE_BIN/mv"
chmod 755 "$FAKE_BIN/mv"
if PATH="$FAKE_BIN:$PATH" \
  HARNESS_FAIL_DEST="$COMMIT_ROLLBACK_PREFIX/bin/harness-exec" \
  HARNESS_FAIL_ONCE="$FAIL_ONCE" \
  HARNESS_LAUNCHER_PREFIX="$COMMIT_ROLLBACK_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-commit-rollback.log" 2>&1; then
  echo "FAIL: source installer ignored an injected commit failure" >&2
  exit 1
fi
[[ -f "$FAIL_ONCE" ]] || {
  echo "FAIL: commit rollback probe did not reach the intended commit step" >&2
  exit 1
}
[[ ! -e "$COMMIT_ROLLBACK_PREFIX/share/harness-launcher/harness-auto" ]] || {
  echo "FAIL: commit failure left a newly installed share asset" >&2
  exit 1
}
[[ ! -e "$COMMIT_ROLLBACK_PREFIX/bin/harness-exec" && ! -L "$COMMIT_ROLLBACK_PREFIX/bin/harness-exec" ]] || {
  echo "FAIL: commit failure left a newly installed bin entrypoint" >&2
  exit 1
}
for file in harness-auto harness-profile; do
  [[ "$(readlink "$COMMIT_ROLLBACK_PREFIX/bin/$file")" == "../share/harness-launcher/$file" ]] || {
    echo "FAIL: commit failure altered existing bin/$file" >&2
    exit 1
  }
done

RACE_PREFIX="$TEMP_DIR/race-prefix"
RACE_BIN="$TEMP_DIR/race-mv-bin"
mkdir -p "$RACE_BIN"
printf '%s\n' '#!/bin/sh' 'for last do :; done' 'if [ "$last" = "$HARNESS_RACE_DEST" ]; then printf "RACE-FOREIGN\\n" > "$last"; chmod 600 "$last"; fi' 'exec /bin/mv "$@"' > "$RACE_BIN/mv"
chmod 755 "$RACE_BIN/mv"
if PATH="$RACE_BIN:$PATH" \
  HARNESS_RACE_DEST="$RACE_PREFIX/share/harness-launcher/harness-auto" \
  HARNESS_LAUNCHER_PREFIX="$RACE_PREFIX" \
  "$ROOT/install.sh" >"$TEMP_DIR/install-race.log" 2>&1; then
  echo "FAIL: source installer ignored a commit-time destination collision" >&2
  exit 1
fi
[[ "$(<"$RACE_PREFIX/share/harness-launcher/harness-auto")" == "RACE-FOREIGN" ]] || {
  echo "FAIL: installer overwrote a destination that appeared during commit" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$RACE_PREFIX/share/harness-launcher/harness-auto")" == "600" ]] || {
  echo "FAIL: installer chmodded a destination that appeared during commit" >&2
  exit 1
}
[[ ! -e "$RACE_PREFIX/share/harness-launcher/aliases.zsh" ]] || {
  echo "FAIL: commit collision rollback left an earlier new asset" >&2
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
