# Build 144 extended installed test result

September 30, 2026. **Overall: HOLD, not a full production pass.**

## Candidate and device

Only CPLCODEX01 was exercised, running macOS 27.0.1 (26A434). The installed
candidate was the frozen, notarized **1.0.66/build 144**, at
`/Applications/Barline.app`, not a rebuilt or re-signed application.

- App source: `abf310725d88025321a7b65482f2c63469d8c9be`.
- Main SHA-256: `90e871f5515ce35051c6910a91d06016635057bfaf84565fb79245954e0551e3`.
- Helper SHA-256: `7ab3837e6afc24bd0e27f6bf61f6875cb9ac2bb357baa6448eaf6dad30499903`.
- Stapled ZIP SHA-256: `795c878c509defdc8d96fe44ee80e5ea40c190ebbb5910aac66e7e1b0386a80c`.
- Apple accepted submission: `db7e2805-5665-4147-99fa-3a4001c2cbef`.

The canonical Claude checkout remained clean at `e4ae943`. The isolated
post-freeze test/documentation checkout started at `39dc91b`. Its fresh fast
gate passed **688 Core tests across 70 suites**, with all fast-gate steps
passing. These later test/documentation commits do not rebind the app binary
to a new source SHA. The broader builds and unit/integration results described
in [the takeover record](MACOS27_TAKEOVER.md) are prior evidence, not fresh
executions in this extended installed run.

## Newly completed checks

- Four HID-path fixture journeys passed: native menu left/right, popover left,
  and popover reuse. Each validated a real accessible synthetic interface
  action, one activation/open/action/close, eventual restoration, a cleared
  temporary-reveal journal, a stable closed shelf, and restored pointer.
- The candidate passed 20 concealed shelf opens before helper interruption
  (p95 155.6 ms, maximum 179.3 ms) and 20 afterward (p95 159.4 ms, maximum
  168.7 ms), with zero timeouts in each run. Guarded termination of the owned
  helper produced a new helper PID without replacing the main process; the
  recovery receipt also validated interaction and pointer restoration.
- A separate **300-open shelf stress test passed**, with zero timeouts,
  p95 **140.6 ms**, maximum **169.6 ms**, and retry feedback within budget.
  These are first committed shelf-feedback timings on an already running
  candidate. They are not cold application launch or fully loaded inventory
  timings.
- A **30-minute bounded resource smoke passed**, with 356 samples over
  1800.07 seconds and a maximum sampling gap of 5.09 seconds. Main RSS changed
  from 132.08 to 152.80 MiB, peaking at 155.31 MiB; helper RSS changed from
  29.03 to 28.92 MiB. The final twelve sampled CPU readings averaged 0.0% for
  both processes. The run included controlled test activity. It is not a
  flat-memory, leak-free, energy, or complete release-soak certification.
- A separate post-resource witness verified the actual main/helper hashes,
  strict nested signature, Gatekeeper assessment, staple, and process birth
  times. The sampler's embedded hash strings alone are not integrity proof.
- One physical Command-W Settings close passed. This is not full Settings
  acceptance or a repeated reopen/persistence result.

Seven installed target/performance/recovery receipts were revalidated against
the frozen app source and main executable hash. GPT-6 Astra High independently
revalidated their status and recomputed the stress/resource statistics, with
overall HOLD. Review does not replace the remaining device gates.

## Authenticated continuation on the same candidate

After the user authenticated UI Automation, the focused XCUITest gate completed
on the same device: **one passing fixture test, two explicit macOS 27 skips,
zero failures**. The skipped native-menu and popover cases are not counted as
passes. These tests build an instrumented fixture; they do not qualify every
screen of the installed production app.

The physical Settings test subsequently passed both Visible and Hidden
assignments, separate no-preference-write app relaunches in each state, and
**three consecutive complete Visible/Hidden round trips**. Both current
synthetic items were positively hit-owned when Visible and not hit-owned when
Hidden. The post-relaunch observations ran before opening Settings and required
both complete saved IDs to match the candidate-produced retained inventory.
Process changes were checked outside the UI harness against the same frozen
main executable. This qualifies the controlled two-item application-level
assignment/persistence path, not arbitrary item ordering or pixel concealment.

An initial controlled baseline incorrectly copied `occurrence-0` for both
items, while the current Native fixture ID used `occurrence-1`. The unmatched
assignment led to the documented fail-visible bundle policy. Rebuilding only
the test baseline from the two complete current IDs removed that mismatch;
the baseline was not reapplied between persistence legs. An immediate startup
check also ran before concealment was ready. Later observations used bounded
readiness waits. These failures remain calibration receipts, not proven
native-concealment defects. A subsequent process-identity guard stopped one
attempt; external checks found the expected process still alive with unchanged
birth time and no new main crash report. The specific guard cause was not
established. A settled repeated-cycle run passed without changing the app.

