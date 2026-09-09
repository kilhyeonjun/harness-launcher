# Changelog

Notable changes are recorded here. This project follows semantic versioning for published launcher packages.

## 0.29.0 — 2026-09-09

### Added

- Launcher-owned Claude cmux title synchronization. Exact SessionStart handoffs
  follow native automatic and custom titles, including later manual renames and
  session switches within the same process.

### Fixed

- Keep title ownership live during slow cmux requests, preserve externally
  changed tab names, and clean up direct-launch brokers when the runtime exits.
- Export the selected profile prefix to Claude title hooks.

## 0.28.2 — 2026-09-09

### Fixed

- Keep Codex preparation warm when a regular `.in_use` runtime marker changes.
  Directory, symlink, and entry-type changes still invalidate the fingerprint.

### Changed

- Run reviewed integration tests with isolated fixtures in at most two shards.
  Security and new tests remain serial; `HARNESS_SURFACE_TEST_JOBS=1` retains
  the original complete serial test command.

## 0.28.1 — 2026-09-09

### Fixed

- Explicitly enable Codex native task progress after the upstream tool became
  opt-in. Warm preparation repairs missing or disabled tracker configuration.

## 0.28.0 — 2026-09-08

### Added

- Opt-in external agent filename namespaces in Codex surface manifests.
  Provider-owned native agent files survive warm and cold preparation, and
  corresponding Claude definitions are not converted over their native peers.
  Unlisted files and symlinks retain the existing quarantine behavior.

## 0.27.0 — 2026-09-08

### Added

- Opt-in Claude direct `fable` preset with high effort, plus a Fable entry in
  the preset and Custom model menus and shell completion. Existing numbered
  menu choices remain stable; Kiro and Codex gateways reject the preset.

## 0.26.2 — 2026-09-08

### Fixed

- Codex tab-title synchronization retries transient cmux errors with bounded
  backoff and stops retrying when its owning process exits. Local diagnostics
  distinguish recovery from exhausted retries without storing title contents.

## 0.26.1 — 2026-09-08

### Fixed

- `HARNESS_CODEX_APPS_ALLOWLIST` now invalidates a converged Codex home when
  ids are added, replaced, or removed. The regenerated policy keeps only the
  configured apps and returns to the warm path afterward.

## 0.26.0 — 2026-09-07

### Added

- `HARNESS_CODEX_APPS_ALLOWLIST` opts a project into named ChatGPT Apps. The
  feature flag stays off without it, and `[apps._default]` keeps unnamed apps
  disabled when it is set.

## 0.25.0 — 2026-09-06

### Added

- Generated profile inspection separates managed settings, project trust, and
  model-picker UI metadata while retaining full output drift detection.

### Fixed

- Codex hook adaptation supplies explicit runtime identity to canonical hooks
  instead of relying only on the inherited Codex home.

## 0.24.0 — 2026-09-06

### Added

- Read-only generated Codex profile inspection with setting provenance, output
  stamp consistency, and explicit limits on runtime and provider verification.

### Fixed

- Canonicalize equivalent Homebrew compatibility and opt preparation entrypoints
  so hook command hashes remain stable when callers use either path.

## [Unreleased]

## [0.23.0] — 2026-09-06

### Added

- Explicit native Codex `astra` profile selects GPT-6 Astra with medium reasoning
  from shell shortcuts and the launcher menu. Existing profiles and defaults
  retain their models. Generated profiles participate in warm-cache validation
  and repair.

### Fixed

- Local HTTP test fixtures no longer depend on reverse DNS before signaling
  readiness; their HTTP and redirect assertions are unchanged.

## [0.22.4] — 2026-09-06

### Added

- Generated Codex homes now enable experimental context management when the
  resolved Codex CLI is 0.153.0 or newer. Eligible ChatGPT sessions can retain
  long-thread details through notes and searchable history instead of relying
  only on a repeatedly compressed summary. Older clients omit the nested table
  because Codex 0.152.1 rejects that shape during bootstrap; API-key and custom
  provider eligibility remains controlled upstream.

### Changed

