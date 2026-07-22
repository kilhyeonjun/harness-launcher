# Documentation

The README covers installation and the first registered project. These documents explain the parts that matter when extending or debugging the launcher.

## User guides

- [Architecture and trust boundaries](architecture.md) — registration, command routing, generated runtime homes, and security boundaries.
- [Codex integration](codex-integration.md) — profile overlays, MCP translation, skills, plugins, hooks, and compatibility behavior.
- [Codex surface manifests](codex-surface.md) — exact skill/plugin/MCP membership, host-token resolution, and warm launches.
- [Orca ADE integration](orca-integration.md) — executable entrypoint, profile-local worktrees, ownership boundaries, and safety gates.
- [Troubleshooting](troubleshooting.md) — shell resolution, stale runtime binaries, generated state, MCP conflicts, and browser-host issues.

## Project policies

- [Contributing](../CONTRIBUTING.md)
- [Security policy](../SECURITY.md)
- [Code of conduct](../CODE_OF_CONDUCT.md)
- [Changelog](../CHANGELOG.md)
- [License](../LICENSE)

## Source map

| Path | Responsibility |
| --- | --- |
| `bin/aliases.zsh` | Project registration, shortcuts, completion, runtime wrappers |
| `bin/harness-auto` | Current-workspace profile resolver for external agent launchers |
| `bin/harness-exec` | Non-interactive executable entrypoint and canonical cwd resolver for external orchestrators |
| `bin/harness-profile` | Durable profile registry and executable prefix installer |
| `bin/launcher.sh` | Interactive runtime/session/mode/safety picker |
| `bin/codex-home-prepare.sh` | Generated per-project Codex home |
| `bin/kiro-home-prepare.sh` | Generated per-project Kiro home |
| `bin/codex-hook-adapter.sh` | Supported hook translation into harness hooks |
| `test/` | Isolated shell regression tests |
| `templates/project.gitignore` | Copyable generated-state and local-config ignore entries |
| `install.sh` | Standalone source installer |

Generated files under a registered project's `.harness/` directory are runtime output, not documentation or configuration sources.
