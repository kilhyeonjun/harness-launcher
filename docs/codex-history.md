# Durable native Codex history

Native conversation artifacts are data. Generated configuration and disposable
Git workspaces have different lifetimes. This design replaces the claim that
all generated runtime-home contents are disposable; it adds no always-on agent
rule, service or daemon.

## Boundaries

- Archives are host-local, source/profile-bound and owner-private (0700/0600).
- Keep original native/isolation UUIDs, source home and runtime provenance.
- Never copy auth, generated config, hook trust, plugins or live process locks.
  The same holds for execpolicy `rules/` (command-approval authority), the exact
  Native app, daemon and tool state names `app-server-control`,
  `app-server-daemon`, `process_manager`, `computer-use`, `vendor_imports`,
  `ambient-suggestions`, `.codex-global-state.json`, `.codex-global-state.json.bak`,
  `.cmux-title-sync` and `.glider`, Finder `.DS_Store`, and interrupted `mktemp`
  siblings of generated files (`.AGENTS.md.XXXXXX`, `.config.toml.XXXXXX`,
  `.plugin-<name>.XXXXXX`, ...). A six-letter word suffix matches that pattern
  too; every matched prefix names generated config, never history. The generic
  `sqlite/` and `tui-luna-reserve/` names are excluded only while they hold the
  app's `codex-dev.db` (automations and inbox) or nothing. Excluded entries are
  not archived, so retiring a root discards them. That state and qualifying
  generic directories are inventoried by name and kind only: content changes do
  not hold a snapshot, but an entry appearing, disappearing or changing kind does.
- Preserve complete sessions and archived sessions, including segmented rollouts,
  parent history, attachments, shell snapshots, memories and native databases.
  `external_agent_session_imports.json` travels with them so an imported
  external session is not imported again.
- Classify every top-level entry. Unknown data, active writers, invalid SQLite,
  symlinks, changed source, missing provenance or incomplete history block deletion.
- Read-only SQLite backup includes committed WAL data. A WAL file alone does
  not prove a live writer; independent database backups do not prove the whole
  home was stable. Check the complete source inventory before and afterward.

## Internal interfaces

`bin/codex-history.py` provides on-demand `snapshot`, `restore`, `verify`,
`catalog`, `presence`, `content-kind` and `protect-pool` operations; it is not a new public executable.

- `snapshot --source HOME --catalog STORE --receipt RECEIPT --source-root ROOT
  --isolation-id UUID --runtime-revision REV` records immutable native data,
  source inventory, provenance and content hashes. `REV` is a full Git SHA or
  the explicit `legacy-unknown` value, never an inferred pin.
- `restore --catalog STORE --snapshot ID --destination HOME --receipt RECEIPT`
  writes native artifacts into a fresh home without overwriting existing native
  files or importing authority. Generated files may already be present.
  With `--native-id UUID`, copy only that thread's committed raw rollout and
  segments, associated attachments/images/shell snapshots, and external import
  ledger. Leave databases, indexes, history lists and unrelated threads in the
  full original snapshot. A selected thread with `history_base` is refused
  before creating the destination: characterized Native 0.163 loses inherited
  projected items when rebuilt from raw-only physical parents. No shortened
  resume or silent fallback to a full HOME copy is permitted.
- `verify --catalog STORE --snapshot ID --source SOURCE_HOME --codex-bin BIN`
  checks the saved hashes and a fresh derived restore. Original source paths
  must be inaccessible during the native full-history read. Only derived
  databases may relocate schema-known home paths; originals remain untouched.
  Full-retirement proof admits characterized Native 0.161.0/0.162.1/0.163.0.
  Native 0.163.0 is checked with complete preserved projections, including
  parent cuts and copied parent metadata. Embedded parent headers require their
  identical standalone original to remain preserved; the selected raw-only restore restriction above remains intact.
  A home with no rollouts must have an empty known SQLite thread catalog and
  projection, no nonempty history lists, and an empty active/archived Native
  catalog. Missing rollouts for a nonempty catalog still block retirement.
  Historical `commandExecution.commandActions` read paths and `fileChange`
  change paths remain unchanged metadata. A retiring-workspace `imageView`
  requires exact thread/turn/item/path custody: bounded no-follow original
  bytes must match a typed inline image in that physical thread and turn.
  The snapshot retains a private content-addressed copy under `attachments/`
  and binds its checksum and tuple into the manifest and archive inventory.
  Offline Native must read both the full raw history and copied image bytes;
  complete wire items remain unchanged. This proves byte preservation, without
  claiming model interpretation or old-path UI navigation. Unknown paths,
  missing inline bytes, changed tuples and corrupt copies still hold retirement.
  Only direct typed tool-output blocks during an active turn qualify; nested
  diagnostic metadata and output after turn completion do not. Valid parent-cut
  projections reuse the physical parent's image custody without assigning a
  new owner. Supported original references are absolute paths or empty-host
  `file:///` URLs whose path is literal; other URI forms gain no exception.