- Context management leaves the existing long-context request and auto-compact
  guard unchanged at `model_context_window = 1000000` and
  `model_auto_compact_token_limit = 414000`.

## [0.22.3] — 2026-09-06

### Added

- Project-owned MCP surface policy values: empty preserves legacy selectors,
  `single-full-compat` accepts direct Claude `light` and Codex `work` selectors
  as full with a deprecation warning, and `single-full` rejects those retired
  selectors. The policy is read only from the trusted project `launcher.env`;
  Kiro keeps its native light/full selection in every mode.
- Opt-in launchpad histories migrate to the full surface before display through
  a validate-then-rewrite transaction. Migration canonicalizes entries, sorts
  and de-duplicates them, bounds retained history, and atomically replaces the
  history file only after the replacement is complete.
- Exact MCP profile policies can now emit positive startup/tool timeouts,
  `required`, default tool approval, and per-tool approval in addition to tool
  allow/deny lists. Validation fails closed on invalid types or approval modes,
  and the warm-home check includes every emitted policy field.
- New Claude Code `opus` preset: the `rich` model at one effort step down
  (`opus[1m]` at `high` on Anthropic direct, `claude-opus-4-6[1m]` at `high`
  through a Kiro gateway, `opus` plus the configured context suffix through a
  Codex gateway). `rich` stays the deepest preset at `xhigh` with forced
  thinking; `opus` keeps the user's own thinking setting because `high` needs
  no override. It appears in the TUI mode menu between `plan` and `rich`, and
  in shell completion.

### Changed

- Generated Codex homes include the native `task-progress` status-line item, so
  `update_plan` progress stays visible without a launcher-owned task store.
- Generated Codex homes now opt into long context. `config.toml` requests
  `model_context_window = 1000000`, which Codex clamps to the model's own
  `max_context_window` — 872000 for the GPT-5.6 luna/terra/sol models every
  mode profile and subagent tier uses, an effective 828400 at the reported 95%.
  Sessions previously resolved the 272000 default, an effective 258400.
  `model_auto_compact_token_limit = 414000` puts the auto-compact line at half
  that effective window, matching the Claude side (`autoCompactWindow` 1000000
  at `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` 50 compacts at 500000 on a real 1M
  window). The keys were unpinned in 0.8.4 because the values then in use
  (1050000 / 900000) scheduled compaction past the real backend ceiling, so it
  never fired; the limit now stays below the effective window by construction.
- Codex subagents mapped from the Claude `opus` tier now default to GPT-5.6 Sol
  with medium reasoning effort. High effort remains an explicit escalation for
  unusually risky or complex reviews instead of the baseline for every review.
- Native Codex launch entrypoints now normalize and isolate the optional
  `HARNESS_CODEX_GLOBAL_MCP_ALLOWLIST` from each trusted `launcher.env` before
  preparation, preventing configured, empty, or inherited values from leaking
  across launches.

## [0.20.3] — 2026-07-27

### Added

- Each harness now derives its own `GH_TOKEN` on launch. `gh` keeps a single
  global active account, but the harnesses legitimately expect different GitHub
  users (personal and team identities), so whichever harness
  switched last decided whether the others' `gh` commands succeeded. On entry
  `harness_gh_token_load` reads `github_user` from the harness' own
  `config/.local/config.yaml` (falling back to `config/config.yaml`) and exports
  the matching `gh auth token --user` value, which takes precedence over the
  stored credentials. Strictly fail-open: a missing config, an unknown user, a
  malformed `github_user`, or no `gh` on `PATH` exports nothing and leaves the
  `pre-bash-gh-auth` hook as the backstop — an empty `GH_TOKEN` would override
  the stored credentials with nothing. The token value is never printed.

## [0.20.2] — 2026-07-27

### Fixed

- `rich` and `ultracode` resolve to `xhigh` (and kiro `rich` to `max`), which the
  API rejects while thinking is disabled: `output_config.effort 'xhigh' is not
  supported when thinking is disabled on this model`. A machine with
  `alwaysThinkingEnabled: false` in `settings.json` therefore 400'd on the first
  prompt of every rich session. Those two efforts now launch with
  `--settings '{"alwaysThinkingEnabled":true}'` so the mode no longer depends on
  per-machine settings. `high` and below are untouched and keep the user's own
  choice; `--settings` merges, so unrelated settings survive.

