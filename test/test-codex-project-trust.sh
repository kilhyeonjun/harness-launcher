#!/usr/bin/env bash
set -euo pipefail
# Codex asks "Trust this folder?" for a project without a [projects."<path>"]
# entry in $CODEX_HOME/config.toml, and the launcher rewrites that file on every
# launch. The launcher trusts only its own roots and keeps the user's decisions.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
PREPARE="$ROOT/bin/codex-home-prepare.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset HARNESS_SOURCE_ROOT HARNESS_SESSION_ROOT HARNESS_SESSION_ID

FAKE_HOME="$TMP/home"
NO_MARKETPLACE="$TMP/no-marketplace"
mkdir -p "$FAKE_HOME"

prepare() {
  HOME="$FAKE_HOME" HARNESS_CODEX_BUNDLED_MARKETPLACE_SOURCE="$NO_MARKETPLACE" \
    "$BASH_BIN" "$PREPARE" "$@" >/dev/null
}

# projects <config>: print each [projects] key and its trust_level, in file order.
projects() {
  python3 - "$1" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
for path, table in (config.get("projects") or {}).items():
    print("%s=%s" % (path, table.get("trust_level")))
PY
}

# The harness is reached through a symlink; Codex keys trust by physical path.
REAL="$TMP/real/harness"
mkdir -p "$REAL/.harness/codex" "$TMP/links"
printf '# fixture harness\n' > "$REAL/CLAUDE.md"
ln -s "$REAL" "$TMP/links/harness"
PHYSICAL="$(cd "$REAL" && pwd -P)"
CONFIG="$REAL/.harness/codex/config.toml"

prepare "$TMP/links/harness"
[[ "$(projects "$CONFIG")" == "$PHYSICAL=trusted" ]] || {
  echo "FAIL: a fresh config must trust exactly the physical harness root" >&2
  projects "$CONFIG" >&2
  exit 1
}
echo "PASS: the launcher trusts the physical harness root"

cp -p "$CONFIG" "$TMP/first.toml"
prepare "$TMP/links/harness"
cmp -s "$TMP/first.toml" "$CONFIG" || { echo "FAIL: an unchanged launch rewrote config.toml" >&2; exit 1; }
echo "PASS: an unchanged launch does not rewrite config.toml"

# The user's own decisions survive byte-for-byte, and a decision for the harness
# root wins over the launcher's entry instead of producing a duplicate table.
# Codex edits the saved table in place when the user changes a decision.
python3 - "$CONFIG" "$PHYSICAL" <<'PY2'
import json
import sys

path, root = sys.argv[1:]
text = open(path, encoding="utf-8").read()
launcher = '[projects.%s]\ntrust_level = "trusted"\n' % json.dumps(root)
assert launcher in text, text
text = text.replace(launcher, '[projects.%s]\ntrust_level = "untrusted"\n' % json.dumps(root))
text += '\n[projects."/tmp/some other repo"]\ntrust_level = "trusted" # exact user decision\n'
open(path, "w", encoding="utf-8").write(text)
PY2
prepare "$TMP/links/harness"
expected="$(printf '%s\n' "$PHYSICAL=untrusted" "/tmp/some other repo=trusted")"
[[ "$(projects "$CONFIG")" == "$expected" ]] || {
  echo "FAIL: user trust decisions were not kept, or the harness root was duplicated" >&2
  projects "$CONFIG" >&2
  exit 1
}
grep -Fq 'trust_level = "trusted" # exact user decision' "$CONFIG" || {
  echo "FAIL: a user [projects] table was not preserved byte-for-byte" >&2
  exit 1
}
echo "PASS: user trust decisions survive and win over the launcher entry"

cp -p "$CONFIG" "$TMP/decided.toml"
prepare "$TMP/links/harness"
cmp -s "$TMP/decided.toml" "$CONFIG" || { echo "FAIL: an unchanged launch rewrote config.toml after user decisions" >&2; exit 1; }
echo "PASS: user decisions keep an unchanged launch stable"

# A shell inside an isolated session inherits HARNESS_SOURCE_ROOT. Preparing any
# other harness from it must not trust that source root.
OTHER="$TMP/other-harness"
mkdir -p "$OTHER/.harness/codex" "$TMP/foreign-source"
printf '# fixture harness\n' > "$OTHER/CLAUDE.md"
HARNESS_SOURCE_ROOT="$TMP/foreign-source" prepare "$OTHER"
HARNESS_SOURCE_ROOT="$TMP/foreign-source" HARNESS_SESSION_ROOT="$TMP/some-session" prepare "$OTHER"
[[ "$(projects "$OTHER/.harness/codex/config.toml")" == "$(cd "$OTHER" && pwd -P)=trusted" ]] || {
  echo "FAIL: an inherited source root was trusted for another harness" >&2
  projects "$OTHER/.harness/codex/config.toml" >&2
  exit 1
}
echo "PASS: an inherited source root is not trusted for another harness"

# An isolated session also trusts its source root, listed first.
SOURCE="$TMP/source-harness"
SESSION="$TMP/session-root"
mkdir -p "$SOURCE" "$SESSION/.harness/codex"
printf '# fixture harness\n' > "$SESSION/CLAUDE.md"
HARNESS_SOURCE_ROOT="$SOURCE" HARNESS_SESSION_ROOT="$SESSION" prepare "$SESSION"
expected="$(printf '%s\n' "$(cd "$SOURCE" && pwd -P)=trusted" "$(cd "$SESSION" && pwd -P)=trusted")"
[[ "$(projects "$SESSION/.harness/codex/config.toml")" == "$expected" ]] || {
  echo "FAIL: an isolated session must trust its source root and its session root" >&2
  projects "$SESSION/.harness/codex/config.toml" >&2
  exit 1
}
echo "PASS: an isolated session trusts its source root and session root"

# Paths are TOML-escaped.
ODD="$TMP/odd \"quoted\" \\ harness"
mkdir -p "$ODD/.harness/codex"
printf '# fixture harness\n' > "$ODD/CLAUDE.md"
prepare "$ODD"
[[ "$(projects "$ODD/.harness/codex/config.toml")" == "$(cd "$ODD" && pwd -P)=trusted" ]] || {
  echo "FAIL: a harness path with quotes and backslashes was not escaped" >&2
  exit 1
}
echo "PASS: trusted paths are TOML-escaped"
