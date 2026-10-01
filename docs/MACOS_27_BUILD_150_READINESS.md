# Build 150 diagnostic qualification

Status: **HOLD**. Private 1.0.66/build 150. Public build 142 is unchanged.

The actual installed saved-layout transition failed on build 149 despite its
passing policy tests. This candidate exposes activation, workspace rollback
and layout rollback separately using a closed diagnostic vocabulary. It does
not change the transaction's compensation, admission or authority rules.

Tests preserve original-error behavior after successful compensation and
verify typed component errors when compensation cannot be verified. Exact
known error literals and raw snapshot rejections are mapped without exposing
names, identities, paths or unknown payloads.

The next runtime gate is the same physical visible-to-hidden saved-layout
transition on CPLCODEX01. Do not treat compilation, packaging or source review
as closure. All open release gates in the build-149 record still apply,
including XCUITest runner setup, native clock visibility, macOS 26 runtime,
notched/multi-display hardware and public-build update qualification.