## [0.20.1] — 2026-07-24

### Changed

- MCP profile resolution now treats `enabled` as a wish-list: a server enabled in
  a profile but absent from every definition source is dropped with a stderr note
  instead of failing the launcher. A gitignored `mcp.local.json` thereby decides
  per-host MCP exposure — a machine without access to a given server (e.g. a
  host-local RAG backend) starts cleanly instead of dropping to the menu.

## [0.20.0] — 2026-07-23

### Changed

- Generalized cmux title and metadata-only observability profile validation to
  every valid registered prefix instead of a private fixed alias set.

### Security

- Removed private profile aliases from tracked code, tests, and documentation,
  with a repository-wide public-sanitization regression gate.

## [0.19.4] — 2026-07-22

### Changed

- Disabled standalone source installation. `install.sh` now exits without writing and directs users to Homebrew.
- Moved runtime-copy setup used by integration tests into a test-only fixture helper.

### Security

- Eliminated the source installer's multi-file commit and rollback surface, including parent-swap TOCTOU writes and cleanup outside the intended prefix.

## [0.19.3] — 2026-07-22

### Fixed

- Reject every existing symlink component and any `..` traversal in the install prefix, share path, and bin path before staging and again immediately before commit.
- Cover symlinked prefixes, symlinked `share` parents, and symlinked prefix ancestors without writing through them.

## [0.19.2] — 2026-07-22

### Fixed

- Removed marker- and filename-based share ownership classification because either proof was forgeable.
- Made source installation additive and fail-closed: missing assets are staged and installed, byte-identical existing assets are left untouched, and differing existing assets abort before any write.
- Kept rollback only for newly added assets, eliminating overwrite and restore paths for pre-existing share files.

## [0.19.1] — 2026-07-22

### Fixed

- Made the standalone source installer transactional: all assets and entrypoints are staged before commit, and a late failure restores the prior managed installation.
- Refused foreign regular files, foreign symlinks, and share-path symlinks instead of replacing or following them.
- Added a managed-share ownership marker while retaining verified upgrades from pre-marker installations.
- Added a real `harness-auto` → `harness-exec` → Claude policy-path test for prompt, resume, and permission argument preservation.

## [0.19.0] — 2026-07-22

### Added

- Add `harness-auto`, a fail-closed external-agent adapter that selects the
  single most-specific registered harness from the canonical current directory
  and then delegates unchanged agent arguments to `harness-exec`. It rejects
  unmatched workspaces, symlink escapes, registry symlinks, and ambiguous
  profile registrations.

### Changed

- Orca may now use `harness-auto` as its Claude, Codex, and Kiro command
  override, so built-in agent startup preserves the selected profile policy
  without a manually selected profile command.

## [0.18.0] — 2026-07-21

### Added

- Add `harness-profile register`, which installs any trusted harness prefix as
  a real executable backed by a small profile registry instead of requiring
  interactive Zsh startup. Registration is fail-closed and preserves existing
  command and profile ownership across trust boundaries.

### Changed

- Registered prefix functions and executable profile commands now share the
  `harness-exec` contract. They automatically keep the current workspace when
  it resolves inside the harness, preserve the harness-root default elsewhere,
  and retain explicit `--cwd` precedence and symlink-escape rejection. Prefix
  registration also rejects unsafe function names and shell-quotes harness paths.

## [0.16.0] — 2026-07-21

### Added

- Add `harness-exec`, a real non-interactive executable for Orca and other
  workspace managers. It supports an explicit profile-local `--cwd`, rejects
  missing or out-of-bound directories, preserves project-scoped Codex/Kiro
  homes, and forwards the same working directory through direct and TUI
  Claude, Codex, and Kiro launches.

## [0.15.2] — 2026-07-16

### Fixed

- Keep the cmux title watcher under the live launcher/Codex process ancestry
  and use `SessionStart` only to hand off the exact session ID. This preserves
  cmux caller authorization after the short-lived hook process exits.

