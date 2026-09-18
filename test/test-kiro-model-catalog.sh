#!/usr/bin/env bash
# test-kiro-model-catalog.sh — native-Kiro model catalog resolution.
#
# The custom-model menu must never depend on a hardcoded list, never spend
# credits, and never hang the TUI. Covers, in order of precedence:
#   - HARNESS_KIRO_MODEL_CATALOG override
#   - fresh cache hit (no probe)
#   - live probe parsing of `chat --list-models` + cache write
#   - stale cache refresh
#   - probe failure → static fallback + negative stamp (no repeat timeout)
#   - stale cache preferred over the static fallback when the probe fails
#   - non-numeric stat output cannot poison the age comparison
#
# harness-common.sh is sourced by launcher.sh (bash) AND aliases.zsh (zsh), and
# the two shells disagree on word splitting and on special variable names, so
# every assertion runs under both interpreters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${KIRO_CATALOG_TEST_SHELL:-}" ]]; then
  rc=0
  for shell_bin in bash zsh; do
    if ! command -v "$shell_bin" >/dev/null 2>&1; then
      echo "SKIP: $shell_bin not available"
      continue
    fi
    echo "── interpreter: $shell_bin"
    KIRO_CATALOG_TEST_SHELL="$shell_bin" "$shell_bin" "$0" || rc=1
  done
  exit "$rc"
fi

cleanup() { [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" ]] && rm -rf "$TEST_TEMP"; }
trap cleanup EXIT
TEST_TEMP="$(mktemp -d)"
export XDG_STATE_HOME="$TEST_TEMP/state"

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || no "$1 — expected '$2', got '$3'"; }

# shellcheck source=/dev/null
. "$LAUNCHER_DIR/bin/harness-common.sh"

CACHE="$(harness_kiro_catalog_cache_path)"
STAMP="$CACHE.failed"
mkdir -p "$(dirname "$CACHE")"

# A stub that mimics `kiro-cli chat --list-models --format plain` and records
# every invocation, so "no probe" can be asserted rather than assumed.
STUB="$TEST_TEMP/kiro-stub"
CALLS="$TEST_TEMP/calls.log"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "CALL:$*" >> "$CALLS"
if [[ -n "${STUB_FAIL:-}" ]]; then
  echo "not logged in" >&2
  exit 1
fi
# stdin must already be /dev/null: if the probe inherited the caller's stdin it
# would read the sentinel below (and in the TUI it would eat the user's keys).
if IFS= read -r _line; then
  [[ "$_line" == SENTINEL* ]] && echo "STDIN_LEAK" >> "$CALLS"
fi
cat <<'OUT'
Available models (* = default):

* auto                 1.00x credits      Models chosen by task
  claude-opus-5        2.20x credits      Claude Opus 5 model with 1M context window
  claude-sonnet-5      1.30x credits      Claude Sonnet 5 model with 1M context window
  glm-5                0.50x credits      GLM-5 model
OUT
EOF
chmod +x "$STUB"
export CALLS

echo "Test: explicit override short-circuits everything"
: > "$CALLS"
out=$(HARNESS_KIRO_MODEL_CATALOG="a b c" harness_kiro_catalog_models "$STUB" | tr '\n' ' ')
assert_eq "override list" "a b c " "$out"
assert_eq "override does not probe" "0" "$(wc -l < "$CALLS" | tr -d ' ')"

echo "Test: live probe parses --list-models and writes the cache"
: > "$CALLS"; rm -f "$CACHE" "$STAMP"
rows=$(harness_kiro_catalog_rows "$STUB" <<< "SENTINEL-stdin-must-not-be-read")
assert_eq "first row is id<TAB>multiplier" "claude-opus-5	2.20" "$(printf '%s\n' "$rows" | sed -n '2p')"
assert_eq "default marker stripped" "auto	1.00" "$(printf '%s\n' "$rows" | sed -n '1p')"
assert_eq "non-Claude model kept" "glm-5	0.50" "$(printf '%s\n' "$rows" | sed -n '4p')"
assert_eq "header line dropped" "4" "$(printf '%s\n' "$rows" | grep -c .)"
grep -q -- '--list-models' "$CALLS" && ok "probe uses --list-models" || no "probe must use --list-models"
grep -q 'STDIN_LEAK' "$CALLS" && no "probe must redirect stdin" || ok "probe does not consume stdin"
[[ -s "$CACHE" ]] && ok "cache written" || no "cache written"
assert_eq "models view is IDs only" "claude-opus-5" "$(harness_kiro_catalog_models "$STUB" | sed -n '2p')"

echo "Test: fresh cache is served without probing"
: > "$CALLS"
printf 'cached-model\t9.99\n' > "$CACHE"; rm -f "$STAMP"
assert_eq "cache hit" "cached-model" "$(harness_kiro_catalog_models "$STUB")"
assert_eq "cache hit does not probe" "0" "$(wc -l < "$CALLS" | tr -d ' ')"

echo "Test: expired cache is refreshed"
: > "$CALLS"
assert_eq "stale cache refreshed" "claude-opus-5" \
  "$(HARNESS_KIRO_CATALOG_TTL=0 harness_kiro_catalog_models "$STUB" | sed -n '2p')"
grep -q -- '--list-models' "$CALLS" && ok "expiry triggers a probe" || no "expiry triggers a probe"

echo "Test: probe failure falls back and stamps"
: > "$CALLS"; rm -f "$CACHE" "$STAMP"
out=$(STUB_FAIL=1 harness_kiro_catalog_models "$STUB")
printf '%s\n' "$out" | grep -qx 'claude-opus-5' && ok "fallback carries the opus tier" || no "fallback carries the opus tier"
printf '%s\n' "$out" | grep -qx 'qwen3-coder-next' && ok "fallback keeps non-Claude models" || no "fallback keeps non-Claude models"
[[ -f "$STAMP" ]] && ok "failed probe is stamped" || no "failed probe is stamped"

echo "Test: negative stamp suppresses the repeat probe"
: > "$CALLS"
STUB_FAIL=1 harness_kiro_catalog_models "$STUB" >/dev/null
assert_eq "stamped failure does not re-probe" "0" "$(wc -l < "$CALLS" | tr -d ' ')"

echo "Test: stale cache beats the static fallback on failure"
printf 'stale-model\t1.00\n' > "$CACHE"; rm -f "$STAMP"
assert_eq "stale cache used" "stale-model" \
  "$(STUB_FAIL=1 HARNESS_KIRO_CATALOG_TTL=0 harness_kiro_catalog_models "$STUB")"

echo "Test: non-numeric stat output cannot poison the age check"
# Without the numeric guard the comparison would raise an arithmetic error, so
# assert on stderr: a clean rejection prints nothing.
harness_file_mtime() { printf 'Filesystem 1K-blocks\n'; }
age_err="$TEST_TEMP/age.err"
if harness_file_age_below "$CACHE" 999999 2>"$age_err"; then
  no "non-numeric mtime must not count as fresh"
else
  if [[ -s "$age_err" ]]; then
    no "non-numeric mtime must be rejected cleanly, got: $(cat "$age_err")"
  else
    ok "non-numeric mtime treated as expired without an arithmetic error"
  fi
fi
unset -f harness_file_mtime

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -gt 0 ]] && exit 1
echo "✓ All kiro model catalog tests passed"
