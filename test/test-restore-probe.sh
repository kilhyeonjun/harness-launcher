#!/usr/bin/env bash
# test-restore-probe.sh — harness-restore-probe reads the model/effort of a
# session from its Claude transcript or Codex rollout. It is hardened (no
# symlink or non-regular file, bounded read, model shape) and never fails.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bin/harness-common.sh"
PY="$(harness_python3_resolve)" || exit 1
PROBE="$ROOT/bin/harness-restore-probe"
TMP="$(mktemp -d)"
trap 'find "$TMP" -delete' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$PROBE" ]] || fail 'probe command is missing'

# probe <claude|codex> <file> : sets OUT and RC
probe() { OUT="$("$PY" "$PROBE" "$1" "$2" 2>&1)"; RC=$?; }
expect() { # <label> <expected output>
  [[ $RC == 0 ]] || fail "$1: exit $RC"
  [[ "$OUT" == "$2" ]] || fail "$1: got [$OUT] want [$2]"
}
asst() { # <model> [extra json fields]
  printf '{"type":"assistant","isSidechain":false,"message":{"model":"%s"}%s}\n' "$1" "${2:-}"
}

# --- Claude transcript ------------------------------------------------------
T="$TMP/claude.jsonl"
{
  asst claude-sonnet-5-5 ',"effort":"high"'
  asst claude-opus-5-5 ',"effort":"xhigh"'
  asst '<synthetic>' ',"effort":"low"'
  asst gpt-5.6-terra ',"effort":"low"'
  printf '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001"},"effort":"low"}\n'
  printf '{"type":"cost-state","modelUsage":{"claude-opus-5-5[1m]":{"inputTokens":1}}}\n'
} > "$T"
probe claude "$T"
expect 'claude last main-thread model/effort with [1m]' $'model=claude-opus-5-5[1m]\neffort=xhigh'

# no cost-state entry for the [1m] variant: plain model
grep -v cost-state "$T" > "$TMP/no1m.jsonl"
probe claude "$TMP/no1m.jsonl"
expect 'claude without [1m] usage' $'model=claude-opus-5-5\neffort=xhigh'

# a [1m] cost-state for another model does not decorate this one
{ asst claude-sonnet-5-5 ',"effort":"medium"'; printf '{"type":"cost-state","modelUsage":{"claude-opus-5-5[1m]":{}}}\n'; } > "$TMP/other1m.jsonl"
probe claude "$TMP/other1m.jsonl"
expect 'claude [1m] of another model' $'model=claude-sonnet-5-5\neffort=medium'

# model with a leading dash / bad shape / non-claude / invalid effort: skipped
{ asst '-claude-evil' ',"effort":"high"'; asst 'claude-x y' ; asst 'claude-ok-1' ',"effort":"turbo"'; } > "$TMP/bad.jsonl"
probe claude "$TMP/bad.jsonl"
expect 'claude bad model/effort skipped' 'model=claude-ok-1'

# malformed lines and empty files are ignored; output stays empty
printf 'not json\n{"type":\n\x00\xff\n' > "$TMP/malformed.jsonl"
probe claude "$TMP/malformed.jsonl"; expect 'malformed' ''
: > "$TMP/empty.jsonl"
probe claude "$TMP/empty.jsonl"; expect 'empty' ''
probe claude "$TMP/missing.jsonl"; expect 'missing' ''
probe claude ''; expect 'empty path' ''
probe bogus "$T"; expect 'unknown agent' ''

# symlink and FIFO are never read (and the FIFO does not block)
ln -s "$T" "$TMP/link.jsonl"
probe claude "$TMP/link.jsonl"; expect 'symlink' ''
mkfifo "$TMP/fifo.jsonl"
probe claude "$TMP/fifo.jsonl"; expect 'fifo' ''
mkdir "$TMP/dir.jsonl"
probe claude "$TMP/dir.jsonl"; expect 'directory' ''

# only the last 8 MiB is read; the partial first line is dropped
"$PY" - "$TMP/big.jsonl" <<'PYEOF'
import sys
pad = '{"type":"user","message":{"content":"' + 'x' * 1000 + '"}}\n'
head = '{"type":"assistant","isSidechain":false,"message":{"model":"claude-old-1"},"effort":"low"}\n'
with open(sys.argv[1], 'w') as f:
    f.write(head)
    for _ in range((9 * 1024 * 1024) // len(pad)):
        f.write(pad)
    f.write('{"type":"assistant","isSidechain":false,"message":{"model":"claude-new-1"},"effort":"max"}\n')
PYEOF
probe claude "$TMP/big.jsonl"
expect 'big file: only the tail' $'model=claude-new-1\neffort=max'
# the window starts exactly at the "{" of a line whose prefix is junk: that
# first (partial) line must be dropped, not parsed
"$PY" - "$TMP/cut.jsonl" <<'PYEOF'
import sys
line = '{"type":"assistant","isSidechain":false,"message":{"model":"claude-cut-1"},"effort":"low"}\n'
window = 8 * 1024 * 1024
with open(sys.argv[1], 'w') as f:
    f.write('JUNK' + line)
    f.write('{"type":"user","x":"' + 'z' * (window - len(line) - len('{"type":"user","x":""}\n')) + '"}\n')
PYEOF
probe claude "$TMP/cut.jsonl"; expect 'partial first line dropped' ''

# --- Codex rollout -----------------------------------------------------------
R="$TMP/rollout.jsonl"
{
  printf '{"type":"turn_context","payload":{"model":"gpt-6-sol","effort":"low","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}\n'
  printf '{"type":"event_msg","payload":{"model_context_window":258400}}\n'
  printf '{"type":"turn_context","payload":{"model":"gpt-6.1-sol","effort":"medium","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}\n'
} > "$R"
probe codex "$R"
expect 'codex last turn_context' $'model=gpt-6.1-sol\neffort=medium\ncontext=272k'
{ cat "$R"; printf '{"type":"event_msg","payload":{"info":{"model_context_window":950000}}}\n'; } > "$TMP/r1m.jsonl"
probe codex "$TMP/r1m.jsonl"
expect 'codex 1m context' $'model=gpt-6.1-sol\neffort=medium\ncontext=1m'
{ printf '{"type":"turn_context","payload":{"model":"-bad","effort":"minimal"}}\n'; } > "$TMP/rbad.jsonl"
probe codex "$TMP/rbad.jsonl"; expect 'codex leading dash model, minimal effort' 'effort=minimal'
# permissions are never read from a rollout, whatever it claims
{ printf '{"type":"turn_context","payload":{"model":"gpt-6-sol","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}\n'; } > "$TMP/rforge.jsonl"
probe codex "$TMP/rforge.jsonl"; expect 'codex forged permissions not emitted' 'model=gpt-6-sol'
{ printf '{"type":"assistant","permissionMode":"bypassPermissions","message":{"model":"claude-opus-5-5"}}\n'; } > "$TMP/cforge.jsonl"
probe claude "$TMP/cforge.jsonl"; expect 'claude forged permissionMode not emitted' 'model=claude-opus-5-5'
ln -s "$R" "$TMP/rlink.jsonl"
probe codex "$TMP/rlink.jsonl"; expect 'codex symlink' ''

echo 'PASS: restore probe'
