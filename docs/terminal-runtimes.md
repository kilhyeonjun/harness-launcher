# Terminal runtimes

The launcher runs inside several terminal hosts: herdr, Orca, cmux, or a plain
terminal. Each host exports its own variables and expects its own behavior from
an agent. Since 0.36.0 the launcher detects exactly one host per launch, removes
every other host's variables, and enables host-specific features only for the
detected host. This guide is the runtime-generic reference; Orca-only material
stays in [Orca ADE integration](orca-integration.md).

## Detection

Detection order is `herdr > orca > cmux > plain`. The first match wins and
exactly one value is used:

| Runtime | Markers |
| --- | --- |
| herdr | `HERDR_ENV=1`, `HERDR_PANE_ID` non-empty, and `HERDR_SOCKET_PATH` names a socket |
| orca | `ORCA_TERMINAL_HANDLE` non-empty, or `TERM_PROGRAM=Orca` |
| cmux | `CMUX_WORKSPACE_ID`, `CMUX_TAB_ID` and `CMUX_SURFACE_ID` all non-empty |
| plain | none of the above |

herdr ranks first because a herdr pane inherits the variables of whatever
started its server (Orca or cmux), yet the pane belongs to herdr. Its socket
test rejects `HERDR_*` variables left exported after the pane is gone. Orca
outranks cmux because cmux variables linger inside Orca terminals.

A launch without a terminal, meaning stdin or stdout is not a TTY, is runtime
`plain` regardless of markers. SDK hosts such as Paseo inherit their daemon's
markers but host no terminal.

## Scrub and announcement

Every launch scrubs the environment before doing anything else, in this order:

1. Unset `CODEX_HOME` and `ORCA_CODEX_HOME` when they are equal (Orca's managed
   home, see [CODEX_HOME sanitization](orca-integration.md#codex_home-sanitization)).
2. Unset `CMUX_*` unless the runtime is cmux.
3. Unset `ORCA_*`, and `TERM_PROGRAM` when it is `Orca`, unless the runtime is
   orca.
4. Unset `HERDR_*` unless the runtime is herdr.
5. Export `HARNESS_TERMINAL_RUNTIME` with the chosen value.

The scrub runs in the agent's process, never in your interactive shell. The
cmux title brokers start only when the runtime is `cmux`.

When the runtime is herdr, the launcher writes the run directory to the
controlling terminal as an `OSC 7` sequence: ESC `]7;file://` followed by the
percent-encoded absolute directory (empty host, so `file:///...`) and BEL. herdr
uses it to type a pane restore in the right directory. No other runtime
receives the sequence.

## Ownership

| Concern | Owner |
| --- | --- |
| Runtime detection, scrub, `OSC 7`, Codex hook rows, resume mapping | launcher |
| Provider-session recorder command (`harness-session-provider-record`) | launcher |
| Registering the recorder as a Claude hook | each harness, through its own hook shim |
| Workspace UI, panes, status display | the terminal host |
| Policy hooks, auth, MCP, skills, model presets | launcher and harness, never the host |

## Codex hook registry

Host status hooks for Codex are rows of one registry in `codex-home-prepare.sh`,
each enabled per harness by a literal assignment in that harness's
`config/launcher.env`. The process environment is ignored, so every caller
generates the same `hooks.json`.

| Runtime | Opt-in | Script | Events | Argument | Timeout (seconds) |
| --- | --- | --- | --- | --- | --- |
| orca | `HARNESS_ORCA_AGENT_HOOKS=1` | `$HOME/.orca/agent-hooks/codex-hook.sh` | `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop` | none | 5 |
| herdr | `HARNESS_HERDR_AGENT_HOOKS=1` | `$HOME/.codex/herdr-agent-state.sh` | `SessionStart` | `session` | 10 |

Both rows run the same status-only, fail-open command:

```text
/bin/sh -c 's="<script>"; [ -x "$s" ] && { /bin/sh "$s" [argument] >/dev/null 2>&1; exit 0; }; cat >/dev/null'
```

The script's output is discarded and the command always exits 0, so a host
script can never block a tool or decide a permission. When the script is not
executable the command only drains stdin. An opted-in row is written whether or
not the script exists, so installing a host integration later needs no new
prepare. Rows are appended after every existing entry in registry order.
Without an opt-in, `hooks.json` is identical to earlier releases. After
enabling or disabling an opt-in, rerun the harness's Codex hook trust step.
Isolated sessions use fresh Codex home clones without that trust, so host status
for isolated Codex sessions is not provided.

## Resume routing

A host restores an agent by re-running its command with `--resume <id>` (Claude)
or `codex resume <id>` (Codex). For profiles that default to isolated sessions,
the launcher maps that single UUID to the isolated session that owns it. Owners
are counted together:

- For Claude, the session directory whose name equals the id (the mapping from
  0.33.0).
- For Claude, every current-harness session whose `provider-sessions` file has a
  line `claude <id>`. This owner maps only when the transcript `<id>.jsonl`
  exists under that session's Claude project directory.
- For Codex, the one session whose Codex home holds the matching rollout file.

Exactly one owner maps. Two or more owners is rejected as ambiguous. No owner
keeps the usual reject message. The session must belong to the current harness.

`harness-session-provider-record` is the recorder. It reads a Claude
`SessionStart` hook payload on stdin, handles the sources
`startup|resume|clear|compact|fork`, and appends `claude <uuid>` to
`<state>/sessions/<HARNESS_SESSION_ID>/provider-sessions` for UUID ids only. It
is silent and exits 0 in every other case. The launcher only ships the command;
the kh, gp and gd harnesses register it through their own hook shim
(`core/hooks/session-provider-record.sh`), which is a separate harness change.
Until a harness registers it, `/clear` ids stay unmapped.

Limits:

- Restore fails closed before 0.36.0: earlier launchers cannot map ids created
  after `/clear`.
- The transcript lookup assumes Claude runs in the session root. A session
  started with `--cwd <subdir>` keeps its transcripts under a different project
  directory, so its `/clear` ids stay unmapped and fail closed with the usual
  reject message. Recover with `<prefix> --isolated-session <uuid> resume`.
- A kh isolated Codex session is not covered by the herdr or Orca status
  hooks, because its Codex home clone lacks hook trust.
- A plain `<prefix>` launch that opens the interactive picker has no session id
  to map.

## Host prerequisites

These are one-time setup steps on the machine, verified on macOS.

herdr:

- Put this line in `~/.zshenv`. It skips the Kiro CLI PTY wrapper, which hides
  agents from herdr, and only inside herdr panes:

  ```zsh
  if [[ -n "$HERDR_ENV" ]]; then export PROCESS_LAUNCHED_BY_Q=1; fi
  ```

- Install the Claude integration with `herdr integration install claude`.
- For Codex, install with a pinned `CODEX_HOME` so herdr writes to the user's
  own home, then opt the harness in:

  ```bash
  env -u CODEX_HOME CODEX_HOME="$HOME/.codex" herdr integration install codex
  ```

  and add `HARNESS_HERDR_AGENT_HOOKS=1` to the harness `config/launcher.env`.

Oh My Zsh:

- Set `zstyle ':omz:update' mode reminder` in `~/.zshrc`. An update prompt at
  shell start would swallow the resume command a host types into a restored
  pane.

Orca setup is in [Orca ADE integration](orca-integration.md).
