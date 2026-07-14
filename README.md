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

The source installer copies the launcher into `$HARNESS_LAUNCHER_PREFIX/share/harness-launcher`. Homebrew is the recommended installation path on macOS.

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

`HARNESS_PREFIX` becomes the shell function name. Register as many projects as you need, but each prefix must be unique.

> [!WARNING]
> `config/launcher.env` is sourced as shell code. Only register project directories you trust.

## Commands

The same command shape works for every registered prefix:

```text
<prefix>                         interactive TUI
<prefix> fast|base|plan|rich     Claude Code preset
<prefix> ultracode               Claude Code opus[1m] + xhigh (direct only)
<prefix> continue|resume         Claude Code session shortcut
<prefix> codex [profile]         native Codex CLI
<prefix> codex work              native Codex CLI with the base profile and work MCP surface
<prefix> codex continue          Codex `resume --last`
<prefix> codex resume            Codex resume picker
<prefix> codex fork              Codex `fork --last`
<prefix> codex full-auto|never|bypass   Codex safety level (bypass disables sandbox — dangerous)
<prefix> kiro-cli [mode]         native Kiro CLI
<prefix> kiro [mode]             Claude Code through a Kiro gateway
<prefix> codex-gateway [mode]    Claude Code through a Codex gateway
```

Extra arguments pass through to the selected runtime.

Run the prefix without arguments for the TUI: pick a runtime, session, and mode,
then review everything on a single summary screen where permission mode, Chrome,
and the Happy wrapper are toggles. The first menu offers **Repeat last** to relaunch
your previous configuration in one keypress (stored per harness in
`.harness/launcher-last`; gateways, generated homes, and MCP configs are revalidated
on every replay). Esc/`q` always goes one step back; at the top menu it exits.
Menu labels are generated from the same mode table the shortcuts use, and the
native-Codex profile labels read the generated profile configs, so what a label
says is what launches. Native Codex offers the `work` MCP surface as a profile
choice: `Default` keeps the minimal project surface, while `work` runs the base
profile with only the approved work MCPs declared by `config/codex-surface.json`.

### Presets

| Preset | Claude Code | Codex CLI | Intended use |
| --- | --- | --- | --- |
| `fast` | Haiku, low effort | GPT-5.6 Luna, low effort | Small edits and quick checks |
| `base` | Sonnet | GPT-5.6 Terra, medium effort | General implementation work |
| `plan` | Opus Plan | GPT-5.6 Sol, high effort, read-only | Investigation and planning |
| `rich` | Opus | GPT-5.6 Sol, high effort | Difficult implementation and review |

These are task-oriented operational presets, not claims about OpenAI's model defaults. The launcher deliberately lowers `fast` for speed and raises `plan`/`rich` for deeper work; an unscoped model picker may use a different general starting effort. Model names follow the capabilities exposed by the installed runtime. The launcher does not pin Codex context-window or auto-compaction values; Codex model metadata remains the source of truth.

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
