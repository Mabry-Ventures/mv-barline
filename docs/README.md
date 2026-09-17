# Barline documentation

Start with the [project README](../README.md) for what Barline is and its
current release status. This page is a map of everything under `docs/`.

## Using Barline

| Document | What it covers |
| --- | --- |
| [Supported configurations](SUPPORTED_CONFIGURATIONS.md) | Menu bar, display, and Space configurations Barline is built for |
| [Known limitations](KNOWN_LIMITATIONS.md) | Current boundaries of Barline 1.0.15 and what is not yet qualified |
| [Focus and App Intents](FOCUS_AND_APP_INTENTS.md) | How saved layouts integrate with Apple's Focus Filters and Shortcuts |
| [Search and Apple Intelligence](SEARCH_AND_APPLE_INTELLIGENCE.md) | Local search, Spotlight indexing, and optional on-device interpretation |
| [Accessibility](ACCESSIBILITY.md) | Accessibility implementation and validation lanes |
| [Privacy architecture](PRIVACY_ARCHITECTURE.md) | What stays local, what is logged, and what is never collected |
| [Support bundles](SUPPORT_BUNDLE.md) | What a reviewed diagnostic export contains and how to share it safely |

Troubleshooting lives in [FREQUENT_ISSUES.md](../FREQUENT_ISSUES.md), and the
user-facing privacy policy in [PRIVACY.md](../PRIVACY.md).

## Building and contributing

| Document | What it covers |
| --- | --- |
| [Building from source](BUILDING.md) | Requirements, bootstrap, build, test, and release-diagnostic commands |
| [Local CI](LOCAL_CI.md) | The `script/ci.sh` gates and what each one proves |
| [Architecture](ARCHITECTURE.md) | Target layout and how app, core, and helper responsibilities divide |
| [Private API boundary](PRIVATE_API_BOUNDARY.md) | Where private WindowServer behavior is isolated and why |
| [Compatibility strategy](COMPATIBILITY.md) | Capability-probe backend selection across macOS versions |
| [Compatibility firewall status](COMPATIBILITY_FIREWALL_STATUS.md) | The strict boundary check that keeps private symbols in the helper |
| [macOS 27 arrangement research implementation plan](MACOS_27_RESEARCH_IMPLEMENTATION_PLAN.md) | Gated fixture research for a native arrangement primitive before production integration |
| [Profile schema](PROFILE_SCHEMA.md) | Profile schema version 7, archive format, and migration rules |
| [Dependencies](DEPENDENCIES.md) | Pinned Swift packages and why each is present |
| [Architecture decision records](adr/) | Accepted decisions on the service boundary and concurrency exceptions |

Contribution rules are in [CONTRIBUTING.md](../CONTRIBUTING.md) and the
[Code of Conduct](../CODE_OF_CONDUCT.md).

## Provenance and licensing

| Document | What it covers |
| --- | --- |
| [Provenance](PROVENANCE.md) | The exact Ice baseline Barline derives from and its vendor tag |
| [Upstream](UPSTREAM.md) | Relationship to Ice upstream and the community compatibility fork |
| [Changes from Ice](CHANGES_FROM_ICE.md) | What Barline changed relative to that baseline |
| [Baseline audit](BASELINE_AUDIT.md) | The audit of the imported baseline at import time |

Licensing terms are in [LICENSE](../LICENSE), with attribution in
[NOTICE.md](../NOTICE.md) and
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Release process

| Document | What it covers |
| --- | --- |
| [Releasing](RELEASING.md) | The credentialed local signing, notarization, and publication pipeline |
| [Test matrix](TEST_MATRIX.md) | Current automated evidence per area and what remains manual |
| [Feature qualification](FEATURE_QUALIFICATION.md) | The acceptance contract for the current release candidate |
| [Reliability-first contract](RELIABILITY_FIRST.md) | The approved delivery direction this release line follows |
| [Performance](PERFORMANCE.md) | Performance and energy budgets and their measurement status |
| [Support delivery](SUPPORT_DELIVERY.md) | How public issues are routed and verified |
| [GitHub configuration](GITHUB_CONFIGURATION.md) | Repository settings this project expects |

## Project history

These are working records kept for traceability. They are point-in-time
engineering journals, not current product documentation.

| Document | What it covers |
| --- | --- |
| [Execution plan](EXECUTION_PLAN.md) | The live build-by-build implementation ledger |
| [Production remediation](PRODUCTION_REMEDIATION.md) | The 1.0.9 build-18 remediation record |
| [Release 1.0.9 notes](RELEASE_1.0.9.md) | Candidate history for the 1.0.9 line |
| [Superseded plans](superpowers/) | Earlier planning and design drafts, retained unchanged |
