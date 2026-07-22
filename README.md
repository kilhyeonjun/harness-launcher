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

It also provides consistent `fast`, `base`, `plan`, and `rich` presets, optional gateway routing for Claude Code, tab completion, and an interactive TUI.

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

### From source

```bash
git clone https://github.com/kilhyeonjun/harness-launcher.git
cd harness-launcher
HARNESS_LAUNCHER_PREFIX="$HOME/.local" ./install.sh
```

The source installer copies the launcher into `$HARNESS_LAUNCHER_PREFIX/share/harness-launcher` and exposes `harness-auto`, `harness-exec`, and `harness-profile` from `$HARNESS_LAUNCHER_PREFIX/bin`. It installs only missing assets, leaves byte-identical existing assets untouched, and aborts before writing when any managed destination differs or is a symlink. Use Homebrew for in-place managed upgrades; for a source upgrade with changed assets, move the old prefix aside and reinstall.

## Quick start

A registered project needs `config/launcher.env`:

```bash
mkdir -p "$HOME/work-harness/config"
cat > "$HOME/work-harness/config/launcher.env" <<'EOF'
HARNESS_NAME="Work harness"
HARNESS_PREFIX="wh"
EOF
```

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
<prefix> fast|base|plan|rich     Claude Code preset
<prefix> ultracode               Claude Code opus[1m] + xhigh (direct only)
<prefix> continue|resume         Claude Code session shortcut
<prefix> light                   Claude Code with the light MCP surface (SSH-backed servers excluded)
<prefix> codex [profile]         native Codex CLI (fast|base|sol|plan|rich)
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

### Presets

| Preset | Claude Code | Codex CLI | Intended use |
| --- | --- | --- | --- |
| `fast` | Haiku, low effort | GPT-5.6 Luna, low effort | Small edits and quick checks |
| `base` | Sonnet | GPT-5.6 Terra, medium effort | Everyday work — recommended default |
| `sol` (Codex only) | — | GPT-5.6 Sol, medium effort | Stronger main model — slower |
| `plan` | Opus Plan | GPT-5.6 Sol, high effort, read-only | Investigation and planning |
| `rich` | Opus | GPT-5.6 Sol, high effort | Deep work — slowest normal preset |

These are task-oriented operational presets, not claims about OpenAI's model defaults. The launcher deliberately lowers `fast` for speed and raises `plan`/`rich` for deeper work; an unscoped model picker may use a different general starting effort. Model names follow the capabilities exposed by the installed runtime. The launcher does not pin Codex context-window or auto-compaction values; Codex model metadata remains the source of truth.

The main profile does not downgrade reviewers: reviewer subagents may still route to Sol/high.

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
- `fast.config.toml`, `base.config.toml`, `plan.config.toml`, and `rich.config.toml`
- generated `AGENTS.md`
- exact manifest-selected skills and MCP flags, or legacy merged links when no surface manifest exists
- project-scoped sessions and history
- an `auth.json` symlink to the active native Codex login

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

The suite dispatches each test through its declared Bash or Zsh interpreter. Run syntax checks as well:

```bash
bash -n bin/*.sh test/*.sh
zsh -n bin/aliases.zsh bin/*.sh test/*.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for project scope, test expectations, portability rules, and the pull request checklist.

## Documentation

- [Documentation index](docs/README.md)
- [Architecture and trust boundaries](docs/architecture.md)
- [Codex integration](docs/codex-integration.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Changelog](CHANGELOG.md)
- [Security policy](SECURITY.md)
- [Code of conduct](CODE_OF_CONDUCT.md)

## Contributing

Bug reports, focused fixes, portability improvements, and documentation corrections are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and use the repository issue templates.

For vulnerabilities or credential-handling problems, do not open a public issue. Follow [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
