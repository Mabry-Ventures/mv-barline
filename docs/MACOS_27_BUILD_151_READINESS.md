# Build 151 grouped-profile qualification

Status: **HOLD**. Private 1.0.66/build 151. Public build 142 is unchanged.

The exact installed build-150 transition reported
`profile_section_or_display_mismatch`, with successful workspace compensation
but `native_reorder_unavailable` during layout compensation. Observed inventory
fell from 14 to 13 items while both Barline controls remained present. The
missing item's cause is not established.

## Repair and safety proof

Grouped macOS 27 visibility assignments can change several siblings in one
operation. Forward execution and compensation now replan against each validated
fresh observation rather than replaying sibling operations or shelf indices
from the original snapshot. Complete admitted membership and display scope
remain mandatory. Execution has a finite move budget; authority still requires
the complete target and consecutive stable postconditions.

Unexpected unrelated section, display or per-display shelf-order changes use
the existing superseded, observation-only path. They are not overwritten by
forward replay or compensation. Cross-display enumeration interleaving is not
mistaken for a display-local shelf edit.

Stateful backend regressions reproduce grouped reveal/compensation failures
against build-150 source, then pass with this repair. Further tests cover real
task cancellation, duplicate refreshed identities, stale/tracking snapshots,
nonconvergence, scoped display activation, external section changes, affected
group relocation and cross-display shelf ordering. The full core suite passes
773 tests. This is source proof, not installed qualification.

## Inventory investigation

Count-only diagnostics distinguish raw AX children, accepted observations,
deduplicated observations, built descriptors and retained hidden descriptors.
Known-owner read failures, empty known-owner child responses, application-element
creation failures and full-scan state are counted without recording identities,
names, paths, screenshots or process lists. No retention or identity guard is
relaxed. Missing visible items are not fabricated.

## Required next proof

Install the exact signed/notarized candidate only on CPLCODEX01. Repeat the
physical visible-to-hidden saved-layout transition and correlate these counters
before making any sampling or identity repair. Passing a capture/apply no-op
does not qualify that transition.

All open build-150 release gates remain open: XCUITest runner initialization,
native clock-panel visibility, macOS 26 runtime, notched/multi-display hardware,
public-build update qualification and the remaining installed authority,
recovery and interaction matrix. No public publication or production signoff
is authorized by this document.
