#!/usr/bin/env zsh
# test-aliases-no-exec-shell-replace.sh — guard against `exec` in launcher
# leaf invocations.
#
# `exec X` inside a zsh function REPLACES the user's interactive shell with X.
# When X exits (Ctrl+C, normal exit), there is no shell to return to and the
# terminal window closes. This test fails if any leaf invocation reverts to
# `exec` so the UX regression cannot ship silently.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALIASES="$(cd "$SCRIPT_DIR/.." && pwd)/bin/aliases.zsh"

[[ -f "$ALIASES" ]] || { echo "FAIL: aliases.zsh missing at $ALIASES"; exit 1; }

PASS=0; FAIL=0

# Each pattern is a leaf invocation that MUST NOT be prefixed with `exec`.
patterns=(
  "exec claude"
  "exec codex"
  "exec \"\$_HARNESS_LAUNCHER_BIN/launcher.sh\""
)

for pat in "${patterns[@]}"; do
  if grep -F -q -- "$pat" "$ALIASES"; then
    ((FAIL++))
    line=$(grep -F -n -- "$pat" "$ALIASES" | head -1)
    echo "FAIL: '$pat' still present — $line"
  else
    ((PASS++))
    echo "PASS: '$pat' not present"
  fi
done

# Sanity: the leaf invocations must still exist (without exec)
for cmd in "claude " "codex " "launcher.sh"; do
  if grep -F -q -- "$cmd" "$ALIASES"; then
    ((PASS++))
    echo "PASS: '$cmd' invocation still wired"
  else
    ((FAIL++))
    echo "FAIL: '$cmd' invocation missing — fix removed too much"
  fi
done

echo "---"
echo "no-exec-shell-replace: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
