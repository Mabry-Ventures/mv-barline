# Barline

**Your menu bar, organized. Your Mac, uninterrupted.**

Barline is a free, open-source menu bar utility for Apple Silicon Macs. Keep
everyday items visible, tuck the rest away, and reveal them when you need them.
No account, subscription, advertising, or paid feature tier.

**Site:** [usebarline.com](https://usebarline.com/) · **Support (optional):** [contribute via Stripe](https://buy.stripe.com/cNibJ1a370l33AVgnk1ck02) · If Barline helps you, a [GitHub star](https://github.com/Mabry-Ventures/mv-barline) helps others find it.

## Download

[Download Barline 1.0.12](https://github.com/Mabry-Ventures/mv-barline/releases/download/v1.0.12/Barline-1.0.12.dmg)
for Apple Silicon Macs running macOS 26 or later. Open the disk image and drag
Barline onto the Applications shortcut. The app is signed with Developer ID,
notarized by Apple, and updates itself through Sparkle. The
[release page](https://github.com/Mabry-Ventures/mv-barline/releases/tag/v1.0.12)
has the release notes, `SHA256SUMS` checksums, and the complete corresponding
source.

Do not download an Ice binary expecting it to be Barline. Do not install an
unofficial "Barline" build, and do not disable macOS security protections to
run one.

## What Barline does

- Organizes visible, hidden, and always-hidden menu bar sections.
- Reveals hidden items through its menu bar control, shelf, or keyboard controls.
- Saves menu bar layouts and integrates with Apple's Focus Filters.
- Searches menu bar items locally and customizes their appearance and spacing.
- Provides reviewed diagnostic export and layout recovery tools.

Groups, search personalization, display-specific layouts, contextual rules, and
per-item shortcuts are included. See [known limitations](docs/KNOWN_LIMITATIONS.md)
for configuration-specific boundaries.

## Compatibility and permissions

The current target is **macOS 26 on Apple Silicon (`arm64`)**. Intel Macs are
not supported. macOS 27 has not been runtime-qualified; a newer OS version is
not automatically a supported configuration.

The secondary shelf and graphical layout editor require an always-visible
system menu bar. Automatically hidden menu bars use a native reveal fallback.
Read [supported configurations](docs/SUPPORTED_CONFIGURATIONS.md) before testing
full-screen, notched, or multiple-display setups.

Accessibility permission enables cross-application discovery and arrangement.
Screen & System Audio Recording permission enables optional item-image previews
and appearance features. Settings, saved layout metadata, search, diagnostics,
and recovery remain available without granting every permission.

Barline relies on unsupported WindowServer behavior. macOS updates can affect
it. Our reliability goal is to preserve your last good state, keep your Mac
usable, and make recovery clear—not to promise that failures are impossible.

## Privacy and optional support

Menu bar data stays local. Barline has no analytics, inventory upload, or remote
AI service. Release builds use a signed update feed; external links open only
when you choose them. Read the [privacy policy](PRIVACY.md).

Barline is donationware. Every feature is included; optional one-time
contributions never unlock features, and the app does not display payment
reminders. If you want to help with development and macOS compatibility
testing, you can [contribute via Stripe](https://buy.stripe.com/cNibJ1a370l33AVgnk1ck02)
or visit [usebarline.com/#support](https://usebarline.com/#support).

## Help and contributions

Start with [troubleshooting](FREQUENT_ISSUES.md). Report reproducible bugs or
suggest improvements through
[GitHub Issues](https://github.com/Mabry-Ventures/mv-barline/issues). Review any
diagnostic attachment and redact private information before sharing it.
Security concerns belong under the [security policy](SECURITY.md), not in a
public bug report.

Developers: see [Contributing](CONTRIBUTING.md), [Building](docs/BUILDING.md),
and the [architecture guide](docs/ARCHITECTURE.md). The
[documentation index](docs/README.md) maps every document in this repository. Iteration uses
`./script/ci.sh fast`; complete local qualification uses `./script/ci.sh full`.
All macOS builds, testing, signing, and notarization run locally. GitHub Actions
runs Linux repository hygiene only.

## License and origins

Barline is GPLv3 software derived from
[Jordan Baird's Ice](https://github.com/jordanbaird/Ice) and
[Xinyan Lu's macOS compatibility fork](https://github.com/lxy1992/Ice).
It is an independent project, not an endorsement by its upstream authors.

See [LICENSE](LICENSE), [NOTICE.md](NOTICE.md),
[third-party notices](THIRD_PARTY_NOTICES.md),
[provenance](docs/PROVENANCE.md), and [changes from Ice](docs/CHANGES_FROM_ICE.md).
Complete corresponding source and required notices accompany distributed builds.
