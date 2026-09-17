# macOS 27 arrangement laboratory

This package is a non-shipping research harness. It publishes controlled
status-item fixtures and observes only fixture-owned Accessibility state. It
must never be included in `Barline.app`, a release archive, or an update feed.

Build the app bundles with:

```bash
./script/build-lab.sh
```

Capture a candidate-bound CPLCODEX01 manifest with:

```bash
./script/capture-manifest.sh /absolute/evidence-directory
```

The research gates and runtime safety requirements are defined in
`docs/MACOS_27_RESEARCH_IMPLEMENTATION_PLAN.md`.

The package deliberately contains no access to `com.apple.MenuBar`,
`CFPreferencesSetValue`, or Barline's position-table store.

Phase 3 cycles use two independently verified input paths:

- `run-synthetic-move.sh` performs the native HID Command-drag inside the
  trusted observer and proves relative placement, unrelated order, and button
  cleanup from live Accessibility elements.
- `run-p3-cycle.sh` briefly foregrounds the unique CPLCODEX01 Screen Sharing
  window, forwards one physical click to the moved item, requires an activation
  delta of exactly one, and restores the previously frontmost app. This is
  necessary because macOS 27 accepts the native drag but its menu-bar proxy can
  report a successful `AXPress` while declining direct synthetic activation.
  Single-item publishers receive a fresh cardinality-bounded AX observation
  immediately before that click so dynamic title changes cannot stale its frame.

The coordinator rejects mismatched display geometry, multiple CPLCODEX01
windows, a non-frontmost Screen Sharing app, an incomplete probe, or any
activation delta other than one.
