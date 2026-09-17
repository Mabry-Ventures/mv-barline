# Reliability-first feature qualification

Published release: **1.0.31, build 108** (September 17, 2026), tag `v1.0.31` at
`0e6ddd1823baa07247b5f7efdd7baf2114c95987`. Its exact packaged build passed
the macOS 26 full gate and macOS 27 native arrangement qualification. The
public DMG, ZIP, source archive, SBOM, checksums, and appcast were downloaded
again and matched the locally qualified artifacts. A clean install and a signed
upgrade from 1.0.15 were not rerun before publication.
Implementation is not a release certificate.
Use the final source SHA and signed executable hash for every installed receipt.
Failed attempts remain in local evidence; do not replace them with a later pass.

## Implementation contract

- Display variants capture only the verified active menu bar display. Unknown,
  ambiguous, stale or empty displays are rejected. Replacement is explicit,
  edits stay in a draft, and save failures do not dismiss the editor.
- Rules are optional and event-driven. A change schedules one cancellable
  three-second settled-context check, not periodic polling. Configured native
  Focus, manual intent, current interactions and pending restoration take
  precedence. Admission is rechecked within the existing serialized transaction.
- Rules start paused on relaunch; Resume is explicit. Manual Command-drag,
  layout selection, history/recovery and workspace-setting changes pause them.
  Rules cannot restart other apps to change system item spacing.
- Per-item shortcuts reuse the existing item activation/restoration path. A
  press/release cycle dispatches once; held keys cannot build an action queue.
  Modifier release is bounded. Failed registration or persistence preserves
  prior intent and exposes unavailable state instead of pretending success.
- Rules, search personalization and item shortcuts have bounded private local
  stores. Corruption, cancellation, failed staging and competing writes do not
  overwrite the previously validated file.

## Evidence classes

| Area | Automated checks | Required installed / physical checks |
| --- | --- | --- |
| Display variants | Scoped capture, stale/disconnected/ambiguous rejection; existing reconnect resolver and transactional rollback tests | Capture/reopen/replace/remove on two displays; unplug/reconnect; notch and overflow |
| Rules | Predicate/priority/staleness tests; admission denial before effects, after journal, between moves and after workspace apply; real disk faults | Foreground app; power/battery where available; configured Focus on/off; native Command-drag/manual override; no self-generated retry loop; pause/relaunch/resume |
| Item shortcuts | Bounded model/duplicate validation; press-cycle tests; actual Carbon conflicts/suspension/recovery; real disk faults | Held/repeated keys; external-app conflict; native left-click and popover item activation; restoration and permissions |
| Groups/search | Group partition/order/collapse and local search tests; private preference fault injection | Keyboard traversal, Return/Space/Escape, favorites/aliases persistence, group rename/collapse and missing items |
| Core reliability | Strict build/lint/analyze; geometry, permission and recovery tests | Fresh upgrade/first click; bounded open/close burst with no failures; four native/popover journeys; helper interruption; journal restart |
| Accessibility | Semantic labels/control assertions and fixture audit | VoiceOver, Full Keyboard Access, contrast and reduced motion on the candidate |
| Distribution | Exact source, GPL notices, SBOM, signatures, notarization, staple, Gatekeeper, signed appcast | Clean install, update/rollback, published asset integrity and canonical site/download validation |

## Current boundary

Build 108 passed 582 Core tests in 60 suites, 201 Xcode tests in four suites,
three XCUITests, Debug/Release build and analysis, privacy and permission checks,
release topology, signing, notarization, stapling, Gatekeeper, repository
hygiene, helper recovery, UI smoke, and performance gates on macOS 26. On
macOS 27, the exact packaged build passed sidebar-away/back state integrity,
competing-click rejection, independent 1Password and Stats moves, movement in
both visible/hidden directions, relaunch persistence, and helper
interruption/recovery.

Fresh public assets matched their checksums; the downloaded disk image again
passed stapling and Gatekeeper assessment. Gemini Flash 3.8 High and GPT-6 Astra
High independently returned GO on the bounded evidence. Physical display
transition, long soak, clean-install, signed-upgrade, and manual
assistive-technology scenarios remain separate from the shipped core
qualification.

### Historical candidate evidence

Build 31 source `704276d1ebcf3aecf764e414b69a481f47dd7821` passed clean
nonfocus qualification after UI Automation authorization: 358 package tests,
168 fixture checks, Debug/Release compilation, static analysis and automated
accessibility/privacy gates. One native-menu fixture journey failed once, then
all four journeys passed with the installed app stopped and again after it was
restored. Preserve the intermittent failure; the later passes do not explain it.

Build 31's Developer ID package passed nested-signature/entitlement checks,
Apple notarization, stapling and Gatekeeper assessment. A signed loopback
Sparkle update from build 30 preserved semantic preferences, the production
feed, saved layouts and recovery data, with one running installed process.
Installed executable SHA-256:
`821af782cf3f76b7a4783ce61673ea1a18b3dc4ae82f2654b996df890b2f46ce`.

The installed build then passed a 20-cycle shelf gate with zero misses and
102.7 ms p95 against the 250 ms budget, forced helper recovery, a five-cycle
post-recovery burst, six maintainer-observed target activations with five-second
re-hiding and no duplicates, and a first-click activation after relaunch.

