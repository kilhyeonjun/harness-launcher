# harness-launcher

Universal launcher for kilhyeonjun-harness / gameduo-*-harness repos.

## Install

```bash
brew tap kilhyeonjun/tap
brew install harness-launcher
```

## Usage

Each harness declares its identity in `config/launcher.env`:

```shell
HARNESS_NAME="kilhyeonjun harness"
HARNESS_PREFIX="kh"
```

Register it in your shell:

```zsh
source "$(brew --prefix)/share/harness-launcher/aliases.zsh"
harness_register "$HOME/kilhyeonjun-harness"
harness_register "$HOME/gameduo-personal-harness"
harness_register "$HOME/gameduo-platform-harness"
```

This creates `kh`, `gd`, `gp` functions with tab completion.

## Runtimes

The launcher supports two AI CLI runtimes:

- **Claude Code** — default. Direct Anthropic, or via Kiro / Codex gateways.
- **Codex CLI** — OpenAI's `codex`, launched natively against a per-harness
  `CODEX_HOME` at `$HARNESS_DIR/.harness/codex/`.

When both `claude` and `codex` are in `PATH`, the no-arg interactive launcher
(`kh`, `gd`, `gp` with no shortcut args) asks which runtime to use first.
With only one available, the menu auto-skips.

## Shortcut commands

```sh
kh                       # TUI (runtime → session → mode → ...)
kh base                  # Claude Code, base mode
kh kiro rich             # Claude Code via Kiro gateway, rich mode
kh codex                 # Codex CLI native (default mode = base)
kh codex base            # Codex CLI native, base profile
kh codex plan            # Codex CLI native, plan profile (read-only sandbox)
kh codex happy           # Happy Codex mode (not Codex CLI passthrough)
kh codex resume          # Codex CLI resume picker
kh codex continue        # Codex CLI resume --last
kh codex-gateway base    # Claude Code via Codex gateway (legacy)
```

`gd`, `gp` follow the same pattern.

### Migration note

Previously, `kh codex` invoked Claude Code with the Codex gateway as backend.
That path now lives under `kh codex-gateway`. The bare `kh codex` runs the
real Codex CLI binary with a per-harness `CODEX_HOME` populated from the
harness's `.mcp.json` and `CLAUDE.md`.

## Codex CLI integration details

`bin/codex-home-prepare.sh` is invoked before every Codex launch and
populates `$HARNESS_DIR/.harness/codex/` with:

- `config.toml` — top-level model defaults, long-context client settings,
  `[mcp_servers.*]` translated from `.mcp.json`, and enabled entries for
  harness-approved Codex bundled plugins (`computer-use`, `chrome`; `browser`
  is pruned for terminal Codex).
- `<profile>.config.toml` (`fast`/`base`/`plan`/`rich`) — per-profile overlay
  files with top-level keys, selected via `codex --profile <name>`. Required by
  Codex 0.134.0+, which rejects inline `[profiles.*]` tables in `config.toml`
  when `--profile` is used.
- `plugins/cache/openai-bundled/` — versioned plugin roots for those bundled
  plugins, so Codex reports them as installed and loads their skills/tools.
- `AGENTS.md` → `../../CLAUDE.md` (symlink, so Codex picks up the harness rules).
- `skills/` — per-skill symlink merge of global `~/.codex/skills` plus
  harness-local `.claude/skills`.
- `auth.json` → `~/.codex/auth.json` (symlink, share login).

The script is idempotent: re-running rewrites `config.toml` only when the
content would change.

Chrome Browser Use still requires the official Codex Desktop Chrome plugin setup
flow. The launcher keeps `chrome@openai-bundled` installed/enabled and keeps the
global native-host target
`~/.codex/plugins/cache/openai-bundled/chrome/latest` valid, but terminal
`codex exec`/TUI currently may still see `Browser is not available: extension`
because the Chrome extension backend is not registered to that terminal turn.
Native Codex should not be routed through a harness-created local app-server
`--remote`; that server also does not receive the Chrome extension backend. Use
Codex Desktop `@Chrome` for Chrome-profile browser tasks unless a live
`agent.browsers.list()` check in the terminal session returns a Chrome backend.

If `happy` is installed, the no-arg interactive launcher asks whether to route
Claude sessions through Happy. Native Codex uses the real Codex CLI. `kh codex
happy` enters Happy's separate Codex mode: it starts from the harness directory
with harness `CODEX_HOME`, but it does not support Codex CLI profiles or
`resume --last`; use `happy resume <happy-session-id>` or `happy codex --resume
<codex-thread-id>` for Happy-managed resumes.