- `catalog --source-root ROOT --state-home STATE [--legacy-state-home STATE] [--native-id UUID]`
  reports native UUID, source/home/isolation, status, time and origin pin from
  canonical, live isolated and validated archived data. No conversation body,
  secret or grant appears in default JSON output. Ambiguous owners fail closed.
  Missing or mismatched original root-inode records produce metadata-only
  `warnings` for that candidate; other verified homes remain discoverable.
  Quarantined bodies are not parsed, their roots cannot be prepared or retired,
  and filename UUID collisions keep that UUID ambiguous. Incomplete filename
  hints block selection rather than guessing an owner. `--native-id` narrows
  the output to that UUID before owner dedupe (same row, same schema); each
  home's inventory is hashed once per call unless its stat signature changes.
  A root-inode record matches when the inode is equal and the device is equal
  or the root sits on the device of its `worktrees` directory (APFS device
  renumbering after a reboot).
  Each row also carries `origin_state_home`, the state home that owns the
  origin's launch record: for a live row `P` of
  `<P>/worktrees/<id>/.harness/codex`, for a snapshot row the same rule on the
  manifest `source`, for a canonical origin the legacy XDG home. It must equal
  exactly one configured state home (current or `--legacy-state-home`); any other
  origin is the empty string and grants nothing.
- `prepare --source-root ROOT --state-home STATE --native-id UUID` snapshots a
  selected stable canonical or terminal isolated home. Canonical provenance uses
  the literal `canonical` marker and exact source home, never a fabricated Git
  UUID. A Native UUID lease spans preparation, fresh creation and Native exit.
- `protect-pool --state-home STATE --source-root ROOT --codex-bin BIN` verifies
  every terminal native-bearing root regardless of age, plus every old tomb,
  before an immutable older runtime can execute its GC. Unknown or unverified
  candidates refuse that launch; old-runtime retention has a 24-hour floor.
  An explicit `archive` retention sentinel remains intact so numeric-only
  older engines refuse deletion. Profiles share one old pool and its GC, so
  each root and tomb is protected under its own recorded source root;
  `--source-root` names only the caller.
- `presence --source HOME --anchor STATE` returns `native` or `absent` only
  after validating accessible, owned directory ancestry. Permission errors,
  redirected paths and failed checks hold the original root or old tomb.
- `content-kind` uses the same boundary checks, then classifies every top-level
  entry. A HOME containing only recognized generated/runtime entries returns
  `generated` and needs no Native probe. Any included payload returns `native`;
  unknown artifacts refuse classification. `presence` retains its old meaning.

Snapshot/archive copies use private APFS copy-on-write clones when supported,
otherwise a safe copy. They never hardlink mutable data. Full original Native
snapshots and raw archives are retained indefinitely; transcript backup alone
cannot authorize deleting a Native snapshot or a unique store.

## Retirement and recovery

GC first takes the existing runtime lease. It snapshots stable terminal data,
moves the original root to recoverable `.archiving-*` staging, and verifies the
restored history without access to the original pathname. Failure restores the
root; crashes retain staging. Delete only after a durable successful native
restore receipt and final source validation. Old `.retired-*` remnants receive
the same protection; a filename is not deletion authorization.
The managed conversation catalog also retains its verified transcript archive.
That transcript backup alone does not authorize Native root deletion. Missing
original inode provenance or an invalid imported-parent ledger holds the root
before Native data is copied. Valid imported-parent source-owner tuples and
ledger hashes remain in Native snapshots; imported parents do not become new
owners in either live or archived Native catalogs.
Fresh Native restores retain all context originals but assign ownership only to
the selected UUID. The managed catalog validates the private restore receipt and
its source-bound, content-addressed Native manifest before reading transcripts.
Its transcript archive preserves that selection after the live home is removed;
changed receipt metadata or a different selection blocks archive reuse.
Existing transcript-only archives remain available through the managed
conversation catalog. The Native CLI catalog discovers its verified Native
snapshots; conversion of older transcript-only archives is not performed.

