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

echo 'PASS: default-isolation route matrix is explicit and bounded'
