# Orca ADE integration

`harness-launcher` remains the policy and runtime-state owner. Orca may own the workspace UI, terminal panes, worktree lifecycle, and diff/review surface, but it must not replace project-scoped auth, MCP, skills, hooks, model presets, or observability.

## Supported boundary

Installations expose a non-interactive primitive and registered profile commands:

```text
harness-auto <agent> [agent arguments...]
harness-exec <harness-dir> [--cwd <dir>] [launcher arguments...]
harness-profile register <harness-dir>
<profile-prefix> [launcher arguments...]
```

`harness-profile register` installs the harness's `HARNESS_PREFIX` as a real executable under `~/.local/bin`. Both that executable and the interactive Zsh function delegate to `harness-exec`. When the current directory resolves inside the harness, it becomes the run directory automatically; outside the boundary, the legacy harness-root default remains. Explicit `--cwd` resolves symlinks and fails closed unless the target exists inside the registered harness.

Examples:

```bash
wh base
wh codex base
wh codex base work
wh kiro-cli base
```

Orca starts project terminals in the selected worktree. `harness-auto` resolves that canonical directory against the registered profile boundaries and delegates to the single most-specific harness. In v0.31.2+, check the decision without launching an agent with `harness-auto --explain codex`; the JSON reports the chosen profile, harness root, work root, and selection reason. `harness-auto --profile <prefix> codex base` pins a profile but fails if the current directory belongs to another boundary. Use a named profile command for manual terminals, and use `harness-exec <harness-dir> --cwd . ...` only for automation that cannot use either public adapter.

## Project and worktree layout

Register the actual code repository in Orca, not the harness repository itself. Set that project's Orca worktree base path to a `.worktrees` directory inside the repository's checkout under the owning harness (v0.33.0+ recommendation):

```text
<registered-harness>/projects/<repo-name>/.worktrees/<task>
```

Ignore `.worktrees/` in that code repository (for example in its `.git/info/exclude`). Keeping worktrees below the harness keeps the launcher boundary and Claude's ancestor path available, while the launcher keeps Codex and Kiro runtime homes under the harness root. Codex discovers project instructions from the Git root toward the working directory, plus its configured `CODEX_HOME`; do not assume a harness-level `AGENTS.md` above a nested code repository is loaded solely because the worktree is under the harness ([official OpenAI Docs](https://learn.chatgpt.com/docs/agent-configuration/agents-md)). A repository under `<harness>/projects/` and a worktree nested anywhere under that harness already use the same **profile selection**; verify effective runtime instructions separately. Worktrees at `<registered-harness>/.worktrees/<repo-name>/` resolve to the same profile and remain supported. An external linked worktree remains unsupported: Git ownership alone does not prove equivalent instruction loading, and `harness-exec` rejects outside `--cwd`.

Orca exposes `worktreeBasePath` in project setup. In the UI, set the project's worktree base path to the absolute profile-local directory above. The CLI also accepts `--worktree-base-path` on `orca project setup-create` and `orca project setup-update`.

Do not create a Git worktree of the harness repository. The harness is the configuration root; only child code repositories belong in Orca worktrees.

## Orca profile mapping

An Orca profile separates the visible projects and the per-profile browser, SSH, and account state. It is not a security boundary on one macOS account: every profile's terminals run in one shared PTY daemon, and every profile's terminal history is readable by the same user (verified on Orca 1.4.147). Keeping personal and company harnesses in one profile is supported; tell them apart with project badges, and use a separate macOS account or machine when they must not be able to read each other.

If you do split profiles, repeat every step below in each profile. A new profile starts from Orca's defaults: no agent command overrides and every agent enabled.

For each profile:

