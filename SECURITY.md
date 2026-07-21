# Security policy

## Supported versions

Security fixes are released on the latest published version. Upgrade before reporting a bug that may already be fixed:

```bash
brew update
brew upgrade harness-launcher
```

| Version | Security support |
| --- | --- |
| Latest release | Supported |
| Older releases | Not supported |

## Reporting a vulnerability

Do not open a public issue for a vulnerability, credential leak, auth-boundary problem, or command-injection finding.

Use [GitHub's private vulnerability reporting form](https://github.com/kilhyeonjun/harness-launcher/security/advisories/new).

Include:

- affected version or commit;
- affected runtime and command shape;
- macOS and shell versions;
- impact and trust boundary crossed;
- minimal reproduction steps;
- a proposed fix, if you have one.

Remove tokens, API keys, auth files, cookies, account identifiers, internal URLs, and personal paths. A reproduction should use fake values and a disposable project directory.

The maintainer will acknowledge the report through the advisory, validate the impact, and coordinate a fix and disclosure. Please do not publish the issue before a patched release is available.

## Security model

`harness-launcher` executes local AI coding CLIs inside directories chosen by the user. It does not sandbox those CLIs beyond the selected runtime's own sandbox and approval settings.

Important boundaries:

- `config/launcher.env` is sourced as shell code. Register only trusted project directories.
- Runtime-specific state is generated under `<project>/.harness/<runtime>`.
- Native Codex auth remains in the user's Codex auth store; project homes reference it rather than copying tokens.
- `.claude/settings.local.json` can provide local environment values to child runtimes. Treat it as sensitive and keep it out of version control.
- `.mcp.local.json`, `mcp.local.json`, and `config/.local/**` are intended for machine-local configuration and secrets.
- Shared Codex plugin/cache writes are serialized with the macOS kernel lock.
- `node_repl` browser integration trusts exact browser-client hashes. Project-writable runtime homes are not trusted code paths.
- A gateway mode sends prompts and tool traffic to the configured gateway. Users are responsible for trusting that endpoint.
- The launcher prefers runtime binaries from `PATH`. `HARNESS_CODEX_BIN` and app fallback options deliberately change the executable trust decision.
- `harness-exec --cwd` resolves symlinks and rejects directories outside the registered project. External workspace managers must keep project worktrees under that boundary.
- A workspace manager does not become the owner of launcher-managed auth, runtime homes, MCP, skills, hooks, approval modes, or observability merely because it starts `harness-exec`.

## Out of scope

The following generally belong upstream unless the launcher creates or worsens the issue:

- vulnerabilities in Claude Code, Codex CLI, Kiro CLI, Happy, Gum, or Node.js;
- model behavior, prompt injection, or unsafe generated code without a launcher boundary failure;
- compromised MCP servers or gateways configured by the user;
- access granted by an explicit runtime bypass or danger-full-access option;
- a malicious `launcher.env` inside a project the user knowingly registered as trusted.

If you are unsure whether a finding is in scope, use the private advisory form.
