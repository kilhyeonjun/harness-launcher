# Changelog

Notable changes are recorded here. This project follows semantic versioning for published launcher packages.

## [Unreleased]

## [0.15.1] — 2026-07-16

### Fixed

- Allow healthy but slow cmux tab rename round trips to complete instead of
  stopping the Codex title watcher at the previous two-second timeout.

## [0.15.0] — 2026-07-16

### Changed

- **Codex puts actionable context first.** The native terminal title now uses
  `activity | thread-title | project-name`, while the footer places
  `context-remaining` before `branch-changes`.
- **cmux tabs use the short harness alias after the thread name.** Native kh,
  gp, and gd launches export their dynamically scoped prefix, and a fail-open
  SessionStart watcher labels only the exact starting tab as
  `<thread name> | kh/gp/gd`. The watcher reads the matching session ID only,
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

[Unreleased]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.15.1...HEAD
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
