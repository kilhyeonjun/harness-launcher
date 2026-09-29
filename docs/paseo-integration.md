# Paseo integration

[Paseo](https://paseo.sh) is a daemon plus desktop, web, and mobile clients that start and supervise coding agents. `harness-launcher` stays the policy owner: profile selection, harness env, MCP, hooks, skills, and model presets come from the launcher, and Paseo only supplies the conversation and its own argv.

Verified with Paseo 0.10.1 and Claude Code 2.1.284 on macOS.

## How Paseo starts Claude

Paseo runs Claude Code through the Claude Agent SDK with `settingSources: user, project, local` and the `claude_code` system prompt preset, so `CLAUDE.md`, project settings, and hooks load from the agent's working directory. A provider may replace the executable with an argv prefix; Paseo then appends the SDK arguments (`--output-format stream-json --input-format stream-json`, `--permission-mode`, `--effort`, `--model`, `--mcp-config`, …) and talks over piped stdio.

`--passthrough` (v0.34.0+) ends launcher keyword parsing. Everything after it reaches Claude verbatim, and an explicit caller `--model`, `--effort`, or `--permission-mode` replaces the launcher default. Without the marker, option values such as `--permission-mode plan` are read as launcher keywords and the launch fails.

## Provider configuration

`~/.paseo/config.json`:

```json
{
  "$schema": "https://paseo.sh/schemas/paseo.config.v1.json",
  "version": 1,
  "daemon": {
    "listen": "127.0.0.1:6767",
    "relay": { "enabled": false },
    "mcp": { "enabled": true }
  },
  "agents": {
    "providers": {
      "harness-claude": {
        "extends": "claude",
        "label": "Harness Claude",
        "command": ["/opt/homebrew/bin/harness-auto", "claude", "base", "--passthrough"]
      }
    }
  }
}
```

`harness-auto` selects the registered profile that owns the agent's working directory, so one provider serves every registered harness. Keywords before the marker (`base`, `rich`, `light`, …) set defaults; Paseo's model, effort, and mode choices override them. Apply edits with `paseo daemon reload`.

## Workspaces

- Use Paseo `local` workspaces whose path is a registered harness root or a directory inside it, such as `<harness>/projects/<repo>`.
- Do not use Paseo-managed worktrees with this provider. They live under `$PASEO_HOME/worktrees` (or the global `worktrees.root`), outside every registered harness, and `harness-auto` fails closed there. Create worktrees inside the owning harness instead, then add them as local workspaces.
- Launches without a TTY never take the isolated-session route, so an isolation-default profile runs in its canonical root, as with any other non-interactive launch.

## Environment hygiene

- Start the daemon from a fresh login shell or through the desktop app, never from inside an agent session. A daemon inherits its parent environment and passes it to every agent; Paseo strips only `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SSE_PORT`, and `CLAUDE_AGENT_SDK_VERSION`, so tokens, `CODEX_HOME`, or terminal-integration variables from the parent would leak.
- Do not set `HARNESS_SESSION_ISOLATION=1` in the daemon environment. It forces isolation routing, which rejects SDK options such as `--verbose` and `--mcp-config`.
- Relay is off on new Paseo homes. Enable it only when you need mobile access; its traffic is end-to-end encrypted.

## Known limits

- Codex is not supported through Paseo. Paseo starts one `codex app-server` per agent in the daemon's working directory and sends each thread's `cwd` inside the app-server protocol, so the launcher's working-directory profile boundary cannot bind the session to a harness. Use a Paseo terminal and the profile command instead.
- `paseo provider diagnostic` runs its auth probe as `<command> auth status`, which receives launcher flags and reports an error. Agent launches are unaffected.
- With the `kiro` or `codex-gateway` provider prefixes, a full model ID from Paseo is passed as-is and is not mapped through `ANTHROPIC_DEFAULT_*`.
