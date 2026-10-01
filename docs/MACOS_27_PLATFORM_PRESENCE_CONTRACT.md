# macOS 27 platform-presence contract

Status: **implementation prerequisite, not release approval**. The native
suppression cause is verified on 27.0.1/26A434; the connected authority repair
below is not yet integrated. GPT 6 Astra High independently reviewed this design.

Build 152 repairs only recovery from failed activation. Its successful-profile
guard correctly rejects loss of an admitted item, but native assessment hiding
suppresses the Focus surface even with every real system enum case allowed.
Retries, guessed cases, nullable allowlists, title-based exceptions and synthetic
visible descriptors cannot establish the required authority.

## First slice: honest observation freshness

Implemented separately: `MenuBarBackend.snapshotForVerification()` bypasses
both app and helper inventory caches on macOS 27. Tahoe reads new WindowServer
inventory for each request. The coordinator requests new observations at
post-mutation, stable convergence, compensation, superseded recovery, history
restore and restart publication. Ordinary UI refresh retains its cache.

This removes duplicate-cache stability proof. Owner-probe scheduling still
applies, so a new observation is not necessarily complete owner enumeration.
No missing-item validation rule is relaxed by this slice.

## Required connected implementation

### 1. Helper-owned assertion receipts

Implemented as a separate source slice: typed receipts cross the existing
environment response and atomic configuration acknowledgement. A helper-owned
ledger expires evidence before native `Begin`, not merely at logical commit.
Uncertain failure clears the trusted deduplication mirrors; retrying the prior
configuration must establish state again. Reveals remain transient; Clock
lift/restoration changes revision even when it returns to identical allowlists.
Lifecycle invalidation and counter exhaustion rotate receipt lifetime. The
locked bridge query acknowledges only explicit idle commits, not native item
presence. Passive cache reuse excludes unstable receipts, and scans compare
receipts before and after enumeration. No Focus exception is admitted yet.

Publish helper-session identity, assertion revision, accepted configuration
revision/digest, and a typed `deasserted/asserted/transient/unknown` state through
the existing environment response. The helper creates receipts; caller-provided
bytes are not proof. Configuration acknowledgement must bind to its committed
receipt, not desired state. The bridge must report actual accepted assertion
presence, because an all-visible commit can intentionally clear it.

Advance assertion revision for every actual lift, reapply, reveal, invalidate
or recovery, including clock activation. Logical configuration changes with
identical native allowlists advance configuration revision. Genuine no-ops
retain receipts; rejected proposals retain prior accepted logical intent and
bridge ownership, but native attempts revoke prior observation proof. An abort
does not establish physical restoration. Uncertain restoration reports unknown.
New helper/session lifetimes invalidate old proof.

### 2. Trusted runtime Focus observations

Reader prerequisite implemented independently: exact three-slot identity and
bounded child-list adapters distinguish AX errors, no value and unsupported
attributes. They reject malformed, duplicate, oversized, changed-count,
cancelled and late responses. Explicit scan cancellation survives dispatch
thread hops; callers must wire its task cancellation handler. These helpers
are not yet connected to publisher attestation or absence authority. Equal
child counts alone do not attest equal membership.

The typed extras copy/adoption path and live publisher verifier are separately
implemented and tested. Fixed Apple-anchor and sealed-ID validity, kernel
lifetime and bounded signing metadata produce a privately constructed runtime
witness. Security calls remain synchronous and non-preemptible: callers must
run off the main actor, wire cancellation, and reject late publication.

On CODEX01 27.0.1/26A434, a supervised native DND ON observation now captured
the exact Focus tuple `com.apple.menuextra.focusmode` / `AXMenuBarItem` /
`AXMenuExtra`, published and owned by the verified MenuBarAgent lifetime.
DND OFF was independently restored. The child settling gate failed because
the node remained beyond its two-second window; the fresh recovery gate later
verified two original inventories. This does not qualify absence under native
Barline suppression, scene/display coverage or production catalogue admission.
Do not activate an exception on the strength of this single positive tuple.

