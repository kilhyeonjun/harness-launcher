# Canonical update through native approval

`harness-canonical-update` opens a fresh, dedicated native OMP main TUI for one
canonical update. The command carries a request, not approval: only a human's
literal native **once** decision can authorize the existing private transaction.
It does not grant a session-wide permission or introduce another write engine.

## Prerequisites and installation

Use an officially reviewed, published launcher release that includes this entry
and its exact private-code pin. The existing trusted, source-admitted private
`launcher-activate` installation flow must install both the public release and
its release-pinned private code closure before this command can run. That flow
can install the new launcher without first updating the canonical repository.
It preserves existing workspaces, sessions and the older Homebrew keg.

Releases **0.78.0 and 0.78.1** contain a stale compiler-helper size/hash in the
bootstrap descriptor. Their private-closure admission correctly refuses with
`canonical_bootstrap_content`; do not patch those releases or their sealed caches.
Release **0.78.2** binds the corrected published private manifest and the actual
seven Git blobs instead. The admitted code and native binary remain the reviewed
ones; no verifier or approval check is relaxed. The candidate-verifier baseline
prerequisite introduced in 0.78.1 also remains in force: each affected repository's
trusted baseline must support verification-only `--verify-candidate` before
adopting that broker. Each profile owner verifies its own prerequisite.

A corrected published descriptor is not an installed-runtime receipt or proof of
canonical apply. Complete the trusted activation and verify its selected runtime
and sealed closure before invoking the new entry.

The closure is executable code, not configuration. Its revision, manifest and
seven-file inventory are fixed by the public release; the installer verifies
source provenance, file modes, sizes and hashes before sealing the cache. Missing,
changed or incomplete code fails closed. There is no user-adjustable pin, cache
path or source override, and this command cannot install or repair the closure.
Use the trusted installation flow rather than copying files into a cache.

The selected sealed launcher runtime and the package exposed by an older
Homebrew keg are different identities. After trusted activation, use the exact
absolute `bin/harness-canonical-update` entry supplied by the new installed
release if the legacy keg does not expose this command. Do not execute a source
checkout or patch the old keg. A subsequent official Homebrew upgrade can expose
the new public command normally. Neither installation nor invocation requires
closing existing workspaces or hot-reloading an old session's sealed tools.

## Request and approval

The only operation arguments, in this order, are:

```text
harness-canonical-update --profile <registered-profile> --expected-base <full40> --revision <full40>
```

`--profile` selects an already registered and enrolled profile, preserving its
existing identifier grammar: `[A-Za-z_][A-Za-z0-9_-]{0,63}`. `--expected-base` is the
expected current canonical commit; `--revision` is the requested target commit.
Both commits must be full 40-character lowercase hexadecimal revisions. The
command also accepts `--help`. It accepts no root, origin, source, native binary,
configuration, credential, provider, model or approval override.

The installed trusted selector resolves the complete selected public runtime
and its immutable private-code authority using the operating-system account
identity, not a caller-supplied home or path. The dedicated native session starts
without auth, skills, rules, tools or ordinary workspace extensions; it is not a
provider login or a model conversation.

Read the native approval's full scope before choosing **once**:

- registered profile and resolved canonical root;
- repository origin;
- exact expected base and requested revision;
- commit and path counts, and the approval expiry;
- selected public release identity and pinned private revision/manifest digest.

The compact and full approval views carry the same bound scope. The native dialog
keeps a short viewport: use **Ctrl+O** to expand details and **Page Up/Page Down**
to inspect every field before choosing **once**. Expansion and scrolling are not
consent. A changed scope,
expired request, changed runtime or lost session ownership cannot reuse that
approval. Denial, cancellation and any answer other than literal **once** do not
authorize apply. The private engine retains its existing prepare/apply/dispose
and canonical validation rules; this carrier does not relax them.

## Why the verifier is installed first

The private transaction uses compatible frozen verifier code admitted **before**
the requested canonical operation. It does not load its verifier from the mutable
target checkout after updating it. Installing the published public/private pair
first therefore breaks the old-verifier bootstrap cycle without making a CLI
flag, an old sealed tool or target-controlled code an approval authority.

## Cancellation and uncertain results

Cancel in the dedicated TUI or interrupt the command to stop its owned operation;
do not close unrelated workspaces. Cancellation invalidates approval and drains
the private transaction's cleanup. An interrupt during apply is not proof that
no effect occurred. The native carrier observes the inherited revocation FIFO
through a file stream: parent closure aborts the pending approval without a key
press. On receiving the drained result, the parent releases that FIFO before
acknowledging the result and waiting for native exit, so reader cleanup cannot
deadlock against exit.

The command reports a structured receipt with the actual engine result when
available, a safe error category and `cleanup_verified`. A missing or unconfirmed
native result is **unknown**, not success and not evidence that nothing changed.
An engine `uncertain` result likewise requires reconciliation. There is no
automatic retry. Preserve the operation evidence and have the trusted operator
reconcile the canonical state and cleanup before considering a new request;
never blindly replay an unknown operation.

## Evidence boundary

A native main-TUI/approval-API existence probe (including a deny/timeout probe)
only establishes that those interfaces exist. It does not establish a genuine
human **once**, a completed canonical apply, an official release or an installed
release receipt. Those require their own actual approval, transaction and
release/install evidence; this guide does not claim they have occurred.
