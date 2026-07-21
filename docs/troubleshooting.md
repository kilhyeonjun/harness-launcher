# Troubleshooting

Run diagnostics from the same Zsh login environment that loads `aliases.zsh`. A command that works in a non-login shell can resolve a different Homebrew prefix, version-manager shim, or runtime binary.

## The project prefix is not a function

Check registration:

```zsh
zsh -lic 'whence -w wh'
```

Expected output:

```text
wh: function
```

If it is missing:

1. confirm `~/.zshrc` sources `aliases.zsh`;
2. confirm `harness_register` points to the right directory;
3. confirm `<project>/config/launcher.env` exists;
4. confirm `HARNESS_PREFIX` and `HARNESS_NAME` are set.

Reload with `exec zsh` after editing shell configuration.

## An alias shadows the prefix

The registration function removes an existing alias with the same name before defining the project function. Verify the final resolution:

```zsh
whence -w wh
```

If a plugin recreates its alias after registration, move the `harness_register` call below that plugin's initialization in `~/.zshrc`.

## `harness-exec` is missing or rejects the worktree

Check the installed external entrypoint:

```zsh
command -v harness-exec
harness-exec "/path/to/harness" --cwd "/path/to/harness/.worktrees/example" codex --version
```

For a source install, ensure `$HARNESS_LAUNCHER_PREFIX/bin` is on `PATH` and rerun `install.sh`. For Homebrew, upgrade or reinstall the formula. A rejected `--cwd` must be moved under the owning harness; do not bypass the boundary with a symlink because canonical symlink targets outside the harness are rejected.

## `codex` reports `ENOENT`

A version-manager shim can exist while its platform package is missing. Check the executable selected by the login shell:

```zsh
zsh -lic 'command -v codex; codex --version'
```

If this resolves into a mise-managed Node installation and fails to spawn its native Codex binary, reinstall through that same environment:

```zsh
zsh -lic 'npm install -g @openai/codex@latest && mise reshim && codex --version'
```

Updating `/opt/homebrew/bin/codex` does not repair a different Codex selected earlier in `PATH`.

## Codex.app is installed but not selected

The terminal `codex` from `PATH` is preferred. This is intentional because Codex.app can bundle an older CLI.

Check both versions before opting into the app fallback:

```zsh
zsh -lic 'codex --version'
/Applications/Codex.app/Contents/Resources/codex --version
```

Enable fallback only when no terminal Codex is available:

```zsh
export HARNESS_CODEX_ALLOW_APP_FALLBACK=1
```

Use `HARNESS_CODEX_BIN=/absolute/path/to/codex` for a deliberate explicit binary.

## The wrong project receives `CODEX_HOME`

Direct `codex` wrapping only activates when `--cd` or `-C` points at a registered project, or at a directory containing `config/launcher.env`.

Inspect the target:

```zsh
codex --cd "/path/to/project" --version
```

Disable automatic preparation temporarily:

```zsh
HARNESS_LAUNCHER_DISABLE_CODEX_WRAPPER=1 codex --version
```

## Duplicate MCP server error

Committed and local MCP files are merged. The same server name cannot appear in more than one file:

```text
.mcp.json
.mcp.local.json
mcp.local.json
```

Rename the local server or remove the duplicate. Local files extend committed config; they do not override it. Native Kiro validates this before creating a fresh `.harness/kiro` home or changing an existing generated Kiro configuration.

Do not solve this by moving credentials into `.mcp.json`.

## Generated Codex config looks stale

Do not edit `.harness/codex/*.toml` directly. Trigger preparation again:

```zsh
wh codex --help >/dev/null
```

If you need a clean disposable runtime home, first make sure no Codex session is using it, then move the generated directory aside:

```bash
mv .harness/codex ".harness/codex.backup.$(date +%s)"
```

Run the launcher again and compare the regenerated result. Keep the backup until sessions and auth links are verified.

For a project with `config/codex-surface.json`, inspect `.harness/codex/skill-catalog.json` to see the selected source path, hash, invocation policy, and MCP profile. A divergent duplicate without `duplicate_choices`, a missing profile-only skill, or an undeclared MCP server is a source error; editing generated TOML does not fix it.

To force one safe rebuild without deleting sessions, remove only the success stamp:

```bash
rm .harness/codex/.surface-success.json
```

## Lock file remains under `~/.codex`

This file is expected:

```text
~/.codex/.codex-home-prepare-global.lock
```

The file's presence does not mean the lock is held. Test nonblocking acquisition:

```bash
/usr/bin/lockf -s -k -t 0 "$HOME/.codex/.codex-home-prepare-global.lock" true
echo $?
```

Exit status `0` means the lock is free. Do not delete it as a routine cleanup step.

## Chrome bridge is not configured

Trigger preparation, then inspect available host configs:

```bash
python3 - <<'PY'
from pathlib import Path
root = Path.home() / ".codex/plugins/cache/openai-bundled/chrome"
for path in root.glob("*/extension-host/macos/*/extension-host-config.json"):
    print(path)
PY
```

Supported host executable names include current `Codex for Chrome` and legacy `ChatGPT for Chrome`. If neither the Codex app marketplace nor a valid global plugin cache exists, the launcher has nothing to materialize.

Do not manually add all of `~/.codex` or a project `CODEX_HOME` to trusted code paths. Browser execution trust must remain hash-based.

## Gateway health check fails

Gateway modes require a local env file and a reachable `/health` endpoint:

```text
config/.local/kiro-gateway.env
config/.local/codex-gateway.env
```

Check that the gateway is running and the configured URL is correct. Redact the URL and all key values before sharing logs.

## Homebrew still shows an older launcher

```bash
brew update
brew info harness-launcher
brew upgrade harness-launcher
```

Confirm the linked installation:

```bash
brew list --versions harness-launcher
```

If you previously edited `/opt/homebrew/share/harness-launcher` directly, Homebrew can replace those changes. Durable fixes belong in the canonical repository and a tagged release.

## Reporting a bug

Use the bug report form and include:

```text
harness-launcher version
macOS version
zsh --version
selected runtime and version
registered command shape
redacted error output
```

Never attach auth files, `.claude/settings.local.json`, gateway env files, or unredacted MCP configuration. Security issues belong in the private reporting flow described in [SECURITY.md](../SECURITY.md).
