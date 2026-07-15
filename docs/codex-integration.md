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

| Profile | Model | Effort | Additional policy |
| --- | --- | --- | --- |
| default | GPT-5.6 Terra | medium | Runtime defaults |
| fast | GPT-5.6 Luna | low | Runtime defaults |
| base | GPT-5.6 Terra | medium | Runtime defaults |
| plan | GPT-5.6 Sol | high | read-only, on-request |
| rich | GPT-5.6 Sol | high | Runtime defaults |

These profiles are task-oriented operational presets, not OpenAI default-effort claims. This launcher deliberately uses Luna/low for the speed preset and Sol/high for the deep plan and rich presets; an unscoped model picker may use a different general starting effort. Effort can still be overridden independently in native Codex. Reserve max or multi-agent ultra execution for exceptional workloads rather than normal profile defaults.

Context-window and auto-compaction values are not pinned. Codex model metadata controls them.

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
opus   → GPT-5.6 Sol, high
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
terminal_title = ["activity", "project-name", "thread-title"]
status_line = ["thread-title", "model-with-reasoning", "git-branch", "branch-changes", "run-state", "context-remaining", "five-hour-limit", "weekly-limit"]
```

After `/rename <name>`, Codex refreshes the footer and emits the configured
terminal title through OSC 0. Terminals such as cmux use that value as the tab
title. Before a rename, `thread-title` can fall back to the thread ID;
`project-name` keeps the terminal tab recognizable. Change these defaults in
`codex-home-prepare.sh`, not in a generated project `config.toml`.

```text
<prefix> codex                 new session with base profile
<prefix> codex fast            new session with fast profile
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
