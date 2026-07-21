# Orca ADE integration

`harness-launcher` remains the policy and runtime-state owner. Orca may own the workspace UI, terminal panes, worktree lifecycle, and diff/review surface, but it must not replace project-scoped auth, MCP, skills, hooks, model presets, or observability.

## Supported boundary

Installations expose a non-interactive executable:

```text
harness-exec <harness-dir> [--cwd <dir>] [launcher arguments...]
```

Unlike a registered Zsh prefix, `harness-exec` does not depend on `.zshrc` or an interactive/login shell. It defaults to the harness root. `--cwd` resolves symlinks and fails closed unless the target directory exists inside the registered harness.

Examples:

```bash
harness-exec "$HOME/work-harness" --cwd . base
harness-exec "$HOME/work-harness" --cwd . codex base
harness-exec "$HOME/work-harness" --cwd . codex base work
harness-exec "$HOME/work-harness" --cwd . kiro-cli base
```

Orca starts project terminals in the selected worktree, so the literal `--cwd .` keeps the command portable without relying on environment-variable expansion.

## Project and worktree layout

Register the actual code repository in Orca, not the harness repository itself. Set that project's Orca worktree base path inside the owning harness:

```text
<registered-harness>/.worktrees/<repo-name>/
```

Add `.worktrees/` to the harness `.gitignore`. Keeping worktrees below the harness preserves ancestor-level Claude instructions while the launcher keeps Codex and Kiro runtime homes under the harness root.

Orca exposes `worktreeBasePath` in project setup. In the UI, set the project's worktree base path to the absolute profile-local directory above. The CLI also accepts `--worktree-base-path` on `orca project setup-create` and `orca project setup-update`.

Do not create a Git worktree of the harness repository. The harness is the configuration root; only child code repositories belong in Orca worktrees.

## Orca profile mapping

Use one Orca profile per trust boundary. Do not mix personal and company repositories in one Orca profile.

For each profile:

1. Add only the owning harness's child code repositories.
2. Configure the profile-local worktree base path.
3. Open an Orca terminal in the selected worktree and start the agent with one of the `harness-exec --cwd .` commands above.
4. Keep Orca's built-in task-agent dispatch disabled during the initial pilot. It starts Orca's own raw `claude`, `codex`, or `kiro-cli` command and can bypass launcher ownership.

Do not replace the built-in agent binaries with recursive PATH shims. Native Orca task dispatch requires a separately reviewed adapter because Orca appends runtime-specific prompt, resume, and permission arguments.

## Required safety settings

Before the first agent launch:

- Set **Agent Permissions** to **Manual**.
- Disable Orca-managed agent hooks. The launcher owns runtime hooks.
- Do not use Orca Codex account switching or managed Codex homes. The launcher owns `CODEX_HOME` and native auth selection.
- Disable telemetry when repository metadata must remain local: `DO_NOT_TRACK=1` and `ORCA_TELEMETRY_DISABLED=1` in the Orca launch environment.
- Keep Computer Use, mobile relay, SSH, and cloud integrations off until each boundary is reviewed separately.

Orca's worktree isolation is not a security sandbox. Runtime approval and sandbox settings still come from the launcher and selected agent.

## Verification

Use a disposable repository before registering production or company code.

1. Create a worktree under `<harness>/.worktrees/<repo-name>/`.
2. Launch Claude, Codex, and Kiro through `harness-exec --cwd .`.
3. Verify the process working directory is the worktree.
4. Verify `CODEX_HOME` and `KIRO_HOME` remain rooted in the owning harness.
5. Verify no other harness's skills, MCP servers, account state, or generated files appear.
6. Verify Orca did not add danger/bypass arguments or managed hooks.
7. Quit and reopen Orca, resume the agent, then remove only the disposable worktree.

Rollback is removal of the Orca project/profile and its disposable worktree. The canonical harness and runtime homes stay unchanged.
