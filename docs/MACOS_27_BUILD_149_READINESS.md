# Build 149 qualification record

Status: **HOLD**. Private 1.0.66/build 149 candidate. Public 1.0.65/build 142
is unchanged. Compilation, notarization and no-op Apply are not runtime proof.

## Reproduced defect and scoped repair

On CPLCODEX01, unchanged installed build 148 failed a physical Apply of the
owned synthetic layout from a different visible arrangement. The fixture
remained visible and no Active/current-presentation/token state stabilized.
The previous five Capture/Apply passes had applied already-matching layouts.

Two new deterministic policy tests fail before the repair with
`unsupportedVisibilityAssignment`: an omitted visible member invalidates an
unchanged visible application group, and omitted already-hidden members
invalidate a saved concealed group. The layout reconciler had already preserved
these items, but native visibility validation checked the saved subset only.

Build 149 validates the complete requested visibility state by retaining every
omitted noncontrol item at its current visible/concealed section. Explicit saved
assignments still win. Mixed hidden/visible third-party application groups remain
rejected. The concealment backend, immutable-item guards and checkpoint admission
are unchanged. Astra independently supports this bounded consistency repair.

A retained-inventory replay passes layout planning and rejects visibility
grouping, but includes historical descriptors. It is **not a live-snapshot
root-cause receipt**. The actual installed transition must pass on the new binary.

All eight deterministic layout/arrangement failures now have distinct closed
diagnostic codes and UI explanations, and require a fresh command instead of
timer replay. Unknown and transient backend failures retain their prior policy.
Recovery evidence and prior authority are not discarded to bypass rejection.

## Deterministic evidence

- Before patch: two new policy tests fail; genuinely mixed hiding stays rejected.
- After patch: 759 core tests pass, including a composed coordinator transition
  with newly observed siblings and omitted hidden/always-hidden items retained.
- Negative coordinator test rejects unsupported mixed concealment before any
  checkpoint callback, workspace mutation, move or concealment call.
- Exhaustive eight-error code, message and fresh-command classification tests;
  transient/unknown classifications remain unchanged.
- Explicit overlapping assignments and omitted pre-existing mixed application
  groups remain rejected, without silently normalizing the user's state.
- Astra and Gemini Flash 3.8 High approve the scoped source repair for installed
  qualification. Neither review supplies runtime or release signoff.

## Required candidate-bound gates

- Clean source SHA, fast gate, Debug/Release builds and focused test-plan gates.
- Signed/notarized/stapled ZIP and DMG, nested trust, checksums and provenance.
- Installed physical saved-layout transitions in both directions, including
  non-no-op variants, durable authority and restart behavior.
- Composed authority-save rejection and duplicate-command no-replay receipts.
- Held-operation UI interaction and actual OS Focus on/off delivery.
- Cold shelf, native/popover interaction, movement, helper interruption and
  recovery performance receipts tied to the final binary.
- Native clock visible-state positive control and unchanged-candidate evidence.
- macOS 26 runtime, notched display and multi-display/reconnect qualification.
- Latest public build's real update path and clean install.
- Gemini Flash 3.8 High and GPT 6 Astra High final candidate/evidence review.

The build-148 full gate and one focused retry both failed during XCUITest runner
initialization, before executing an app test, with "Timed out while enabling
automation mode." Developer Tools mode is enabled. Preserve both `.xcresult`
bundles; this environment boundary is not an app assertion and not a pass.
Do not weaken the gate, reset privacy state, or restart the Mac to conceal it.
