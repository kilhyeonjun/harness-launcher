# Bound candidate verification

## Acceptance and exclusions

The trusted remote baseline verifier must inspect exactly the broker's complete merged candidate without committing or pushing. This is a narrow delivery repair, not activation of the broad SSOT draft, storage rollout, DB authority, credentials, fencing or custody. Unsupported baselines refuse; never invoke the submitted verifier as fallback or grant maintenance authority.

## Implementation contract

1. After fresh-baseline merge and exact submitted/candidate path-and-kind comparison, compute the candidate tree. Invoke the trusted verifier with `--staged-only --dry-run --no-push --verify-candidate BASE_OID TREE_OID` in both normal and headless branches.
2. The repository implementation binds full commit/tree identities, freezes the complete index, uses committed baseline policy, scans frozen blobs, checks actual worktree bytes/modes and rechecks HEAD/ref/index/tree/selected test inputs. Ordinary protected staged-only delivery remains refused.
3. The broker independently rechecks submission, candidate HEAD/tree, and commit parent/tree/index before non-force publication. A remote advance rebuilds and reverifies. Preserve queue custody, leases, recovery and receipts.
4. Headless verification remains in a scrubbed disposable sandbox. Recreate only `refs/remotes/origin/main` at the explicit fresh BASE in the candidate copy and trusted clone; force `HARNESS_AUTHORITY_NO_REFRESH=1`. Do not restore URLs, credentials, network refresh or copy verifier changes back. Authenticated release/cache unavailability remains a refusal.

## Verification plan and execution record

Session: 2026-10-26 protected-delivery continuation. Launcher baseline `3ce891197185466993f403653969bad083650ffe`; implementation commit `e07674323b4cdb7ef265d7a5268bb28b26b493f1`. Source plan was preserved in the task's local contract before implementation; this repository copy records the plan and evidence for draft PR172. It does not retroactively claim this file existed before draft creation.

- Independent design reviews required baseline policy, real worktree equivalence, frozen secret scanning and final rebinding. Implementation retained those constraints.
- `ReviewBoundBrokerImplementation` reviewed the broker diff; `ReviewHeadlessBoundAnchor` reviewed its later cache-only baseline repair. Recorded actual model for both: `anthropic/claude-opus-5-5`, `resolvedModelIsFallback=false`. Authors and reviewers were separate passes.
- The headless reviewer found a test probe referencing a file deleted by an earlier scenario. Corrected the probe to surviving `merge.txt`; the complete final session-isolation regression passed in 255.89 seconds, including sandbox HOME denial, scrubbed environment and multiprocessing behavior.
- Earlier matching concurrency and headless suites passed in 66.436 and 375.474 seconds; 31 queue tests passed in 183.990 seconds. Those unchanged scenarios were not rerun for a fixture-only correction.
- Real-source broker smoke exercised normal/headless success, excluded-path refusal and index-flag mutation refusal against disposable local bare remotes. The exact company-profile baseline plus five-path bootstrap patch passed 127 repository cases in 179.43 seconds and all six smoke scenarios in 26.84 seconds. Accidental personal-profile-only selection tests were removed from the company-profile bundles, not accommodated by importing unrelated policy.
- CI exposed a sandbox-denied compiled system Git configuration path and private aliases in this plan. The repair forces `GIT_CONFIG_NOSYSTEM=1` only in the scrubbed headless environment, retains generated global configuration, and leaves normal mode and sandbox permissions unchanged. The plan is now profile-neutral; sanitization policy was not weakened.
- Independent follow-up implementation review (`ReviewFinalGitIsolation`) approved the repair. The tool result did not expose its actual provider/model or fallback metadata; no model attribution is inferred. Final consolidated verification passed: full session isolation 181.647 seconds, full headless suite 311.538 seconds, and the previously failing queue scenario 5.454 seconds. The regression proves an existing forbidden system-config file remains unreadable while Git succeeds, with caller-zero preserved normally and forced to one headlessly. Public sanitization (four tests) and markdownlint (26 files) passed before this evidence-only addition.
- Rebuilding the company-profile bundle against a newly advanced remote changed no approved source bytes or modes; upstream changes were unrelated documentation. The current exact bundle passed 127 tests in 93.85 seconds and six real-source smoke scenarios in 17.598 seconds.
- Full host-suite execution, production remote integration, installed activation and operational SSOT are not implied by these proofs. No frontend surface changed; browser screenshots are not applicable.

## Required rollout order

1. Deliver the already-supported repository through its admitted official broker and freshly verify the actual remote commit and delivered manifest.
2. For each unsupported company baseline, prepare an exact source-only bundle against a fresh remote baseline. Include only the repository verifier, portable candidate tests and minimal API documentation/index changes. Keep hashes, modes, origin, BASE and matching test evidence. Refuse upstream overlap; do not substitute an older local clone.
3. A genuine native maintainer, outside AI execution, must coordinate quiescence through application and publication. Require the exact canonical root/origin/main, clean index/worktree, fresh remote equality and approved BASE. The publication helper requires the canonical checkout to already equal the approved BASE; it does not fast-forward or rewrite the checkout. Immediately before the existing path-scoped commit wrapper, verify exact approved bytes, modes, pathset and unchanged baseline. Keep all effective hooks, shared delivery lock and non-force push. No agent self-grant, identity clearing or guard bypass.
4. Independently fetch and verify remote parent, exact pathset, bytes and modes. Wrapper exit zero is insufficient because remote verification can remain incomplete; post-commit hooks may publish before wrapper readback.
5. Only after all three trusted remote baselines support the API may PR172 be merged and released through the ordinary tag/release/tap/upgrade process. Exercise the actual installed broker. Preserve immutable existing runtime snapshots and keep broad PR171 activation separate.

## Deferred observations

The 375.474-second headless fixture is a measured bottleneck candidate, not evidence of a regression. Runtime admission errors and irreversible-guard classification of a read-only company-repository clone are separate follow-ups. Do not add runner refactoring or bypasses to this repair.
