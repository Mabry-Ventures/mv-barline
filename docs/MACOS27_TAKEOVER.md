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

`script/test-golden-gate-clock.swift` is a real-pointer, candidate/hash-bound
clock probe for an authorized GUI harness. It emits structural Notification
Center counts and event timings, not notification contents. A passing probe
does not by itself establish that native concealment returned; verify that
separately against a controlled fixture.

## Open boundaries

- Stored local notarization profile exists but Apple returned HTTP 401. The
  remote profile cannot currently be read because its default Keychain is
  locked. Do not reset other credentials or access a password vault.
- No macOS 26 runtime is currently available.
- Aggregate AX inventory deadlines, transient-owner retention/backoff, and
  redundant metadata reads remain performance workstreams. This cache fix must
  not be sold as bounding the complete scan.
- Native synchronous Begin/Commit and AX queue acquisition cannot be interrupted
  by the cooperative timing policy. Measure watchdog/disconnect behavior; do
  not claim a hard end-to-end 250 ms restore bound.
- Multi-display, sleep/wake, native overflow, and capture side effects require
  explicit device evidence. Do not publish while the required matrix is open.
