#!/usr/bin/env bash
# test-launcher-stable-path.sh — every Homebrew spelling of the launcher package
# (compat share link, opt link, versioned Cellar keg) resolves to the `opt`
# spelling for generated hook paths, under /bin/bash 3.2 and zsh; a different
# active keg never wins. aliases.zsh entered through the keg names hooks by opt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd -P "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

PREFIX="$TMP/brew"
KEG="$PREFIX/Cellar/harness-launcher/1.0.0"
PACKAGE="$KEG/share/harness-launcher"
mkdir -p "$PACKAGE" "$PREFIX/opt" "$PREFIX/share"
cp -R "$ROOT/bin/." "$PACKAGE/"
ln -s "$KEG" "$PREFIX/opt/harness-launcher"
ln -s "$PACKAGE" "$PREFIX/share/harness-launcher"
OPT="$PREFIX/opt/harness-launcher/share/harness-launcher"

for sh in /bin/bash zsh; do
  got() { "$sh" -c '. "$1/harness-common.sh"; harness_launcher_stable_dir "$2"' _ "$PACKAGE" "$1"; }
  [[ "$(got "$PACKAGE")" == "$OPT" ]] || fail "$sh: the versioned keg must map to opt: $(got "$PACKAGE")"
  [[ "$(got "$PREFIX/share/harness-launcher")" == "$OPT" ]] || fail "$sh: the share link must map to opt"
  [[ "$(got "$OPT")" == "$OPT" ]] || fail "$sh: opt must stay opt"
  [[ "$(got "$ROOT/bin")" == "$ROOT/bin" ]] || fail "$sh: a source tree must stay unchanged"
done
echo 'PASS: keg, share link and opt spellings resolve to opt under bash 3.2 and zsh'

# aliases.zsh entered through the keg (a shell route that resolved symlinks)
# names the Claude launch-record hook by the opt spelling.
HOOK="$(env -i HOME="$TMP" PATH=/usr/bin:/bin zsh -f -c '
  source "$1/aliases.zsh" >/dev/null 2>&1
  print -r -- "BIN=$_HARNESS_LAUNCHER_BIN"
  HARNESS_DIR=/srv/h _harness_launcher_claude_launch_settings false "" ""' _ "$PACKAGE")"
[[ "$HOOK" == *"BIN=$OPT"* ]] || fail "aliases.zsh must keep the opt spelling: $HOOK"
[[ "$HOOK" == *"$OPT/harness-launch-record claude"* && "$HOOK" != *"/Cellar/"* ]] \
  || fail "the Claude launch-record hook must name the opt path: $HOOK"
echo 'PASS: aliases.zsh entered through the keg names hooks by the opt path'

# A different active keg is not an alias of this one and must not win.
OTHER="$PREFIX/Cellar/harness-launcher/2.0.0"
mkdir -p "$OTHER/share/harness-launcher"
rm "$PREFIX/opt/harness-launcher"
ln -s "$OTHER" "$PREFIX/opt/harness-launcher"
for sh in /bin/bash zsh; do
  out="$("$sh" -c '. "$1/harness-common.sh"; harness_launcher_stable_dir "$1"' _ "$PACKAGE")"
  [[ "$out" == "$PACKAGE" ]] || fail "$sh: another active keg must not replace this keg: $out"
done
echo 'PASS: another active keg never replaces the running package path'
