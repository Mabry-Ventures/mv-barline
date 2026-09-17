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
