# SDK host hardening and Paseo config management (v0.35.0) design

Status: revision 2, after the independent design review (H1–H4, M1–M6, M8, M9, L1–L11 applied; M7's hook backstop is not added because launcher `-C` validation plus the schema drift test cover the known entry points). The user asked on 2026-09-29 to remove every remaining constraint reported after v0.34.0 and to manage Paseo configuration from the launcher. Scale: HIGH (public argv contract, a new trust boundary for Codex app-server, and a new writer of a user config file). Design and implementation each need an independent review.

Baseline: `origin/main` 7c9ea50 (v0.34.0 plus #65). Paseo 0.10.1, codex-cli 0.158.0, Claude Code 2.1.284.

## Constraints being removed

| ID | Constraint after v0.34.0 | Change |
| --- | --- | --- |
| C1 | Codex cannot run through Paseo: Paseo starts `<command> app-server` in the daemon cwd and sends each thread's `cwd` over JSON-RPC, so the cwd profile boundary cannot bind it | S1, S2, S3 |
| C2 | The launcher inserts `-p <profile>` before subcommands that reject it | S2 |
| C3 | Paseo's Codex feature gates probe `<command[0]> --version`, which fails for `harness-auto` | S1 |
| C4 | Shell `claude`/`codex` wrappers capture launcher keywords from native argv | S5 |
| C5 | Tokens after a launcher `--` are still captured as keywords, and launcher flags are appended after it | S4 |
| C6 | `rich`/`ultracode` plus a caller thinking disable keeps xhigh and forced thinking | S4 |
| C7 | An error return after an isolated session is acquired keeps the lease | S4 |
| C8 | Paseo's diagnostic `auth status` probe receives launcher flags | S4 |
| C9 | `harness-auto` does not validate attached `-C<dir>`/`-C=<dir>` forms | S6 |
| C10 | Paseo provider entries are edited by hand and drift from the profile registry | S7 |
| C11 | Paseo-managed worktrees live outside every harness | S8 (documented recipe) |

## Interface

### S1 `harness-codex` entrypoint

New installed executable next to `harness-auto`.

- `harness-codex --version` or `-V`: exec the native `codex --version`.
- `harness-codex --profile <name> [codex args...]`: validate `<name>` against the registry (reserved `register`/`checkup` rejected), then exec `harness-profile <name> codex --passthrough [codex args...]`. The profile command keeps its rule: run in the current directory when it is inside the harness, else in the harness root.
- `harness-codex [codex args...]`: exec `harness-auto codex --passthrough [codex args...]`.
- Invalid `--profile` usage exits 2.

### S2 Codex `--passthrough`, profile placement, caller wins

In `_harness_launcher_run_codex_cli`:

- Tokens after the first `--passthrough` are appended verbatim and are never launcher keywords.
- `harness_codex_subcommand <args...>` (in `harness-common.sh`) skips options with the value-taking table already used by isolation routing (unknown options are flags), stops at `--`, and prints the first subcommand word or nothing. The launcher omits `-p <profile>` when it is one of `agents login logout plugin app-server remote-control app completion update doctor apply a migrate-rollouts cloud exec-server features help`, or `debug` not followed by `prompt-input`. An explicit launcher profile keyword with such a subcommand exits 2: `harness-launcher: codex profile '<p>' applies only to runtime commands; '<subcommand>' rejects --profile`.
- Caller wins after the marker: a caller `-p`, `-p<name>`, `--profile`, or `--profile=*` suppresses the launcher `-p`. A caller `-C`, `-C<dir>`, `-C=<dir>`, `--cd`, or `--cd=*` suppresses the launcher `--cd` after its value passes `harness_resolve_run_dir` for the harness (exit 2 otherwise), so every entry point enforces the boundary. Scans stop at `--`. Without the marker a caller `-C`/`--cd` still fails as a duplicate, as today.
- A test compares the rejecting table with `codex --help` when `codex` is installed.
- Isolation routing, Codex branch: `--passthrough` switches to passthrough scanning. `resume`/`fork` keep `reject`, subcommands keep `legacy`, and bare launcher keywords become prompt text (`isolate`).

### S3 Codex app-server boundary guard

When the Codex subcommand is plain `app-server`, the launcher runs `harness-python codex-app-server-guard.py --root <harness dir> --server-cwd <effective --cd> --prefix <prefix> --registry <profiles dir> -- <codex argv>`. `<harness dir>` is the isolated session root for an isolated launch. Nested `daemon`/`proxy`, `--listen` values other than `stdio://`, and the `remote-control`/`exec-server`/`mcp-server` subcommands exit 2, because they serve clients around the relay (implementation review M3).

- Scope: fields that decide where Codex executes or which instructions it loads. Every client message (request, notification, or response to a server request) is scanned recursively for the keys `cwd`, `cwds`, `runtimeWorkspaceRoots`, and `extraRoots` (string or list of strings) and `selectedCapabilityRoots` (`location.path` of each item). Exempt and documented in `EXEMPT_FIELDS`: `fs/*` paths, config write targets, plugin and project records, rollout `path`, permission grants, `skills/config/write` `path`, fuzzy-search `roots`, `sandboxPolicy.writableRoots`, and turn input items (Paseo sends image attachments as temp-file paths).
- A value is allowed only when it is an absolute path (after `~` expansion) whose real path (symlinks resolved; the nearest existing ancestor for a missing tail) is the harness root or below it by whole path components, and no other registered harness root is a deeper ancestor. Relative paths and non-strings are violations.
- `thread/resume` and `thread/fork` without `cwd` get `cwd` set to the server cwd, so a thread recorded elsewhere cannot run outside the boundary. `thread/start` and `turn/start` without `cwd` use the server cwd, which is inside.
- A violating request gets `{"id": <id>, "error": {"code": -32602, "message": "harness-launcher: <method> <field> is outside the <prefix> harness boundary: <value>"}}` and is not forwarded. A violating notification is dropped with a stderr line; a violating response is replaced by an error response to the server. An unparseable line gets a -32700 error and a JSON array, duplicate keys, or a message that cannot be checked (embedded NUL, excessive nesting) a -32600 error; none is forwarded and the relay continues. Nested harness roots are compared by inode so letter case cannot bypass them.
- Relay: line-oriented bytes without a length cap, written and flushed under one lock shared with injected errors; stderr inherited; exits with the child's status (128+signal when signalled) once the child exits, even if stdin stays open; forwards SIGINT/SIGTERM/SIGHUP; terminates the child when the client stdout pipe breaks.
- Drift: `test/fixtures/codex-app-server-path-fields.json` lists every field a client can send (definitions reachable from `ClientRequest`, `ClientNotification`, and the responses to `ServerRequest`) that is path-typed (`AbsolutePathBuf`, `LegacyAppPathString`) or named `cwd`, `cwds`, `path`, `paths`, `root`, `roots`, `*Root`, `*Roots`, `*Path`, `*Paths` in `codex app-server generate-json-schema --experimental`. Each must be classified as guarded or exempt. A test regenerates the list when `codex` is installed and fails on differences.
- It is a profile-consistency boundary for a trusted local client, not a sandbox; free-form `config` overrides are not inspected. The app-server runs without `-p`, so it uses the top-level `config.toml` defaults of the profile's `CODEX_HOME`; the host selects the model per thread.

### S4 Claude launcher fixes

- Management subcommands after the marker: if the first passthrough token is a Claude management subcommand (list moved to `harness-common.sh` as `harness_claude_is_management_command`), run the existing `claude-management` path with the passthrough argv. Isolation routing returns `legacy` for that shape, so no isolated session is created first.
- Thinking control: only an explicit disable counts: `--thinking disabled`, `--max-thinking-tokens 0`, or an inline JSON `--settings` whose `alwaysThinkingEnabled` is `false`. Then, with no caller `--effort`, the launcher drops its `xhigh`/`max` effort and forced-thinking `--settings`. Other `--settings` values (Paseo sends `fastMode`) leave launcher effort alone.
- `--` boundary: in the keyword loop `--` ends keyword parsing; `--` and everything after it are forwarded last, after launcher-owned flags, and imply a direct launch. Passthrough scans, bootstrap eligibility, autocompact detection, and the isolated `--session-id` guard scan only argv before a caller `--`.
- Isolated sessions: everything after the session is acquired runs inside a zsh `{ … } always { … }` block. The `always` block stops a started heartbeat and finishes the session once when no normal path finished it, and never returns. Normal paths mark completion.

### S5 Shell wrappers

With `harness_shell_enable`, plain `claude` calls `harness-auto claude base --passthrough "$@"` and plain `codex` calls `harness-auto codex --passthrough "$@"`; `codex --version`, `-V`, and `--help` go straight to native Codex. Management routing (`claude mcp …`) is unchanged. Breaking change: `claude rich` in an enabled shell now passes `rich` as a prompt, like native Claude; use `<prefix> rich` for presets.

### S6 `harness-auto` Codex working-directory validation

`validate_codex_working_dirs` also validates `-C<dir>`, `-C=<dir>`, and `--cd=<dir>`, continues past `--passthrough`, and stops at `--`.

### S7 `harness-paseo` config management

New installed executable (Python, launched through a wrapper that keeps the unresolved invocation path). The profile registry is the source of truth.

- Ownership: a sidecar `~/.config/harness-launcher/paseo-managed.json` (`{"version": 1, "configs": {"<config realpath>": ["<provider id>", ...]}}`) records the provider IDs sync wrote. Sync owns only `extends`, `label`, and `command` of those IDs; every other provider key and every other config key are preserved.
- `harness-paseo print [--bin-dir DIR]`: print the expected managed fields as JSON.
- `harness-paseo sync [--config PATH] [--bin-dir DIR] [--reload]`: the config (default `$PASEO_HOME/config.json`, else `~/.paseo/config.json`) must exist; a missing file is `FAIL: start Paseo once` (creating it could leave the relay on under Paseo's compatibility default). Merge the expected fields, remove owned IDs that are no longer expected (also from `agents.metadataGeneration.providers`), and leave unowned `harness-*` IDs with a WARN. When nothing changes, write nothing. Otherwise write a 0600 backup `config.json.harness-paseo.bak` atomically, then the config atomically with its mode kept, re-reading the original bytes just before the rename and exiting 1 if Paseo changed the file meanwhile. `--reload` runs `paseo daemon reload` and reports a failure without failing the sync.
- `harness-paseo check [--config PATH] [--bin-dir DIR] [--profile NAME]`: `OK`/`WARN`/`FAIL` lines. `FAIL`: missing config, missing managed provider, managed field mismatch, owned stale provider, provider ID collision, missing `<bin>/harness-auto` or `<bin>/harness-codex`. `WARN`: `daemon.relay.enabled` not `false`, unowned `harness-*` provider, unregistered `--profile`, `<bin>` inside a Git worktree. Exit 1 on any `FAIL`.
- Expected fields:
  - `harness-claude`: `extends: claude`, `label: Harness Claude`, `command: ["<bin>/harness-auto", "claude", "base", "--passthrough"]`.
  - Per registered profile `p` (lowercased, `_` → `-`, must match `^[a-z][a-z0-9-]*$`): `harness-codex-<id>`: `extends: codex`, `label: <p> Codex`, `command: ["<bin>/harness-codex", "--profile", "<p>"]`. Profiles mapping to one ID are skipped with FAIL.
- `<bin>` defaults to the directory of the unresolved invocation path (Homebrew: `$(brew --prefix)/bin`).

### S8 Harness-local Paseo worktrees (documented, no new command)

Paseo has only a global `worktrees.root` and an internal per-repository hash, so its worktree mode cannot be placed inside the owning harness. `docs/paseo-integration.md` documents the supported recipe: `git -C <harness>/projects/<repo> worktree add -b <branch> .worktrees/<slug> origin/HEAD`, then `paseo workspace create --isolation local --path <that path> --title <slug>`; remove with `paseo workspace archive <id>` and then `git worktree remove`.

## Tests (RED first)

- `test_codex_app_server_guard.py`: allowed and violating `cwd`/`cwds`/`runtimeWorkspaceRoots`/`extraRoots` (including nested `environments[].cwd`), symlink escape, `..`, `~`, relative, non-string, nested registered harness, missing tail under the root; exempt fields forwarded; resume/fork cwd injection; violating notification dropped; unparseable and array errors; child exit status; SIGTERM forwarding with stdin open; usage errors; schema drift snapshot classification plus live regeneration when `codex` exists.
- `test-launcher-codex-passthrough.sh`: guard argv for `--passthrough app-server --enable goals` and `app-server` (no `-p`); `fast app-server` exit 2; `debug models` no `-p`; `debug prompt-input` and `exec x` keep `-p base`; `-c k=v app-server` no `-p`; caller `-p`/`--profile=` single profile; caller `-C <inside>` replaces `--cd`, `-C <outside>` exit 2; `continue` after the marker verbatim; `app-server proxy` and `--listen ws://…` exit 2; isolated root passed to the guard.
- `test-harness-codex.sh`: `--version`; `--profile alpha app-server` from an outside cwd; no profile; bad and reserved profiles exit 2.
- `test-launcher-passthrough.sh` additions: `--passthrough auth status` management path; thinking disable rules (including Paseo-style `--settings '{"fastMode":true}'` keeping xhigh); `base -- continue`; `-- 'prompt'` direct launch; `--passthrough -- --model x` keeps the launcher model.
- Lease: failures after acquisition (gateway URL missing, retired `light`, passthrough session conflict) finish the session, and a relaunch of the same id succeeds.
- Routing: Codex passthrough cases and `--passthrough auth status` → `legacy`.
- Shell routing expectations include `--passthrough`; `claude -p plan` and `codex -a never` stay verbatim; `codex --version` native.
- `harness-auto`: attached `-C` forms and post-marker `-C` validated.
- `test_harness_paseo.py`: print; sync merge preserving user keys and provider settings, stale owned removal (including metadata generation), unowned `harness-*` kept with WARN, idempotence (no write, no backup), 0600 backup, concurrent-change abort, missing config FAIL; check lines and exit codes; ID collisions; bin-dir default without symlink resolution.

## Harness side (each registered harness)

- `harness-runtime-audit.sh --paseo`: run `harness-paseo check --profile <HARNESS_PREFIX>` when `harness-paseo` and the Paseo config exist, fold its `OK`/`WARN`/`FAIL` lines into the audit, `SKIP` otherwise. Fixture override: `PASEO_AUDIT_CONFIG`.
- Knowledge: `domains/knowledge/tools/paseo/paseo-host.md` with index and cascading updates per each harness's rules.

## Host (this Mac)

After release: `brew upgrade`, `harness-paseo sync --reload`, remove hand-written providers, run E2E for Claude plan mode and each profile's Codex (thread start inside and outside the boundary), and make the Paseo desktop app start at login so the daemon survives reboot with a login-shell environment.
