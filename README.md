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

- `config.toml` — top-level model defaults, `[profiles.fast|base|plan|rich]`,
  and `[mcp_servers.*]` translated from `.mcp.json`.
- `AGENTS.md` → `../../CLAUDE.md` (symlink, so Codex picks up the harness rules).
- `skills` → `~/.codex/skills` (symlink, share global Codex skills).
- `auth.json` → `~/.codex/auth.json` (symlink, share login).

The script is idempotent: re-running rewrites `config.toml` only when the
content would change.

If `happy` is installed, the no-arg interactive launcher (Claude branch)
asks whether to route the session through Happy for mobile control.
Shortcut invocations like `kh base` or `kh codex plan` skip the prompt.
