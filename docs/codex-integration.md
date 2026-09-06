# Codex CLI integration

This document describes the maintained native Codex path. It replaces the original implementation plan and reflects the current generated layout and compatibility policy.

## Native Codex versus gateway mode

The command names are intentionally distinct:

```text
<prefix> codex             native OpenAI Codex CLI
<prefix> codex-gateway     Claude Code through a Codex-compatible gateway
```

Native Codex receives a project-scoped `CODEX_HOME`. Gateway mode remains a Claude Code launch and does not use Codex profiles or sessions.

## Binary resolution

The launcher resolves native Codex in this order:

1. `HARNESS_CODEX_BIN`, as an executable path or command name;
2. `codex` from `PATH`;
3. `/Applications/Codex.app/Contents/Resources/codex` only when `HARNESS_CODEX_ALLOW_APP_FALLBACK=1`.

The app fallback is opt-in because the bundled CLI may be older than the terminal installation.

A global `codex` wrapper is also defined after sourcing `aliases.zsh`. When a direct Codex invocation includes `--cd`/`-C` pointing at a registered project, the wrapper prepares the matching project `CODEX_HOME` before delegating to the real binary. Set `HARNESS_LAUNCHER_DISABLE_CODEX_WRAPPER=1` to disable this behavior.

## Generated layout

Before launch, `codex-home-prepare.sh` converges:

```text
<project>/.harness/codex/
├── config.toml
├── fast.config.toml
├── base.config.toml
├── sol.config.toml
├── astra.config.toml
├── plan.config.toml
├── rich.config.toml
├── AGENTS.md
├── auth.json -> ~/.codex/auth.json
├── hooks.json
├── skill-catalog.json
├── surface.config.toml
├── skills/
├── agents/
├── plugins/
├── sessions/
└── history.jsonl
```

The exact set depends on available source files and installed Codex features. The directory is generated runtime state and should be ignored by Git.

When `config/codex-surface.json` exists, preparation uses its exact skill, Claude-plugin, Codex-only, and MCP allowlists instead of importing every available source. See [Codex surface manifests](codex-surface.md) for schema version `1`, profile selection, and warm-path invalidation.

## Profiles

Codex 0.134.0 and newer load named profiles from `<profile>.config.toml` files with top-level keys. The launcher does not generate legacy `[profiles.<name>]` tables.

```toml
# config.toml
model = "gpt-5.6-terra"
model_reasoning_effort = "medium"

# fast.config.toml
model = "gpt-5.6-luna"
model_reasoning_effort = "low"

# plan.config.toml
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
sandbox_mode = "read-only"
approval_policy = "on-request"
```

Current routing:

| Profile | Model | Effort | Additional policy | Intent |
| --- | --- | --- | --- | --- |
| default | GPT-5.6 Terra | medium | Runtime defaults | Everyday work — recommended default |
| fast | GPT-5.6 Luna | low | Runtime defaults | Quick, shallow work |
| base | GPT-5.6 Terra | medium | Runtime defaults | Everyday work — recommended default |
| sol | GPT-5.6 Sol | medium | Runtime defaults | Stronger main model — slower |
| astra | GPT-6 Astra | medium | Runtime defaults | Explicit frontier-model selection |
| plan | GPT-5.6 Sol | high | read-only, on-request | Deep planning — slower |
| rich | GPT-5.6 Sol | high | Runtime defaults | Deep work — slowest normal preset |

These profiles are task-oriented operational presets, not OpenAI default-effort claims. This launcher deliberately uses Luna/low for the speed preset and Sol/high for the deep plan and rich presets; an unscoped model picker may use a different general starting effort. Effort can still be overridden independently in native Codex. Reserve max or multi-agent ultra execution for exceptional workloads rather than normal profile defaults.

`<prefix> codex astra` selects the native Astra profile explicitly. It is also
available as the last Profile menu entry, preserving existing numeric choices.
The menu reads the generated model and effort; native `--model` and `-c` options
still pass through. Availability is enforced by the selected Codex CLI/account;
the launcher does not issue a paid readiness probe or silently fall back.
`sol` remains Sol. A prior manual Astra edit to generated `sol.config.toml` is
restored on preparation; select `astra` instead for a persistent launch choice.
The new profile participates in atomic publication and warm-cache drift repair.

