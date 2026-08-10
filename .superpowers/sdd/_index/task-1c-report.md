# Task 01C Report — Atomic Managed-Output Publication

## Outcome

`bin/codex-home-prepare.sh` now performs all surface ownership/profile/policy preflight against the live home before creating a managed-output candidate. Cold generation runs only in a same-filesystem `.codex-home-prepare-stage.*` directory, validates the complete candidate, canonicalizes candidate paths, and publishes only centrally declared launcher-owned roots. Publication uses atomic rename exchange with reverse-order rollback, and publishes `.surface-success.json` last.

The live `CODEX_HOME` is never swapped. Sessions, `history.jsonl`, auth files/links, user runtime plugins, user skills, and other non-managed paths remain in place on success, compiler failure, resolver/preflight failure, candidate failure, publication failure, and signal cleanup.

## Owned files

- `bin/codex-home-prepare.sh`
- `bin/codex-surface.py`
- `bin/codex-surface-warm.py`
- `test/test_codex_surface.py`

## RED evidence

1. Managed ownership was not centrally queryable:

   ```text
   /opt/homebrew/opt/python@3.13/libexec/bin/python3 test/test_codex_surface.py \
     PrepareIntegrationTests.test_preflight_failure_preserves_every_managed_output
   FAIL: codex-surface.py rejected managed-output-paths as an invalid command
   elapsed: 2.204s
   ```

2. Publication fault injection initially did not fail or exercise rollback:

   ```text
   /opt/homebrew/opt/python@3.13/libexec/bin/python3 test/test_codex_surface.py \
     PrepareIntegrationTests.test_publish_failure_rolls_back_every_managed_output
   FAIL: expected return code 1, received 0
   elapsed: 4.521s
   ```

The production changes that make these tests fail when removed are the resolver-owned managed-root inventory and the rollback path after partial publish, respectively.

## GREEN evidence

- Preflight duplicate failure preserves the exact managed snapshot and removes staging artifacts: PASS, 3.208s.
- Compiler failure, post-candidate failure, and `SIGTERM` during the candidate pause preserve managed and runtime snapshots: PASS, 16.936s (fresh rerun later included in the 10-test batch).
- Successful cold rebuild preserves sessions/history/auth/user plugin/user skill state: PASS, 5.541s.
- Injected partial publication failure reverses all prior exchanges and restores the exact managed snapshot: PASS, 3.685s.
- Focused atomic/global/drift/marker/plugin regression batch: 10 tests PASS in 49.139s.
- Focused shell suite:

  ```text
  HARNESS_PYTHON_BIN=/opt/homebrew/opt/python@3.13/libexec/bin/python3 \
    /bin/bash test/test-codex-home-prepare.sh
  ✓ All codex-home-prepare tests passed
  ```

  Streamed wall metadata totaled approximately 90s (11s initial yield, then 30s + 30s + 19.4s).

- Syntax/static checks:

  ```text
  /bin/bash -n bin/codex-home-prepare.sh
  /opt/homebrew/opt/python@3.13/libexec/bin/python3 -m py_compile \
    bin/codex-surface.py bin/codex-surface-warm.py
  git diff --check
  ```

  All returned exit 0.

## Ownership and preservation details

`codex-surface.py managed-output-paths` is the observable ownership source used by both tests and publication. It contains fixed outputs (stamp, fingerprint cache, AGENTS, config and every config variant including `sol`, hooks, catalog, surface config, markers, and the known bundled plugin roots) plus trusted dynamic skill/agent roots derived from the previous success stamp signatures. A poisoned marker cannot claim an unowned skill or agent.

Candidate generation seeds only the launcher-owned `config.toml` needed to preserve its allowed runtime sections. It does not copy the live home or stage runtime files. The compiler writes through an isolated harness facade into the candidate rather than mutating the live AGENTS.md.

## Self-review

- Confirmed `.surface-success.json` is ordered last in publication.
- Confirmed the fingerprint cache is generated in the candidate and the live cache is untouched until publication.
- Confirmed stale dynamic roots come only from trusted prior stamp signatures, not marker membership.
- Confirmed failed exchanges, creates, and deletes each have a reverse operation and rollback runs in reverse order.
- Confirmed candidate staging is beside the live home and device IDs are checked before publication.
- Confirmed existing kernel lock and legacy non-surface behavior remain intact; focused shell lock/race tests pass.
- `git diff --check` reported no whitespace errors.

## Concerns / skipped verification

- The existing 100ms warm assertion was retained unchanged, as required, but failed on this host despite the compiler staying warm. The latest run reported median 160.6ms with samples `160.6,163.3,161.9,152.5,151.6ms`; earlier runs reported medians 148.0ms and 209.2ms. No warm-path optimization or threshold weakening was made in this task.
- The full test suite was intentionally not run per task instruction.