## [0.15.1] — 2026-07-16

### Fixed

- Allow healthy but slow cmux tab rename round trips to complete instead of
  stopping the Codex title watcher at the previous two-second timeout.

## [0.15.0] — 2026-07-16

### Changed

- **Codex puts actionable context first.** The native terminal title now uses
  `activity | thread-title | project-name`, while the footer places
  `context-remaining` before `branch-changes`.
- **cmux tabs use the short harness alias after the thread name.** Registered
  profile launches export their dynamically scoped prefix, and a fail-open
  SessionStart watcher labels only the exact starting tab as
  `<thread name> | <profile>`. The watcher reads the matching session ID only,
  sanitizes controls, suppresses duplicate writes, and stops with its Codex
  owner or an unavailable cmux surface.

### Added

- Packaged `codex-cmux-title-sync.py` beside the other launcher-owned runtime
  adapters and included it in generated-surface fingerprinting.

## [0.14.1] — 2026-07-15

### Changed

- **Codex profile intent is explicit in the launcher UI.** `base` is labeled
  `Everyday · Recommended`, `sol` is labeled `Stronger · slower`, and `rich`
  is labeled `Deep · slowest`, while each row continues to show the generated
  model and effort. The underlying profile routing, the default `base`
  selection, and saved-history replay are unchanged. Reviewer subagents may
  still route independently to Sol/high even when the main session uses base.

## [0.14.0] — 2026-07-15

### Added

- **Subagent model/effort routing is now a single source of truth.**
  `bin/subagent-model-map.tsv` maps each Claude subagent frontmatter tier
  (haiku/sonnet/opus) to a per-runtime model + effort, and both
  `codex-home-prepare.sh` and `kiro-home-prepare.sh` read it so the three
  runtimes cannot silently drift. The Codex tier mapping is empirically tuned
  (gpt-5.6 luna/terra/sol measured on representative subagent tasks), not a
  mechanical opus→flagship lift: `haiku→luna/low`, `sonnet→terra/medium`,
  `opus→sol/high`. Missing table falls back to the same literals.
- **Kiro CLI now gets per-subagent agents.** `.claude/agents/*.md` are converted
  to `$KIRO_HOME/agents/<name>.json` with the tier-resolved Kiro model ID
  (column 4 of the map) and read-only vs workspace `allowedTools` derived from
  the agent's declared tools, so `chat.enableDelegate` can route to each
  subagent on its intended model. Generated files carry an ownership marker and
  are reversible-quarantined on source removal; the launcher's own
  `harness.json` and any hand-authored agent JSON are never touched. Effort is
  intentionally left to the session default — the Q/Kiro agent schema has no
  per-agent effort field.

## [0.13.0] — 2026-07-15

### Changed

- **Launchpad ordering.** "New …" composer entries now sit at the top of the
  launchpad with recent configurations listed below them, and the gum filter
  viewport is tall enough to show every row (header/input no longer eat list
  lines).
- **Codex `work` is now an MCP-surface toggle, matching Claude/Kiro `light`.**
  The Profile menu lists model profiles only; `work` moved to a
  `🔌 MCP surface: default|work` toggle on the summary screen and combines
  with any profile (previously base-only). The shortcut gained the same
  freedom: `<prefix> codex rich work` / `<prefix> codex work sol` both select
  the profile and the work surface, and `work` stays a surface keyword
  regardless of order with session/safety keywords (`continue work`,
  `full-auto work`, …) — only a genuinely free-form token before it (e.g.
  `codex exec work`) demotes it to prompt text. Happy + work is rejected
  (toggle exclusivity in the TUI, fail-closed before home preparation in the
  shortcut).

## [0.12.0] — 2026-07-15

### Added

