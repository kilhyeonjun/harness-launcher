# Architecture and trust boundaries

## Overview

`harness-launcher` is a shell and executable adapter. It registers a project directory as a short profile command, translates presets into runtime arguments, prepares project-scoped runtime state, and then hands control to the selected CLI.

```text
~/.zshrc
  └─ harness_register <project>
       └─ reads config/launcher.env
            └─ defines <prefix>() and completion
                 ├─ Claude Code
                 ├─ Codex CLI  → prepare .harness/codex
                 └─ Kiro CLI   → prepare .harness/kiro
```

External orchestrators use the same runner through a registered executable profile or `harness-exec` rather than depending on shell startup:

```text
workspace manager
  └─ <profile-prefix> ...
       └─ harness-exec <project> ...
       └─ the same _harness_launcher_run policy path
```

The current workspace is adopted only when its canonical path resolves inside the registered project; explicit `--cwd` uses the same boundary. Workspace managers own UI and worktree lifecycle; the launcher continues to own runtime homes, auth routing, MCP, skills, hooks, presets, and observability.

The launcher is not a model proxy and does not host an API. Gateway modes are optional routes to user-configured external processes.

## Registration

Each project provides:

```bash
# config/launcher.env
HARNESS_NAME="Example harness"
HARNESS_PREFIX="ex"
```

`harness_register` resolves the project to an absolute path, sources `launcher.env`, defines the prefix function, and attaches completion when Zsh's `compdef` is available. `harness-profile register` persists the same prefix as an executable command without copying policy.

Because `launcher.env` is sourced, registration is a trust decision. The launcher does not attempt to parse or sandbox arbitrary shell code in that file.

## Command routing

The prefix function and executable profile both delegate through `harness-exec` to `_harness_launcher_run`:

```text
ex                         interactive TUI
ex <mode>                  direct Claude Code
ex codex <profile>         native Codex CLI
ex kiro-cli <mode>         native Kiro CLI
ex kiro <mode>             Claude Code through a Kiro gateway
ex codex-gateway <mode>    Claude Code through a Codex gateway
```

Runtime-specific arguments remain arrays until execution. The launcher passes unknown arguments through to the selected CLI.

## Binary selection

Native Codex uses this precedence:

```text
HARNESS_CODEX_BIN
  → codex resolved from PATH
  → Codex.app bundled CLI only when HARNESS_CODEX_ALLOW_APP_FALLBACK=1
```

Kiro follows the same explicit-override pattern through `HARNESS_KIRO_BIN`, then `kiro-cli` from `PATH`.

This order matters on macOS because an app-bundled CLI or a version-manager shim can differ from the executable expected by the user. Verify binary selection from the same login shell that loads the launcher.

## Generated runtime homes

The launcher keeps project-specific state under:

```text
<project>/.harness/codex
<project>/.harness/kiro
```

These directories can contain generated config, session history, plugin state, hooks, skills, and links to the active runtime auth store. They should be ignored by Git and treated as disposable output.

User-authored sources live outside `.harness`:

```text
config/launcher.env
config/codex-surface.json
.mcp.json
.mcp.local.json
mcp.local.json
.claude/skills/
.codex-only/skills/
.claude/settings.local.json
config/.local/
```

Preparation is idempotent. Re-running a launcher command converges generated files to the current source configuration.

When `config/codex-surface.json` is present, it is the membership boundary for generated Codex skills, imported Claude plugins, Codex-only profiles, and enabled MCP servers. Host tokens are expanded at preparation time. The generated catalog records exact source paths and hashes; it is evidence, not source.

## MCP configuration

Committed MCP definitions can live in `.mcp.json`. Machine-local additions can live in `.mcp.local.json` or `mcp.local.json`.

The launcher rejects duplicate server names across these files. Local config extends committed config; it does not override it silently. Native Kiro validates and renders MCP configuration in external staging before it materializes a runtime home: a duplicate leaves an existing `.harness/kiro` unchanged and creates no `.harness/kiro` state for a fresh project.

Codex preparation translates supported MCP entries into TOML:

```json
{
  "mcpServers": {
    "docs": {
      "command": "npx",
      "args": ["-y", "@example/docs-mcp"]
    }
  }
}
```

```toml
[mcp_servers.docs]
command = "npx"
args = ["-y", "@example/docs-mcp"]
```

HTTP bearer values should be represented through environment-variable references. Generated config stores the variable name, not the secret value.

## Global state and concurrency

Most Codex state is project-scoped, but bundled plugin caches and the Chrome native-host bridge can use global `~/.codex` paths. These writes are a cross-project critical section.

On macOS, preparation opens a persistent lock file and acquires `/usr/bin/lockf` on an inherited descriptor. The kernel holds the lock for the protected subshell lifetime, including signal and child-process cases. The lock file can remain on disk after release; successful reacquisition proves that no process still owns it.

Do not replace this with PID files, mtime-based stale reclamation, or signal cleanup that removes a directory while child work continues.

Manifest-enabled homes also keep an atomic successful-input fingerprint plus a source-identity watch snapshot. The lean warm path validates watched file identities, semantic TOML policy, launcher-owned output hashes, product-plugin skill digests, explicit-only policies, skill/plugin directory topology, and every managed skill link before returning; it does not rescan plugin tests/docs/assets. Unexpected generated-home skill routes force a cold rebuild and reversible quarantine, and marker membership alone never proves ownership. Auth contents, sessions, hook trust state, and generated output mtimes remain runtime state and do not invalidate source generation. Any cold rebuild removes its old success stamp before mutation.

## Browser and plugin trust

The launcher can materialize supported Codex bundled plugins when a compatible marketplace source or existing cache is available.

Security rules:

- Terminal Codex does not enable the desktop-only Browser plugin surface.
- Chrome bridge support accepts current and known legacy native-host names.
- `node_repl` trusts exact browser-client SHA-256 values.
- Project-writable `CODEX_HOME` and global `~/.codex` directories are not added as broad trusted code paths.
- Marketplace synchronization completes before generated config reads plugin versions or browser hashes.
- Complete marketplace content, not one manifest, determines cache freshness.

## Auth boundary

Generated Codex homes link to the active native Codex auth file. The launcher does not copy, serialize, or convert OAuth refresh tokens.

A native account switch therefore happens in the Codex auth store, not by editing each project's generated home. Contributors must not add logs or diagnostics that print auth JSON or environment values.

## Gateway boundary

Gateway modes source local files under `config/.local/` and probe the configured `/health` endpoint before launching Claude Code.

Anything sent through a gateway leaves the local runtime boundary. Users must trust the gateway endpoint and its operator. Gateway configuration and credentials should never be committed.

## Failure behavior

The launcher prefers visible failures over silent fallback when a boundary is ambiguous:

- missing project config stops registration;
- duplicate MCP server names stop launch;
- missing explicit runtime binary stops launch;
- lock acquisition timeout stops shared cache mutation;
- failed runtime-home preparation stops the selected runtime;
- app-bundled Codex fallback requires explicit opt-in.
