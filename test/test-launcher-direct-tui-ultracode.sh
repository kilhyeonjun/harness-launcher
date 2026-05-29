#!/usr/bin/env bash
# test-launcher-direct-tui-ultracode.sh — verify the Claude direct TUI offers the
# Ultracode mode (below Rich) and resolves it to opus[1m] + --effort xhigh.
# ultracode's orchestration half is session-only (set in-session via /effort),
# so the launcher can only start rich-equivalent (opus[1m] + xhigh) and must NOT
# pass '--effort ultracode' (the CLI rejects it).
# Subprocess + numbered stdin pattern (mirrors test-launcher-codex-tui.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() { [[ -n "${TT:-}" && -d "$TT" ]] && rm -rf "$TT"; }
trap cleanup EXIT

TT="$(mktemp -d)"
H="$TT/fake-harness"; BIN="$TT/bin"
mkdir -p "$H/config" "$BIN"
cat > "$H/config/launcher.env" <<'EOF'
HARNESS_NAME="test harness"
HARNESS_PREFIX="test"
EOF

# Only `claude` in PATH (no codex/happy) → runtime menu auto-skips, no Happy prompt.
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "EXEC:claude"; echo "ARGS:$*"; } >> "$TEST_STUB_FILE"
exit 0
EOF
chmod +x "$BIN/claude"

STUB="$TT/out.txt"; : > "$STUB"
# No gateways → single provider (direct), STEP starts at session menu.
# Flow: session=New(1) → mode=Ultracode(5) → advanced=No, start now(2)
TEST_STUB_FILE="$STUB" PATH="$BIN:/usr/bin:/bin" \
  HARNESS_DIR="$H" HARNESS_NAME="test harness" \
  bash "$LAUNCHER_DIR/bin/launcher.sh" <<< $'1\n5\n2\n' > "$STUB.log" 2>&1 || true

PASS=0; FAIL=0
if grep -qE "^ARGS:.*--model opus\[1m\]" "$STUB"; then PASS=$((PASS+1)); else
  echo "FAIL: tui ultracode model"; echo "--- stub ---"; cat "$STUB"; echo "--- log ---"; cat "$STUB.log"; FAIL=$((FAIL+1)); fi
if grep -qE "^ARGS:.*--effort xhigh" "$STUB"; then PASS=$((PASS+1)); else
  echo "FAIL: tui ultracode effort (expected xhigh)"; cat "$STUB"; FAIL=$((FAIL+1)); fi
# Must NOT pass the (CLI-rejected) ultracode effort value.
if grep -qE "^ARGS:.*--effort ultracode" "$STUB"; then
  echo "FAIL: tui must not pass '--effort ultracode'"; cat "$STUB"; FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
# The session-only hint must be surfaced in the TUI output.
if grep -qE "/effort" "$STUB.log"; then PASS=$((PASS+1)); else
  echo "FAIL: tui should print a /effort hint"; cat "$STUB.log"; FAIL=$((FAIL+1)); fi

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
