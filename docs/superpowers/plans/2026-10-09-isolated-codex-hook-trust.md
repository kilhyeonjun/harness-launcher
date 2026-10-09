# Preserve approved Codex hooks in isolated sessions

Frozen delivery plan, promoted from the task's reviewed scope before release.
Baseline: launcher 0.49.2. Risk: HIGH, because hook trust controls code execution.

## Acceptance

- A fresh isolated session can inherit an existing approval for the same verified
  hook definition and script bytes without another native hook review.
- Native hook decisions in `<profile>.config.toml`, including disabled hooks and
  foreign/plugin state, survive warm launches and cold regeneration.
- Unknown or changed hooks, callback bytes, native executables, and malformed or
  ambiguous approval/broker evidence retain native review.
- Global config, existing native sessions, legacy package selection, and other
  profiles' source files are preserved.

## Interfaces and boundaries

1. The operator captures a private approval artifact only after explicit user
   approval and an exact source audit. It includes the physical source root,
   normalized complete hook set/digest, approved snapshot/base blob provenance,
   native version/executable identity, and script/callback hashes. Raw hooks-file
   SHA is audit metadata because each isolated path changes those raw bytes.
   The launcher never creates or refreshes an approval artifact.
2. `inherit(config, candidate_hooks, published_home)` verifies the launcher-owned
   session record, source/root/inode association and exactly one OPEN state.
   Canonical native fingerprints are revalidated. Script bytes must match the
   approved artifact and both approved/current Git base blobs.
3. Only literal core-hook root tokens and the four registered package callbacks
   may change paths. A callback must be the current verified package file and
   match the unique old approved path's bytes and recorded hash. Other argv,
   matcher and handler attributes remain exact. Host status commands stay literal.
4. Source/broker reads use bounded same-user fd reads with `O_NOFOLLOW`, nlink1
   and no group/world write. Native 0644/0755 source modes remain supported;
   approval artifacts require 0600.
5. `profile_signature` excludes only native hook-state blocks from launcher-owned
   profile output signatures. `preserve_profile` retains those blocks exactly;
   every other profile byte remains managed. Profile and base config publication
   use the existing compare/exchange transaction.

## Verification

Production-prepare RED/GREEN tests cover fresh inheritance, stale or absent
approval, changed scripts/callbacks, forged broker records, ambiguous journals,
native identity drift, normalized digest/base blob mismatches, symlink races,
hardlinks/writable files, and unrelated new commits. Profile tests retain 48
native/foreign decisions across warm and cold launches and repair unrelated
profile drift. Package-path tests allow only verified same-byte callback moves.
Native Codex 0.161 `hooks/list` fingerprints verify the supported command subset.

## Delivery

Publish the reviewed source through a PR, tagged release and exact Homebrew tap
revision. Activate the existing immutable release store for future sessions;
preserve legacy packages and old session bindings. Install only the operator's
already-approved source artifacts, then verify fresh native sessions and clean
up owned probes. Fetch and compare the final remote SHA and delivered paths
before claiming delivery. No general hook-trust bypass or daemon restart.
