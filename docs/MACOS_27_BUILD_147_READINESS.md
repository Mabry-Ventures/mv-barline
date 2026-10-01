# Build 147 qualification contract

October 1, 2026. **HOLD: not production-qualified or published.**

This 1.0.66 candidate includes build 146's unique live-identity migration and
adds verified profile authority publication. Public 1.0.65/build 142 is unchanged.
All earlier binary-bound results are diagnostic history, not build 147 proof.

## Verified failure path and repair

The old manager swallowed authority encoding/size/readback failures after
applying a layout, then published Active and success. Build 147 awaits envelope
and token verification before success. Rejected writes withdraw coordinator,
manager and token authority while retaining the actual workspace presentation
and recovery envelope. Focus recovery reports the typed error to Intent delivery
so an already applied layout is not automatically replayed. Prior authority is
restored only after verified physical rollback and a verified storage commit.

The generic store compensates its own failed write first. Manager withdrawal is
a separate post-layout step: restored storage is recovery evidence, not proof
that the old physical layout is active. Startup independently requires matching
tokens and live workspace verification. The token is written before the envelope
so an interruption at that boundary retains a pending Focus checkpoint.
Two UserDefaults keys are not an atomic disk transaction. Unverified rollback is
reported explicitly; there is no guarantee a failing storage backend retained
every prior byte. Tests freeze an in-process write boundary, not a real crash.

## Required candidate-bound gates

- Clean fast/nonfocus/full source gates and strict application compilation.
- Developer ID nested signing, notarized ZIP/DMG, staple and Gatekeeper.
- Private updater install/relaunch and semantic user-data preservation.
- Installed layout edits, native left/right and popover activation/restoration.
- Helper interruption/recovery, bounded burst latency and startup responsiveness.
- Profile first capture, Apply, relaunch authority, manual revoke and relaunch.
- Focus activation/restoration and authority-failure no-replay coverage.
- Independent native clock A/B/A proof before scoring candidate clock behavior.
- Actual macOS 26 runtime and physical display/notch/reconnect lanes where claimed.
- Independent Astra High and Gemini Flash 3.8 High source/evidence review.

Current storage-unit tests do not substitute for Manager/Intent integration.
The clock observer currently cannot prove native NC occlusion with Barline absent;
that is UNKNOWN, not a product failure or a successful candidate clock test.
Both currently available Macs run macOS 27.0.1; a macOS 26 device is still needed.
Private receipts stay in ignored artifact paths. Do not publish on partial proof.
