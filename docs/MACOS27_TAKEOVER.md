# macOS 27 takeover and qualification contract

## Scope and baseline

September 30, 2026. The public latest is 1.0.65, source `887d335`. Claude's
unpublished clock branch ends at `e4ae943`; the prior Codex repair starts at
`47d5f6c`. This work is isolated from Claude's checkout and the public feed.
Candidate 1.0.66/build 143 must qualify its own source and binary.

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

## September 30 device findings

The app code remained frozen at `74b38e1` throughout these comparisons. Its
Developer ID export is 1.0.66/build 143; main executable SHA-256 is
`6517559b983b794e5ace8723fa1515227b441b96fe209d24afa0798c10aa4e42`.
The harness-only follow-up changes do not retroactively rebind that binary to
a newer app source SHA. Raw receipts and failed attempts are retained locally
under `.artifacts/takeover-runtime-evidence`.

- Clean fast gate: 681 Core tests across 70 suites, no failed steps. Xcode 27
  Debug build, Developer ID archive/export, and deep strict signature passed.
- Empty concealment: three clock open/close cycles passed. This is not proof of
  restoring hidden items.
- Controlled concealment: a single live Native fixture was positively hit-owned
  in five visible calibration samples, then excluded before each test. Three
  clock open/close cycles returned Notification Center's structural window
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
- **Concealed-configuration shelf is not qualified.** Under the unnotarized
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

Gemini Flash 3.8 High and GPT-6 Astra High retain a release HOLD. They do not
identify another confirmed clock source defect, and the calibrated runtime
findings do not justify more timer changes. The inaccessible-control comparison
and production trust boundary must be resolved before concealed-shelf signoff.

## Open boundaries

- Stored local notarization profile exists but Apple returned HTTP 401. The
  remote profile cannot currently be read because its default Keychain is
  locked. Do not reset other credentials or access a password vault.
- Do not work around candidate control removal with speculative hit rectangles,
  repeated reassertion, or source timing changes before the same-binary trust
  comparison. A successful source gate cannot override this device failure.
- No macOS 26 runtime is currently available.
- Aggregate AX inventory deadlines, transient-owner retention/backoff, and
  redundant metadata reads remain performance workstreams. This cache fix must
  not be sold as bounding the complete scan.
- Native synchronous Begin/Commit and AX queue acquisition cannot be interrupted
  by the cooperative timing policy. Measure watchdog/disconnect behavior; do
  not claim a hard end-to-end 250 ms restore bound.
- Multi-display, sleep/wake, native overflow, and capture side effects require
  explicit device evidence. Do not publish while the required matrix is open.
