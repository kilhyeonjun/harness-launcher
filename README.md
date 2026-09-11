# harness-launcher

[![CI](https://github.com/kilhyeonjun/harness-launcher/actions/workflows/ci.yml/badge.svg)](https://github.com/kilhyeonjun/harness-launcher/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/kilhyeonjun/harness-launcher)](https://github.com/kilhyeonjun/harness-launcher/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A profile-aware Zsh launcher for Claude Code, OpenAI Codex CLI, and Kiro CLI. Register one or more project directories, give each a short command, and keep runtime state isolated per project.

```text
wh             interactive runtime and mode picker
wh base        Claude Code with the base preset
wh codex fast  Codex CLI with the fast profile
wh kiro-cli    Kiro CLI with an isolated KIRO_HOME
```

## Why use it?

AI coding CLIs usually keep sessions, configuration, skills, and MCP servers in a global home directory. That gets messy when you work across projects with different trust boundaries.

`harness-launcher` keeps the command short while preparing project-scoped runtime homes:

```text
<project>/.harness/codex
<project>/.harness/kiro
```

It also provides consistent `fast`, `base`, `opus`, `plan`, `rich`, and `fable` presets, optional gateway routing for Claude Code, tab completion, and an interactive TUI.

## Requirements

- macOS
- Zsh
- Python 3.11 or newer (`tomllib` is required by the Codex surface validator)
- At least one supported runtime:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
  - [OpenAI Codex CLI](https://github.com/openai/codex)
  - [Kiro CLI](https://kiro.dev/cli/)

Optional tools:

- [`gum`](https://github.com/charmbracelet/gum) for a richer menu
- [`happy`](https://github.com/slopus/happy) for Happy-managed sessions
- Node.js when using local Claude gateway health checks

## Install

### Homebrew

```bash
brew tap kilhyeonjun/tap
brew install harness-launcher
```

Upgrade later with:

```bash
brew update
brew upgrade harness-launcher
```

### From source (disabled)

Standalone source installation is disabled due to an unfixable TOCTOU vulnerability in portable shell installers. Use Homebrew instead. Existing source installations should migrate:

```bash
brew tap kilhyeonjun/tap
brew install harness-launcher
# Then remove the old source-installed files from $HARNESS_LAUNCHER_PREFIX
```

## Quick start

A registered project needs `config/launcher.env`:

```bash
mkdir -p "$HOME/work-harness/config"
cat > "$HOME/work-harness/config/launcher.env" <<'EOF'
HARNESS_NAME="Work harness"
HARNESS_PREFIX="wh"
EOF
```

### MCP surface policy

`config/launcher.env` is the only authority that can opt a project into the
single-full policy. An inherited shell value is ignored. Leave
`HARNESS_MCP_SURFACE_POLICY` empty or omit it to preserve the legacy behavior:
Claude and Kiro can select `light`, and native Codex can select the manifest's
`work` MCP profile.

Projects can choose one of these opt-in values in `config/launcher.env`:

```bash
# Temporary compatibility phase: accept retired direct selectors with a warning.
HARNESS_MCP_SURFACE_POLICY="single-full-compat"

# Enforced phase: reject retired Claude/Codex direct selectors.
HARNESS_MCP_SURFACE_POLICY="single-full"
```

Both opt-in values use the full user-facing surface for Claude and Codex. In
the compatibility phase, direct `light` (Claude) and `work` (Codex) selectors
continue as full with a deprecation warning; the enforced phase rejects those
selectors. Kiro remains intentionally independent: its native `light` and
full choices continue to work in every policy. An invalid value fails before
the project command is registered.

Add the launcher and project registration to `~/.zshrc`. Use the source line that matches how you installed it.

Homebrew:

```zsh
source "$(brew --prefix harness-launcher)/share/harness-launcher/aliases.zsh"
harness_register "$HOME/work-harness"
```

Source install with `HARNESS_LAUNCHER_PREFIX="$HOME/.local"`:

```zsh
source "$HOME/.local/share/harness-launcher/aliases.zsh"
harness_register "$HOME/work-harness"
```

Start a new shell and verify the command:

```bash
exec zsh
wh codex --version
```

`HARNESS_PREFIX` becomes the shell function name. Register as many projects as you need, but each prefix must be unique. To make the same prefix available as a real executable outside interactive Zsh startup, register it once:

```bash
harness-profile register "$HOME/work-harness"
```

This installs a profile entry under `~/.config/harness-launcher/profiles/` and a command symlink under `~/.local/bin/` without copying project policy.

Registered commands are workspace-aware. If the current directory resolves inside the owning harness, the launcher uses it automatically; otherwise it preserves the legacy harness-root default. An explicit `--cwd` still takes precedence.

Workspace managers that need to choose the profile instead of naming it can use `harness-auto`. It resolves the current directory against the private profile registry, selects the single most-specific owning harness, and fails closed outside or across ambiguous boundaries:

```bash
harness-auto codex base
harness-auto claude base
harness-auto kiro-cli base
```

This is the supported command override for Orca's built-in Claude, Codex, and Kiro agent entries. It does not infer a profile from repository names or remotes; the worktree must live below its registered harness boundary.

External orchestrators and non-interactive shells can bypass `.zshrc` while keeping the same project policy:

```bash
harness-exec "$HOME/work-harness" codex base
```

When the external terminal starts inside the harness, no `--cwd .` is needed. If supplied, `--cwd` must resolve inside the registered harness. This is the supported boundary for Orca and similar worktree managers; see [Orca ADE integration](docs/orca-integration.md).

> [!WARNING]
> `config/launcher.env` is sourced as shell code. Only register project directories you trust.

## Commands

The same command shape works for every registered prefix:

```text
<prefix>                         interactive TUI
<prefix> fast|base|opus|plan|rich Claude Code preset
<prefix> fable                   Claude Code fable + high (direct only)
<prefix> ultracode               Claude Code opus[1m] + xhigh (direct only)
<prefix> continue|resume         Claude Code session shortcut
<prefix> light                   Claude Code with the light MCP surface (SSH-backed servers excluded)
<prefix> codex [profile] [272k|1m] native Codex CLI; 272K default, 1M opt-in
<prefix> codex [profile] work    native Codex CLI with the work MCP surface (any profile)
<prefix> codex continue          Codex `resume --last`
<prefix> codex resume            Codex resume picker
<prefix> codex fork              Codex `fork --last`
<prefix> codex full-auto|never|bypass   Codex safety level (bypass disables sandbox — dangerous)
<prefix> kiro-cli [mode]         native Kiro CLI
<prefix> kiro-cli light          native Kiro CLI with the light MCP surface
<prefix> kiro [mode]             Claude Code through a Kiro gateway
<prefix> codex-gateway [mode]    Claude Code through a Codex gateway
```

Extra arguments pass through to the selected runtime.

Run the prefix without arguments for the TUI. The top screen is a **launchpad**:
your recent launch configurations (up to 8, newest first, deduped per harness in
`.harness/launcher-history`) plus one "New …" composer entry per installed
runtime, fuzzy-searchable under gum — type to filter, Enter to launch. Picking a
history row relaunches that exact configuration; gateways, generated homes, and
MCP configs are revalidated on every replay. The composer collects session and
mode, then shows a single summary screen where permission mode, Chrome, the MCP
surface (`full`/`light` — light drops SSH-backed servers: `start-ssh-mcp.sh`
stdio wrappers and loopback HTTP on ports 38200–38299), and the Happy wrapper
are toggles. Esc (or `q`/invalid-then-`q` in the no-gum fallback) goes one step back; at the launchpad it exits.
Menu labels are generated from the same mode table the shortcuts use, and the
native-Codex profile labels read the generated profile configs, so what a label
says is what launches. Native Codex exposes its `work` MCP surface the same way
Claude/Kiro expose `light` — a `🔌 MCP surface` toggle on the summary screen,
combinable with any profile: `default` keeps the minimal project surface, while
`work` uses only the approved work MCPs declared by `config/codex-surface.json`.
The same screen exposes `🧠 Context`: cost-conscious `272K` is the recommended
default, while `1M` is an explicit opt-in preserved in launch history.

Native Codex homes explicitly enable the `update_plan` task tracker, including
on Codex 0.152.0+ where it defaults to disabled. See [native task progress](docs/codex-integration.md#native-task-progress).

### Presets

| Preset | Claude Code | Codex CLI | Intended use |
| --- | --- | --- | --- |
| `fast` | Haiku, low effort | GPT-5.6 Luna, low effort | Small edits and quick checks |
| `base` | Sonnet | GPT-5.6 Terra, medium effort | Everyday work — recommended default |
| `sol` (Codex only) | — | GPT-5.6 Sol, medium effort | Stronger main model — slower |
| `fable` (Claude direct only) | Fable, high effort | — | Explicit frontier-model selection |
| `astra` (Codex only) | — | GPT-6 Astra, medium effort | Explicit frontier-model selection |
| `plan` | Opus Plan | GPT-5.6 Sol, high effort, read-only | Investigation and planning |
| `opus` (Claude only) | Opus, high effort | — | Strong main model without `rich`'s xhigh cost |
| `rich` | Opus | GPT-5.6 Sol, high effort | Deep work — slowest normal preset |

These are task-oriented operational presets, not claims about OpenAI's model defaults. The launcher deliberately lowers `fast` for speed and raises `plan`/`rich` for deeper work; an unscoped model picker may use a different general starting effort. Model names follow the capabilities exposed by the installed runtime. Generated homes default to a 272,000-token window with a 217,600-token compact threshold; explicit 1M mode requests 1,000,000 with a 414,000 threshold. Codex model metadata determines the effective window, and neither setting is Astra-specific tuning.

Use `<prefix> fable` for Claude Code's opt-in `fable` alias with `high` effort, or select Fable in the direct TUI preset or Custom model menus. Existing numbered choices stay stable; the Fable preset is appended after Custom. Effort tokens still override the preset, for example `<prefix> fable xhigh`. The launcher rejects this preset on Kiro and Codex gateways. The alias follows the installed Claude Code runtime and any `ANTHROPIC_DEFAULT_FABLE_MODEL` override; availability remains account-dependent. As of September 8, 2026, Claude Code v2.1.255+ resolves it to Fable 5.1 by default ([official model configuration](https://code.claude.com/docs/en/model-config)).

Use `<prefix> codex astra` for the opt-in native profile. The default remains Terra and `sol` remains Sol; do not rename the model inside a generated `sol.config.toml`, because preparation restores launcher-owned profiles. Astra availability and the loaded model/effort must be verified in the selected Codex account. No API probe or silent model fallback is added.

The main profile does not downgrade reviewers: reviewer subagents route independently to Sol/medium by default and may explicitly escalate effort for unusually risky work.

## Project layout

A typical registered project looks like this:

```text
work-harness/
├── config/
│   ├── launcher.env
│   ├── codex-surface.json      # optional exact Codex runtime allowlists
│   └── .local/                 # optional, never commit secrets
├── .claude/
│   ├── skills/                 # shared Claude/Codex-compatible skills
│   └── settings.local.json     # optional local environment values
├── .codex-only/
│   └── skills/                 # project skills exposed only to Codex
├── .mcp.json                   # optional committed MCP definitions
├── .mcp.local.json             # optional local MCP definitions
└── .harness/                   # generated runtime state; gitignore this
```

The launcher merges `.mcp.json`, `.mcp.local.json`, and `mcp.local.json`. Duplicate MCP server names fail fast instead of silently overriding one another.

## Codex integration

Before each native Codex launch, `bin/codex-home-prepare.sh` prepares an isolated `CODEX_HOME` under `<project>/.harness/codex`:

- `config.toml` with project MCP servers and the default Terra/medium route
- `fast.config.toml`, `base.config.toml`, `sol.config.toml`, `plan.config.toml`, `rich.config.toml`, and `astra.config.toml`
- generated `AGENTS.md`
- exact manifest-selected skills and MCP flags, or legacy merged links when no surface manifest exists
- project-scoped sessions and history
- an `auth.json` symlink to the active native Codex login

To expose selected user-global MCP definitions, set `HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST` in the trusted project `config/launcher.env`, for example `HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST="docs,jira"`. The launcher trims and deduplicates names before every native Codex preparation; an empty or omitted value is explicitly unset, so a prior launch or caller environment cannot add global MCPs. Definitions remain authoritative in `$HOME/.codex/config.toml`, while the project surface manifest must explicitly opt into `codex-global-allowlist`.

ChatGPT Apps and connectors follow the same shape but stay off unless requested: `HARNESS_CODEX_APPS_ALLOWLIST="asdk_app_<id>"` turns on `[features].apps` and enables only the named ids, while `[apps._default]` keeps every other app disabled. Omitting the variable leaves `[features].apps = false`, so no connector tool reaches a session. Changing or removing the list regenerates the managed home before the next native Codex launch.

The terminal `codex` from `PATH` is preferred. Set `HARNESS_CODEX_BIN` for an explicit binary. Codex.app's bundled CLI is only used when `HARNESS_CODEX_ALLOW_APP_FALLBACK=1` because app bundles can lag behind the terminal release.

Browser support keeps the terminal-safe `browser-harness` path, materializes supported bundled plugins, and uses an exact browser-client SHA allowlist for `node_repl`. Shared plugin cache updates use the macOS kernel lock (`lockf`) so concurrent project launches cannot corrupt global cache state.

See [Codex integration](docs/codex-integration.md) for the generated layout, configuration translation, plugin policy, and compatibility notes.
For large installations, see [Codex surface manifests](docs/codex-surface.md) for duplicate collapse, explicit-only skills, exact MCP profiles, and the warm prepare path.

## Local configuration and secrets

Keep machine-specific gateway URLs, API keys, and MCP credentials out of Git:

```text
config/.local/kiro-gateway.env
config/.local/codex-gateway.env
.claude/settings.local.json
.mcp.local.json
mcp.local.json
```

Use environment-variable references in committed MCP configuration when authentication is required. Never paste credentials into bug reports, logs, screenshots, or pull requests.

Copy the relevant entries from [the project `.gitignore` template](templates/project.gitignore) into each registered project's existing `.gitignore`. Do not overwrite a project's existing ignore rules.

Read [Security](SECURITY.md) before changing auth, MCP, plugin, or runtime-home behavior.

## Troubleshooting

Common fixes are collected in [docs/troubleshooting.md](docs/troubleshooting.md), including:

- a prefix shadowed by an existing alias
- a login shell selecting a stale mise-managed Codex binary
- Codex.app fallback behavior
- duplicate MCP names
- generated state that needs regeneration
- Chrome native-host compatibility

When reporting a bug, include the launcher version, macOS version, Zsh version, selected runtime version, command shape, and a redacted error message.

## Development

Clone the repository and run the full suite:

```bash
git clone https://github.com/kilhyeonjun/harness-launcher.git
cd harness-launcher
./test/run-all.sh
```

The suite dispatches each test through its declared Bash or Zsh interpreter.
Codex surface tests run unlisted and safety-sensitive cases serially, then run
36 reviewed private-HOME metadata/configuration tests in at most two subprocess
shards. Every test keeps its own repo, generated home, lock and compiler counter;
the actual prepare and publication assertions are unchanged. New tests stay
serial until reviewed in `test/surface_test_runner.py`.

Use `HARNESS_SURFACE_TEST_JOBS=1 ./test/test-codex-surface.sh` for the original
serial unittest command. The default is 2; larger values are rejected. The
runner reports group and total wall time and preserves each group's failure
output. `--report PATH` writes machine-readable group and individual-test wall
times when invoking the Python runner directly. In one same-host full-suite
comparison, expanding the reviewed set reduced the serial group from 63 tests
in 316.6 seconds to 41 tests in 86.6 seconds, and total wall time from 353.9
seconds to 172.8 seconds. Host load varies, so these are observations, not a
speed guarantee.

The Codex home integration suite runs its config/skills, hooks, and generated
surface groups with isolated temporary homes. The default is three concurrent
groups; use `HARNESS_HOME_PREPARE_TEST_JOBS=1` to run them sequentially.
`./test/test-codex-home-prepare.sh --report PATH` writes group wall times as
JSON. On one same-host comparison, isolation plus bounded concurrency reduced
wall time from 132.5 seconds to 19.9 seconds; this is an observation, not a
speed guarantee.

Run syntax checks as well:

```bash
bash -n bin/*.sh test/*.sh
zsh -n bin/aliases.zsh bin/*.sh test/*.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for project scope, test expectations, portability rules, and the pull request checklist.

## Documentation

- [Public-safe contract demo](https://github.com/kilhyeonjun/harness-launcher-demo)
- [Documentation index](docs/README.md)
- [Architecture and trust boundaries](docs/architecture.md)
- [Codex integration](docs/codex-integration.md)
- [Session titles in cmux](docs/session-titles.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Changelog](CHANGELOG.md)
- [Security policy](SECURITY.md)
- [Code of conduct](CODE_OF_CONDUCT.md)

## Contributing

Bug reports, focused fixes, portability improvements, and documentation corrections are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and use the repository issue templates.

For vulnerabilities or credential-handling problems, do not open a public issue. Follow [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