Build 28's explicitly approved available-item recovery completed and survived a
restart. Its original checkpoint remains archived and was preserved by the
build 29 update. Build 29 rejected a stale native Work layout once without
repeating the error over a 50-second observation window; Work-off cleared its
requested state. A newer layout then activated through native Work Focus and
created a checkpoint. Work-off cleared active authority and the checkpoint
without logged operation failures. The manual archive remained unchanged.

These observations do not independently prove restored item-order equivalence,
manual override, the remaining interaction/accessibility matrix, or the
second-device display lane. The accepted localized-review refinement changed
source and advanced the candidate to build 33. Build 33 then passed signing,
notarization, update, and installed interaction gates, but its true clean-install
cold launch did not publish the visible shelf in Barline's Accessibility window
list. Build 34 added explicit window semantics and a post-commit notification,
then passed its full source, distribution, signed-update and installed gates.
Its independent clean-package run still exposed a root-publication failure:
the shelf remained directly hit-testable but absent from the application's
Accessibility window list. Build 35 retains the panel's AppKit registration
while hidden and uses the standard nonactivating order path; earlier evidence
cannot certify it. Build 36 carries that change, ships Sparkle arm64-only, and
accepts the BLN-17 shelf close miss as a documented known limitation. It needs
its own exact-source evidence.

Build 31's local receipts are retained under ignored `.artifacts/ci/`,
`.artifacts/release/` and `.artifacts/build31-installed-evidence/` paths in its
frozen qualification worktree. Do not substitute them for build 36 receipts.

## Historical findings and evidence

Build 22 (`249dcb0`) passed the clean nonfocus and bounded installed receipts,
but failed native Focus Filter configuration loading in System Settings.
The subsequent extension topology correction required a fresh signed candidate.
Listing a filter is not proof that its configuration loads
or that Focus activates a layout. See FOCUS_AND_APP_INTENTS.md and the latest
execution-plan checkpoint. Earlier build-21 evidence below remains historical.

The subsequent observation-lifecycle repair (BLN-19) ensures that
old status-item window/screen publishers are canceled on replacement, nil clears
cached values, and queued delivery is canceled inside the switched owner stream.
Its standalone production-operator regression is a fast-gate check. Build-21
installed receipts below do not qualify this changed source. BLN-17 attribution
remains open independently.

Frozen build-21 source `59de12d` passed clean nonfocus qualification, real
preference fault probes, Carbon registration conflict/recovery checks,
Debug/Release compilation and analysis. The signed/notarized candidate passed
a preference-preserving Sparkle update, all four installed target-interface
journeys and one helper interruption. Installed checks cover single-display
variant authoring, rule editing while disabled, final-layout deletion and
shortcut-recorder accessibility exposure, not the full acceptance matrix above.

Additional installed checks cover temporary group creation, saved rename,
reopening and Escape cancellation preserving the prior saved group. The layout
was not applied. Forty-four focused search/group tests and real preference-store
fault probes passed; installed search interaction and shelf-group collapse remain
separate pending lanes.

A physical Control-Option-Command-9 fixture shortcut attempt on September 7
dispatched and opened/closed a native menu, but received no action click and
the maintainer reported nothing visible. A second, passively observed attempt
received exactly one activation/open/action/close. The fixture-owned menu was
on-screen, intersected the active display, and stayed open approximately five
seconds before the action. The restoration journal was empty afterward; the
temporary shortcut and fixture were removed. This proves one completed physical
native-menu shortcut journey, not repeatability or the cause of the first miss.
Both receipts and the fixture-only geometry trace remain in ignored
`.artifacts/local-acceptance-2026-09-07/shortcut-failure/`.

The initial installed shelf gate failed one opening cycle out of twenty.
Subsequent diagnostic runs passed but did not establish the cause; no passing
performance receipt replaces that failed attempt. BLN-17 remains open.
Physical hardware, native keyboard/Focus, VoiceOver, macOS 27, public-download
and production GO remain unclaimed. See the latest execution-plan checkpoint.

The earlier shelf-close miss remains recorded. The driver now treats a failed
close as a failed cycle and reacquires click geometry each time. This corrects
misclassification, but does not retroactively prove why that earlier click was
missed. Requalify the final candidate with retained raw cycle results.

## Visitor prerequisites

Private GitHub vulnerability reporting is enabled. The maintainer-confirmed
private conduct contact is dev@mabryventures.com. The README's pre-release
disclosure was replaced with the published 1.0.11 download on September 11. Marketing drafts and
unrelated work must not be swept into a release commit.

The September 8 public-surface preflight verified the staging site, About and
Privacy pages, and contribution-link reachability. Staging remains `noindex`;
link reachability is not a new payment-processing test. The public repository
had no releases then; `v1.0.11` was published on September 11. Canonical-domain activation remains pending: `usebarline.com`
returned no A/AAAA answers and `www.usebarline.com` returned NXDOMAIN in the
preflight. Verify DNS, HTTPS, versioned downloads, the update feed and support
delivery again when the final public candidate is authorized.

## Hardware sequence

Complete and stabilize the current Mac's local qualification first. Then use
Jared's Work MacBook Pro for the notched-display and display-transition lane.
Naming that device is not evidence that it has been tested. macOS 27 remains a
separate runtime lane; do not upgrade either Mac merely to satisfy a gate.
