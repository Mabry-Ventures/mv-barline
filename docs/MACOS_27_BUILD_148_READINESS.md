# Build 148 qualification contract

October 1, 2026. **HOLD: not production-qualified or published.**

This private 1.0.66 candidate preserves build 147's verified authority-publication
repair and adds targeted profile-capture UI hardening. Public 1.0.65/build 142
and its update feed remain unchanged. Earlier binary-bound receipts are history,
not qualification of this candidate.

## Observed capture failure and bounded mitigation

Two uninstrumented first-profile captures on build 147 saved the synthetic
profile but left Settings unresponsive with a saturated main thread. Samples
showed AttributeGraph, AppKit text-field property observation and
SafariPlatformSupport focus/visibility work. The same baseline subsequently
passed two first-profile capture/Apply runs. This is an intermittent failure;
neither the focused-field enabled transition nor toolbar observation has been
established as its root cause.

Removing the parent ProfileManager-to-AppState publication relay did not
prevent an installed recurrence. A scoped busy-control diagnostic passed, but
its baseline reversals passed too, so it did not establish causality. Standalone
controls did not reproduce the hang. A debugger trace confirmed that Capture
changes the focused name field's enabled state, but did not reproduce the
original uninstrumented hot stack; debugger-delayed UI timeouts are not product
failure proof.

The candidate keeps the new-layout name field editable while disabling actions
that compete with capture. A synchronous admission owner snapshots the exact
submitted name and rejects duplicate Capture submissions before task scheduling.
Already-open editor and recovery callbacks check admission explicitly, retain
drafts/checkpoints on rejection, and do not infer authority from a UI result.
Editor Reset now returns its actual completion outcome; failed reset retains
the editable draft instead of dismissing on admission.

The candidate also replaces toolbar KVO writes with Apple's native fixed label
style. This is independent observer cleanup, not a claimed capture root cause.
No private framework swizzling or unrelated Space publication change is included.

## Independently verified concurrency defect

Archive export, archive preview and Ice preview previously set and cleared
`isBusy` outside the profile-operation semaphore. A concurrent operation could
therefore lose its busy indication. These three owners now acquire the same
existing serialization lock. Its ordering and callback behavior require source
review and installed regression coverage; this finding is not attributed as
the cause of the sampled capture freeze.

## Qualification requirements

- Clean exact-source fast/nonfocus/full gates and application compilation.
- Production capture-admission helper tests: synchronous state publication,
  duplicate rejection, held operation, draft snapshot, internally handled
  failure and re-admission. These do not qualify SwiftUI rendering or Manager
  persistence by themselves.
- Signed, notarized and stapled ZIP/DMG with nested identity, entitlements and
  Gatekeeper checks. No diagnostic debugger entitlement in release products.
- Private real Sparkle install/relaunch, preserving preferences and saved data.
- Repeated uninstrumented cold first-profile Capture, second Capture, Apply,
  editor variant/save, active-authority relaunch and manual-revoke relaunch.
- Held-operation UI admission, editable name, duplicate/shortcut blocking,
  already-open editor/importer/recovery rejection and draft preservation.
- All installed native-menu and popover journeys, layout edits, helper recovery
  and quiescent twenty-cycle latency receipts on this candidate.
- Real Focus activation/restoration and composed Manager/Intent authority-save
  failure/no-replay proof. Store fault injection is not composed-path proof.
- Independent native clock positive control before candidate clock scoring.
- Actual macOS 26 execution and physical display/notch/reconnect coverage for
  claimed support. Both currently available test Macs run macOS 27.0.1.
- Final independent Astra High and Gemini Flash 3.8 High evidence review.

The sustained soak remains user-deferred. Test setup failures, interrupted
foreground sessions, observer UNKNOWN results and earlier candidate passes do
not close these gates. Retain exact receipts privately under ignored artifacts.
