#!/usr/bin/env bash
# test-codex-hook-adapter.sh — verify codex-hook-adapter.sh translates
# Claude-format hook output ({"additionalContext": "..."}) into the schema
# Codex requires for SessionStart, UserPromptSubmit, and Stop events.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$LAUNCHER_DIR/bin/codex-hook-adapter.sh"

PASS=0
FAIL=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

[[ -x "$ADAPTER" ]] || { echo "FAIL: $ADAPTER missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

make_script() {
  local name="$1" content="$2"
  local path="$TMPDIR/$name.sh"
  printf '%s\n' "$content" > "$path"
  chmod +x "$path"
  printf '%s' "$path"
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# 1. Empty wrapped-script output → empty {} (Codex no-op).
script="$(make_script empty 'true')"
out="$(printf '{}' | "$ADAPTER" SessionStart "$script")"
assert_eq "empty wrapped output emits {}" "$out" '{}'

# 2. Claude SessionStart additionalContext → Codex hookSpecificOutput nest.
script="$(make_script ss 'echo "{\"additionalContext\":\"hello\"}"')"
out="$(printf '{}' | "$ADAPTER" SessionStart "$script" | jq -S -c .)"
assert_eq "SessionStart wraps additionalContext into hookSpecificOutput" \
  "$out" '{"hookSpecificOutput":{"additionalContext":"hello","hookEventName":"SessionStart"}}'

# 3. Claude Stop additionalContext → Codex decision/reason form.
script="$(make_script stop 'echo "{\"additionalContext\":\"checklist payload\"}"')"
out="$(printf '{}' | "$ADAPTER" Stop "$script" | jq -S -c .)"
assert_eq "Stop translates additionalContext to decision=block + reason" \
  "$out" '{"decision":"block","reason":"checklist payload"}'

# 4. UserPromptSubmit additionalContext → hookSpecificOutput nest with matching event name.
script="$(make_script ups 'echo "{\"additionalContext\":\"prompt-ctx\"}"')"
out="$(printf '{}' | "$ADAPTER" UserPromptSubmit "$script" | jq -S -c .)"
assert_eq "UserPromptSubmit wraps additionalContext" \
  "$out" '{"hookSpecificOutput":{"additionalContext":"prompt-ctx","hookEventName":"UserPromptSubmit"}}'

# 5. Already-Codex output (hookSpecificOutput present) → passthrough untouched.
script="$(make_script passthrough 'echo "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"X\"}}"')"
out="$(printf '{}' | "$ADAPTER" SessionStart "$script" | jq -S -c .)"
assert_eq "pre-formatted Codex JSON passes through" \
  "$out" '{"hookSpecificOutput":{"additionalContext":"X","hookEventName":"SessionStart"}}'

# 6. Decision-shaped output (block) → passthrough.
script="$(make_script blocking 'echo "{\"decision\":\"block\",\"reason\":\"already block\"}"')"
out="$(printf '{}' | "$ADAPTER" Stop "$script" | jq -S -c .)"
assert_eq "decision-shaped output passes through" \
  "$out" '{"decision":"block","reason":"already block"}'

# 7. Missing wrapped script → safe no-op (don't break Codex).
out="$("$ADAPTER" SessionStart "/nonexistent/path-$$.sh" </dev/null)"
assert_eq "missing wrapped script returns {}" "$out" '{}'

# 8. Wrapped script exits non-zero → adapter still exits 0 (advisory hooks must not crash Codex).
script="$(make_script crashy 'exit 2')"
"$ADAPTER" SessionStart "$script" </dev/null >/dev/null 2>&1
adapter_rc=$?
assert_eq "adapter swallows wrapped non-zero exit" "$adapter_rc" "0"

# 9. PreToolUse with empty output → {} (no rewrite path defined, default safe).
script="$(make_script empty2 'true')"
out="$(printf '{}' | "$ADAPTER" PreToolUse "$script")"
assert_eq "PreToolUse with empty output returns {}" "$out" '{}'

# 10. Stdin payload reaches the wrapped script (verified via sidecar capture).
sentinel="$TMPDIR/payload-capture.txt"
script="$(make_script reflect "cat > '$sentinel'")"
printf '{"hook_event_name":"SessionStart","session_id":"abc-123"}' \
  | "$ADAPTER" SessionStart "$script" >/dev/null
if [[ -f "$sentinel" ]] && grep -q '"session_id":"abc-123"' "$sentinel"; then
  echo "PASS: stdin payload forwarded to wrapped script"
  PASS=$((PASS + 1))
else
  echo "FAIL: stdin payload not forwarded (sidecar=$(cat "$sentinel" 2>/dev/null))"
  FAIL=$((FAIL + 1))
fi

echo "---"
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
