# Route enrolled bare menus through the sealed launcher

Frozen delivery plan, promoted from the independently reviewed scope before
release. Baseline: `ab3fcaaa185a6de1d7a0f378f39e10a6ffce8b79` (launcher 0.77.7).
Risk: HIGH because the consumer boundary controls which launcher code executes.
The design was reviewed before implementation; this records the same approved
scope, not a new authority or runtime approval.

## Acceptance

- An enrolled host's normal bare menu can offer OMP from the current verified
  sealed consumer rather than fail its binding check from Homebrew aliases.
- The profile source remains authoritative for model modes and default ordering.
  No default-provider change or automatic Native/model launch is introduced.
- Bare entry, cwd paths containing spaces and the existing isolation controls
  retain their workdir and cancellation/finalization behavior.
- Explicit providers, prompt values, source files, enrollment records, selected
  snapshot data and existing user sessions remain unchanged.

## Interfaces and boundaries

1. Keep the public `harness-exec` selector position after optional leading
   `--cwd <dir>` and one workspace control: `--isolated`, `--no-isolated`, or
   `--isolated-session <uuid>`. Registered functions and profile commands already
   converge on this executable.
2. Dispatch when the discriminator is exactly `omp`, or when its position is
   exactly one past the final argument and the host enrollment index exists.
   A literal empty argument and incomplete controls are not exhausted argv.
3. Reuse `dispatch-source` and execute the returned sealed `harness-exec` with
   the same cwd and argv before aliases or session allocation. Never substitute
   another consumer pathname or alter current/enrollment to satisfy selection.
4. Run `model-mode-early` only for explicit OMP. Preserve the existing
   directory-equality recursion guard and all later profile, namespace, native,
   source, lease and ownership validation.
5. With enrollment present, a missing or invalid closure fails closed before
   allocation. The whole bare menu then stops, including profiles absent from
   the host index; explicit non-OMP routes remain available unchanged.
6. Without an enrollment index, keep the legacy menu without a new bootstrap
   Python or snapshot requirement. No raw-binary or unverified-package fallback
   is added for an enrolled menu.

## Verification

Use the real synthetic Publisher and current-source sealed snapshot, the actual
packaged public entry and real PTY menu interactions. Cover default-first
ordering, all supported controls, cwd spaces, reopening a normally CLOSED
journal and normal cancellation before any fake Native OMP invocation. Retain
source/index/snapshot preservation and historical explicit-OMP/consumer guards.

Negative cases cover missing and tampered closure before allocation,
no-enrollment legacy entry without a closure, literal empty arguments and
incomplete controls. All fixture authority stays inside owned temporary homes.
Close only those terminals; do not signal user process groups or weaken the
production receipt validator to accommodate invalid fixture state.

The focused suite recorded 17 passes in 26.150 seconds. Independent design and
implementation reviews approved their source scopes. These records do not
replace full required CI or installed-profile acceptance.

## Delivery and exclusions

Deliver the bounded entry patch, behavioral tests and paired architecture and
changelog through a reviewed PR. Require normal repository CI, then publish
from clean main through the tagged release, exact Homebrew tap archive digest
and ordinary package upgrade. Fetch and compare remote SHA and delivered paths.

After installation, use genuine launcher-owned isolated sessions to observe
registered profiles' actual recommended first row and cancel before confirming
a model mode. Preserve old runtime snapshots, live user sessions and source
changes. No installed-file hotpatch, manual current-pointer edit, enrollment
republish, forged launcher identity, self-granted maintenance or CI bypass.
Other applications' fixes and remote-host activation are outside this plan.
