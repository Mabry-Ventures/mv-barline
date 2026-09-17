# macOS 27 P5 persistence identity result

Status: native position-record identity contradicted  
Source: `7e612f5fc5b79cf5196b549033c9b22513bb4c9f`  
Host: CPLCODEX01  
OS: macOS 27.0 (`26A428`)

## Result

The macOS 27 native position table does not provide a durable record identity
that Barline can resolve from the current Accessibility snapshot or safely use
as mutation authority.

All nine controlled cases completed a verified native Command-drag of the
fixture-owned `beta` item relative to `gamma`. The postcondition observer
proved the requested adjacency and preserved unrelated order. After each move,
the harness waited for the fixture subset of the native table to remain stable
for at least one second after a minimum two-second observation period.

Despite those verified native moves:

- Eight cases produced no position-record delta.
- The missing-title case changed two opaque record aliases.
- The changed-record set was not stable across cases.
- Neither the baseline nor the changed-autosave case mapped all three current
  autosave names to exactly one current record.
- Historical records remained present across launches and revisions.

The result is not a claim that macOS never writes the table. It proves the
opposite product-relevant point: a verified move does not yield a synchronous,
stable, transaction-owned record correlation that Barline can derive and
validate.

## Evidence

The exact-source manifest is stored at:

```text
.artifacts/macos27-lab/7e612f5fc5b7/p5-identity/manifest.json
```

The complete remote study is stored at:

```text
/Users/jaredmabry/Library/Application Support/BarlineArrangementLab/evidence/7e612f5fc5b7/p5-identity-20260917T030937Z
```

The manifest records a clean research source, Xcode 27.0, macOS 27.0 build
`26A428`, no competing menu-bar manager, and these executable hashes:

- Identity fixture:
  `278e2cd7ec33c526973f16416850284df7e137529df88ab4b6aa8300e72e74b1`
- Trusted observer:
  `fd3b8975624a4304affcc46cccbbf90ae519497b1feb5b3354f0e3464ce78034`

The installed production app remained Barline 1.0.28 build 102 with executable
SHA-256
`9b4a354e54a4f687b4a03288237dfdfae9c71a7ca48054ba1f9d6767d33e201b`.

No identity fixture remained running after the study.

## Variables exercised

The study varied one fixture-owned signal at a time:

1. Baseline.
2. Changed AX identifier.
3. Missing AX identifier.
4. Changed title.
5. Duplicate title.
6. Missing title.
7. Reversed creation order.
8. Removal and recreation of the moved item in-process.
9. Changed `NSStatusItem.autosaveName` revision.

Every case used a fresh process, a complete fixture receipt, a complete AX
observation, a verified native move report, read-only position-table snapshots,
and per-run HMAC aliases instead of exporting raw private record keys.

## P5 gate disposition

- Native move postcondition in every case: pass, nine of nine.
- Read-only observation and quiescence: pass.
- Stable current autosave mapping: fail.
- Stable changed-record set across required lifecycles: fail.
- Durable AX-to-native-record mapping: contradicted.
- Position-table writer eligibility: denied.

P6 must remove the macOS 27 position-table path from mutation authority. Native
ordering may use only the P3 gesture transaction with fresh geometry and a
live AX postcondition. Saved layouts, Focus application, shortcuts, rules, and
automation must not claim that they can restore native system order on macOS 27.
