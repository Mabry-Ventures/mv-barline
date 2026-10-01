# Build 145 qualification contract

September 30, 2026. **HOLD: not production-qualified or published.**

This is the next 1.0.66 candidate after the frozen build 144 investigation.
The isolated worktree owns the source changes. The canonical Claude checkout,
public 1.0.65/build 142, website download and update feed are untouched.

## Verified repair scope

- Request leases include queue wait, expire against monotonic deadlines, bind
  one admission epoch and generation, and reject obsolete callbacks and replay.
- Every fresh physical XPC session completes startup and accepted configuration
  replay before readiness. A rejected durable proposal loses recovery authority
  before native compensation. This does not promise zero transient exposure
  from a recovery already ahead of compensation on the request queue.
- A cold initializing read is retired on timeout. A ready read may complete
  during six seconds of grace before its own unfinished generation is retired.
  Eight outstanding workers is a per-Session limit across physical generations;
  production's shared Connection owns one Session. Cancellation is not assumed
  to release an OS transport worker immediately.
- Native concealment deduplication includes the exact running-app allowance
  captured for the bridge, and publishes only after native commit succeeds.
- Snapshots require a valid Space, explicit menu-tracking observation and
  unchanged display identities and geometry. Ambiguous/off-screen ownership
  remains unresolved; control boundaries are resolved per display.
- Reconnect observation uses a finite coalesced retry lifecycle. Published or
  pending authority superseded by manual intent is revoked permanently. Startup
  catalog loading does not revoke an unpublished persisted token. Cancellation
  and live-ticket checks surround asynchronous observation and publication.
- Incidental Caps Lock flags no longer defeat empty-space click shortcuts;
  Command, Shift and conflicting control modifiers remain rejected.

## Deterministic evidence, not installed proof

The lead executed 12 actual production Session orchestration scenarios against
an isolated test transport and actual production concealment-controller tests
against a workspace/bridge double. These include grace completion, stalled
ready reads, stale cleanup, worker saturation, cold handshake timeout,
replacement ownership, restart/replay rejection, explicit cancellation races
and failed persistence compensation. The repeatable gate is
`bash script/test-service-recovery.sh`; it starts no app, real XPC or assertion.

Core policy tests cover modifier combinations, changing running-app allowances,
per-display classification, geometry changes, reconnect retry/coalescing,
one-shot claims and authority revocation/startup preservation. Policy tests do
not establish actual ProfileManager startup or a real display reconnect.

The lead's local pre-freeze Debug build and strict lint passed. Final clean
source gate, Release build, analysis, archive and installed evidence must be
captured after the source freeze. Exact SHA, executable hashes, signing and
notarization receipts belong in ignored candidate-bound release metadata.

## Independent review

GPT-6 Astra High independently reviewed recovery and reconnect ownership and
confirmed the source closures. Gemini Flash 3.8 High identified the rejected
layout replay and lingering ready-read worker gaps; both are repaired and
covered by deterministic tests. Its alleged missing wire response and missing
AX messaging timeout were disproved by reading the actual nested wire contract
and AXHelpers' 250 ms application/descendant limits. The final bounded review
of complete Session files returned source-review PASS and distribution HOLD.
Its optional proposal to start recovery leases only after queue admission was
not adopted: including queue delay is part of the bounded request contract.
No reviewer opinion is device evidence or a proof of freedom from all races.

## Remaining mandatory qualification

1. Freeze a clean source candidate and rerun all affected source/build gates.
2. Produce exact Developer ID, notarized, stapled application, ZIP and DMG;
   assess nested signatures, App Group topology and Gatekeeper without re-signing.
3. On CPLCODEX01 only: full source/UI gate and the exact installed native/menu,
   popover, visible/hidden persistence, helper interruption, cold launch, shelf
   latency/stress, Focus and lifecycle journeys. Keep private original settings
   and support data recoverable. Never touch CPLCLAUDE01 or close Screen Sharing.
4. Calibrate independent clock visibility with Barline absent before using the
   identical frozen observer on the candidate. An unqualified native positive
   control is UNKNOWN, not evidence of an app failure or a candidate pass.
5. Test a real private Sparkle update from public 1.0.65 and compare preserved
   preferences/support state. Manual replacement is not updater proof.
6. Run the actual macOS 26 runtime lane. The lead Mac and CPLCODEX01 currently
   run macOS 27.0.1/26A434; deployment target 26 is not runtime qualification.
7. Complete independent candidate-bound review and founder release approval.

No publication is authorized by a green compile, mocks or historical build 144
results. Preserve failed calibration receipts and report gaps explicitly.
