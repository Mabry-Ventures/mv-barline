# Reliability-first delivery contract

Approved direction: September 7, 2026. This document supersedes older roadmap
language about macOS 27 feature adoption or deferring its compatibility work.
It does not supersede the source-bound qualification record of any candidate.

The latest implementation and remaining feature gates are tracked in
[FEATURE_QUALIFICATION.md](FEATURE_QUALIFICATION.md). Version 1.0.14 includes
the authoring/rule/shortcut paths. Consult the qualification record for the
installed candidate and exact source-bound results. Installed qualification remains
separate from implementation. The user has conditionally
authorized release once all required qualification passes.

## Product promise

Your menu bar, organized. Your Mac, uninterrupted.

"Bulletproof" is our engineering standard, not a claim that unsupported macOS
interfaces can never fail. A failed or unsupported operation must leave the Mac
usable, preserve the last successful state, explain the limitation, and offer
recovery. No account, paid tier, telemetry, background network dependency, or
new macOS-exclusive feature is needed to organize a menu bar.

## Delivery sequence

1. **Protect the core.** Every change retains single-instance startup, one-click
   activation, native-menu/popover/right-click handling, generation ownership,
   cancellation-safe compensation, durable restoration, contextual permissions,
   and deterministic fallback. No feature gets a second event synthesis path.
2. **Guided native Focus and display layouts.** Use Apple's Focus Filter, not a
   parallel Focus system. Make capture, assignment, activation, deactivation,
   manual override, and disconnected-display behavior understandable. Only
   expose operations the application actually supports.
3. **Explainable rules.** A small local deterministic evaluator proposes saved
   layouts from foreground application or power context. Focus takes precedence;
   manual override pauses automation. Stable context, fresh generation, valid
   target, and no interaction/mutation/recovery are mandatory. Unknown context
   does not mean false; it cannot authorize an action. No scripts, location,
   image recognition, inference, or arbitrary trigger language. Live automatic
   application stays disconnected until its full transaction journey passes.
4. **Useful groups.** A group collapses shelf members behind an accessible
   disclosure. It does not create a second status-item owner or move real items.
   Expansion is presentation-local. Ambiguous membership cannot hide an item.
5. **Keyboard quality.** Search favorites and aliases are local, bounded, and
   stable-ID based. Native activation remains authoritative. Per-item shortcuts
   need conflict detection and exactly-once dispatch before becoming available.
6. **Quiet support.** Static Cloudflare Pages site; voluntary one-time hosted
   Stripe contributions; a single About link once the canonical destination is
   live. No nags, badges, timed prompts, donation tracking, or unlocked features.

Each step is independently reviewable. Implementation, automated proof, signed
installed proof, and public availability are separate states. Do not label
unwired domain models or untested UI as completed product features.

## Required release acceptance

| Area | Acceptance | Evidence |
| --- | --- | --- |
| Build | Strict formatting/lint; Swift 6; Debug/Release/analyze; Core/integration/fixture tests | `ci.sh fast`, then `ci.sh full` on frozen candidate |
| Startup/update | One instance; first click works without opening Settings; preferences retained | Installed signed upgrade plus first-click journey |
| Activation | One native left/right or popover action; no duplicate shelf item; original section/display restored | Four installed target receipts; failed attempts retained |
| Speed | Shelf visible p95 <250 ms in at least 20 bounded samples, zero failures; measure search latency separately | Candidate-bound raw samples and percentile summary |
| Recovery | One bounded helper interruption; preserve app PID; successful subsequent action; journal recovery without silent loss | Installed receipt and explicit restart-recovery lane |
| Permissions | No first-launch prompt merely to open Settings; revoke/regrant invalidates in-flight capture; fallback still useful | Adapter regressions and separate actual TCC lane |
| Focus/display | Activate/deactivate configured native Focus; manual override; reconnect; absent/ambiguous display | System Focus and physical-display evidence, not simulated catalog data |
| Rules | Explain winner; deterministic conflicts; stale/unknown inputs defer; no mutation during native interaction; rollback verified | Pure tests plus real app transaction lane before wiring |
| Groups/search | No lost/duplicate targets; collapsed traversal; Return/Space/Escape/context action; aliases persist | Pure tests, semantic AX and physical keyboard journey |
| Accessibility | VoiceOver naming/order, Full Keyboard Access, reduced motion, contrast | Manual candidate-bound record plus automated checks |
| Distribution | Exact source, SBOM, GPL notices, signature, notarization, staple, Gatekeeper, signed update, rollback | Frozen source and executable hashes |

