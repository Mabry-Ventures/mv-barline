# Barline execution plan

## Barline 1.0.49 performance candidate — September 23, 2026

Build 126 is a staged, unpublished candidate. It bounds macOS 27 AX child
requests, suppresses unchanged retained-inventory writes, and adds privacy-safe
inventory and shelf timing intervals. The macOS 26 source/build gates and the
macOS 27 installed candidate still need exact-source evidence before any
release decision. In particular, a macOS 26 build cannot establish a macOS 27
latency improvement or concealment correctness. Keep the public v1.0.48 feed
unchanged until both OS lanes pass.

## Barline 1.0.31 macOS 27 native arrangement release published — September 17, 2026

Barline 1.0.31 (build 108), annotated tag `v1.0.31` at
`0e6ddd1823baa07247b5f7efdd7baf2114c95987`, is public. The release keeps the
established macOS 26 XPC backend and uses the system position table as the
authoritative arrangement substrate on macOS 27, with exact identity,
convergence verification, serialized transactions, rollback, and interruption
recovery.

The exact candidate passed 582 Core tests, 201 Xcode tests, three XCUITests,
build/analyze, repository/privacy/accessibility gates, UI smoke, performance,
and helper recovery on macOS 26. The exact packaged build passed native
visible/hidden moves in both directions, independent third-party item moves,
competing-click rejection, relaunch persistence, and helper interruption and
recovery on macOS 27. Its Developer ID app and disk image are notarized,
stapled, and Gatekeeper-accepted. Fresh public downloads match their checksums.
Gemini Flash 3.8 High and GPT-6 Astra High returned GO on the bounded evidence.

A 1.0.31 clean install and signed upgrade from 1.0.15 were not rerun before
publication. Physical display transitions, release-duration soak, VoiceOver,
and Full Keyboard Access remain separate evidence classes.

## Historical: Barline 1.0.17 macOS 27 position-table candidate — September 15, 2026

The macOS 27 backend now treats the system menu-bar position table as the
authoritative ordering substrate. It resolves exact item identities, plans only
bounded key changes, synchronizes through CFPreferences, verifies fresh
Accessibility convergence, and conditionally rolls back its own proposal when
verification fails. A fully synchronized versioned journal protects staged,
applied, and verified phases across interruption without overwriting a later
native or user change.

macOS 26 remained on its established XPC backend. The shared coordinator
distinguishes preflight rejection, external supersession, and recovery-owned
transactions so it never manufactures a stale second restore. Pure planning,
multi-key re-spacing, protected-anchor, recovery, profile-compensation, and OS
routing gates passed in the 531-test source suite on macOS 26.6.2. This record
is retained as the research-stage predecessor to the published 1.0.31 design.

## Barline 1.0.14 macOS 27 compatibility release published — September 14, 2026

Barline 1.0.14 (build 62), annotated tag `v1.0.14` at
`d749eb63dfd114fcdb78f5e5a4e744cf7cca88be`, is public. The same exact signed
executable passed the six-receipt installed suite on macOS 26.6.2 and macOS 27
RC 26A428, including native left/right activation, popover reuse, 20-cycle
performance, and forced helper recovery. The ZIP SHA-256 is
`a4b2bf08300923a08cf5496356dc05288a996690b6a095b995d57b7977107e00`; the DMG
SHA-256 is `fcbff754a6339ab33d5c830040d0950ab5a080cf9c09c9ff1ae0f1331e7f6e27`.

The Developer ID app and DMG are notarized, stapled, and Gatekeeper-accepted.
A signed Sparkle update from public 1.0.13 preserved preferences and recovery
digests. Draft assets were downloaded again, checksum-verified, and assessed
before publication; the live appcast and DMG then matched the qualified files.
Gemini Flash 3.8 High, Muse Spark 1.3 Contributor xhigh, and GPT-6 Astra High
returned GO with no P0-P2 findings. Retained transient restoration and host
Xcode runner boundaries are documented in FEATURE_QUALIFICATION.md.

## Barline 1.0.13 discovery hotfix published — September 13, 2026

Barline 1.0.13 (build 38), tag `v1.0.13` at `fa60b13`, is public. It replaces
the menu-item discovery spinner's implicit empty-cache inference with explicit
state, bounded transient retry, last-known-good preservation, and terminal
empty/error UI with a Try Again action. The source candidate passed 380 Core
tests and the local build, fixture, recovery, accessibility, privacy, menu-bar,
and performance lanes. The XCUITest lane was blocked by host UI Automation
authorization; independent Accessibility UI and performance probes passed.

The app and disk image are Developer ID signed, notarized, stapled, and
Gatekeeper-accepted. The exact public DMG hash was verified before installing
build 38 on the maintainer Mac. GitHub release assets, the Sparkle appcast, and
the canonical Cloudflare Pages download are live. Clean-first-install and
cross-device physical coverage remain separate evidence classes.

## Barline 1.0.12 published — September 12, 2026

Barline 1.0.12 (build 37) is published as GitHub release `v1.0.12`, marked
latest at 2026-09-12T22:55:11Z. The annotated tag points at `fcafa20`, the
source of the signed package.

`ci.sh release` on `fcafa20` passed every full-gate lane; its release step then
failed before signing because the freshly created release worktree lacked the
ignored `Config/Local.xcconfig`. After copying that file in, leaving the worktree
clean, `script/release.sh` ran directly on the same commit and passed: Developer
ID export, notarization of the zip (`Accepted`, submission
`986af9e1-2ce2-43fa-b9b7-20b653ddc57c`) with the app stapled, a zip-only appcast
enclosure check, and the disk image built, signed, notarized (`Accepted`,
submission `9906d9a6-98e6-45ab-ab0f-fdd1854d242f`), stapled, and
Gatekeeper-assessed.

Independent verification passed all 34 checks: build 37 throughout, arm64-only
code in all eight Mach-O files, strict signatures with the team identifier,
Hardened Runtime, and secure timestamps on all nested code, stapled tickets and
Gatekeeper `Notarized Developer ID` for both the app and the disk image, the
disk image layout, an app inside the image byte-identical to the notarized zip,
matching checksums that include the image, and an appcast whose single
enclosure is the zip and which embeds exactly the approved 1.0.12 notes. All six
draft assets were re-downloaded and matched byte for byte before publication.
The live `releases/latest/download/appcast.xml` feed is identical to the
verified appcast, and the public disk image and zip match the verified files.

A signed Sparkle update from the maintainer's installed build 36 to build 37
through a loopback feed passed with no failures. The updated executable matches
the notarized zip, the feed URL is the production feed, preference and recovery
digests including saved layouts are unchanged, and signature, Gatekeeper,
staple, App Intents topology, status item, helper, and a cold relaunch passed.
After the update and after the cold launch, no first-run marker or walkthrough
progress was written and no move offer or walkthrough window appeared. The build
36 backup is retained in ignored release evidence.

Clean installation on a Mac that has never run Barline, which alone exercises
the disk image install, the move-to-Applications offer, and the walkthrough's
real permission grants, remains open. Installed click journeys, the second
notched device, accessibility, macOS 27, and the release-duration soak also
remain open.

## Build 37 release candidate for 1.0.12 — September 12, 2026