- **Light MCP surface for Claude Code and Kiro CLI.** `light` drops SSH-backed
  MCP servers — `core/bin/start-ssh-mcp.sh` stdio wrappers and loopback HTTP
  servers on the SSH-tunnel port band 38200–38299 — and keeps everything else,
  unifying the MCP-surface concept across all three runtimes (Codex keeps its
  `work` profile):
  - TUI: a `🔌 MCP surface: full|light` toggle on the Claude and Kiro summary
    screens.
  - Shortcuts: `<prefix> light` (Claude, via `--strict-mcp-config` + a
    generated `.harness/claude/mcp-light.json`) and `<prefix> kiro-cli light`
    (via `HARNESS_KIRO_MCP_PROFILE=light` at home preparation).
  - The generated light config revalidates duplicate server names on every
    launch, matching the full-surface validation.

### Changed

- **Launchpad TUI.** The top screen now lists your recent launch configurations
  (up to 8, newest first, per-harness `.harness/launcher-history`) plus one
  "New …" composer entry per installed runtime, fuzzy-searchable under gum
  (type to filter, Enter to launch). Picking a history row replays that exact
  configuration through the same assembly path as a fresh config. Entries are
  deduped by config identity — relaunching an old row moves it to the top
  instead of duplicating it. The previous single-entry "Repeat last"
  (`.harness/launcher-last`) is migrated into the history automatically.

## [0.11.0] — 2026-07-15

### Added

- Codex `sol` profile shortcut (`<prefix> codex sol`, TUI Profile menu):
  GPT-5.6 Sol at medium effort — the stronger model at everyday effort.

### Changed

- Label Codex Fast/Base/Plan/Rich routes as operational speed, balanced, or deep presets and document how they differ from general model starting effort; generated routing remains unchanged. (In the TUI these labels are now generated from the profile configs.)
- **TUI v2 redesign.** Choice collection and command assembly are now separate;
  every launch (including replays) revalidates gateways, generated homes, and
  MCP configs through one assembly path per runtime.
  - **Repeat last**: the first menu relaunches the previous configuration in one
    keypress (per-harness `.harness/launcher-last`).
  - Step diet: permission mode, Chrome, and Happy are toggles on a single
    launch-summary screen instead of chained yes/no prompts.
  - Esc/`q` is one-step-back everywhere (top menu exits); the no-gum fallback
    menu reprompts on invalid input instead of silently exiting.
  - Gateway health probes run in the background at startup (no 2s×N blocking)
    and the provider menu shows live 🟢/🔴/⚪ marks.
  - Breadcrumb headers (`harness ▸ runtime ▸ session`) and a unified launch
    banner across Claude/Codex/Kiro.
- **Single source of truth** (`bin/harness-common.sh`) shared by the TUI, the
  shortcut path, and tab completion: mode→model/effort tables (Claude + Kiro),
  binary resolution, gateway probes, MCP local-config validation, secrets
  export, and auto-compact PCT. Menu labels and completion descriptions are
  generated from the table, so they can no longer disagree with what launches.
  Native-Codex profile labels are read from the generated profile configs.
- TUI work MCP surface is now base-profile-only (a Profile-menu entry), matching
  the shortcut path; the old separate surface menu that allowed rich/plan + work
  combinations is removed.
- Shortcut parity: `codex fork` now forks the last session like the TUI, and
  `codex full-auto|never|bypass` map to the Codex safety flags instead of
  passing through as prompt text.

### Fixed

- TUI no longer launches when `.mcp.local.json`/`mcp.local.json` duplicates a
  committed `.mcp.json` MCP server (validation failure now blocks, matching the
  shortcut path).
- Fast preset label claimed Sonnet while launching Haiku; labels are now
  derived from the mode table (tab-completion text included).
- TUI honors `HARNESS_KIRO_BIN` for Kiro runtime detection and launch.
- Ultracode session hint no longer leaks into a different mode picked after
  backing out of the ultracode selection.
- `cd "$HARNESS_DIR"` failures abort the launcher instead of starting sessions
  in the wrong directory.
- Tab completion no longer leaks gateway API keys into interactive shell
  variables (env files are sourced in subshells).
- String→`xargs` argument round-trip removed; arguments are arrays end-to-end,
  so values containing quotes/spaces can no longer silently wipe the command
  line.
- Keep the manifest warm-path validator aligned with the Codex 0.144 status-line fields so unchanged homes no longer rebuild on every launch.

## [0.10.2] — 2026-07-11

### Fixed