The **actual private Sparkle upgrade passed** from original 1.0.65/build 142
to the frozen 1.0.66/build 144. Physical Settings controls requested the offer,
download, installation, and relaunch. A new main PID was observed, the old PID
was gone, and the installed version, actual main/helper hashes, nested strict
signature, Gatekeeper assessment, and staple matched the frozen candidate.
The loopback-only server recorded the appcast and exact ZIP requests. The
public feed and release were unchanged.

All **60 compared pre-existing preference keys matched semantically**, including
the explicit fixture layout. Serialized JSON data was compared after decoding;
a byte-order difference in the appearance JSON was not a setting change.
Retained inventory and five Sparkle operational/override keys were excluded
explicitly from that comparison. The complete support-directory comparison
had zero differences. This is not a separate Focus activation or fresh-user
profile test.

After the upgrade, all four native/popover physical target lanes passed again.
The owned helper interruption produced a replacement helper while preserving
the main PID and a successful recovery interaction. Two fresh performance
runs each contained 20 measured shelf openings with zero timeouts: post-update
baseline p95 **150.2 ms**, maximum **158.2 ms**; post-interruption p95
**144.4 ms**, maximum **147.7 ms**. The seven new target/performance/recovery
receipts passed the canonical installed-evidence validator. Its earlier
five-receipt attempt correctly failed `missing_xpc-interruption`; missing
recovery and post-interruption receipts were executed rather than waived.
These timings concern first committed shelf feedback on a running app, not
cold launch or complete inventory loading.

A separate five-sample first-shelf probe responded to every click before
Settings opened, but the canonical writer rejected its undersized sample
count. It remains informational, not a passed performance gate.

The independent clock experiment remains **UNKNOWN, not PASS and not a proven
app defect**. A temporary, nonactivating test panel established a closed
starting state through three owned AX anchor points and on-screen CG geometry.
One marked clock down was delivered; the helper logged that its lifted clock
press succeeded and concealment was reapplied. The observer did not establish
the required distinct opened sidebar, so no cycle or exactly-once visibility
claim follows. Notification contents and screenshots were not read/exported.
The pointer was restored. In-process anchor-close observation was inconclusive;
owned harness exit and final test-process cleanup were separate witnesses. That
cleanup did not establish Notification Center's final visible state. The v4
observer emitted only its initial closed-state ownership/geometry diagnostics;
its receipt does not establish what geometry or AX owners appeared after the
click.
The private observer and its failed calibration revisions did not modify the
production bundle.

### Native clock positive control and independent review

A subsequent **native-no-Barline positive control also returned UNKNOWN**.
The original build 142 remained installed and untouched; exact-name process
guards required both Barline and `BarlineMenuService` absent throughout the
control. The unchanged opening predicate again qualified the closed starting
state, delivered one marked native clock down, observed zero unrelated inputs,
and completed zero scored cycles.

Unlike v4, the control retained content-free post-click diagnostics. They show
a Notification Center-owned full-display surface (1920 × 1080, layer 21,
alpha 1) above the anchor, with the top anchor AX hit owned by Notification
Center and the other two still owned by the anchor. No separate qualifying
narrow sidebar was reported. Thus this observer cannot qualify the native
path on this host. That reproducible measurement limitation prevents attribution
of the candidate's UNKNOWN result to a Barline timing defect.

The pointer was restored and the owned panel was independently absent before
the control exited. An external scoped window check subsequently found none of
the retained observer window IDs on screen; no Barline/helper/harness process
remained and the original installed executable hash was unchanged. Notification
Center's final closed state remained unqualified. No cleanup toggle was sent
from UNKNOWN, and no notification text or pixels were captured.

**Gemini Flash 3.8 High and GPT-6 Astra High both recommend HOLD** in bounded
read-only evidence/source reviews. Astra independently reran the seven-receipt
validator. Both distinguish press API success from visible presentation and
flag the existing 150 ms settle as a hypothesis to investigate, not an
established root cause. Gemini's inference that v4 observed only a fullscreen
scaffold was rejected: v4 did not retain post-click geometry. The later native
control supplies that limited geometry observation only for the no-Barline
lane. Neither review constitutes a complete production audit or runtime signoff.

Before another candidate clock run, repair and positively calibrate the
observer. A proposed privacy-bounded discriminator uses three small patterned
owned sentinels inside a stable, non-fullscreen NC-owned AX rectangle, plus an
always-visible reference patch. Tiny display-composite samples would be
cropped at capture source, processed locally to match/occlusion booleans, and
never persisted/exported; fresh frames, unchanged NC PID/birth, AX ownership,
and bracketed CG ordering would be required. This pixel observer is **not yet
implemented or qualified**. If suitable geometry, a safe closed baseline, or
capture integrity cannot be established, the outcome remains UNKNOWN. Even a
pass would establish sampled NC-owned occlusion, not continuous/exactly-once
presentation or complete product readiness. No production timing patch follows
from the current results.

