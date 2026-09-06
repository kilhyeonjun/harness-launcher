# Codex Context Management Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable experimental context management by default in three launcher-managed Codex homes.

**Architecture:** The generator detects the resolved Codex CLI version and emits the nested setting on 0.153.0+. The warm probe uses the same capability result so upgrades, downgrades, and manual drift rebuild exactly once.

**Tech Stack:** Bash, Python 3.13, TOML, Homebrew Formula

**Spec:** Chat-approved bounded design from the 2026-09-06 session.

## Global Constraints

- Emit `[features.context_management]` with `experimental_mode = true` on Codex 0.153.0+.
- Omit the table on older/unavailable clients; 0.152.1 rejects the nested map.
- Preserve `model_context_window = 1000000`, `model_auto_compact_token_limit = 414000`, and all other feature values.
- Release/install `v0.22.4`; regenerate and read back all three target homes.
- Preserve unrelated dirty files and stage only task-owned paths.

---

### Task 1: Generator and warm-path semantics

**Files:** `bin/codex-home-prepare.sh`, `bin/codex-surface-warm.py`, `test/test-codex-home-prepare.sh`, `test/test_codex_surface.py`

**Interfaces:** Consumes resolved `codex-cli MAJOR.MINOR.PATCH`; produces version-compatible TOML and one-rebuild convergence.

- [x] Add parsed-TOML generator tests for 0.152.1 omission and 0.153.0 activation.
- [x] Add warm repair test for `experimental_mode = false`.
- [x] Verify RED: missing key and unconditional 0.152 table fail.
- [x] Parse the resolved version and export `HARNESS_CODEX_CONTEXT_MANAGEMENT_SUPPORTED=true|false`.
- [x] Conditionally emit the nested TOML and compare the same expected mapping in the warm probe.
- [x] Prove capability downgrade/upgrade rebuilds once, then stays warm; mutation of the warm predicate must fail.
- [x] Run:

```bash
env -u HARNESS_RUN_DIR bash test/test-codex-home-prepare.sh
env -u HARNESS_RUN_DIR python3.13 test/test_codex_surface.py -v
```

### Task 2: Documentation

**Files:** `CHANGELOG.md`, `docs/codex-integration.md`, canonical harness `domains/knowledge/tools/codex-cli/feature-flags.md`

- [x] Document the version/eligibility boundary and same-thread versus cross-session memory.
- [x] Correct the stale unpinned-context claim and retain the exact 1000000/414000 policy.
- [x] Run `rg -n "context_management|0\.153\.0|414000" <three docs>` and repository-scoped `git diff --check`.

### Task 3: Verification, review, and release

**Files:** task-owned launcher paths; Homebrew `Formula/harness-launcher.rb`; three generated `.harness/codex/config.toml` files

- [x] Run:

```bash
env -u HARNESS_RUN_DIR bash test/run-all.sh
git diff --check
```

- [x] Independent review: implementation approved; add surfaced capability-transition evidence and keep this plan under 80 lines.
- [x] Re-review the bounded fixes once.
- [ ] Commit/push launcher, tag `v0.22.4`, and verify fetched local/remote SHA equality.
- [ ] Set formula tag/revision, audit/test, commit/push, and verify remote delivery.
- [ ] Reinstall launcher; require installed generator SHA to match the released source.
- [ ] Regenerate all target homes and require `CODEX_HOME=<home> codex features list` to report `context_management ... true`.
- [ ] Commit the canonical knowledge update or report its dirty/behind delivery blocker without stashing/resetting unrelated work.
