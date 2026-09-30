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

## Failed, partial, and blocked checks

**XCUITest executed zero UI cases.** Both the direct run and a second run
launched through the unlocked logged-in GUI session failed initialization with
`Timed out while enabling automation mode.` Developer Tools Security was
already enabled. No security database, authorization policy, or test gate was
changed to bypass this failure.

An older system alert said `BarlineFixture cannot be opened because of a
problem.` Its Help/Ignore/Report controls and exact owned fixture headline were
identified before a guarded physical Ignore click dismissed it. The pointer
was restored. This alert does not implicate the current production candidate.
No new production main-process crash was observed in the scoped checks.

The physical assignment test is **partial, not PASS**. The current two-item
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
loopback-only server for a private Sparkle update test. **The actual offer,
download, installation, relaunch, and preservation journey did not run.**
Appcast generation is not updater qualification. The public feed and release
were not changed.

Independent clock/Notification Center visibility is still unqualified. The
earlier clock run failed its third structural cycle; this extended run does
not replace it with a visual or exactly-once PASS. Cold launch, repeated
Settings reopen, complete assignment round-trip/relaunch persistence,
profiles/Focus installed journeys, fresh-user, physical display/Space,
sleep/wake, and full recovery/deferred-input matrices remain open.

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

Next action: authenticate the host UI-automation prompt, then execute only
the blocked/missing candidate-bound lanes. Do not rerun already-completed
stress tests merely to substitute activity for remaining acceptance proof.