Tests must not repeatedly steal focus, launch duplicate apps, or run unattended
crash/restart loops. Physical scenarios require a bounded session and restoration
of user settings. A test bypass is not a passing gate. Do not expand thresholds
to accommodate a regression.

## macOS 27 compatibility, not feature adoption

Barline 1.0.14 was qualified on separate Apple Silicon macOS 26.6.2 and macOS
27 RC 26A428 hosts. The same signed executable passed the native left/right,
popover reuse, performance, and forced-helper-recovery receipt set on both.
Compilation on an older host is still not accepted as runtime evidence.

macOS 27-specific features wait for a later release. Compatibility changes use
the smallest OS-specific path and must preserve the established macOS 26 path.
Future macOS 27 updates still require candidate-bound runtime regression across
native menu hosting, permissions, displays, Spaces, Focus, update, recovery,
and accessibility. Local-only execution remains mandatory; Barline uses no
macOS or self-hosted GitHub Actions runners.

## Website and payment boundaries

- Canonical domain: `usebarline.com`. The user confirmed registration through
  Cloudflare on September 7, 2026. DNS/Pages/TLS still need deployment validation.
- Build static semantic HTML/CSS with no runtime JavaScript dependency for
  navigation, download information, support, or privacy content.
- Use an external Stripe-hosted one-time contribution flow; no card fields,
  secret keys, webhook server, licensing state, or payment-success inference.
- A missing release or checkout URL renders honest availability text, not an
  inert download button or a fake success screen. Production build fails when
  required approved destinations are missing.
- Reconnect and select the correct Stripe account before any account-specific
  setup. Test mode and live mode remain explicitly separated.
- Confirm Cloudflare account/project and domain ownership before deployment.
- The public GitHub release, signed update feed, and canonical download must
  remain bound to the same qualified version and checksums.

## Historical initial checkpoint

The installed 1.0.9 build 18 remains untouched while these changes are built.
Its qualification packet is under the ignored source-bound release directory
for `184edc7cb01944153e7f93c8946b75372b44a3f6`. That evidence does not qualify
new source. Feature, website, and macOS 27 acceptance must be recorded afresh.

## Historical September 7 initial implementation evidence

Branch: `codex/reliability-first`, uncommitted iteration atop
`184edc7cb01944153e7f93c8946b75372b44a3f6`. This is not a release candidate.

- Fast gate passed: 296 Core tests in 28 suites, strict formatting/lint, geometry
  and event ordering, new real persistence failure probe, platform classification,
  evidence validators, repository hygiene, project resolution and plist checks.
  Receipt: `.artifacts/ci/184edc7cb01944153e7f93c8946b75372b44a3f6/fast-2026-09-07T20-25-01Z/summary.json`.
- Unsigned Debug/Release compilation and final Debug static analysis passed.
  Final Release and analysis logs: `.artifacts/workstreams/reliability-release-final.log`
  and `.artifacts/workstreams/reliability-analyze-final.log`. These are not
  notarization, installed behavior, or performance proof.
- Six website tests passed. Authorized Cloudflare Preview deployment and browser
  checks are documented in `site/QA.md`; production and checkout remain inactive.
- Installed executable remains SHA-256
  `6e1cabff0f756cee080e82b49fc727429c68d599296f6e6e7b0c2ff35112f91a`.
  No native app launch, update, permission reset or focus-stealing test was run.

Remaining at that checkpoint (subsequently implemented; see current qualification):
safe contextual admission coordinated with Focus,
manual override, recovery and presentation leases; persisted rule UI and signal
adapters; per-item global shortcut conflict/dispatch handling. Display variants
currently expose existing imported state read-only, not a new capture/authoring
workflow. New groups, search personalization and guidance need signed installed
keyboard/AX/Focus/display qualification. A frozen source candidate then needs
the full gate and new distribution receipts. macOS 27 still needs its own host.
