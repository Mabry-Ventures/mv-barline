# macOS 27 takeover and qualification contract

## Scope and baseline

September 30, 2026. The public latest is 1.0.65, source `887d335`. Claude's
unpublished clock branch ends at `e4ae943`; the prior Codex repair starts at
`47d5f6c`. This work is isolated from Claude's checkout and the public feed.
Candidate 1.0.66/build 144 must qualify its own source and binary. Build 143
remains a preserved comparison, not the current candidate.

Only the Barline Claude transcript was reviewed. No credentials or unrelated
Claude projects were included in external review. The implementation does not
copy Bartender's proprietary code. Its
[published macOS 27 release notes](https://www.macbartender.com/Bartender7/release_notes/)
provide product acceptance targets, not proof of how its internals work or
independent performance measurements.

## Verified causes and changes

1. Native assessment concealment interferes with clock/Notification Center
   interaction. Claude's direct probes and the subsequent community
   [Ice investigation](https://github.com/RabenkoYevhenii/Ice/commit/d1858fb)
   corroborate this platform behavior. Barline's narrow workaround releases
   the assertion, settles, presses only a fresh clock hit, then restores the
   committed configuration. It does not treat every menu-bar click as a clock.
2. A request deadline created at handler delivery can make an old click fresh
   again. Admission now uses the original Quartz timestamp. Pointer-down
   counters detect later input; bracketing event-age reads rejects preempted
   or inconsistent samples. The final action checks expiry and supersession.
3. Cancellation could abandon restoration, and detached retries could outlive
   restart cleanup. Restoration runs independently of caller cancellation,
   with one cooperative foreground attempt and a lifecycle-owned, revocable
   background recovery lease. Invalidation clears desired state and the lease.
4. AX timeouts set on a system-wide element affect the entire process, not
   merely that handle. Apple's `AXUIElement.h` documents this explicitly.
   Clock hit testing and focused-element reading share a barrier-protected
   timeout scope that resets the default; per-element clock setters must
   succeed. The assertion activation deadline starts before native Begin.
5. Both inventory caches used scan-start time for their reuse lifetime. A scan
   slower than 100 ms therefore returned already-expired data and invited
   another crawl. Successful completion now starts the reuse window, without
   changing snapshot capture timestamps or forced refresh behavior.

## Evidence interpretation

Claude's final device transcript records clock toggles, shelf timings, and
notarization of its own candidate. Its final full gate failed three checks;
screen lock was recorded, but that does not prove every failure was environmental.
The earlier Codex shelf smoke passed 20 cycles, but its receipt lacked source
and binary binding. Neither packet certifies this candidate.

Pure transaction/input/cache tests and an unsigned Xcode 27 build are useful
iteration proof. They do not establish private assertion behavior, production
TCC identity, installed update behavior, or macOS 26 compatibility.

Gemini Flash 3.8 High and GPT-6 Astra High review the scoped source. Independent
verification rejected several Gemini claims: restoration does not crawl AX
inventory, activation already sleeps, the system-wide timeout API is supported,
and each bridge Begin creates a fresh native assertion. Review signoff cannot
replace runtime proof.

## Required installed journeys

- Source SHA, executable hash, version/build, OS build, host, and exact PID
  recorded for each run; reject dirty or changed candidates for release proof.
- Cold accessory launch: first icon click responds and the shelf registers in
  Accessibility without opening Settings first.
- During real concealment: clock opens and closes Notification Center exactly
  once per click; hiding returns afterward. Repeat with stale/rapid competing
  input, helper interruption, cancellation, and restored empty configuration.
- Control Center, normal application menus, unrelated/empty menu-bar clicks,
  Caps Lock, Globe+N, volume/brightness, and capture/privacy indicators do not
  regress. Never use unrelated user apps to create test side effects.
- Shelf/native menus and popovers remain clickable; one activation, no duplicate
  shelf/native icon, eventual reconcealment, relaunch persistence, dynamic labels.
- Measure first feedback separately from fully loaded shelf, cold/warm inventory,
  idle CPU/memory, stalled owners, notch overflow, and physical display/Space/
  sleep transitions. Vendor claims are not measured Barline performance.
- Developer ID export, nested signatures/profiles, notarization/stapling,
  Gatekeeper, installed upgrade, and actual Sparkle update are separate gates.
- Both actual OS lanes are required for cross-version release claims. Compiling
  with Xcode 26 on macOS 27 is not a macOS 26 runtime test.

`script/test-golden-gate-clock.swift` is a synthetic HID-path, candidate/hash-bound
clock probe for an authorized GUI harness. A listen-only Quartz tap correlates
marked input; explicit synthetic uptime timestamps do not validate physical
hardware timestamp provenance. It emits structural Notification Center counts,
event timings, and controlled-fixture hit witnesses, not notification contents.
Concealment runs require a same-fixture positive visible calibration first.
Hit exclusion is not independent pixel proof. Test source/binary identity is
recorded separately from the frozen app candidate.

## September 30 initial device findings (historical build 143)

The app code remained frozen at `74b38e1` throughout these comparisons. Its
Developer ID export is 1.0.66/build 143; main executable SHA-256 is
`6517559b983b794e5ace8723fa1515227b441b96fe209d24afa0798c10aa4e42`.
The harness-only follow-up changes do not retroactively rebind that binary to
a newer app source SHA. Raw receipts and failed attempts are retained locally
under `.artifacts/takeover-runtime-evidence`.

- Clean fast gate: 681 Core tests across 70 suites, no failed steps. Xcode 27
  Debug build, Developer ID archive/export, and deep strict signature passed.
- Empty concealment: three structural clock cycles completed. AX counts alone
  do not establish independent visual open/closed state or exactly-once behavior.
- Controlled concealment: a single live Native fixture was positively hit-owned
  in five visible calibration samples, then excluded before each test. Three
  structural clock cycles returned Notification Center's structural window
  count from 0 to 8 to 0. After observed closure, stable fixture hit exclusion
  returned in approximately 498–507 ms.
- Longer hold: three additional cycles held Notification Center open for five
  seconds, then dismissed it with Escape, without a second clock transaction.
  The fixture was hit-owned at the early approximately 400 ms observation, but
  excluded at every subsequent sampled observation from approximately one
  through five seconds. Exclusion persisted after dismissal. This refutes an
  indefinite open-Notification-Center override; it is consistent with delayed
  native state settling, not proof of its precise mechanism or a universal bound.
- Empty-configuration shelf: 20 opens passed with 0 timeouts, median 91 ms,
  p95 145.1 ms, maximum 154.7 ms; rapid retry passed. The process was already
  running, so the script's first-cycle `cold=true` label is not cold-launch proof.
- **The original alternate-path concealed-shelf attempt was not qualified.** Under the unnotarized
  candidate's controlled fixture assertion, Barline's own control rectangle
  resolved to AX menu-bar background, not the candidate. With no concealment,
  the same rectangle resolved to its AX menu-bar item. Timing tests could not
  reach the control, and their failures are retained rather than counted as
  shelf latency samples.
- The installed notarized 1.0.65/build 142 passed Gatekeeper/staple checks and
  retained its reachable control under the same fixture-only concealment.
  This changes both source and trust state; it does **not** prove notarization
  alone explains the difference. The independent
  [Ice PR 1001](https://github.com/jordanbaird/Ice/pull/1001) reports a similar
  own-control removal under Apple Development/unnotarized Developer ID builds,
  with notarization explicitly untested. The decisive next comparison is the
  **same 1.0.66 executable after notarization**, using the same fixture witnesses.
  That comparison and the subsequent installation crossover are completed below.

These initial results were a release HOLD, not evidence for another timer change.

## Same-binary trust and installation crossover

The renewed local `barline-notary` profile worked. Apple accepted the frozen
build 143 export (submission `4ff9658f-88de-41bd-8cb5-8da64409452a`), and
stapling, nested strict signatures, and Gatekeeper passed. Main/helper hashes
were unchanged by notarization. Trust alone did not repair its alternate-path
control hit.

The decisive crossover used the already notarized public 1.0.65 binary: its
control was reachable at `/Applications/Barline.app`, unreachable after an
identical bundle copy to the alternate candidate location, and reachable again
at the canonical location under the same fixture-only preferences. Frozen
build 143 then passed at the canonical location, including 20 concealed-shelf
opens (zero timeouts, p95 130.5 ms). This establishes an installation-context
confound, not a confirmed private LaunchServices/Assessment identity mechanism.
Removing the explicit application bootstrap in a separately signed/notarized
comparison did not resolve the alternate-path failure; that source change was
discarded. No guessed hit rectangle or extra concealment retry was added.

## Native-menu closing click repair: build 144

On build 143, the stricter native journey completed one fixture activation,
open, action and close, restored concealment, and cleared its journal, but the
shelf sometimes reopened. Privacy-safe app logs identified the reopening route:
`Empty-space click toggling section` immediately preceded a new shelf show.
`ShowOnClick` was enabled and `ShowOnHover` disabled. The asynchronous gap
lookup had reinterpreted a native-menu closing click after its target vanished.

Build 144 rejects that input before lookup while activation, restoration, or
either OS's tracked item observation owns it. Before committing a gap click it
also checks the original event's age, positive unchanged hit window, input
sequence, presentation lease, monitoring and feature state, and current item
interaction. A window sampled in the monitor is not claimed to be original
hardware-target proof. Pure tests exercise each rejection separately; the final
check and plain-click toggle have no intervening suspension.

Frozen app source: `abf310725d88025321a7b65482f2c63469d8c9be`.
Version/build: **1.0.66/144**. Executable hashes:

- Main: `90e871f5515ce35051c6910a91d06016635057bfaf84565fb79245954e0551e3`
- Helper: `7ab3837e6afc24bd0e27f6bf61f6875cb9ac2bb357baa6448eaf6dad30499903`

On CPLCODEX01, macOS 27.0.1 (26A434), canonical installed candidate:

- Clean fast gate: **688 Core tests / 70 suites**, no failed steps.
- A separate clean-source broader gate passed Debug/Release builds, static
  analysis, build-for-testing, **six Xcode unit/integration tests**, **212 fixture
  checks**, and the recovery, notch, Accessibility, support privacy and
  architecture checks. Core line coverage was **96.93%**. The raw summary's
  Xcode count is one because it only counts the XCTest aggregate; the retained
  log also records five passing Swift Testing cases.
- The broader gate's sole failure was **XCUITest initialization**: the runner
  timed out enabling automation mode before **any UI tests executed**. Its
  overall verdict remains FAIL. Developer Tools Security is enabled, but that
  does not establish UI automation authorization. No authorization database
  change, repeated blind retry or gate waiver was used.
- Release archive/export, Apple notarization (submission
  `db7e2805-5665-4147-99fa-3a4001c2cbef`), staple and strict signature/Gatekeeper
  checks passed locally and on the test host.
- **24 native menu/popover journeys passed**, left/right three repetitions for
  each interface type, repeated after helper interruption. Each required one
  activation/open/action/close, accessible real interface action, restored
  concealment/journal, and stable closed shelf. No AXPress or production
  notification bridge was used.
- **20 concealed-shelf opens:** zero timeouts, median 92.7 ms, p95 144.9 ms,
  maximum 146.5 ms. These measure first committed shelf feedback, not fully
  loaded inventory or a cold application launch.
- Guarded termination of the owned helper caused a new helper PID; three
  subsequent shelf opens passed, followed by the 12 repeated interaction lanes
  included in the total above. This is one interruption experiment, not the
  entire recovery matrix.
- A separately hashed, post-freeze, fail-closed harness verified menu-bar
  background before HID input: three genuine gap open/close cycles passed and
  remained closed. It restored the original pointer. The earlier observer
  version is retained separately, not substituted for this stronger receipt.
- Six stationary samples over approximately 25 seconds showed unchanged
  process CPU times at 0.01-second reporting resolution and stable resident
  sizes (main approximately 132.9 MiB, helper 31.7 MiB). This is a short idle
  observation, not an energy, leak or long-soak qualification.
- A same-fixture five-sample visible calibration passed before concealed clock
  diagnostics. Two structural cycles returned baseline 8 → 10 → 8 with stable
  reconcealment; the third failed `notification_center_tree_incomplete`.
  That run is **FAIL**, not three passing cycles. The subsequent five-sample
  hidden witness passed. Neither these counts nor the older zero-count baseline
  prove independent Notification Center visibility or exactly-once operation.

Raw receipts, harness hashes and preserved failures are under ignored
`.artifacts/native-gap144` and `.artifacts/notarized-comparison`. Post-freeze
test/documentation commits do not rebind the app binary to another source SHA.

After both installed testing and the broader gate, the original 1.0.65 app was
restored at the canonical installation path and passed strict signature and
Gatekeeper checks. All 63 original preference keys matched semantically and
the support-directory comparison had zero differences. The app was not
running at the start and was not relaunched. Owned candidate, fixture and
keep-awake processes were stopped; comparison bundles remain recoverable in
the private evidence directory. The pre-existing Intents process was not
touched. No Screen Sharing window was closed and no Mac was restarted.

GPT-6 Astra High agrees the plain-click regression is causally validated on the
tested canonical macOS 27 installation, with overall release HOLD. Gemini Flash
3.8 High's updated review conditionally agrees. Lead verification rejected its
initial treatment of pre-fix evidence as a post-fix failure and its later claim
that this `Task` is unisolated: `HIDEventManager` is `@MainActor`, the task
inherits that actor, and complete strict concurrency/warnings-as-errors builds
pass. Reviews supplement runtime receipts; they do not certify OS parity.

## Open boundaries

The later [extended build-144 installed test result](MACOS_27_BUILD_144_FULL_TEST_RESULT.md)
adds 300-open stress, 30-minute resource, and helper-recovery evidence, while
keeping full acceptance and publication on HOLD. It also records the physical
layout test's partial result, the authentication obstruction, and verified
restoration of the test host. It does not supersede failed or unexecuted lanes
with a release pass.

- The local notarization credential boundary is resolved. Remote credential
  access is unnecessary; no vault, unrelated TCC reset or Keychain reset was used.
- Alternate-installation control behavior remains unqualified. Do not describe
  canonical-path proof as qualification of all installation contexts.
- No macOS 26 runtime is currently available.
- XCUITest requires host UI automation authorization before the focused gate
  can run; zero executed UI tests cannot qualify installed acceptance.
- Deferred hover work, delayed secondary context menus, and activation-failure
  shelf fallback still need explicit ownership review and installed tests.
- Independent clock/Notification Center visibility, full UI acceptance, actual
  Sparkle update, fresh-user and lifecycle/display coverage remain release gates.
- Aggregate AX inventory deadlines, transient-owner retention/backoff, and
  redundant metadata reads remain performance workstreams. This cache fix must
  not be sold as bounding the complete scan.
- Native synchronous Begin/Commit and AX queue acquisition cannot be interrupted
  by the cooperative timing policy. Measure watchdog/disconnect behavior; do
  not claim a hard end-to-end 250 ms restore bound.
- Multi-display, sleep/wake, native overflow, and capture side effects require
  explicit device evidence. Do not publish while the required matrix is open.