The main profile does not downgrade reviewers: reviewer subagents route independently to Sol/medium by default and may explicitly escalate effort for unusually risky work.

Generated homes request `model_context_window = 1000000`; Codex clamps that
request to the selected model's actual maximum. The launcher pins
`model_auto_compact_token_limit = 414000`, half of the effective 828400-token
window currently reported by the GPT-5.6 Luna/Terra/Sol models, to leave
headroom for the compaction turn and per-turn resend cost. The opt-in Astra
profile inherits this existing policy. Verify its effective context in a native
session before changing the threshold; the public API context window and API
pricing thresholds do not establish native account context or subscription cost.

With Codex CLI 0.153.0 or newer, generated homes also enable
`features.context_management.experimental_mode`. Eligible ChatGPT Plus, Pro,
or Pro Lite sessions on the Codex backend use notes and searchable history to
preserve details within a long-running thread. This is separate from
cross-session `memories`. The launcher omits the nested setting for older
clients because Codex 0.152.1 rejects it during bootstrap; API-key sessions,
custom providers, and temporary structured threads remain excluded upstream.

## Launcher MCP surface policy

The project-owned `config/launcher.env` is the sole opt-in authority for
`HARNESS_MCP_SURFACE_POLICY`; a caller's inherited value cannot opt a project
in. Empty or omitted resolves to legacy behavior, preserving the native Codex
`work` selector and its manifest MCP profile.

`single-full-compat` is the transition setting. A direct `work` selector is
accepted with a deprecation warning and launches the full user-facing surface.
`single-full` is the enforced setting: that retired direct selector is rejected.
For either opt-in setting, the launcher clears an inherited
`HARNESS_CODEX_MCP_PROFILE` before preparing Codex. The manifest's
`mcp.default_profile` then selects the enabled Codex MCP set; this does not
replace the generic multi-profile manifest resolver for projects that keep the
legacy policy.

The user-facing surface choice is aligned between Claude and Codex under this
policy. Their definition-source systems are still separate: Claude keeps its
own configuration path, while Codex resolves the manifest and its selected MCP
definition sources. Kiro's native light/full choice is unchanged, including
for opt-in projects.

## MCP translation

Preparation reads, in order:

```text
<project>/.mcp.json
<project>/.mcp.local.json
<project>/mcp.local.json
```

Local files extend the committed file. Duplicate server names are rejected.

Supported input forms include HTTP and stdio servers:

```json
{
  "mcpServers": {
    "remote-docs": {
      "type": "http",
      "url": "https://mcp.example.invalid/api"
    },
    "local-docs": {
      "command": "npx",
      "args": ["-y", "@example/docs-mcp"],
      "env": {
        "LOG_LEVEL": "warn"
      }
    }
  }
}
```

Generated TOML uses `[mcp_servers.<name>]` and optional `.env` tables. Authorization headers that reference an environment variable are converted to Codex's environment-variable field rather than storing the bearer value.

Local environment values can be inherited from `.claude/settings.local.json`. Keep that file out of version control and never log its contents.

### Allowlisted global MCPs

`$HOME/.codex/config.toml` remains the sole authority for user-global Codex MCP definitions. A project can project specific definitions only when both boundaries agree:

1. its trusted `config/launcher.env` sets `HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST`, such as `"docs,jira"`; and
2. `config/codex-surface.json` includes `codex-global-allowlist` in `mcp.definition_sources`.

Every native entrypoint (prefix shortcuts, the direct `codex --cd` wrapper, and the TUI) normalizes the setting after loading `launcher.env`: whitespace is trimmed, duplicates preserve first occurrence, and an empty or absent value is unset before `codex-home-prepare.sh` runs. The preparer does not execute `launcher.env` itself. Exact profiles decide which projected names are enabled; a global definition never silently bypasses that profile boundary. A selected global name that duplicates a project, local, or product-managed definition fails closed.