- Track curated-plugin skill directory membership separately from volatile install metadata, preventing metadata-only rewrites from forcing a cold surface rebuild while still detecting new plugin versions.

## [0.10.1] — 2026-07-11

### Fixed

- Pin the Homebrew runtime to Python 3.13 and prefer its versioned path, avoiding a Python 3.14 `pyexpat` bottle incompatibility observed on a supported macOS/Xcode combination.

## [0.10.0] — 2026-07-11

### Added

- Schema-v1 `config/codex-surface.json` resolution for exact skill, Claude-plugin, Codex-only, and MCP profile membership.
- Atomic skill catalogs and successful-input fingerprints for validated warm Codex-home preparation.
- Manifest-governed explicit command wrappers that cannot overwrite a canonical project skill with the same name.
- Optional namespaces for package-scoped Codex-only skill profiles.

### Changed

- Manifest-enabled homes collapse duplicate skill routes, keep explicit-only skills out of implicit prompt matching, and disable unselected routes by exact `SKILL.md` path.
- Manifest MCP profiles render explicit enabled flags and gate bundled Computer Use; warm no-op preparation now avoids compiler and plugin work.
- Warm validation uses cached source identities and plugin topology, preserving invalidation for newly installed unapproved plugins without hashing plugin tests, docs, or assets.
- Exact homes discard stale overrides of selected skills, quarantine unmanaged generated-home routes, catalog enabled product-plugin skills, and shell-quote hook paths safely.
- Warm stamps validate launcher-owned output hashes and a normalized managed-config projection, including complete MCP payloads, while preserving intended runtime trust and external-plugin state.
- Generated skill and agent inventories are exact; unexpected entries are moved intact to a reversible quarantine.
- Python 3.11 or newer is now required, with Homebrew/non-login path selection and an explicit `HARNESS_PYTHON_BIN` override.

## [0.9.5] — 2026-07-10

### Added

- Contributor guide, security policy, issue forms, pull request template, and CI workflow.
- Architecture, maintained Codex integration, and troubleshooting documentation.
- Generic project registration examples and public trust-boundary guidance.

### Fixed

- Source installation now includes the Kiro runtime-home adapter.
- Kiro MCP inputs are validated in external staging; duplicate server names leave no new or modified generated runtime state.
- Codex takes the global cache lock only when bundled marketplace or plugin work needs synchronization.

### Changed

- Reorganized the README for public installation, onboarding, development, and support.
- Replaced the stale native Codex implementation plan with maintained integration documentation.

## [0.9.4] — 2026-07-10

### Fixed

- Added compatibility for retained macOS Chrome plugin caches whose native host is named `ChatGPT for Chrome`.
- Preserved the current `Codex for Chrome` name as the preferred host.

## [0.9.3] — 2026-07-10

### Added

- GPT-5.6 Codex profiles: Luna/low for fast, Terra/medium for base and default, and Sol/high for plan and rich.
- Project-local `.codex-only/skills` discovery.
- Chrome bridge and Computer Use plugin preparation for terminal Codex.
- Generated Codex agent model mapping by capability tier.

### Changed

- Codex context and compaction values now follow runtime model metadata instead of launcher pins.
- Terminal Codex from `PATH` is preferred over the app-bundled CLI.
- Shared global plugin/cache writes use macOS kernel locking.

### Security

- Browser execution trust uses exact browser-client SHA allowlisting.
- Project-writable runtime homes are not added as broad trusted code paths.
- Global MCP drift warnings are opt-in.

## 0.9.2 — 2026-07-09

### Fixed

- Made Codex CLI resolution deterministic across direct and interactive launcher paths.

[Unreleased]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.22.3...HEAD
[0.22.3]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.22.2...v0.22.3
[0.16.0]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.15.2...v0.16.0
[0.15.2]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.15.1...v0.15.2
[0.15.1]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.15.0...v0.15.1
[0.15.0]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.14.1...v0.15.0
[0.14.1]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.10.2...v0.11.0
[0.10.2]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.10.1...v0.10.2
[0.10.1]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.5...v0.10.0
[0.9.5]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.2...v0.9.3
