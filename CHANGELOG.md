# Changelog

Notable changes are recorded here. This project follows semantic versioning for published launcher packages.

## [Unreleased]

### Added

- Contributor guide, security policy, issue forms, pull request template, and CI workflow.
- Architecture, maintained Codex integration, and troubleshooting documentation.
- Generic project registration examples and public trust-boundary guidance.

### Fixed

- Source installation now includes the Kiro runtime-home adapter.

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

[Unreleased]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.4...HEAD
[0.9.4]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/kilhyeonjun/harness-launcher/compare/v0.9.2...v0.9.3
