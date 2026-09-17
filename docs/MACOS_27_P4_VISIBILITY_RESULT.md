# macOS 27 P4 visibility result

Status: native primitive passed; shipping integration fails P4 enforcement  
Source: `040a2b418d604f89011846b1b0353a18fc03f4db`  
Host: CPLCODEX01  
OS: macOS 27.0 (`26A428`)

## Result

Native assessment concealment is safe only at these granularities:

- A third-party application publishing one status item can be assigned as one
  item because its application group contains exactly one item.
- A third-party application publishing multiple status items can be assigned
  only as the complete application group.
- A mixed assignment within one third-party application must fail visible.
- System items require a separately known native system-item identifier.
- Unknown Apple items, Barline controls, untrusted publishers, and ambiguous
  assignments remain visible or unavailable.

The current shipping route is disconnected: on macOS 27,
`XPCMenuBarBackend.configureConcealment` calls the in-process
`GoldenGateAXSnapshotProvider.configureConcealment`, which is a no-op. The real
transactional concealment controller exists in `BarlineMenuService` but is not
reached by that route.

## Evidence

The exact-source manifest is stored at:

```text
.artifacts/macos27-lab/040a2b418d60/p4-visibility/manifest.json
```

The complete remote pilot is stored at:

```text
/Users/jaredmabry/Library/Application Support/BarlineArrangementLab/evidence/040a2b418d60/p4-visibility-20x2-20260917T023857Z
```

The pilot passed 40 of 40 cycles:

- 20 cycles concealed and restored a notarized one-item publisher.
- 20 cycles concealed and restored all five items from a notarized multi-item
  publisher as one application group.
- In every active assertion, the target had zero hittable menu extras and the
  independent control publisher retained its baseline hittable count.
- In every restoration, both publishers returned to their baseline counts.
- The SHA-256 of the serialized `TrailingItemPreferredPositions` preference
  value was identical before and after the pilot.
- No visibility probe remained running after the pilot.
- `/Applications/Barline.app` remained byte-identical at executable SHA-256
  `9b4a354e54a4f687b4a03288237dfdfae9c71a7ca48054ba1f9d6767d33e201b`.

The pure fixture policy tests additionally prove that a partial selection from
a three-item publisher is rejected, a complete three-item selection is
admitted as an application group, and local shelf ordering does not mutate its
native-order input value.

## Interaction smoke

After the pilot and complete restoration, Computer Use on CPLCODEX01 verified:

- The restored one-item publisher opened its native menu from one click and
  dismissed with Escape.
- Control Center opened and dismissed normally.
- The clock/Notification Center surface opened and dismissed normally.
- The Apple menu opened and dismissed normally.
- A normal foreground-application menu opened and dismissed normally.

No notification contents or unrelated menu labels were retained in evidence.

## Trust-boundary limitation

The controlled research fixtures are Developer ID signed but unnotarized.
Gatekeeper reports `source=Unnotarized Developer ID`, and an active assessment
configuration excludes them even when their bundle identifiers appear in the
allowlist. The notarized installed publishers pass the same live checks. The
fixture result is therefore a trust-boundary rejection, not contradictory
visibility evidence.

The `barline-notary` keychain profile returned HTTP 401 during a read-only
credential check, so the fixtures were not submitted to Apple merely to bypass
that production-relevant trust boundary.

## P4 gate disposition

- Visibility granularity identified: pass.
- Whole-application grouping enforced in the pure policy: pass.
- Mixed same-app assignment fails visible: pass.
- Local shelf order separated from native order in the pure model: pass.
- Native position preference unchanged by visibility operations: pass.
- Repetition and restoration: pass, 40 of 40.
- Reveal, activation, dismissal, and protected system surfaces: pass.
- Relaunch safety: the assertion owner exits after every cycle and native state
  restores before the next cycle; pass.
- Focus, shortcuts, rules, and automation enforcement: fail in the current
  shipping integration. The no-op app-process route and missing shared
  group-policy admission mean the product does not yet enforce this primitive.
  P6/P7 must route every entry point through one capability and policy before
  the product-level P4 gate can close.
