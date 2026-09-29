# SDK host passthrough (`--passthrough`) design

Status: approved direction by the user on 2026-09-29 ("근본 추천으로 검토후 진행"). Scale: HIGH (public launcher argv contract used by terminals, Orca, and SDK hosts). Design and implementation each need an independent review. Release follows `v0.33.0` (Orca main host): rebase onto it, then tag `v0.34.0`.

Revision 2 applies the independent design review: Codex app-server support is removed from this change (H1), and the Claude argv ordering, forced-thinking, and session-flag rules are now explicit (M1, M2, M5).

## Problem

SDK hosts such as Paseo (<https://paseo.sh>, v0.10.1) spawn Claude Code through the Claude Agent SDK. A provider may replace the executable with an argv prefix; the host then appends its own arguments and talks stream-json over piped stdio. With the prefix `harness-auto claude base` the launcher keeps harness env, MCP, hooks and profile selection, but two defects block real use. Both were reproduced on 2026-09-29 against installed `v0.32.0`:

1. Keyword capture. The Claude keyword loop matches launcher keywords at any position, including option values. The SDK sends `--permission-mode plan` and `--permission-mode acceptEdits` for Plan Mode and Accept File Edits, and `--effort high|low|medium|xhigh|max` for thinking choices. Observed: `error: option '--permission-mode <mode>' argument '--model' is invalid` (Plan Mode) and `Warning: Unknown --effort value '--model'` (effort).
2. Launcher-appended defaults override the caller. The launcher appends `--effort <mode effort>` after all caller arguments, so a host's explicit effort loses.

`--` cannot be repurposed: it is already the documented prompt boundary (`test-session-isolation-routing.sh`: "After the explicit prompt boundary, control-looking text is prompt content").

## Interface

### P1 Claude `--passthrough`

- Syntax: `[launcher prefix] [provider] [keywords...] --passthrough [claude arguments...]`, through `<prefix>`, `harness-exec`, or `harness-auto claude`.
- Every token after the first `--passthrough` is forwarded to Claude verbatim and in order, including a later `--passthrough`. None is interpreted as a launcher keyword. The first marker itself is not forwarded.
- `--passthrough` implies a direct launch (no TUI) even without a mode keyword.
- Argv order in passthrough mode: `claude <keyword-derived args> <launcher effort/thinking/name args> [--mcp-config <harness MCP>] --exclude-dynamic-system-prompt-sections <passthrough args>`. Light mode keeps its existing `--strict-mcp-config --mcp-config <light file>` prefix. The boolean `--exclude-dynamic-system-prompt-sections` closes the launcher block, so the variadic `--mcp-config` can never absorb a caller prompt, and a caller `--` cannot turn launcher flags into prompt text.
- Caller wins, only for passthrough tokens:
  - `--model` or `--model=*` present: drop every keyword-derived `--model <value>` pair.
  - `--effort` or `--effort=*` present: do not append the launcher `--effort`. Append the forced-thinking `--settings '{"alwaysThinkingEnabled":true}'` only when the caller effort is `xhigh` or `max` and the caller passed none of `--thinking`, `--thinking=*`, `--max-thinking-tokens`, `--max-thinking-tokens=*`, `--settings`, `--settings=*`.
  - `--permission-mode` or `--permission-mode=*` present: drop keyword-derived `--permission-mode <value>` pairs (`bypass`, `acceptEdits`, `dontAsk`).
- Session flags: if a launcher session keyword (`continue`, `resume`) was given and the passthrough contains any of `-c`, `--continue`, `-r`, `-r*`, `--resume`, `--resume=*`, `--session-id`, `--session-id=*`, `--fork-session`, fail with exit 2 before launching.
- Unchanged in passthrough mode: harness env export (GH token, `.claude/settings.local.json` env, observability), gateway provider env for `kiro`/`codex-gateway` (a full model ID from the caller is not mapped to `ANTHROPIC_DEFAULT_*`), the autocompact override, run directory resolution, and TTY-only title bootstrap.
- Paths that do not use the Claude keyword loop (`claude-management`, `checkup`, `codex`, `codex-smoke`, `kiro-cli`) do not accept the marker; Codex and Kiro receive it as an ordinary argument.

### P2 Isolation routing

`harness_session_isolation_default_route` currently returns `invalid` for the unknown flag `--passthrough`. After the change, in the Claude branch, `--passthrough` switches to passthrough scanning: bare words are positional (break, then `isolate`), and Claude option classification (`reject`, `legacy`, value-taking, `invalid`) is unchanged. `--` still ends scanning. The Codex branch is unchanged. Non-interactive launches keep returning `legacy` before any argv inspection.

### P3 `harness-auto`

No code change. `harness-auto claude … --passthrough …` reaches `harness-exec` with the argv unchanged.

## Out of scope (reported, not changed)

- Codex through SDK hosts. Paseo starts one `codex app-server` per agent with no working directory (the daemon's cwd) and sends each thread's `cwd` inside the protocol (`thread/start`, `turn/start`). The launcher's cwd-based profile boundary and `--cd` validation therefore cannot bind a Paseo Codex session to a harness. Supporting it needs a separate design: a profile-bound app-server plus a per-thread cwd check inside the harness boundary.
- Codex `-p` injection for profile-rejecting subcommands (`app-server`, `login`, `debug models`, …), which fails today with `Error: --profile only applies to runtime commands`.
- The shell auto-routing wrappers (`_harness_launcher_auto_runtime`) share the keyword-capture root cause (`claude -p plan` selects opusplan). Fixing them changes the meaning of shell shortcuts.
- `validate_codex_working_dirs` misses the attached `-C<dir>` form.

## Tests (RED first)

- Direct Claude, stub argv: `base --passthrough` plus the Paseo SDK argv gives the SDK tokens contiguous and in order, exactly one `--model claude-sonnet-5-5`, exactly one `--effort high`, `--permission-mode plan` intact, no `opusplan`, no forced thinking, `--exclude-dynamic-system-prompt-sections` and the harness `--mcp-config`, and no marker.
- `rich --passthrough --permission-mode acceptEdits --effort=low`: verbatim, no launcher `--effort`, no forced thinking, keyword model kept.
- `--passthrough` alone launches directly without launcher model/effort.
- `bypass --passthrough --permission-mode=plan`: the keyword permission pair is dropped.
- `base --passthrough resume fast`: forwarded verbatim; no session flag.
- `base --passthrough --verbose -- 'prompt text'` and `base --passthrough 'prompt text'`: the prompt is last, launcher flags precede it, and the MCP value list is closed by the boolean flag; the same for `light` in a `legacy` MCP policy harness.
- `base --passthrough --effort max`: forced thinking appended; `--effort max --thinking adaptive`: not appended.
- `continue --passthrough --resume=ID`: exit 2, no launch.
- `--passthrough --passthrough`: the second marker is forwarded.
- Without the marker, `base --verbose` is byte-identical to `v0.32.0`.
- Routing: `legacy 0 base --passthrough --permission-mode plan`; `isolate 1 base --passthrough --permission-mode plan`; `reject 1 base --passthrough --resume=x`; `isolate 1 base --passthrough continue`; `invalid 1 base --passthrough --mcp-config x`.
- `harness-auto claude base --passthrough --permission-mode plan` reaches `harness-exec` unchanged.

## Docs and release

- `docs/paseo-integration.md`: provider JSON (`harness-claude` with `["/opt/homebrew/bin/harness-auto","claude","base","--passthrough"]`), the workspace policy (local workspaces inside a registered harness; Paseo-managed worktrees under `~/.paseo/worktrees` are outside every boundary and fail closed), env hygiene (start the daemon from a login shell or the app, never from inside an agent session; do not set `HARNESS_SESSION_ISOLATION=1` in the daemon env), relay off by default, and known limits (Codex unsupported, the diagnostic `auth status` probe receives launcher flags, gateway model mapping).
- README link, CHANGELOG `v0.34.0`, and Formula packaging following the `v0.33.0` docs pattern.
