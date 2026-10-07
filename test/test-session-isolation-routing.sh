#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/bin/harness-common.sh"

assert_route() {
  local want="$1" interactive="$2"
  shift 2
  local got
  got="$(harness_session_isolation_default_route "$interactive" "$@")"
  [[ "$got" == "$want" ]] || {
    printf 'FAIL: route want=%s got=%s argv=' "$want" "$got" >&2
    printf '<%s>' "$@" >&2
    printf '\n' >&2
    exit 1
  }
}

# A wrong route here either recreates the repeated Stop block, clones for a
# non-session command, or silently resumes against the canonical dirty root.
assert_route isolate 1 base
assert_route isolate 1 rich acceptEdits 'fresh task'
assert_route isolate 1 codex base
assert_route isolate 1 codex astra never 'fresh task'

assert_route legacy 0 base
assert_route legacy 1
assert_route legacy 1 -h
assert_route legacy 1 --version
assert_route legacy 1 base -p 'batch task'
assert_route legacy 1 base --print='batch task'
assert_route legacy 1 codex exec 'batch task'
assert_route legacy 1 codex review
assert_route legacy 1 codex-smoke
assert_route legacy 1 checkup prompt-audit
assert_route legacy 1 kiro-cli base
assert_route legacy 1 kiro base
assert_route legacy 1 codex-gateway base

assert_route reject 1 resume
assert_route reject 1 base continue
assert_route reject 1 base --resume=session-id
assert_route reject 1 codex resume
assert_route reject 1 codex base continue
assert_route reject 1 codex fork
assert_route reject 1 codex --model gpt-5.6 resume
assert_route reject 1 codex --cd /tmp resume
assert_route reject 1 --model sonnet resume
assert_route reject 1 --settings '{}' --continue

# After the explicit prompt boundary, control-looking text is prompt content.
assert_route isolate 1 base -- --isolated
assert_route isolate 1 codex base -- --isolated-session

# After --passthrough, launcher keywords are ordinary Claude arguments while
# Claude options keep their classification.
assert_route legacy 0 base --passthrough --permission-mode plan
assert_route isolate 1 base --passthrough --permission-mode plan
assert_route isolate 1 base --passthrough continue
assert_route isolate 1 --passthrough resume
assert_route reject 1 base --passthrough --resume=session-id
assert_route legacy 1 base --passthrough -p 'batch task'
assert_route invalid 1 base --passthrough --mcp-config '{}'
# harness-headless argv: --strict-mcp-config alone is a plain Claude flag.
assert_route legacy 1 --passthrough --strict-mcp-config -p
assert_route legacy 1 --passthrough -p --output-format json --max-budget-usd 1 --permission-mode bypassPermissions --strict-mcp-config --settings '{}' -- prompt
assert_route isolate 1 base --passthrough -- --resume
# A management subcommand right after the marker runs natively (no clone).
assert_route legacy 1 base --passthrough auth status
assert_route legacy 1 --passthrough mcp list
assert_route isolate 1 base --passthrough 'auth status'
# Codex after the marker: subcommands stay legacy, resume/fork reject, bare
# launcher keywords (including `continue`) are prompt text.
assert_route legacy 1 codex --passthrough app-server --enable goals
assert_route legacy 1 codex base --passthrough exec x
assert_route reject 1 codex --passthrough resume --last
assert_route reject 1 codex --passthrough fork
assert_route isolate 1 codex --passthrough continue
assert_route isolate 1 codex --passthrough fast 'fresh task'
assert_route reject 1 codex continue
assert_route isolate 1 codex --passthrough -C/tmp -pbase 'fresh task'
assert_route invalid 1 codex --passthrough --passthrough

echo 'PASS: default-isolation route matrix is explicit and bounded'