Build 37 advances the app, helper, and Intents extension from build 36 as the
1.0.12 candidate. It ships the drag-to-Applications disk image and the
move-to-Applications offer (#19), the first-run walkthrough (#20), and the
earlier CompactSlider 2.1.0 port (#17) and Ifrit removal (#18). The source has
changed since `v1.0.11`, so no build 36 receipt certifies build 37.

On its exact `main` source, build 37 requires the full gate and a credentialed
`ci.sh release`: Developer ID export, notarization of the zip, stapling of the
app it contains, and Gatekeeper; the disk image built after the appcast with a
zip-only enclosure check, then signed, notarized, stapled, and assessed.
Independent verification must cover the disk image layout and confirm its app
matches the notarized zip. The update baseline is the maintainer's installed
build 36: a signed Sparkle update to build 37 with a cold launch must leave
preferences and saved layouts unchanged and show neither the move offer nor the
walkthrough, writing no onboarding state.

Clean installation on a Mac that has never run Barline, covering the disk image
install, the move offer, and the walkthrough's real permission grants, is
tracked separately and remains open. Installed click journeys, the second
notched device, accessibility, macOS 27, and the release-duration soak also
remain open.

## Barline 1.0.11 published — September 11, 2026

Barline 1.0.11 (build 36) is published as GitHub release `v1.0.11`, marked
latest at 2026-09-11T21:22:33Z. The annotated tag points at `3c5328f`, the
source of the signed package. That credentialed release passed the full gate and
Apple notarization (`Accepted`, submission
`df1bda06-58ba-43ac-bd5f-b4f0db20fe9c`). Independent verification of the
packaged zip passed all 23 checks: build 36 throughout, arm64-only code in all
eight Mach-O files, strict signatures with the team identifier, Hardened
Runtime, and secure timestamps, a stapled ticket, Gatekeeper `Notarized
Developer ID`, matching checksums, and an appcast that embeds exactly the
approved 1.0.11 notes. Draft assets were re-downloaded and matched byte for byte
before publication. The live `releases/latest/download/appcast.xml` feed is
identical to the verified appcast, and its enclosure matches the notarized zip.

A signed Sparkle update from the maintainer's installed build 34 to build 36
through a loopback feed passed. The updated executable matches the notarized
zip, the feed URL is the `mv-barline` production feed, preference and recovery
digests including saved layouts are unchanged, and signature, Gatekeeper,
staple, App Intents topology, status item, and a cold relaunch all passed. The
build 34 backup and digests are retained in ignored release evidence.

The maintainer chose to publish without the four installed click journeys and
`ci.sh full --installed`; that evidence class remains open. Clean installation
on a separate Mac, the second notched device, accessibility, macOS 27, and the
release-duration soak also remain open.

## Signed build 36 superseded for release notes — September 11, 2026

The credentialed release on `9ace0c8` passed. `ci.sh release` completed the
full gate, Developer ID export, and Apple notarization (`Accepted`, submission
`988a800c-b6fb-4e0b-b6bd-15a33669e6d6`), with stapling and Gatekeeper passing.
Independent verification of the packaged zip confirmed build 36 in the app,
helper, and Intents extension; arm64-only code in all eight Mach-O files,
including Sparkle; strict signature verification with the team identifier,
Hardened Runtime, and secure timestamps on all nested code; a valid stapled
ticket; Gatekeeper `Notarized Developer ID`; matching SHA-256 sums; and an
appcast requiring macOS 26.0 and arm64.

That appcast embedded the entire CHANGELOG as Sparkle update-dialog notes,
including unpublished candidate and unreleased sections and release-process
paragraphs. The package was not published. Release packaging now embeds only
the list items from the exact version's CHANGELOG section. The signed
`9ace0c8` evidence cannot certify the changed source; build 36 requires a new
credentialed release on the resulting main commit.

## Build 36 Apple Silicon packaging and release decisions — September 11, 2026

Build 36 advances all shipping targets from build 35 for the signed 1.0.11
candidate. Release packaging now removes non-arm64 slices from prebuilt
dependencies inside the archive before Developer ID export, and rejects any
Mach-O file in the app that contains non-Apple Silicon code. The unsigned
`bd8a3d6` dry run had shown Barline's app, helper, and Intents extension as
arm64-only while Sparkle's framework and four helpers were universal; the
previous check covered only the main executable.

The maintainer accepted the BLN-17 shelf close miss as a documented known
limitation for 1.0.11. Notarization uses the existing `barline-notary` login
Keychain profile, which authenticates with an Apple ID app-specific password
and was confirmed by a read-only notary history request on September 11. A
validated team App Store Connect API key was also stored under that profile
name; notarytool does not select it while the app-specific-password item
exists.

Build 36 requires the full gate, signed packaging, notarization, stapling,
Gatekeeper, a signed build-34-to-36 update, clean-install cold launch,
installed target journeys, helper recovery, and bounded performance on its
exact source.

## Merged rename, gate harness permissions, and BLN-17 close miss — September 10, 2026

PR #12 merged by rebase as `765e0b3`, `9ac2619`, and `62e17bc` after the
exact-head full gate on `284fce8` passed (`full-2026-09-11T02-35-11Z`), including
all four fixture XCUITests, UI smoke, the 20-cycle performance probe, and the
reopen burst with one forced helper recovery. `main` has an identical tree but a
different SHA, so build 35 release evidence must be regenerated on the final
`main` commit.

Earlier attempts on the same source failed for environment reasons and remain
retained: a locked screen (`08c4890`), an undeclared ripgrep dependency (fixed by
`62e17bc`), and a gate host without Screen Recording. The Claude Code agent runs
as `com.anthropic.claude-code` through Claude.app's disclaiming helper, so the
desktop app's grant does not apply; without it CGWindowList hides other
processes' window titles and the window-title probes report no Barline window.
Granting Screen Recording to that bundle resolved the three production lanes.

The `full-2026-09-11T02-25-20Z` attempt failed the reopen burst with
`closeTimedOut` on cycle 11. A bounded follow-up ran 15 traced 20-cycle
status-item probes against one Release process: 14 passed and 1 missed a close,
about one miss per 300 open/close cycles, with passing p95 between 66.5 and
85.2 ms. In both misses the shelf commit verifier timed out after 300 ms with
`missingWindowServerWindow` while CGWindowList showed the shelf visible, and the
close click posted during that wait produced no `Control action delivered` log
and was never delivered late. Observer failures occurred on exactly those two of
384 presentations. A slow close, panel overlap with the control item, the
pending-commit hide guards, a main-thread hang, and Sparkle's `-spks` look-ups
were ruled out. Where the click was delivered and why the observer missed a
visible window remain unattributed. The commit wait predates build 35
(`1714f09`); whether build 35 changed the rate is not established.

BLN-17 stays open. Further attribution is deferred: a missed close recovers on
the next click, human close clicks are expected to land well after the 300 ms
commit wait, and changing the shelf path again before first publication carries
regression risk. At the measured rate, the roughly 45 status-item cycles in a
full gate imply about one failed full gate in seven from this cause alone; such
failures are retained and never overwritten by a later pass. Findings are
retained in the gate worktree under ignored
`.artifacts/bln17-close-rate/284fce8-2026-09-11T02-40-32Z/`.

The follow-up full gate on `11f44ad` failed the reopen burst when the opening
click of cycle 13 never reached the control item: 24 control actions for 12
presentations, with no observer failure. The maintainer briefly used the Mac
during that run, so the miss is not attributed to BLN-17. Production gate
cleanup also stopped the maintainer's installed Barline by process name and
never relaunched it. `ci.sh` now pauses an installed `/Applications/Barline.app`
only for production lanes and relaunches it on exit, leaving the
installed-candidate lane untouched. Direct script runs still stop processes by
name. `docs/LOCAL_CI.md` now states that `ci.sh release` takes the credentialed
notarization path rather than an unsigned dry run.

## Repository rename to `mv-barline` — September 9, 2026

The canonical repository is now `Mabry-Ventures/mv-barline` and the local
working tree is `~/Development/MV/mv-barline`. All 44 in-repo references were
rewritten, including `BARLINE_SPARKLE_FEED_URL`, the About pane links, issue
templates, `script/release.sh`, the SPDX document namespace, and the website.
Because no binary release has been published, no installed client points at the
previous feed URL.

This changes build 35 source. Its 2026-09-09T10:13Z full gate, which failed only
`test-xcode-ui` on a Developer Tools automation-mode timeout, does not certify
the renamed source. Build 35 requires a fresh full gate, signed packaging,
notarization, clean-install cold-launch, and update evidence on its new SHA.
Visitor-facing documentation was refreshed in the same change: the README now
states the honest pre-release status instead of linking a nonexistent v1.0.11
download, and `docs/README.md` indexes every document.

## Build 35 cold-launch Accessibility root repair — September 9, 2026

Build 34 passed the exact-merge full gate, Developer ID signing, Apple
notarization, stapling, Gatekeeper, a signed build-33-to-34 update, six installed
receipts, helper recovery, and bounded performance. Its independent install
from the notarized ZIP then reproduced a release blocker: the shelf surface and
exact child button were visible and directly hit-testable, but the shelf was
missing from the cold accessory process's Accessibility window list on repeated
presentations. Build 34 was not published.

Build 35 removes the shelf's forced custom root role, retains the panel with
`orderOut` while hidden, and presents it through AppKit's standard
nonactivating `orderFront` path. A dedicated `NSApplication` subclass augments
AppKit's live Accessibility window list only while the shelf is visible rather
than replacing that list, so native Settings windows remain discoverable. The
pointer path still must not activate
Barline, make it frontmost, or claim key/main-window focus. Publication requires
fresh exact-source, signed update, clean-package cold-launch, four target
journeys, helper-recovery, and performance evidence.

## Build 34 cold-launch Accessibility closeout — September 9, 2026

Barline 1.0.11 build 34 was the next public-release candidate. Build 33 passed
the complete local gate, signed packaging, Apple notarization, stapling,
Gatekeeper, signed update, installed target journeys, helper interruption and
bounded performance checks. Its true clean-install cold launch ordered a
visible shelf but failed to expose that shelf in Barline's Accessibility window
list, so publication remained blocked.

Build 34 preserves the existing nonactivating, non-key pointer presentation and
publishes its committed panel with explicit window semantics and a window-created
Accessibility notification. The UI smoke regression requires the shelf
in both the window server and Accessibility tree while Barline remains inactive
and nonfrontmost. Build 34 must repeat the complete gate and all distribution
and installed checks on its exact merge commit, including a real build-33-to-34
Sparkle update and true clean install. Publication is allowed only after both
localized reviewers, hosted repository checks, exact-merge qualification and
installed validation pass. macOS 27 runtime qualification, the extended soak,
and the second notched device remain explicitly deferred and are not launch
claims.

## Build 33 public-release closure — September 9, 2026

## Build 32 localized-review refinement — September 9, 2026

The next qualification candidate is 1.0.11 build 32. A matched localized review
using Muse Spark 1.3 Contributor at xhigh and AGY Gemini 3.8 Flash High found a
real presentation-boundary regression in build 31's diagnostic change: the
input-idle timeout no longer conformed to `LocalizedError`, so a manual layout
move could present a framework-domain alert. Both reviewers also identified the
string-coupled timeout taxonomy; AGY traced the concrete `NSAlert(error:)` path.

The timeout is now a typed, localized, Sendable error with a closed diagnostic
code. Helper capability reasons used by diagnostics share compile-time constants
across the app, core and helper. Unknown payload-bearing reasons still collapse
to generic codes. Eight focused tests and the dirty-worktree fast gate passed;
fresh clean-candidate gates are required after commit.

Build 31 remains historical evidence. Its signed/notarized installation
preserved settings, the production feed and recovery archive. It passed a
20-cycle shelf probe with zero misses and 102.7 ms p95, forced helper recovery,
a five-cycle post-recovery burst, six maintainer-observed Google Drive/Time
Machine activations with re-hiding, and a post-relaunch first-click check. Those
results do not certify changed build 32 source or the remaining physical matrix.

## Build 31 diagnostic candidate — September 8, 2026

Build 31 includes the closed activation-error diagnostics from `211b04d`,
whose focused tests and fast gate passed. No click timing, process-resolution
guard, event-delivery behavior, or restoration policy is intentionally changed.
The candidate must pass local build/distribution gates before a preserved-state
update and a bounded Time Machine/Google Drive reproduction. Build 30 remains
installed until then; shelf activation remains a release blocker.

## Build 30 activation release blocker — September 8, 2026

The installed signed update passed preservation checks and the maintainer
confirmed first-click shelf opening after a controlled restart, with a brief
unmeasured loading message. Shelf activation subsequently failed: icons move
into the main menu bar but require a second physical click to open their menus.
The maintainer confirmed Time Machine, Google Drive, and all attempted items.
This is not a successful activation or merely a false warning.

Retained logs include one generic activation failure and one temporary-move
capability rejection. Current diagnostic changes distinguish input-idle timeout,
source-app resolution, drag synthesis and event delivery with exact closed codes;
unknown payloads remain redacted. Eight focused diagnostic tests passed. No
behavioral fix or build 30 activation qualification is claimed. Do not weaken
source-process resolution safeguards or suppress failures to clear this gate.

## Build 30 preparation — September 8, 2026

Build 30 advances all six shipping target configurations together for the next
signed-update qualification. It includes the shared recovery description fix.
The preceding source `aa00f1f08805203582ab2e9e7eca3530a725376f` passed clean
nonfocus qualification (357 Core tests, 168 fixture checks, four Xcode UI tests,
Debug/Release/analyze and automated accessibility/privacy checks) and Linux CI.
This version change requires its own frozen-source qualification and signed
package; prior evidence is not a build 30 release certificate. Installed build
29 remains unchanged until the new candidate passes distribution checks.

## Build 29 native Focus runtime checkpoint — September 8, 2026

Installed source `e05e577f383ea7b41cfe95ce3abdfdc40e0ed993` passed the
stale-layout no-retry observation: one rejection and no repeat over 50 seconds.
Work-off cleared requested Focus state. A second cycle using the post-recovery
layout activated successfully and created authority/checkpoint state; Work-off
cleared both without a logged operation failure. The original manual archive
hash was unchanged throughout. Receipts are retained in ignored local acceptance
artifacts as `build29-work-on-stale-regression.md` and
`build29-valid-focus-cycle.md`. These checks do not independently prove restored
item-order equivalence, manual override, relaunch, or other-device behavior.

Runtime inspection also found the shared recovery controls called an archived
checkpoint an interrupted Focus. The pending copy-only correction describes both
supported checkpoint sources without changing recovery selection, persistence,
confirmation, or mutation behavior. It requires new candidate qualification;
build 29 evidence remains bound to the installed source above.

## Work Focus stale-item rejection — September 8, 2026

The next qualification candidate is **1.0.11 build 29**, including this correction
and the support-export filename fix. Build 28 remains installed until the new
candidate's source, signing and update gates pass.

Build 28's approved available-item recovery completed and survived a restart;
the original checkpoint remains archived, outside active Focus authority. A
subsequent native Work test reached the configured layout but failed with
`stale_item`. After Work was turned off, command processing completed and retries
stopped. Capture-only comparison found one unavailable non-system item in the
assigned saved layout (19 saved versus 18 current), with no alias-only match.
This failed native test remains evidence, not a completed Focus gate.

The source now rejects that individual stale-item command without timed replay.
It preserves saved layouts and recovery journals and asks the user to reopen the
missing app or update the layout before a fresh command. Transient failures keep
the existing retry path. The result is bound to the command's operation callback,
not a shared last-error field. Native Focus ownership is persisted independently
of successful layout activation so a rejected Focus does not yield priority to
automatic rules. The latest payload-free profile error is available in support
exports. Three focused Core tests and Debug compilation passed; full qualification
and signed installed retesting are still required. Local evidence is retained in
`.artifacts/local-acceptance-2026-09-07/` under `build28-focus-*` and `stale-retry-*`.

## Support export filename regression — September 8, 2026

Corrected the literal date expression in the suggested JSON filename to Swift
string interpolation. The existing exporter harness now asserts the exact
filename for a fixed timestamp: it failed before the correction and passed
afterward. Red/green logs are retained under
`.artifacts/local-acceptance-2026-09-07/support-filename-{red,green}.log`.
`./script/ci.sh fast` also passed; its log is retained alongside those receipts
as `support-filename-fast.log`.
This is a post-build-28 source change, not part of its signed qualification;
the installed app and existing user-exported files remain unchanged.

## Build 28 installed qualification checkpoint — September 8, 2026

Frozen source `b73150a5a96f6a986805cd71a9203037f2158ef1` passed clean nonfocus
qualification (354 Core tests, 168 fixture checks, four Xcode UI tests) and
GitHub's Linux hygiene check. Its Developer ID package passed notarization,
stapling and Gatekeeper, then a guarded signed Sparkle update from build 27
preserved semantic preferences and the production feed. Installed executable
SHA-256: `b73f8550b5d3acea1de96dcc3ff0631a7a4ecca2a23001c4718d44fce99369a5`.

The available-item preview opened and reported one missing saved item. It was
canceled; no partial restore was applied, and the original checkpoint remains
unchanged. Approval for that explicit test is pending. Native Focus, remaining
physical interaction/accessibility checks, the Work MacBook Pro lane, and final
public-release approval remain outstanding. No public release or feed activation
has occurred. See FEATURE_QUALIFICATION.md for evidence scope and historical
failures; the implementation-stage entries below are chronological history.

## Explicit available-item recovery — September 8, 2026

The interrupted Focus recovery UI now offers a separate read-only preview with
missing/new item counts and an explicit available-items confirmation. Prepared
recovery binds the original checkpoint, live logical layout/workspace and local
mutation epoch; changed state rejects confirmation before side effects. The
transaction verifies the full reconciled target, including preserved new items,
and uses the existing strict compensation path on failure. Partial success does
not claim prior profile authority. It durably archives the original checkpoint
in a separate manual-only store before ending the pending Focus lifecycle.
Crash recovery recognizes a matching archive and resumes cleanup, not replay.
The bounded archive cannot silently replace another receipt; an independently
visible, token-confirmed discard action prevents older receipts from blocking
later recovery. Settings change-and-revert invalidates confirmation by revision,
and completion reports the observed active display rather than a historical one.
Display topology and known hardware fingerprints must still match.

All 354 Core tests pass, including partial success, stale-preview rejection,
change-and-revert, manual archive reopen/no-overwrite and failed-target compensation;
Debug app/helper compilation also passes. The read-only safety review findings
are addressed. App, helper and extension advance to build 28 for clean candidate
qualification; fresh fast/candidate gates are pending. Installed build 27 is
unchanged. No physical partial recovery or release readiness is claimed.

## Recovery inventory preview — September 8, 2026

Exact restoration now preflights the inventory before workspace writes, and the
helper uses the shared fixed-anchor plan instead of replaying every descriptor.
It rechecks inventory between operations and verifies the complete admitted
target afterward. Missing/new identities fail exact restoration rather than
silently dropping items; incomplete recovery remains a separate unfinished path.
The status message distinguishes inventory/display recovery failure from a generic
operation failure. All 349 Core tests pass, including a stale-checkpoint test
asserting zero workspace and restore side effects; app/helper Debug compilation
passes in isolated DerivedData. These are source checks, not an installed pass.
The subsequent dirty-worktree fast gate also passes after the reviewed generated
duplicates were quarantined. Logs: ignored `recovery-preflight-fast.log`,
`recovery-preflight-all-core.log`, and `recovery-preflight-debug-final.log` under
`.artifacts/local-acceptance-2026-09-07/`. No signature or runtime claim attaches
to these uncommitted source checks.

Installed build 27 passed its clean nonfocus gate, notarization and signed local
upgrade. Its explicit Focus restore progressed beyond capability admission but
failed with `stale_item`. A read-only comparison found one saved non-control
identity absent from the live census, with new identities also present. The
checkpoint remains retained; restoration has not passed.

`WorkspaceRecoveryPlanner` now computes a pure preview using exact identities
and the existing fixed-anchor reconciler. It reports missing and added items,
requires explicit approval for incomplete restoration, rejects duplicate
identities, changed display assignments/topology and empty live responses, and
preserves new items in the admitted target. Five focused tests and strict lint
pass. Available-item recovery is not yet connected to the live transaction: preview UI,
generation-bound execution, exact admitted-target verification and checkpoint
completion semantics remain required. Existing strict rollback validation is
unchanged. Build 27 remains installed; no new candidate is released.
The dirty fast run at `14:55:57Z` passed all 345 Core tests but is not a
qualification pass: SwiftFormat initially required a property-body wrap (now
corrected), and site hygiene rejected `site/dist/robots 2.txt`. Inspection also
found `site/dist/styles 2.css`. Both were subsequently verified byte-identical
to their canonical generated outputs and moved (not deleted) into ignored
`.artifacts/local-acceptance-2026-09-07/site-output-duplicates/` for recovery.
The original failure logs are retained under the ignored candidate artifact path.

## Transient backend capability recovery — September 8, 2026

Installed diagnostic build 26 reports `capability_unavailable` during explicit
Focus restoration. Its local support bundle confirms Fallback/unavailable with
all capabilities false while Accessibility and Screen Recording are granted.
The original lock/start timing is not yet proven, but permanently retaining a
failed factory probe prevents later recovery regardless of that trigger.

The helper now retains a probe-gated backend after unavailable startup and uses
a serialized, demand-driven two-second capability cache. It neither advertises
capabilities based solely on OS version nor runs a background timer. Later
observations can recover or revoke capabilities. Four pure transition/bounding
regressions and strict lint pass; helper compilation and clean candidate gates
are next. Installed build 26 is unchanged and the Focus checkpoint is retained.
No successful runtime recovery or release readiness is claimed.
App, service and extension advance to build 27. The default DerivedData build
failed on a stale Sparkle precompiled header; retain its log and use clean
isolated DerivedData via the canonical qualification script, not a source
workaround for the cache failure.

## Installed recovery failure diagnosis — September 8, 2026

Build 25 at `23e55ce` is installed; the maintainer confirmed the clock/Control
Center shelf defect resolved (BLN-20). The approved explicit pre-Focus restore
then failed on the installed candidate. Its journal was retained; successful
restoration is not claimed. BLN-4 remains open.

The next diagnostic change uses closed, payload-free error codes and separates
transaction failure from final recovery verification failure. Six focused
diagnostics tests and strict lint pass. This is instrumentation, not a recovery
fix or a new installed-candidate pass. The current source change requires fresh
build and candidate qualification before its diagnostics can be used live.
App, service and extension advance together to diagnostic build 26. The dirty
fast run passed all other gates but failed site hygiene on `robots 2.txt`;
the original failure is retained and no such file is removed to bypass it.
No checkpoint is deleted to bypass recovery, and unrelated marketing work stays
outside the change.

## Build 25 qualification candidate — September 8, 2026

Follow-up review excludes Barline's stretching hidden/always-hidden separators
from the helper's live button hit test. Their broad window bounds must not disable
genuine empty-space activation. Exact-identity regression tests preserve the
visible Barline control, clock and Control Center as occupied regions. This source
change requires a new clean run; the preliminary `e0fab66` run remains separate.

Build 25 retains version 1.0.11 and includes the system-control hit-test correction
and explicit interrupted-Focus recovery action. App/service/extension versions
advance together. Unsigned Debug compilation passes including the click sequence
guard; recovery success and compensated-failure regressions both pass.
The dirty fast gate passed Core tests but failed site hygiene on an unexpected
`robots 2.txt` entry that was absent on subsequent inspection. Its failure log is
preserved; no files were removed to bypass the gate. A new clean candidate outside
the synchronized workspace must pass qualification. Build 24 remains installed;
no live recovery, new signed installation, public release or feed change is claimed.

## System-control clicks misclassified as empty space — September 8, 2026

The user reported that clicking the clock or Control Center opens the shelf and
leaves it visible. Inspection found that HID hit-testing used `managedItems`,
whose cache deliberately excludes `canBeHidden == false` and system clones.
The accepted cache now retains an independent hit-test list before management
filtering. Click/hover empty-space classification uses this list and refuses an
empty/unavailable cache. Empty-space left-click toggling also requires the helper's
live point context to confirm no menu-bar item owns the point. Event modifiers
are captured from the initiating event before the asynchronous lookup.

Seven click-arbitration tests pass, including missing-snapshot rejection and
preserved genuine-gap eligibility. Updated app compilation and fast gates are
running. Physical clock/Control Center checks and shelf dismissal remain required;
the source correction is not yet installed or claimed as a live fix.

## Explicit interrupted-Focus recovery — September 8, 2026

Installed build 24 at `682a7e7` passed 20 bounded status-item clicks (zero
timeouts, p95 109.4 ms) and one controlled helper interruption (app process
preserved, replacement helper, recovery click 203.8 ms). Exact candidate receipts
remain in the frozen worktree's ignored `build24-installed` artifacts. These
passes do not resolve the earlier input miss or qualify the remaining journeys.

The retained interrupted Focus checkpoint still cannot be automatically recovered
after presentation evidence was lost across restart. Layouts & Focus now exposes
a confirmation-gated Restore Pre-Focus Layout action for pending transactions.
Confirmation binds to the exact journal token; the existing transactional restore
must succeed and the resulting workspace must match before the journal is cleared.
Cancellation, stale confirmation and failed restoration cannot discard the journal.
Automatic recovery remains conservative and is not granted user-override authority.

A focused Core regression passes for explicit checkpoint restoration with absent
live presentation after restart. Fast checks and unsigned app compilation are in
progress. No installation or live restore has run for this source change; build 24
remains installed and its checkpoint is untouched. New source needs fresh candidate
qualification before distribution.

## Build 24 independent-review corrections — September 7, 2026

The preliminary clean candidate `d342b85` passed the complete nonfocus suite and
Linux repository hygiene, but independent review found two correctness gaps.
Production Barline separators are manually movable and were therefore being
planned as ordinary saved items; dragging a separator changes neighboring
section classification. Planning now treats Barline controls as anchors without
changing their manual movability. Exact hidden/always-hidden separator identities
must remain last in their display-local section; duplicates and impossible saved
ordering fail before mutation. Fourteen planner tests pass, including both
separator types with their actual movable descriptor flags.

Base plans now validate the complete admitted item set and unchanged display
topology. Explicit display overrides retain their bounded scope. Regression
coverage includes a new display with items and an empty connected display.
The corrected source needs fresh clean qualification; no signing, notarization,
installed update, or public release occurred for the preliminary candidate.

## Build 24 candidate freeze — September 7, 2026

Version 1.0.11 build 24 incorporates the fixed-anchor activation and retained
Focus recovery presentation changes. App, menu service, and intents extension
build numbers advance together. Clean-source qualification, signing/notarization,
and installed Focus activation/recovery are required anew; build 23 receipts do
not qualify this candidate. The installed app remains untouched during the
noninteractive gates. No public release or update feed activation is authorized
by this candidate freeze alone.

## Integrated fixed-anchor activation — September 7, 2026

Activation now preflights the display-local move plan before creating a checkpoint
or applying workspace settings, emits only necessary movable-item operations, and
verifies the complete admitted target. Profile authority uses the same anchor
ordering instead of a saved prefix. New or missing items during the transaction
invalidate the target rather than being silently accepted.

Empty-destination behavior is an explicit optional backend capability. Missing
capabilities (including older peers) require a physical destination item; all
production backends retain that requirement and the helper checks are unchanged.
The logical test backend explicitly advertises its existing empty-section support.
Rollback tests now request actual changes instead of depending on redundant no-op
drags to trigger failures. New regressions verify preflight has no checkpoint or
workspace effects, preserved anchors, immutable item exclusion, and authority.

The integrated fast run's 329 Core tests and unsigned Debug compilation passed.
Its formatting gate found import ordering and await placement; both were corrected
and the complete fast-gate rerun passed. Prior failed integration runs remain
in the ignored local acceptance logs. A read-only replay of the actual retained
20-item checkpoint produces six moves, zero fixed-item moves and zero unspecified
item moves under the physical destination contract. This is planner evidence,
not live WindowServer execution. Installed build 23 and its
pending recovery checkpoint remain untouched. No new installed Focus activation,
restoration, signature, notarization, or release qualification is claimed.

## Fixed-anchor profile planning — September 7, 2026

A read-only replay of build 23's failed Focus checkpoint found that its saved
18-item layout was applied to a 20-item snapshot. Fixed-index activation requests
moving an immovable visible item from section index 12 to 10 after nine simulated
moves. This proves an invalid plan from the retained input, not the exact live
failure location. The existing prefix-based authority checks also need to account
for newly discovered items rather than forcing fixed system items ahead of them.

`ProfileLayoutReconciler` now constructs a complete target while preserving the
relative order and sections of unspecified items and immovable anchors. Impossible
fixed-item reorder/section changes and invalid identities fail before a target is
returned. Four focused tests pass. It is intentionally not wired into activation
yet: movement generation, display scoping, postconditions and authority matching
must be integrated and tested together. No live recovery or installed fix is
claimed by this target-construction step.

The per-display move builder now emits helper-compatible pre-removal insertion
indices in reverse target order, never scheduling unspecified or immovable items.
Seven focused tests pass, including all 144 combinations of a small ordering,
idempotence, cross-section transfers and unavailable physical destinations. Mixed
display input is rejected by this per-display primitive; multi-display composition
is still required before integration. The preceding target-only fast gate passed;
later move-builder edits have focused compilation/test evidence, not that earlier
gate's full certificate. No live event path uses this builder yet.

Multi-display composition now splits base layouts by current display ownership
and translates each local operation against simulated global section indices.
A scoped layout emits operations only for its requested display. Nine focused
tests pass, including interleaved displays and scope exclusion. Activation remains
unwired pending shared postconditions/authority integration and empty-destination
contract review: the physical helper requires another destination item, whereas
some existing fake-backend activation fixtures allow empty target sections.
Do not silently change those tests or weaken the physical precondition to obtain
a passing integration run.

## Native Focus activation/recovery finding — September 7, 2026

Installed build 23 (`aa3e738`) passed native filter configuration and saved-layout
selection, but a physical Work Focus activation failed. The application retained
a pending checkpoint without committing Focus authority; returning to Sleep did
not resolve it. The temporary Work filter was removed, Sleep was verified on,
and the application checkpoint remains untouched. A changed serialized appearance
hash is not proof of a modeled appearance difference: target and checkpoint
appearance values match. The original layout mutation failure remains unattributed.

A two-case coordinator regression demonstrates that a partial activation can
restore with retained live presentation, but must remain inconclusive without
that evidence. The app's pending-error path previously erased that presentation
while clearing active profile authority. It now retains the presentation actually
left by apply/rollback, without reconstructing it from the desired journal state
or relaxing recovery comparisons. Inconclusive/failed recovery likewise does not
author a nil workspace. This addresses an in-process recovery-evidence loss,
not relaunch reconstruction or the original activation failure. New source needs
fresh qualification; the signed installed build and its evidence remain unchanged.

The focused two-case reproduction, 315 Core tests within the fast gate, the
remaining fast checks, formatting, and unsigned Debug compilation passed locally.
Evidence is retained under `.artifacts/local-acceptance-2026-09-07/` in the
`focus-recovery-*` logs. These tests establish the recovery-evidence distinction;
they do not certify the ProfileManager error path on the installed app or repair
the original live activation failure.

## Native Focus extension repair — September 7, 2026

Signed build 22 (`249dcb0`) passed clean nonfocus gates, notarization, a
preference-preserving Sparkle upgrade, all four installed target journeys,
20 shelf cycles (p95 73.5 ms), and a single helper interruption/recovery.
Installed temporary-layout checks also passed canceled group rename and
single-display variant save/reopen, replacement confirmation/cancel, and removal.
No temporary layout was applied and local rules remained off.

The native Focus setup check then found a concrete blocker: macOS listed the
filter but displayed “Could not load Focus Filter.” Its log reported no
Launch Services extension record. The extension's legacy product/registration
and absent AppIntentsExtension entry point differed from the installed Xcode
macOS template. The correction adopts ExtensionKit without new identifiers or
entitlements, plus source and built-bundle regression gates. Build 23 must be
qualified afresh; build 22 remains installed until replacement gates pass.

BLN-17's original intermittent click miss is independently unresolved. A proposed
diagnostic generator was never executed; review found unsafe abort handling,
so its launch mode was removed. No passing later burst explains the earlier
miss. Native Focus loading/catalog/activation, search/keyboard, accessibility,
physical displays, and final installed gates remain separate requirements.
No public release, feed activation, or cross-device Focus changes occurred.

## Fixture setup and production-site safeguards — September 7, 2026

The clean `9c3af20` nonfocus run passed its non-UI gates but failed three
fixture UI preconditions: the running menu-bar layout placed newly created
synthetic status items off-screen. No off-screen click was attempted. Fresh
fixture sessions now seed only their own nonpersistent preferred position and
wait at most three seconds for an actual on-screen frame. Installed journeys
retain their original position/restoration behavior. The focused four-test
XCUITest rerun passed with exact activation/open/action/close receipts; both
the failed and successful `.xcresult` bundles are retained. This is a fixture
setup repair, not attribution or closure of BLN-17.

The static site now has explicit production-mode validation for the canonical
domain, approved contribution link, exact versioned binary/source/checksum and
release links, canonical pages, and launch-ready indexing. Current preview
content intentionally fails production validation before output changes.
Website regression tests also run in the existing Linux repository-hygiene
lane. Configuration validation is not proof of artifact availability, rendered
production QA, app qualification, or permission to publish. No site content,
deployment, or installed app was changed by this checkpoint. Freeze the new
source and rerun local qualification before signed build 22 packaging.

## Build 22 preparation — September 7, 2026

Version 1.0.11 build 22 incorporates the BLN-19 observation-lifecycle repair.
App, helper and intent-extension build numbers advance together. Validate a
clean frozen checkout; retain build 21 installed until the new candidate's
local gates and signed packaging pass. Its source change invalidates earlier
candidate-bound certificates. No public release or production feed activation
is authorized by packaging alone, and the original BLN-17 input miss remains
unattributed. The independent site/support review does not substitute for app
runtime, physical-device or accessibility acceptance.

## Search, groups and observation lifecycle — September 7, 2026

Installed build 21 passed temporary group create/save/reopen, rename/save/reopen
and Escape cancellation of an unsaved rename. No saved layout was applied.
The focused search/group run passed 44 tests in six suites; the actual search
preference actor passed private-file, reopen, cancellation, I/O failure,
competing-writer and damaged-store probes. These are not installed search,
group-collapse, Focus or accessibility acceptance.

Read-only review found BLN-19 independently of the unresolved BLN-17 click miss:
ControlItem retained superseded button/window/screen subscriptions and ignored
nil detachment. The repair observes only the latest owner, clears detached
values, and schedules delivery inside the switched stream so already queued old
values cannot escape cancellation. A noninteractive probe compiles the actual
production operator, reproduces the legacy overwrite/nil-retention and queued
delivery failures, and verifies replacement, detach/reattach and duplicate-owner
subscription behavior. It is now part of the macOS fast gate. This is not an
atomic multi-property geometry snapshot or a change to input delivery.
Focused regressions, strict fast checks, Debug and Release compilation, and
Release static analysis passed during integration. These local results do not
qualify a signed/installed replacement, and BLN-19 remains open for that lane.

The installed signed candidate remains source `59de12d`; the lifecycle source
change needs new candidate-bound build/release/runtime qualification. Do not
close BLN-17 or carry the old candidate's certificate forward. Pending installed
search uses a temporary Control-Option-Command-8 shortcut; remove it and the
temporary layout when that check finishes. No public release has been made.

## Physical shortcut checkpoint — September 7, 2026

Installed build 21 (`59de12d`) received a physical fixture shortcut activation
and native menu open/close, but the maintainer saw no response and no fixture
action was received. A second attempt, with a passive fixture-only window
geometry observer, completed exactly one activation/open/action/close; its menu
intersected the active display and remained open approximately five seconds.
The restoration journal was empty before removing the temporary shortcut and
stopping only the fixture. The installed app was not replaced or restarted.
Preserve both attempts: this bounded success does not explain the earlier miss
or establish repeatability. Remaining qualification and release NO-GO are
unchanged. See FEATURE_QUALIFICATION.md and the ignored shortcut-failure packet.

## Local-first qualification direction — September 7, 2026

The maintainer confirmed dev@mabryventures.com as the private conduct-report
contact; CODE_OF_CONDUCT.md now publishes it. Complete and stabilize the current
Mac's remaining runtime checks before using Jared's Work MacBook Pro for notch
and display-transition coverage. No test pass or release approval is implied by
the device selection. Keep the installed signed candidate and the original
BLN-17 failure evidence intact while narrowing the remaining local checks.

The shelf probe now distinguishes unexpected foreground UI from a timing
timeout, stops after the first opening failure instead of sending more clicks,
and emits buffered per-dispatch timing/flag metadata at exit. It collects no
coordinates, app names or outside input. Six deterministic cycle tests cover
success, timeout/baseline failures and interrupted opening/closing. These are
diagnostic corrections, not attribution or a product fix for the original miss.

## Build 21 qualification checkpoint — September 7, 2026

Frozen source `59de12d883c49d48b53b32d7874d4adff36ff76e`, installed
1.0.11 build 21, passed clean nonfocus qualification: 314 Core tests,
158 fixture/state tests, four fixture UI tests, Debug/Release builds and
static analysis. Packaging, notarization, staple and Gatekeeper passed.
The real build-20-to-21 Sparkle upgrade preserved semantic preferences,
the production feed and a single installed app process.

All four installed target-interface journeys passed on their first attempt:
native right, native left, popover left and popover reuse. Each witnessed
exactly one activation/open/action/close, the target's real accessible action,
the shelf staying closed during activation, hidden-position restoration and
pointer restoration. One forced helper interruption also recovered without
restarting the app. Deleting the final temporary layout now succeeds; shortcut
recorders are exposed in the installed accessibility tree. These observations
do not establish physical-keyboard or VoiceOver qualification.

**Release remains NO-GO.** The initial 20-cycle shelf gate failed cycle 9
with one opening timeout. Its failed log is retained, with no passing
performance receipt. The interval lacked both the product action log and
AppKit tracking/action messages; this narrows the investigation but does not
prove where input was lost. A traced 20-cycle run, buffered transport-observer
100-cycle diagnostic and corresponding 100-cycle run without that observer
passed. Passing diagnostics do not erase the original failure or establish a
root cause. No production workaround, extra click or automatic replay was added.

Temporary test layout, rule, shortcut and fixture process were cleaned up;
the installed signed candidate remains available. Build-20 and build-21 logs,
failed attempts, source/binary metadata and receipts are retained under ignored
`.artifacts/retained-qualification/2026-09-07-build20-21/`. Draft PR #6 contains
the implementation and visitor documentation; the Linux hygiene check passed.
No public release, update-feed activation or canonical download was published.

Outstanding: BLN-17 input-loss attribution; installed groups/search and
physical shortcut/Focus/manual-override checks; second-display/notch and power
transition hardware coverage; accessibility acceptance; private conduct-report
contact; final exact-candidate release gates. This host has one external display
and no macOS 27 runtime. Do not claim those unavailable lanes as tested.

## Installed qualification findings — September 7, 2026

Source `3400f35` (1.0.11 build 20) passed clean nonfocus qualification,
312 Core tests, 158 fixture/state tests, four fixture UI tests, strict
Debug/Release builds and analysis. Signed packaging/notarization, a real
build-19-to-20 Sparkle upgrade with retained preferences and one process,
20 shelf cycles (zero timeouts, p95 97 ms), and helper interruption passed.
Native left activation passed, but native right activation intermittently
failed twice: the target process received reveal/move events but no right
click, while the helper's session barrier reported delivery. Passing diagnostic
retries do not erase those failures. Public release remains blocked.

Build 21 restores the imported compatibility baseline's target-PID assignment
on the exact matched click at the session boundary, before exit acknowledgement.
No second mouse-down or automatic click replay is added. Regression tests cover
matched routing/payload preservation and nonmatching-event rejection. Passive
tap mutation is compatibility behavior, not an Apple API delivery guarantee;
fresh signed installed target-action qualification is mandatory.

Installed build-20 UI checks passed single-display capture, save/reopen,
replacement confirmation and discarded removal drafts. A temporary rule could
be created while global rules remained off. These are bounded checks, not the
physical-display, native Focus, power-transition or accessibility matrix.
The outdated read-only display-help text is corrected. Test data remains
explicitly named temporary until cleanup. Original failed evidence is retained
under `.artifacts/feature-installed/` in the clean qualification worktree and
will be copied into the main repository's ignored evidence storage.

Cleanup exposed a preexisting last-layout deletion restriction inconsistent
with the supported empty state. Build 21 permits an empty persisted local
catalog while retaining nonempty public archive validation. Regression tests
cover reopen, previous-layout backup and recovery from an empty backup.
The installed shortcut recorder also exposed a semantic grouping issue: its
buttons were visible but absent from the accessibility subtree in a nested
item row. Explicit child containment now preserves those controls; installed
accessibility verification remains required. A shortcut was recorded for the
synthetic native fixture, but a tool-generated chord did not establish global
Carbon dispatch, so no physical-keyboard activation pass is claimed.

## Feature completion and visitor cleanup — September 7, 2026

Candidate 1.0.11 build 20 integrates display-variant authoring, opt-in event-driven
context rules and per-item shortcuts, alongside existing groups, search
personalization and native Focus guidance. The implementation/qualification
contract is [FEATURE_QUALIFICATION.md](FEATURE_QUALIFICATION.md). Editors retain
failed-save drafts; rules recheck admission through the transaction, never
restart other apps for spacing, pause after manual changes and start paused
after relaunch. Shortcut conflicts, suspension and teardown now retain explicit
ownership and fail closed.

Visitor documentation and issue templates are corrected; detailed operational
documents were preserved in ignored local backups. Private vulnerability
reporting was verified enabled. A monitored private conduct contact remains a
user choice. An unrelated awareness-campaign draft appeared during this work;
it is preserved and excluded from engineering changes.

Iteration evidence includes passing Core regression suites, actual preference
write/cancellation/corruption/conflict probes, actual Carbon registration checks
without event injection, Debug/Release builds and the fast gate at
`.artifacts/ci/946e116047562599723ab7adce2a787b17d886e1/fast-2026-09-07T23-33-40Z`.
Subsequent changes require fresh full gates. Installed 1.0.10 build 19 remains
untouched during source work. No feature runtime pass, macOS 27 support,
notarization for new source or public availability is claimed by this checkpoint.

## BLN-17 diagnostic correction — September 7, 2026

Candidate `946e116` (1.0.10 build 19) was signed/notarized and installed through
a real preference-preserving Sparkle upgrade. Its final full gate failed one
of 20 shelf cycles; the original failure and four passing target receipts remain
under that source-bound artifact directory. Release has not been published.

The performance driver discarded a failed close, misclassifying the following
close as an opening timeout. It now rejects an unclosed baseline, fails the
actual close phase, resolves the owned status-item target for each dispatch,
and includes dispatch/lookup in latency. Four deterministic cycle regressions
are wired into the fast gate. These are test-driver corrections, not a proven
application fix for the original missed click.

Two bounded diagnostic runs on the unchanged signed executable passed: the
hardened 20-cycle probe (p95 163.5 ms including lookup/dispatch), and the original
rapid cadence with a temporary listen-only session event observer (all 42
clicks' down/up pairs observed). The latter ran alongside compilation and is
diagnostic evidence, not a clean performance certificate. No target movement
was observed in the hardened run. The original missed close is not reproduced
or conclusively attributed; BLN-17 and release qualification remain open.
No app relaunch, permission reset, target action bypass, or timeout relaxation
was used. Temporary observer code is confined to ignored artifacts.
Fast gate passed with the four new cycle regressions and 296 Core tests;
receipt: `.artifacts/ci/946e116047562599723ab7adce2a787b17d886e1/fast-2026-09-07T22-53-17Z`.
This dirty-tree iteration receipt is not a new release certificate.

Additional-feature status: groups and search personalization are implemented
but still need installed keyboard/persistence qualification; native Focus
guidance is implemented, display variants are read-only, automatic context-rule
integration and per-item global shortcuts remain unfinished. Site/donations
are on staging; the canonical public-domain launch remains separate.

## Fresh release qualification — September 7, 2026

User authorized release only after a new qualification battery passes. Candidate
1.0.10 build 19 includes the reviewed reliability-first app changes and retains
the installed 1.0.9 build 18 until a signed replacement is available. No previous
SHA's receipts qualify it. Run fast, full installed-candidate gates, signed
packaging, real upgrade, and the changed-feature/manual acceptance matrix.
Keep failures, exact source/binary hashes and runtime evidence under ignored
artifacts. Public release is conditionally authorized, never authorized on a
partial or bypassed gate. macOS 27 remains a separately unqualified OS lane.

## Reliability-first direction — September 7, 2026

The current forward plan is [RELIABILITY_FIRST.md](RELIABILITY_FIRST.md): core
reliability/speed first, guided native Focus/display layouts, explainable rules,
functional shelf groups, keyboard personalization, and a quiet donationware
site on Cloudflare Pages. macOS 27 compatibility now requires rigorous runtime
qualification; macOS 27-exclusive features are deliberately not day-one scope.
Older milestone snapshots below are historical, not current certificates.
Public release/update publication remains staged for final approval.

Implementation checkpoint on `codex/reliability-first`: accessible collapsible
shelf groups, local search favorites/aliases with atomic private persistence,
guided native Focus setup and honest read-only display-variant descriptions,
and a configuration-gated About support link are implemented but not installed
or runtime-qualified. The contextual-rule evaluator is proposal-only; safe
automatic application and per-item global shortcuts remain unfinished. Do not
treat them as shipped features. The working installed 1.0.9 build 18 is untouched.

Cloudflare Pages project `barline-site` now has an authorized `staging` preview.
`usebarline.com` is the user-owned canonical domain, not yet activated. Stripe
sandbox success/decline/abandonment are verified. Approved live one-time support
is configured and linked from staging with real-payment disclosure; public
domain/app release activation remains gated. BLN-9 records checkout evidence.
Barline Linear team (BLN) owns the roadmap (BLN-1–14). GitHub issue/comment
delivery to `#productsupport` and inbound Linear Triage sync passed a controlled
test. Linear posting to `#barline` is authorized and verified with creation and
comment receipts from BLN-16; roadmap/status/triage notifications are enabled. Ice credit moved
to the deployed About page. Receipts: [SUPPORT_DELIVERY.md](SUPPORT_DELIVERY.md).
Site delivery evidence is recorded
in [site/QA.md](../site/QA.md). New source invalidates prior candidate certificates;
the current checks are iteration evidence, not signed release qualification.

## Distribution refinement — 1.0.9 build 18 preparation

Build 17 (`f7478cf`) passed fast, signing/notarization, semantic upgrade, and
all four isolated fixture XCUITests. Installed qualification failed: one
restoration observation timed out and a later native-target move failed before
activation. Successful intervening popover runs do not erase those failures.
Build 18 guards both intentional drag dispatch stages against cancellation,
allows release to commit geometry without requiring an intermediate change,
and adds closed failure codes. Final placement checks remain unchanged.
Focused no-event regressions cover dispatch ordering and release sequencing.
Fresh full and signed installed proof remain mandatory; publication is staged.

Build 16 (`67399bb`) passed fast, signing/notarization, and upgrade/preferences.
Its first shelf presentation committed, but closed roughly 400 ms later before
fixture controls became actionable; the installed journey therefore failed.
Build 17 applies primary control hit ownership to smart rehide as well as
empty-space arbitration, including windowless hosted events with stale bar
geometry. Shelf clicks are similarly excluded using captured event geometry.
Deferred dismissal reasons now have bounded diagnostics. Policy regressions
cover each exclusion and the genuine outside-click positive control. This is
not runtime qualification until the new candidate passes its installed gates.

Build 15 passed signing/notarization, upgrade/preference checks, and 263 Core
tests, but its first installed shelf-open journey failed. The deferred-work
lease does not prevent a second handler from toggling the same current click.
Build 16 makes control-window target ownership authoritative even with stale
geometry and uses the event's captured coordinates in click arbitration.
Ownership checks read the live status button's window and geometry synchronously rather
than relying only on its queued published window after a button replacement.
A Core regression covers a control-window event with all geometry claiming
empty space. Installed runtime proof remains mandatory.

User authentication now permits XCUITest execution. Its fixture-only status
tests failed because the concurrently running Barline hid those fresh items;
qualification must isolate that lane from the installed utility, then reopen
the exact candidate once for installed runtime gates. This is separate from
the observed first-click product failure. All failed attempts remain retained.

Build 14 passed signing/notarization, a semantic-preference-preserving signed
upgrade, all four installed target lanes, 20 shelf opens (p95 47.3 ms), and one
helper replacement with preserved app PID. The five-open follow-up failed one
sample: generation 49 began and was immediately closed without another control
action. All evidence remains under its source-bound artifact directory; the
six passing receipts do not override the failed enclosing burst gate.

Review found delayed smart-rehide work had no presentation ownership and read
the later pointer location. Build 15 captures the original event location and
binds smart, timed, hover, and focused-app delayed dismissals to a presentation epoch.
Closing/reopening invalidates earlier dismissal leases. Four pure regression
cases cover current, closed, reopened, and repeated presentation lifetimes.
This closes a demonstrated code-level race consistent with the retained trace;
the prior logs do not conclusively identify which dismissal caller fired.
Fresh installed qualification is required. UI Automation authentication remains
an independent external gate; public publication remains approval-gated.

Build 13 passed four consecutive installed target-action/restoration lanes and
direct restart-recovery UI checks. Its full gate passed builds, analysis,
Core/integration execution, fixture, semantic accessibility and privacy checks.
XCUITest hit a distinct macOS authentication boundary: automation mode is
disabled and requires user authentication, despite DevToolsSecurity being enabled.
The performance harness also rejected a verified hosted icon's two-point width
difference; build 14 fixes that comparison with eight regressions and keeps the
250 ms budget unchanged. A focused real click then passed at 23.7 ms. That single
sample is not the required 20-sample candidate performance certificate.

Build 12 passed signing/notarization and a localhost Sparkle upgrade, but failed
its first installed hidden-item action gate. The new checkpoint required display
ownership while the helper supplied physical intersection only, leaving hidden
off-screen items unresolved. Build 13 separates logical WindowServer ownership
from physical click visibility, including restoration destination selection.
The working 1.0.8 install was restored while correcting this failure. All build
12 artifacts remain rejected qualification evidence. Public release and update
feed activation are staged for the user's final approval, not authorized now.

The September 7 follow-up audit identified mutable-neighbor restoration and
candidate-receipt enforcement gaps. Temporary reveals now carry a durable,
bounded checkpoint of the original display/section plus ordered stable anchors.
Moved/missing anchors cannot redirect restoration; unavailable topology pauses
for explicit recovery, and three failed attempts stop automatic retrying.
After restart, retained entries require Retry Item Restoration in Layouts & Focus
rather than silently overwriting possible outside-app edits.

New authoritative layout operations are blocked while compensation remains;
they never discard a pending reveal before an operation that might roll back.
Manual dragging first attempts restoration. Focus/layout failures explain the
recovery prerequisite. Core tests cover the guard, journal and resolution policy.

The installed full gate already called performance and XPC interruption through
the reopen-burst script; the audit's claim that these were entirely skipped was
too broad. This refinement makes their receipts explicit and mandatory, together
with four actual target-interface lanes, exact source SHA and executable hash.
Receipt validator/writer tests cannot themselves certify runtime behavior.

Build, signed candidate qualification, and distribution preparation are in
progress. No new runtime, notarization, upgrade or public-release success is
claimed by this implementation checkpoint. macOS 27 and soak remain deferred.

This is the live implementation ledger. A milestone is complete only when its
code and evidence match the build specification; documentation alone is not a
gate result.

## Current checkpoint: shelf activation correction, 1.0.8 build 11

The installed 1.0.7 user journey exposed a real regression: a temporarily
revealed native item remained in the shelf projection, and a no-interface
timeout reopened the picker. Logs also captured presentation during an active
click. The corrected candidate blocks picker presentation during activation
and restoration, excludes outstanding temporary reveals from shelf rendering
without changing saved layout authority, and keeps an unconfirmed click distinct
from a failed operation. Unconfirmed clicks no longer reopen the picker over a
possibly delayed target interface.

The helper click path now follows the exact vendor baseline's session dispatch
with source-queue null barriers, cleared modifiers, and down/up click states
1/0. Real clicks are not directly reposted to the source PID; passive delivery
acknowledgement is still not target activation proof. The synthetic journey must
observe the target menu/action and restoration on the signed installed candidate.
Current iteration: 221 Core tests and three production event-delivery ordering
tests pass. A shelf-only screenshot proved fixture items rendered while their
representable wrappers exposed no actionable AX buttons; explicit SwiftUI
accessibility semantics now wrap the native pointer controls. Compilation and
signed runtime qualification continue. The first signed iteration has passed
the installed synthetic native-menu and custom-popover journeys, including
target actions and position restoration. The harness now verifies the fixture's
hosted autosave-name alias instead of assuming its rendered text is its AX label.
These results must be rebound after this gate correction changes the source SHA.
No public release or production GO is implied.

The second signed iteration (`a7f6e72`) also passed native-menu and popover
activation, action, closure, and original-position restoration with a stricter
visible-action resolver. Earlier failures are retained, not discarded: a menu
opened and closed without its action receipt, and another run missed its short
visible interval. The gate now requires a unique, enabled, on-screen,
fixture-owned action with the expected menu-item or button role. This prevents
stale or wrong-interface selection; it does not establish that as the cause of
every earlier failure. The final source-bound package must rerun these journeys.

The subsequent `05525e3` native journey passed after a fresh background launch,
but its popover attempt produced no fixture activation. This remains a failed
candidate, despite its passing fast/signature/notarization gates. Baseline
comparison found two omitted protocol details: paired mouse-up releases and
consumption of source-queue null barriers. Build 10 restores these and the
baseline's balanced cursor hiding instead of drag-style cursor disassociation.
No second mouse-down or full-gesture retry is introduced. The installed journey
now fails on duplicate activations, opens, actions, or closes; exactly one of
each is required. Source parity is a hypothesis to validate, not a runtime pass.

The bounded build-10 observer established the actual popover failure: the
synthetic hosted item retained `kCGWindowIsOnscreen = true` while both its CG
and AX frames were outside every active display. Its frame and target receipt
did not change during the failed journey. The app therefore took its direct
activation branch and clicked off-display instead of temporarily revealing it.
Build 11 derives menu-item visibility from the reported flag AND a finite click
center inside an active display. Hidden descriptors remain in the inventory;
generic interface observations keep their existing visibility semantics. The
helper checks fresh geometry again before any click side effects. Regression
tests cover the observed stale-flag condition and multi-display geometry.

The September 6 audit found 12 issues in `b03645e` (installed 1.0.6).
The historical milestone table below is not qualification evidence for this
replacement. Follow [the finding ledger](PRODUCTION_REMEDIATION.md) for current
implementation and candidate-bound gates. Scope includes activation and return
transactions, ownership continuity and legacy layout identity migration, real
menu tracking, permission reconciliation, runtime-log privacy, Sparkle 2.9.6,
native shelf accessibility, image fallback, bounded off-main search/icon work,
and an explicit [auto-hide support boundary](SUPPORTED_CONFIGURATIONS.md).

Release validation is in progress. Local builds and focused tests are iteration
evidence only until rebound to the final clean source SHA. The installed-target
journey must observe the target menu and receipt, not just shelf visibility.
Repeated Settings-foregrounding gates have been replaced by bounded shelf and
helper-recovery probes. macOS 27 and release-duration soak remain user-deferred.

The first clean-main Build 32 full run exposed a recovery-probe measurement
error rather than a shelf-presentation regression: WindowServer logs showed the
shelf ordered within milliseconds, while synchronous synthetic-event delivery
returned hundreds of milliseconds later. The status-item probe now begins its
WindowServer observation before dispatch, retains the pre-click latency anchor,
requires dispatch to complete, and applies the same model to rapid retry.
Cancellation, deadline anchoring, foreground-UI rejection, and cross-thread
result delivery have focused strict-concurrency coverage. The corrected local
recovery burst passes, but exact clean-SHA full qualification must be rebound
after this gate-only change lands.

Final integration review added cancellation-independent serialized compensation,
capture permission epochs checked at UI publication, initial/late-window
auto-hide discovery, and image-owning native shelf buttons. The 219-test Core
iteration and Debug build pass. New fixture event-receipt qualification remains
red on this host (XCTest delivered no activation); the independent installed
journey has opened the shelf but has not yet established target activation.
These are explicit pending gates, not a production GO or permission to bypass
the protected local check. Updated signing/install validation continues locally.

The September 14 macOS 27 runtime lane exposed two additional activation
boundaries after discovery succeeded. A nonactivating shelf panel did not
receive pointer events until it explicitly set `ignoresMouseEvents` to false,
and the helper tried to begin interface observation through the obsolete
per-status-item WindowServer inventory. Build 56 routes pointer, keyboard, and
Accessibility activation through one native shelf button; resolves Golden Gate
items through the shared public Accessibility identity builder; binds interface
observation to the uniquely resolved owner process; and rejects ambiguous
identity changes. Signed diagnostic fixtures have exercised native-menu and
popover activation on macOS 27, but exact-SHA release packaging and both OS
qualification lanes remain required before release.

The later build-67 installed reuse journey exposed a successful macOS 27 target
activation followed by a rejected stale inventory snapshot. Status-item clicks
are commands owned by the target application, not transactional Barline layout
mutations: opening a menu may legitimately change status-item state before the
click returns. Build 69 therefore validates authority and target identity only
before delivery, treats the backend return as the acknowledgement, and performs
no post-delivery snapshot validation, rollback, or shelf reopen. A regression
supplies the exact unchanged-generation condition and proves it is never read
after delivery. The full build-68 gate also found and rejected a stale generic
activation call in natural-language search; build 69 routes that final entry
point through the dedicated API. Exact build-69 macOS 26 and macOS 27 installed journeys remain
required before distribution.

| Milestone | Owner | Status | Dependencies | Evidence |
| --- | --- | --- | --- | --- |
| 0. Import and provenance | Lead; delegated audit | Complete | none | Exact history, remotes, ancestor proof, vendor tag, license/provenance records |
| 1. Baseline build and audit | Lead; delegated audits | Complete | M0 | Debug/Release/analyze/archive and policy scripts pass; permission-gated launch; result bundles |
| 2. Rebrand and build system | Lead | Complete | M1 | Debug/Release/analyze pass; strict lint 0 violations; canonical Run verification pass |
| 3. Core and compatibility firewall | Lead | Complete | M2 | 193 Core tests; strict source/binary firewall; helper generation rebasing, absolute mutation deadlines, session-cancellation quiescence, durable authority rehydration, fail-closed recovery, and pure shelf-presentation commit policy |
| 4. Fixture and local CI | Lead; delegated validation | Exact-head full gate passing | M3 | `ci.sh full --publish-status` passes on the exact candidate with 180 Core tests, 134 fixture regressions, fixture XCUITest, semantic accessibility, privacy, XPC interruption, UI smoke, a 20-cycle performance probe, and the 100-cycle plus eight helper-recovery reopen burst; retain the ignored `.artifacts/ci/<sha>/` packet |
| 5. Profiles and Focus | Lead | Native layout filter implemented; exact-head system execution pending | M3–4 | Apple Focus Filter selects any saved Barline menu bar layout by stable identifier; Barline links to the system-owned Focus configuration because Apple exposes no public Focus-mode catalog; configured app-group store, bounded import, generation-checked workspace/layout/presentation history and rollback, atomic crash-recovery authority envelope, exact-target promotion, original-state recovery, unrelated-state preservation, durable Focus journal, and conservative display reconnect; exact-head signed Focus activation/deactivation remains required |
| 6. Search and on-device interpretation | Lead | Complete for macOS 26 | M3–5 | collision-free opaque item identities, deterministic ranking, bounded and serialized latest-wins Spotlight replacement, cross-display metadata, 180 Core tests; macOS 27 tool remains gated |
| 7. UI and accessibility | Lead | Exact-head automated validation passing | M3–6 | profile UI, fixture UI, diagnostics review/save, fixture XCUITest, and semantic accessibility pass on the exact candidate; foreground VoiceOver and Full Keyboard Access remain manual validation lanes |
| 8. OS hardening | Lead | Shelf commit hardening implemented; exact-head full gate pending | M3–7 | Shelf presentation now sizes before ordering and requires two consecutive AppKit plus helper-owned WindowServer confirmations when that observer is available. A valid local AppKit presentation remains ordered when unrelated helper work delays WindowServer observation, so observer availability cannot roll back a user click; invalid local geometry still retries and fails closed. The semantic helper probe bypasses mutation serialization, never exports ephemeral window IDs, and cannot invalidate the shared session on its bounded timeout. The runtime harness has a real status-item click lane pinned to the exact app PID and window number. Exact-head full/candidate testing, physical scenario matrix, release soak, and macOS 27 remain pending. |
| 9. Distribution readiness | Lead | Notarized 1.0.5 installed; replacement candidate validation in progress | M0–8 | Developer ID export, App Group profile validation, notarization, stapling, Gatekeeper, Sparkle signing, checksums, SBOM, and source archive passed for installed 1.0.5; exact-head evidence must be regenerated for the helper-independent shelf presentation correction. |

## External boundaries currently known

- The local build host uses Xcode 26.6 with the macOS 26.5 SDK. macOS 27
  compilation does not depend on an unavailable Xcode 27 toolchain.
- An Apple Silicon macOS 27.0 runtime host is available for installed-candidate
  qualification. Diagnostic execution is iteration evidence until rebound to
  the exact signed and notarized release candidate.
- The canonical `Mabry-Ventures/mv-barline` repository, `origin`, protected ruleset,
  and pull request exist; the protected local macOS check is published from the
  exact candidate full gate.
- A valid Mabry Ventures Developer ID identity and Barline App Group
  provisioning profiles exist locally. Keychain authorization is configured,
  and a Developer ID export has passed nested signature validation.
- Sparkle signing material and the full credentialed release path pass locally.
  The `barline-notary` profile is stored in the login Keychain; release tooling
  selects that Keychain explicitly to avoid a same-named stale credential in a
  different backend. Exact-head release validation uses this explicit
  credential-selection path.
- Developer Tools automation mode and the fixture accessibility path have been
  validated. The production reopen-to-visible p95 gate necessarily activates
  Barline and was run in a dedicated unlocked interactive session; Barline is
  closed after each runtime gate.

The lead owns all project-file, scheme, test-plan, configuration, entitlement,
identifier, dependency, and integration changes. Delegated audits are advisory
until their findings are incorporated and rerun by the lead.
Build 69 passed the clean source gates and distribution pipeline, but its first
installed macOS 27 native journey exposed a separate status-control recovery
collision: the target opened and completed successfully, then a shelf click was
misclassified as a missing control click and reopened the shelf. Build 69 is
rejected. Build 70 narrows recovery to exact button screen geometry and rejects
shelf-owned events before scheduling the fallback.

Build 70 passed both clean full OS gates and all four installed macOS 26
journeys. Its first installed macOS 27 journey completed successfully, but the
target menu action was then misclassified through the hosted button's broad
scene geometry and armed the same recovery fallback. Build 70 is rejected.
Build 71 requires exact status-item-sized accessibility geometry and a true
menu-bar event before recovery is eligible.

Build 71 passed both exact clean full OS gates, but macOS 27 visual inspection
found that the read-only inventory mixed an AppKit-resolved light control
background with the dark SwiftUI Settings foreground and still consumed
unreliable per-item captures. Build 72 uses one semantic SwiftUI appearance
boundary and deterministic named artwork for macOS 27. Exact signed visual,
installed-journey, and both-OS release qualification remain required.

The signed build-72 macOS 27 visual gate passed, but its first installed native
journey exposed a second use of the unsupported capture path in the shelf. The
shelf window initially measured 216 points wide while its resolved target had
already moved beyond that frame during asynchronous fallback publication.
Build 73 disables Golden Gate item capture at the cache boundary, supplies
fixed-width semantic shelf artwork without Screen Recording, and makes the
journey wait for stable in-window geometry. Build 72 is rejected.

The exact signed build-73 shelf rendered stable artwork on macOS 27, but its
native journey exposed a persistent Numeric Pad modifier flag (`0x200000`) on
that host. The generic input-idle guard treated the device flag as a held key,
timed out after ten seconds, and rejected every item activation. Build 74 limits
that guard to modifiers that can actually change pointer routing. Build 73 is
rejected; both exact OS lanes and installed journeys must be repeated.

Build 74 was rejected before packaging because the clean application compile
found the modifier adapter's missing explicit AppKit import. Build 75 adds that
dependency at the app boundary; all qualification evidence must bind to its new
source SHA and executable.

Build 75 passed the exact clean full gate on macOS 26 and macOS 27, confirming
the pointer-modifier correction across both toolchains. It is rejected before
packaging because installed macOS 27 visual inspection found the inventory
surface resolving light while its semantic labels remained light and became
invisible. Build 76 uses explicit opaque, contrast-safe light and dark palette
pairs at that compatibility boundary. Exact signed visual inspection and the
complete installed journey matrix remain required on both operating systems.