This continuation clears the authentication, controlled assignment/persistence,
and actual-updater gaps. **Overall remains HOLD.** Independent clock visibility,
profiles/Focus installed journeys, fresh-user, physical display/Space,
sleep/wake, and the broader recovery/deferred-input matrix remain open. No
macOS 26 runtime was exercised.

## Earlier failed, partial, and blocked attempts

This section records outcomes **at the time of the initial run**, before the
authenticated continuation above. Its assignment/persistence, actual-updater,
and UI-authentication gaps were subsequently cleared within the stated narrow
scope. Historical failures remain retained, not current blockers or new passes.

**The initial XCUITest attempts executed zero UI cases.** Both the direct run and a second run
launched through the unlocked logged-in GUI session failed initialization with
`Timed out while enabling automation mode.` Developer Tools Security was
already enabled. No security database, authorization policy, or test gate was
changed to bypass this failure.

An older system alert said `BarlineFixture cannot be opened because of a
problem.` Its Help/Ignore/Report controls and exact owned fixture headline were
identified before a guarded physical Ignore click dismissed it. The pointer
was restored. This alert does not implicate the current production candidate.
No new production main-process crash was observed in the scoped checks.

At that stage, the physical assignment test was **partial, not PASS**. The two-item
fixture was bound to its receipt, PID, session, bundle, and normalized bundle
path. One transition to Visible committed both assignments and positively
hit-tested both live native items. The next target check failed
`fixture_chip_disabled_or_nonunique`; the cause was not established. A later
return-to-Hidden attempt independently hit an overlying
`com.apple.LocalAuthentication.UIAgent` panel and failed closed before sending
the click. That later obstruction does not prove the cause of the earlier
failure. Authentication was requested from the user; the agent did not
interact with authentication controls.

Test-harness calibration failures, including retained historical fixture rows,
path normalization, obscured targets, and insufficient settling, remain in
the private evidence directory. They are not counted as product passes or
silently relabeled as proven product defects. A negative hit-owner result
alone is not independent pixel proof of concealment.

A correctly signed build-144 appcast and exact ZIP were staged on a temporary
loopback-only server for a private Sparkle update test. **At that stage, the
actual offer, download, installation, relaunch, and preservation journey had
not run.** Appcast generation alone was not updater qualification. The later
authenticated continuation executed that journey. The public feed and release
were not changed.

Independent clock/Notification Center visibility is still unqualified. The
earlier clock run failed its third structural cycle; this extended run does
not replace it with a visual or exactly-once PASS. At the initial checkpoint,
cold launch, repeated Settings reopen, complete assignment round-trip/relaunch
persistence, profiles/Focus installed journeys, fresh-user, physical
display/Space, sleep/wake, and full recovery/deferred-input matrices were open.
The continuation subsequently qualified controlled assignment round trips and
relaunch persistence, not the other listed lanes.

No macOS 26 runtime was exercised. No cross-version release claim follows
from this macOS 27 device run.

## Recovery and evidence

The exact original **1.0.65/build 142** installation was restored, with original
executable SHA-256
`9f7cb676cab94b7f652e9d53f9ac2345ac296591de4081fa927ba03c476a32d5`,
strict signature, and Gatekeeper checks passing. All **63 original preference
keys matched semantically** and the support-directory comparison had zero
differences. The original app was not running at test start and was not
relaunched. The candidate, fixture, helper, test harnesses, owned keep-awake
process, and private update server were stopped. The pre-existing Intents
process was untouched. No Mac was restarted; no Screen Sharing window was
closed; CPLCLAUDE01 and the local installed Barline were not used.

The frozen tested bundle and comparison backups remain recoverable. Raw
receipts, failure logs, and test-only harness revisions are retained under
ignored `.artifacts/full144` locally and the private `barline-full144` directory
on CPLCODEX01. The restoration receipt is `cleanup-verification.log`.

The authenticated continuation was restored and independently checked again:
original build 142/main hash, all 63 original preferences, and the support
directory matched; zero owned test processes remained and the pre-existing
Intents process was untouched. The private server and owned keep-awake process
were stopped. The post-updater build-144 bundle remains recoverable. New
receipts, failed attempts, and test-only harness revisions are under ignored
`.artifacts/resume144`; seven post-update installed receipts were independently
revalidated locally as well as on the device.

Next action: independently qualify clock/Notification Center visibility, then
complete the remaining installed feature/environment matrix and obtain an
actual macOS 26 runtime. Authentication is no longer the blocker. Do not rerun
already-completed stress tests merely to substitute activity for missing proof.
