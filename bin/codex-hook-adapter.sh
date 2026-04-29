#!/usr/bin/env bash
# codex-hook-adapter.sh — translate Claude-format hook stdout JSON into the
# schema Codex 0.125 requires, so a single canonical hook script in the
# Claude harness can drive both runtimes without per-event forks.
#
# Usage: codex-hook-adapter.sh <event> <claude-hook-script>
#   <event>: Codex hook event name (SessionStart, UserPromptSubmit, Stop, ...)
#   <claude-hook-script>: absolute path to harness/core/hooks/*.sh
#
# Failure modes are deliberately swallowed (exit 0, empty {}). These hooks are
# advisory; a malformed transform must not surface as a Codex hard-error.

set -u

EVENT="${1:-}"
SCRIPT="${2:-}"

PAYLOAD="$(cat 2>/dev/null || true)"

if [[ -z "$SCRIPT" || ! -f "$SCRIPT" ]]; then
  echo '{}'
  exit 0
fi

OUTPUT="$(printf '%s' "$PAYLOAD" | bash "$SCRIPT" 2>/dev/null || true)"

# Whitespace-only output is treated as empty.
if [[ -z "${OUTPUT//[[:space:]]/}" ]]; then
  echo '{}'
  exit 0
fi

# Without jq we cannot reliably rewrite JSON; emit safe no-op rather than
# forwarding a payload Codex would reject.
if ! command -v jq >/dev/null 2>&1; then
  echo '{}'
  exit 0
fi

# Already-Codex-shaped output (decision/continue/hookSpecificOutput/
# systemMessage) → passthrough. Lets a hook opt into native Codex semantics.
if printf '%s' "$OUTPUT" \
   | jq -e '.decision // .continue // .hookSpecificOutput // .systemMessage' \
   >/dev/null 2>&1; then
  printf '%s\n' "$OUTPUT"
  exit 0
fi

ADDL="$(printf '%s' "$OUTPUT" | jq -r '.additionalContext // empty' 2>/dev/null || true)"

if [[ -z "$ADDL" ]]; then
  echo '{}'
  exit 0
fi

case "$EVENT" in
  SessionStart)
    jq -n --arg ctx "$ADDL" '{
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $ctx
      }
    }'
    ;;
  UserPromptSubmit)
    jq -n --arg ctx "$ADDL" '{
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $ctx
      }
    }'
    ;;
  Stop)
    jq -n --arg msg "$ADDL" '{
      decision: "block",
      reason: $msg
    }'
    ;;
  *)
    echo '{}'
    ;;
esac

exit 0