Do not reopen DELIVERED or DISCARDED journals to recover conversation data.
Historical native resumes use a fresh owned Git session and compatible verified
runtime. Origin UUID/pin remain provenance, separately from the new execution
UUID/pin. Running sessions and their bindings remain unchanged. The explicit
history-restore path uses `session-isolation.sh create --local` with a locally
available cached origin/main (or local main for a repository without origin),
records that exact base, and never fetches. Ordinary new-session creation keeps
its existing fetch behavior; delivery still uses the normal remote verifier.

## User behavior and verification

`<prefix> codex resume` lists locally discoverable history before selection;
`resume --list` provides JSON without launching a model. Exact native UUID and
`continue` use the same source-local catalog. Noninteractive ambiguous requests
require an exact ID. Network and the summary service are not prerequisites.

Tests must cover lossless WAL and parent/segment restoration after the original
path disappears, all GC deletion paths, old-pin entry protection, writer and
profile boundaries, authority exclusion, failure recovery, offline selection,
and real native history reads without a model prompt. Fixture verification is
separate from operational host migration and authenticated model turns.

The deletion verifier characterizes Native **0.161.0**, **0.162.1** and **0.163.0**. Other
versions keep roots until their history protocol is verified. The proof compares
every original rollout byte and all original projection items; it does not
reconstruct projection items already missing from the original database or
recover data removed before an archive existed. Source, archive and restoration
are host-local; installing the launcher does not synchronize conversations
between machines. Existing auth and hook approvals come from normal preparation.

Native 0.163 multi-agent v2 children can reject direct resume while unloaded.
Only that characterized refusal permits a metadata-only `thread/read`; the same
requested ID and every paginated turn/item must still match. Raw file reads use
linear response framing and a budget derived from the archived file's base64
size plus 4096 bytes, with a 128 MiB raw-file ceiling. Other RPCs retain their
64 MiB response limit and all calls retain the existing deadline and offline
restrictions. Oversized or mismatching history keeps the original root.

An existing transcript archive can remain valid after SQLite reconstructs its
`state_5.sqlite-shm` WAL index. Reuse permits only `iChange`, its dependent header
checksums and `nBackfillAttempted` to differ. Both duplicated headers, checksums,
DB/WAL page size, salts and commit frame must validate. File sets and sizes,
every other SHM byte, and all persistent DB/WAL/raw-history hashes must match.
The prior archive, including its original SHM bytes, stays immutable. New archive
publication still requires exact bytes; Native restoration and work proofs remain
independent requirements. See the [SQLite WAL-index format](https://sqlite.org/walformat.html#the_wal_index_or_shm_file).

## Explicit terminal work preservation

GC still retains unaccounted work by default. An operator can explicitly preserve
one reviewed terminal owner using `bin/harness_session_work_recovery.py`:

1. Run `inventory --state STATE --owner UUID` and review its exact inventory hash.
2. Run `preserve --state STATE --owner UUID --expected SHA256`. The existing
   runtime lease must be free. The approved inventory must still match.
3. Run ordinary owner-filtered GC. It rechecks the immutable custody record
   against the current root and again after Native retirement staging.

This archive preserves complete nonexcluded work files, symlink targets, empty
directories, the original Git index and every staged blob. Distinct staged and
unstaged contents survive independently, including deletion states and ignored
files. It does not deliver changes or rewrite the original index or lifecycle.
Generated authority/config exclusions retain the existing work-proof boundary;
Native history uses its independent archive and verifier.
Symlink modes are restored without following their targets, including under a
private umask. Unsupported mode restoration retains the original root.

Private content-addressed objects and receipts live in the owner's
`work-recovery` record. Publication requires complete readback, file/directory
fsync and a fresh independent index/worktree restore. A durable pending marker
keeps interrupted publication held until the final parent entry is synced.
A crash after publication can conservatively retain that marker and hold GC.
Owner, source, root
incarnation, base, terminal lifecycle, delivery metadata and every current byte
are bound to the receipt. Later work, corrupted archives or replaced identities
remain held. Headless or unmerged indexes and unsupported object formats refuse
preservation. GC never creates these archives or automatically approves dirty
sessions. Archives have no expiry.

To recover after retirement, run `restore --archive ARCHIVE --destination NEW`.
The destination must be new. It receives the original worktree and a standalone
Git index/blob store, preserving `git show :path` separately from worktree bytes.
The canonical base remains identified by the manifest; no branch is delivered.

For real offline Native characterization, set `HARNESS_TEST_REAL_CODEX_BIN` to
the native backend and run `test/test-codex-history-native.sh`. Without that
explicit binary, real-backend tests report skipped; fixture transport tests
still run. The characterization covers 101 turns, full pagination, parent cuts,
archived segments, committed SQLite WAL, original path disappearance and empty
catalogs, with no model turn or network access.