1. Add only the owning harness's child code repositories.
2. Configure the profile-local worktree base path.
3. Override Orca's built-in agent commands with the absolute path returned by `command -v harness-auto` (Homebrew on Apple Silicon normally installs `/opt/homebrew/bin/harness-auto`):

   ```text
   Claude command: harness-auto     arguments: claude base
   Codex command:  harness-auto     arguments: codex
   Kiro command:   harness-auto     arguments: kiro-cli
   ```

4. Select one reviewed default runtime; **Codex** is the conservative default for mixed-profile projects. Do not select Orca's **Auto** mode unless every agent it may choose is either mapped through `harness-auto` or disabled.
5. Keep Agent Permissions on **Manual**. Orca-managed agent status hooks are allowed under the policy in [Agent status hooks](#agent-status-hooks).

Do not replace the native binaries with same-name recursive PATH shims. `harness-auto` is a separate launcher-owned command: the first fixed argument names the real runtime, and Orca's remaining prompt, resume, and permission arguments stay in order. It fails closed when a worktree is outside every registered boundary or matches more than one equally specific registration.

## Required safety settings

Before the first agent launch:

- Set **Agent Permissions** to **Manual**.
- Orca-managed agent status hooks are allowed, but only as status reporters and only as described in [Agent status hooks](#agent-status-hooks). The launcher still owns policy hooks.
- Do not use Orca Codex account switching or managed Codex homes. The launcher owns `CODEX_HOME` and native auth selection; see [CODEX_HOME sanitization](#codex_home-sanitization).
- Disable telemetry when repository metadata must remain local: `DO_NOT_TRACK=1` and `ORCA_TELEMETRY_DISABLED=1` in the Orca launch environment.
- Keep Computer Use, mobile relay, SSH, and cloud integrations off until each boundary is reviewed separately.

## Agent status hooks

Runtime-generic behavior (detection order, scrubbing, the Codex hook registry, resume routing) is in [Terminal runtimes](terminal-runtimes.md); this section covers the Orca row.

Orca can install status hooks that report agent activity (working, waiting, done) in its sidebar.

- **Claude**: Orca writes its hooks into the user-global Claude settings file. Harness-owned hooks in project settings continue to run; the two sets are additive. This needs no launcher change.
- **Codex**: the launcher owns `CODEX_HOME`, so Orca's own Codex hook installation never reaches a launcher-generated home. Opt in per harness by adding `HARNESS_ORCA_AGENT_HOOKS=1` to that harness's `config/launcher.env` (v0.33.0+). `codex-home-prepare.sh` then appends one matcher-less entry per event (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`) after every existing entry, with a 5 second timeout. This is the `orca` row of the runtime registry described in [Terminal runtimes](terminal-runtimes.md#codex-hook-registry); herdr has its own row. Each entry is a fixed status-only, fail-open command: it runs `~/.orca/agent-hooks/codex-hook.sh` (when executable) with its output discarded and always exits 0, so Orca's script can never block a tool or decide a permission; otherwise it only drains stdin. Without the opt-in, `hooks.json` is identical to earlier releases. The opt-in is read only from the literal `HARNESS_ORCA_AGENT_HOOKS` line in the harness's `config/launcher.env` (`=1`, `="1"` or `='1'`, optional `export`, last assignment wins) by the prepare script itself, and the process environment is ignored. Every caller, including harness-side resyncs that run the prepare script directly without launcher state, therefore generates the same `hooks.json` and keeps its trust.
- **Trust**: Codex only runs hooks the harness has trusted. After enabling or disabling the opt-in, rerun the harness's Codex hook trust step. Trusting the wrapper trusts whatever Orca's script contains later, so later Orca script updates run without another review. Isolated sessions use fresh Codex home clones without that trust, so Orca status for isolated Codex sessions is not provided.
- **Rollback**: remove the opt-in line (or downgrade the launcher) and rerun the trust step; the next launch regenerates `hooks.json` without the Orca entries.

The cmux title brokers are not ported to Orca. Inside an Orca terminal, stale `CMUX_*` variables never start a broker (v0.33.0+); since v0.36.0 they are also removed from the agent's environment, and brokers start only when the detected runtime is cmux (see [Terminal runtimes](terminal-runtimes.md#scrub-and-announcement)).

## CODEX_HOME sanitization

Orca sets `CODEX_HOME` for terminals and its interactive shell wrappers copy `ORCA_CODEX_HOME` back into it. When `ORCA_CODEX_HOME` is non-empty and `CODEX_HOME` equals it, every launcher entry point (`harness-exec`, `harness-auto`, plain `claude` after `harness_shell_enable`, `claude-management`, `checkup`, and the interactive launcher) unsets both variables before doing anything else (step 1 of the per-launch scrub in [Terminal runtimes](terminal-runtimes.md#scrub-and-announcement)), so Claude and other launcher-owned runtimes never inherit Orca's managed home. The `codex` path then exports the harness's own `CODEX_HOME`. A `CODEX_HOME` you set yourself that differs from Orca's value is left untouched. `checkup prompt-audit` additionally drops every `ORCA_*` variable from the audit process.

## Profiles and relaunch

Orca profile switching and moving a project between profiles relaunch the Orca app into the target profile. In Orca 1.4.147 the multi-profile UI appears only when Orca starts with `ORCA_MULTI_PROFILE_UI=1`, and no CLI command manages profiles. Terminals from the previous profile keep running in the shared PTY daemon but disappear from view, so stop their agents before switching. The launcher does not switch Orca profiles for you.

## Resuming agents for isolated profiles

Orca restores an agent by re-running its command with `--resume <id>` (Claude) or `codex resume <id>` (Codex). Profiles that default to isolated sessions used to answer that with exit 2. From v0.33.0:

- A fresh isolated Claude launch adds `--session-id <lowercase session UUID>` (after the title `--name`), unless the arguments already name or resume a session.
- A restore with exactly one UUID (`--resume <id>`, `--resume=<id>`, `-r <id>`, `-r<id>`, or `codex resume <id>`) is mapped to the isolated session that owns it: for Claude the session directory whose name equals the id (v0.36.0+: or a session whose `provider-sessions` records the id and whose transcript exists), for Codex the one session whose Codex home holds the matching rollout file. The session must belong to the current harness. Unknown ids, non-UUID ids and other harnesses' sessions keep the original rejection message; several owners is reported as ambiguous; delivered sessions, retired workspaces and sessions held by another launcher each fail with their own message and exit 2.
- `--no-isolated` still opts out, and profiles with the isolation default off are unaffected.

Known limit: after Claude's `/clear` the conversation gets a new id that is no longer the session UUID, so its restore is rejected until the harness registers `harness-session-provider-record` (v0.36.0+), which records the new id so the restore maps, including sessions that run in a harness subdirectory (see [Resume routing](terminal-runtimes.md#resume-routing)). Otherwise recover with `<prefix> --isolated-session <uuid> resume`. A plain `<prefix>` launch that opens the interactive picker has no session id to map either.

Orca's worktree isolation is not a security sandbox. Runtime approval and sandbox settings still come from the launcher and selected agent.

## Verification

Use a disposable repository before registering production or company code.

1. Create a worktree under `<harness>/projects/<repo>/.worktrees/<task>`.
2. Launch Claude, Codex, and Kiro through `harness-auto` and verify the selected harness prefix.
3. Verify the process working directory is the worktree.
4. Verify `CODEX_HOME` and `KIRO_HOME` remain rooted in the owning harness.
5. Verify no other harness's skills, MCP servers, account state, or generated files appear.
6. Verify Orca did not add danger/bypass arguments, and that only the status hook described in [Agent status hooks](#agent-status-hooks) was added.
7. Quit and reopen Orca, resume the agent, then remove only the disposable worktree.

Rollback is removal of the Orca project/profile and its disposable worktree. The canonical harness and runtime homes stay unchanged.