Global definitions accept only portable Codex MCP fields. Static `env` and `http_headers` are rejected; use `env_vars`, `env_http_headers`, or `bearer_token_env_var` references instead. This keeps credentials in the process environment rather than generated TOML.

## AGENTS.md, rules, and hooks

`CODEX_HOME/AGENTS.md` is a generated file, not a symlink. Preparation uses the project's Codex-native rule compiler when available, then falls back to compatible project rules or `CLAUDE.md`. A Codex response-language supplement is appended without changing the source files.

Supported hooks are translated through `codex-hook-adapter.sh`. Hook parity is intentionally partial. A hook that depends on Claude-only payloads or lifecycle semantics should remain unwired until it has a Codex-specific test.

Legacy project-root `.codex` directories can conflict with generated state. The migration/preparation path quarantines stale layouts rather than merging them silently.

## Skills and generated agents

Without a surface manifest, `CODEX_HOME/skills` is a per-skill merge from available sources:

```text
~/.codex/skills
~/.agents/skills
<project>/.claude/skills
<project>/.codex-only/skills
```

Use `.codex-only/skills` when a skill should not appear in Claude Code.

With a surface manifest, only selected routes are linked. Explicit-only skills remain callable but are excluded from implicit prompt matching. Divergent duplicate hashes require an explicit source choice; unselected routes are disabled by exact `SKILL.md` path without deleting their installation.

Portable Claude agent definitions can be converted into Codex agent TOML. Model tiers map by capability:

```text
haiku  → GPT-5.6 Luna, low
sonnet → GPT-5.6 Terra, medium
opus   → GPT-5.6 Sol, medium
```

Generated agent files are output. Edit the source agent definition instead.

## Bundled plugins and browser support

Terminal Codex can materialize supported entries from the bundled OpenAI marketplace:

- Computer Use
- Chrome bridge

The desktop-only Browser plugin remains pruned from terminal project homes. Browser automation can still use a separately configured CDP/browser-harness path.

The Chrome native host has used several executable names across app and cache versions. Discovery prefers the current platform/architecture path and then known legacy names:

```text
extension-host/macos/<arch>/Codex for Chrome
extension-host/macos/<arch>/ChatGPT for Chrome
extension-host/macos/<arch>/extension-host
```

Plugin synchronization rules:

- synchronize the complete marketplace before deriving plugin version or browser hash;
- atomically replace materialized content when any bundled plugin changes;
- serialize shared `~/.codex` writes with `/usr/bin/lockf`;
- trust only exact browser-client SHA-256 values for `node_repl`;
- do not trust the project-writable `CODEX_HOME` or all of `~/.codex` as code paths.

## Auth behavior

`CODEX_HOME/auth.json` links to the active native Codex auth file. This keeps login selection global while sessions, MCP config, rules, skills, and history remain project-scoped.

The launcher never copies refresh tokens between auth stores. Login and account switching belong to the native Codex CLI or the user's account-management tooling.

## Session commands

Generated homes expose the saved Codex thread name on both native TUI title
surfaces:

```toml
[tui]
terminal_title = ["activity", "thread-title", "project-name"]
status_line = ["thread-title", "model-with-reasoning", "git-branch", "context-remaining", "branch-changes", "run-state", "task-progress", "five-hour-limit", "weekly-limit"]
```

After `/rename <name>`, Codex refreshes the footer and emits the configured
terminal title through OSC 0. The native non-cmux fallback renders activity,
then the thread name, then the repository project name. The footer prioritizes
context remaining ahead of branch changes, and native `update_plan` progress
ahead of account-limit meters. Before a rename, `thread-title` can
fall back to the thread ID. Change these defaults in `codex-home-prepare.sh`,
not in a generated project `config.toml`.

