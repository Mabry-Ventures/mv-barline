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

Phase 4 visibility research is isolated from native ordering. The visibility
probe holds one native assessment assertion while the trusted observer records
only per-application item counts and hit-test results. Unnotarized fixtures are
intentionally treated as ineligible by the macOS runtime, so the live pilot
uses installed notarized single-item and multi-item publishers while the pure
fixture policy tests enforce item versus whole-application assignment.

Run the P4 visibility pilot from the research worktree with an absolute
directory on CPLCODEX01:

```bash
./script/run-p4-visibility-pilot.sh \
  "/Users/jaredmabry/Library/Application Support/BarlineArrangementLab/evidence/<sha>/p4-visibility" \
  20
```

Every cycle proves that the selected application is non-hittable, the control
application remains hittable, invalidating the assertion restores both, and
the native position table's serialized preference value has the same SHA-256
before and after the pilot. The script stops on the first mismatch and
invalidates any assertion left active by a failed check.

Phase 5 varies only fixture-owned identity signals while performing a real
native Command-drag in every case. It records current AX metadata and reads the
native position table without mutating it. Position keys are retained only as
per-run HMAC aliases, so the evidence can compare stability without exporting
the private keys themselves.

Run the bounded P5 identity study with an absolute directory on CPLCODEX01:

```bash
./script/run-p5-identity-study.sh \
  "/Users/jaredmabry/Library/Application Support/BarlineArrangementLab/evidence/<sha>/p5-identity"
```

The study changes AX identifier, title, title uniqueness, creation order,
in-process lifecycle, and autosave revision independently. Historical native
records are reported separately from the three records matched to the current
fixture receipt. A pass establishes only the classification written to
`summary.json`; it never authorizes a position-table writer.

Run the full P3 pilot with an absolute directory on CPLCODEX01:

```bash
./script/run-p3-pilot.sh \
  "/Users/jaredmabry/Library/Application Support/BarlineArrangementLab/evidence/<sha>/p3-pilot" \
  20
```

The pilot discovers the current native order before every cycle, requests the
opposite placement, and runs 20 fresh-launch cycles for each admitted class.
