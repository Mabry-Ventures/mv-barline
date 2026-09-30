# Preserved repository contract

The active scope and development model routing in [AGENTS.md](AGENTS.md) supersede older routing/scope statements here. All other product, review, test, security and release constraints remain binding. Read applicable sections before work.

# Barline engineering rules

Barline is a GPLv3, Apple Silicon-only macOS utility derived from the exact Ice
compatibility baseline recorded in `docs/PROVENANCE.md`. Preserve attribution,
the `ice-upstream` and `ice-community` remotes, and the vendor tag. Never reuse
an upstream bundle identifier, signing identity, Sparkle feed, or update key.

## Canonical commands

```bash
./script/build_and_run.sh --verify
swiftlint lint --strict --config .swiftlint.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Barline.xcodeproj -scheme Barline \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Once Milestone 4 lands, use `./script/ci.sh fast` during iteration and
`./script/ci.sh full` before merging. macOS builds, tests, signing, notarization,
and releases are local-only. GitHub Actions may run only the Linux repository
hygiene workflow; never add `macos-*`, `self-hosted`, or
`pull_request_target`.

## Architecture boundaries

- Keep SwiftUI and domain state authoritative; use AppKit only for macOS
  presentation or event behavior SwiftUI cannot express.
- Keep private WindowServer symbols, raw event synthesis, and ephemeral window
  references inside `BarlineMenuService` behind typed XPC messages.
- Keep pure models, profile/state/search rules, and compatibility contracts in
  `BarlineCore`; do not import AppKit there.
- Use Swift 6, complete strict concurrency, explicit actor isolation, structured
  cancellation, and warnings-as-errors for Barline-owned targets.
- Do not put WindowServer work, screen capture, filesystem I/O, indexing, or
  model inference on the main actor.
- Treat snapshots as untrusted. Retain the last-known-good state when a response
  is empty, incomplete, stale, or implausible.
- Make mutations transactional and generation-checked. Never leave a partially
  activated profile as authoritative state.
- Keep the app useful in fallback mode: settings, profiles, metadata search,
  diagnostics, import/export, and recovery remain reachable.

## Product and privacy

- One product and one feature set: no account, subscription, tier, analytics,
  advertising, cloud service, remote AI, or hidden payment gate.
- Request permissions contextually. Never show an Accessibility or Screen
  Recording dialog the user did not ask for, and never make a permission a
  condition of using the app. The first-run walkthrough may explain both
  permissions and request each one only when the user clicks to allow it;
  every step must be skippable.
- Never log secrets, user content, screen images, usernames, full paths, raw
  process inventories, signing identities, or private profile names.
- Keep identity in `Config/*.xcconfig`. Keep credentials and
  `Config/Local.xcconfig` out of Git.
- Keep external links absent or explicitly placeholder-only until their
  canonical Barline destinations exist.

## Validation and evidence

- Do not claim a behavior, OS lane, signature, notarization, accessibility pass,
  or performance target without exact local evidence.
- A changed source SHA invalidates earlier candidate-bound release evidence.
- Preserve `.xcresult`, logs, machine-readable summaries, and measurements under
  ignored `.artifacts/` paths.
- macOS 27 compilation requires an explicit Xcode 27 path. macOS 27 runtime
  support requires execution on a macOS 27 host.
- Keep the worktree reviewable. Update `docs/EXECUTION_PLAN.md` and relevant
  architecture/change documentation at milestone checkpoints.

## Project ownership

The lead integration agent owns `project.pbxproj`, shared schemes/test plans,
xcconfig, entitlements, identifiers, dependencies, and final gates. Do not let
parallel workers modify those files concurrently. Preserve unrelated user
changes and inspect a dirty worktree before editing.