Preserve typed AX read outcomes and their actual errors. A failed children read
is unknown, not an empty menu bar. Explicitly scan the relevant owner despite
the normal owner-probe schedule. Read assertion receipts before and after the
scan; both must agree. Revalidate publisher/AX-owner lifetimes and scene/display
ownership before and after observation.

Bind the exact observed Focus AX identity to its publisher. Verify running code
against an Apple-anchor requirement and approved sealed signing identifier,
using dynamic validity checks, not a bundle prefix or unsigned team metadata.
The publishing PID is distinct from the AX element's re-vending PID. Missing
identity, ambiguous bindings, PID reuse, replacement, invalid code or unresolved
process lifetime leaves the evidence unknown. Persisted descriptors must not
resurrect signature/lifetime trust after restart.

Use a closed, versioned catalogue of exact identities verified on the OS lane.
No title fallback or arbitrary Apple item enters that catalogue. Store runtime
presence separately as observed/absent/unknown. Absent under an assertion is not
proof that Focus mode is off or that the assertion caused this absence.

### 3. One immutable transaction projection

At admission, create a fixed contract identifying only attested platform-owned
controls excluded from controllable layout authority. Later observations cannot
enlarge the set after a mismatch. Project both requested and observed layouts
through the same contract; keep raw snapshot items truthful. No phantom bounds,
image, descriptor, click target or retained visible item is permitted.

Every other application/system/control ID, display and section remains exact.
Preserve required per-display shelf ordering, normalizing ordinal positions
after projection rather than treating changed numeric indices as user edits.
Raw uniqueness, geometry, scene, freshness and control validation remains strict.
Any continuity-baseline adjustment must use the exact verified binding; do not
weaken global collapse ratios or pad counts.

### 4. Integrate all authority boundaries together

- Resolve/admit/replan profile identities and logical arrangement.
- Verify individual/grouped steps, terminal convergence and compensation.
- Refresh active authority, reconnect and rehydrate after restart.
- Match persisted authority, pending activation promotion and conditional restore.
- Admit/check checkpoints, recovery previews, history and undo/redo.
- Capture base/display layouts and templates without saving native Focus promises.
- Preserve runtime observation association through all snapshot projections.
  Drop current attestation explicitly at persistence/sanitization boundaries.

The app's macOS 27 snapshot provider, not helper `.snapshot`, supplies inventory
to the coordinator. Its initial/final helper `environment()` calls provide the
receipt transport. Ordinary cache reuse must compare the assertion receipt as
well as scene and geometry. A cached generation alone is never new proof.

## Required transition semantics and tests

- Hidden to hidden retains a verified restriction, with truthful Focus absence.
- Hidden to visible verifies deassertion and controllable layout; legitimate
  Focus-off absence is not a mandatory-reappearance failure.
- A legacy visible Focus reference is projected only through exact trusted
  evidence, with the original archive retained. Ambiguous or hidden Focus
  instructions are explicitly unsupported, not silently fulfilled.
- Restart discards runtime evidence and reconstructs it from a fresh verified
  session/scan. Unbound legacy references leave authority unclaimed.
- Forged Apple identifiers, invalid signature, publisher/owner mismatch, missing
  PID, lifetime replacement, helper restart, revision change during scan, failed
  versus empty reads, duplicates, display movement, unrelated additions/losses,
  reorder and hidden-section edits must fail closed at every authority boundary.

Run successful non-no-op saved-layout and native Focus Filter transitions on
the final signed candidate, plus fault/interruption and installed upgrade
journeys on both OS lanes. Source tests cannot stand in for those gates.

## UX and release boundaries

This model neither creates Barline-owned Focus modes nor implies native Focus
was preserved. The user choice remains open: a clearly identified replacement
that opens native Focus controls, or explained access through Control Center.
Do not silently add a replacement control while the choice is pending.

macOS 26 runtime, native clock-panel rendered visibility, XCUITest setup,
notched/multi-display hardware and exact final upgrade evidence remain required.
Keep public v1.0.65/build 142 and its download/update feed unchanged until all
required final-candidate gates and independent readiness reviews pass.
