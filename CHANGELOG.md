# Changelog

Notable changes are recorded here. This project follows semantic versioning for published launcher packages.

## [Unreleased]

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

[Unreleased]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.5...v0.10.0
[0.9.5]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.2...v0.9.3
