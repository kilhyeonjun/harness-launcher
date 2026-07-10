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

Codex binary resolution is explicit-first: `HARNESS_CODEX_BIN`, then `codex`
from `PATH`. The bundled Codex.app CLI is not used by default because it can
lag behind the terminal CLI; set `HARNESS_CODEX_ALLOW_APP_FALLBACK=1` only when
you intentionally want the app bundle as a fallback.

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

- `config.toml` — GPT-5.6 Terra+medium top-level defaults, unpinned
  context/auto-compact values from Codex model metadata, `[mcp_servers.*]`
  translated from `.mcp.json`, and enabled entries for harness-approved bundled
  plugins (`computer-use` and the Chrome bridge; `browser` stays pruned).
- `<profile>.config.toml` (`fast`/`base`/`plan`/`rich`) — Luna+low,
  Terra+medium, Sol+high read-only, and Sol+high overlays respectively. Files
  use top-level keys selected via `codex --profile <name>`, as required by
  Codex 0.134.0+.
- `plugins/cache/openai-bundled/` — versioned plugin roots for those bundled
  plugins, so Codex reports them as installed and loads their skills/tools.
- `AGENTS.md` — generated harness rules plus the Codex response-language
  supplement.
- `skills/` — per-skill symlink merge of global `~/.codex/skills`, active
  Skills CLI installs from `~/.agents/skills`, harness-local `.claude/skills`,
  and Codex-only `$HARNESS_DIR/.codex-only/skills`.
- `auth.json` → `~/.codex/auth.json` (symlink, share login).

The script is idempotent: re-running rewrites `config.toml` only when the
content would change.

Browser automation for kh/gd/gp terminal Codex keeps `browser-harness` as the
stable CDP path and also materializes Codex's Chrome plugin bridge when the
Codex app bundle provides it. `browser@openai-bundled` remains pruned;
`chrome@openai-bundled` and the `node_repl` Chrome bridge are generated into
the isolated per-harness `CODEX_HOME`. Native Codex is never routed through a
harness-created local app-server `--remote`.

If `happy` is installed, the no-arg interactive launcher asks whether to route
Claude sessions through Happy. Native Codex uses the real Codex CLI. `kh codex
happy` enters Happy's separate Codex mode: it starts from the harness directory
with harness `CODEX_HOME`, but it does not support Codex CLI profiles or
`resume --last`; use `happy resume <happy-session-id>` or `happy codex --resume
<codex-thread-id>` for Happy-managed resumes.
