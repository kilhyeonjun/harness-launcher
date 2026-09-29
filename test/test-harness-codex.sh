#!/usr/bin/env bash
# test-harness-codex.sh — the Codex executable used by SDK hosts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PREFIX="$TMP/prefix"
HOME_DIR="$TMP/home"
BIN_DIR="$HOME_DIR/.local/bin"
STUB_BIN="$TMP/stub-bin"
ALPHA="$HOME_DIR/alpha harness"
ALPHA_PROJECT="$ALPHA/projects/app"
OUTSIDE="$TMP/outside"
LOG="$TMP/codex.log"

mkdir -p "$ALPHA/config" "$ALPHA_PROJECT" "$OUTSIDE" "$BIN_DIR" "$STUB_BIN"
cat > "$ALPHA/config/launcher.env" <<'EOF'
HARNESS_NAME="alpha test"
HARNESS_PREFIX="alpha"
EOF
cat > "$STUB_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf 'NATIVE:%s\n' "$*"
EOF
chmod 755 "$STUB_BIN/codex"

bash "$ROOT/test/lib/install-runtime-fixture.sh" "$ROOT" "$PREFIX"
HOME="$HOME_DIR" HARNESS_PROFILE_BIN_DIR="$BIN_DIR" \
  "$PREFIX/bin/harness-profile" register "$ALPHA" >/dev/null
cat > "$PREFIX/share/harness-launcher/harness-exec" <<'EOF'
#!/usr/bin/env bash
{
  printf 'HARNESS:%s\n' "$1"
  shift
  printf 'ARGV:'
  printf ' <%s>' "$@"
  printf '\n'
} > "$HARNESS_CODEX_TEST_LOG"
EOF
chmod 755 "$PREFIX/share/harness-launcher/harness-exec"
ALPHA_REAL="$(cd "$ALPHA" && pwd -P)"

fail() {
  echo "FAIL: $1" >&2
  [[ -f "$LOG" ]] && sed 's/^/  /' "$LOG" >&2
  exit 1
}

run() {  # <cwd> <harness-codex args...>
  local cwd="$1"; shift
  : > "$LOG"
  (
    cd "$cwd"
    HOME="$HOME_DIR" PATH="$STUB_BIN:/usr/bin:/bin" HARNESS_CODEX_TEST_LOG="$LOG" \
      "$PREFIX/bin/harness-codex" "$@"
  )
}

for flag in --version -V; do
  out="$(run "$OUTSIDE" "$flag")" || fail "$flag failed"
  [[ "$out" == "NATIVE:$flag" ]] || fail "$flag did not reach native codex: $out"
done
echo 'PASS: --version and -V run native codex'

run "$OUTSIDE" --profile alpha app-server --enable goals || fail '--profile alpha failed'
grep -Fqx "HARNESS:$ALPHA_REAL" "$LOG" || fail '--profile alpha did not select alpha'
grep -Fqx 'ARGV: <codex> <--passthrough> <app-server> <--enable> <goals>' "$LOG" \
  || fail '--profile alpha changed the argv'
run "$OUTSIDE" --profile=alpha exec x || fail '--profile=alpha failed'
grep -Fqx 'ARGV: <codex> <--passthrough> <exec> <x>' "$LOG" || fail '--profile=alpha argv'
echo 'PASS: --profile selects the registered harness from an outside cwd'

run "$ALPHA_PROJECT" exec x || fail 'auto selection failed'
grep -Fqx "HARNESS:$ALPHA_REAL" "$LOG" || fail 'auto selection did not select alpha'
grep -Fqx 'ARGV: <codex> <--passthrough> <exec> <x>' "$LOG" || fail 'auto selection argv'
echo 'PASS: without --profile the cwd selects the harness'

for args in '--profile' '--profile missing' '--profile register' '--profile checkup' '--profile ../x' '--profile='; do
  rc=0
  # shellcheck disable=SC2086
  run "$OUTSIDE" $args app-server 2>/dev/null || rc=$?
  [[ "$rc" == 2 ]] || fail "'$args' expected exit 2, got $rc"
  [[ -s "$LOG" ]] && fail "'$args' launched codex"
done
rc=0
run "$OUTSIDE" app-server 2>/dev/null || rc=$?
[[ "$rc" != 0 && ! -s "$LOG" ]] || fail 'outside cwd without --profile launched codex'
echo 'PASS: invalid, reserved, and unregistered profiles exit 2'

echo 'All harness-codex tests passed'
