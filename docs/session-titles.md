# Session titles in cmux

The launcher owns transport from native session names to the exact starting
cmux tab. The paired harness owns the policy for choosing names from task goals.
Neither title broker starts an inference request or edits a native session file.

## Codex

The existing Codex broker follows the latest valid `session_index.jsonl` entry
for the exact SessionStart ID. Native `/rename` and metadata API name updates
use the same display path. Profile suffixes identify the launching harness.

## Claude

Claude launches now start a broker before the interactive runtime. Each launch
gets a separate private `launch.*` directory under
`<harness>/.harness/claude/.cmux-title-sync/`.

A paired harness's main SessionStart command hook forwards its unchanged JSON
stdin to the inherited helper:

```sh
"$CLAUDE_CMUX_TITLE_HELPER" --claude-session-start
```

The launcher supplies `CLAUDE_CMUX_TITLE_REQUEST_FILE` and
`CLAUDE_CMUX_TITLE_STATE_DIR`. A hook must not guess another session or reuse a
different launch's request. The helper discovers the live Claude ancestor PID
and hands over the exact session ID and transcript path. Repeated handoffs
support `/clear`, resume and fork without restarting the launcher broker.

The reader follows top-level records for that exact session. The latest
`custom-title` wins over all `ai-title` records, including a later automatic
record. Thus native `/rename` still appears after a harness or SDK title update.
Idle, unchanged transcripts are not rescanned. A later native event cannot
overwrite an externally changed tab once the broker has observed its own prior
title. The first write accepts the matching native title and known activity
spinners, retries transient shell titles or unavailable reads, and preserves
an unrelated pre-existing tab name.

## Ownership and fallback integration

The broker emits a private `active.json` containing owner, launcher and broker
PIDs, session/workspace/surface identity, UID and heartbeat time. It contains
no prompt, title text or command output. A separate heartbeat remains active
during bounded cmux calls, so a legacy hook cannot mistake a slow write for a
dead owner. On exit, the broker verifies its private owner seed, removes only its known
state files and removes the empty launch directory.

A paired harness may retain an older Stop/SessionEnd title-persistence hook.
That hook should skip only when the ACK is same-UID, exact-session, fresh and
its three processes are alive. Release legacy-owned tab names before handing
the new session to the broker, not in a concurrent SessionStart hook. Successful
broker writes also record the exact legacy ownership tuple for the next launch.

Missing cmux, missing metadata or failed IPC must not prevent the CLI from
starting. Existing running sessions retain their launcher's code; start a new
session after upgrading. Raw/direct and launchpad Claude routes share this
integration. The installed helper keeps its existing filename for compatibility.

## Tests

`test/test-claude-cmux-title-sync.sh` covers title priority, manual overrides,
repeated handoffs and slow-command heartbeats with disposable fixtures. The
Codex title suites continue to cover exact-session indexing and process ancestry.