Inside cmux, the launcher starts a fail-open title broker under the live
launcher/Codex process ancestry. The short-lived `SessionStart` hook hands the
broker only the exact session ID and Codex owner PID; the broker then replaces
the native composite title with `<thread name> | <profile>`. It reads only that
session ID from the project's
`session_index.jsonl`, targets the exact starting tab surface, and never
renames the workspace. Missing cmux state or thread metadata is a silent no-op.
Because Codex trusts hook commands by hash, review a newly generated or changed
command through `/hooks` when Codex requests it.

```text
<prefix> codex                 new session with base profile
<prefix> codex fast            new session with fast profile
<prefix> codex astra           new session with Astra at medium effort
<prefix> codex [profile] work   new session with the work MCP surface (any profile)
<prefix> codex continue        resume --last
<prefix> codex resume          resume picker
```

The interactive launcher also supports forking the last Codex session. Extra runtime arguments pass through after launcher parsing.

When native Codex is selected interactively, the Profile menu offers the model
profiles only; the work surface is a `🔌 MCP surface` toggle on the summary
screen (the same UX as the Claude/Kiro `light` toggle) and combines with any
profile. `default` leaves `HARNESS_CODEX_MCP_PROFILE` unset and uses the
manifest's minimal default surface; `work` exports
`HARNESS_CODEX_MCP_PROFILE=work` before preparing `CODEX_HOME`, so preparation
and the launched process use the same approved work integrations. The Happy
wrapper and the work surface are mutually exclusive (the later toggle wins).
Backing out never silently upgrades the surface.

The global MCP projection is part of the exact-surface warm fingerprint. A changed allowlist or selected `$HOME/.codex/config.toml` definition triggers cold preparation; unrelated global MCPs do not. `CODEX_HOME` remains project-scoped, so one harness cannot publish another harness's generated MCP state.

## Verification

Generated TOML proves what the launcher intended, but a real session proves what Codex loaded. For model-routing changes:

1. create a disposable project with `config/launcher.env`;
2. run one real Codex request per distinct profile;
3. inspect the session JSONL `turn_context` for `model`, `effort`, and sandbox values;
4. remove the disposable project;
5. confirm no real project gained tracked changes.

Automated coverage lives in:

```text
test/test-codex-home-prepare.sh
test/test-launcher-codex-cli.sh
test/test-launcher-codex-tui.sh
test/test-launcher-codex-gateway.sh
test/test-codex-hook-adapter.sh
test/test-codex-global-mcp-drift.sh
```

## Inspect generated profile settings

Use the installed resolver to inspect a prepared home without running Codex,
refreshing credentials, changing hook approval, or regenerating files:

```bash
python3 "$(brew --prefix harness-launcher)/share/harness-launcher/codex-surface.py" \
  inspect --codex-home /path/to/project/.harness/codex --profile astra
```

The JSON reports allowlisted model, effort, context, sandbox, and approval values
with their base or profile file provenance. Provider URLs, credentials, MCP
arguments, and hook commands are omitted. A missing profile fails instead of
silently displaying the base model.

`output_consistency` compares generated outputs with their last preparation
stamp. It does not validate current source inputs, CLI/environment overrides,
account availability, or the model loaded in a running session. Unknown values
remain unknown; configured context is not a verified native model limit.

New preparation stamps also separate TOML diagnostics:

- `managed_settings_consistency` covers model, effort, policy, and other settings.
- `trust_settings_consistency` tracks project trust separately; a change is never
  treated as harmless UI state or automatically approved.
- `runtime_metadata_changed` tracks only `tui.model_availability_nux`. Unknown
  settings remain part of the managed comparison.

These fields do not replace full output hashes or alter warm-cache repair. A
legacy stamp reports unknown diagnostics until normal preparation writes them.

Homebrew preparation through its compatibility `share` link uses the equivalent
`opt` package path when both resolve to the same directory. This keeps generated
hook command spelling stable. It does not approve hooks or redirect a source
checkout to a different installed package.

The Codex hook adapter sets `HARNESS_HOOK_RUNTIME=codex` for its child hook only.
Shared hooks should prefer an explicit runtime identity over a stale
`CODEX_HOME` inherited by a Claude session.
