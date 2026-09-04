# Apple tree gap on `main`

**Status:** Documented gap · no Apple bring-up this sprint  
**As of:** 2026-09-04  
**Sprint 0 source of truth:** `main` (Rust / serverless)

## Governance

Sprint 0 governance source of truth is **`main`**. The live baseline is the Rust node (`node/`), protocol specs (`protocol/`), shared vectors, and serverless CI. A feature branch does not silently hold authority for trees that are not on `main`.

## Absent trees

As of this note, `ios-native/` and `RAVEN-WatchApp/` are **absent on `main`**. Related CODEOWNERS claims and CI path filters that name those trees are also a documented gap — not silent authority of `feature/raven-serverless-v1`.

Apple working trees currently exist on `feature/raven-serverless-v1` for **reference only**, until Eng Program’s landing plan executes.

## Inert CODEOWNERS and CI path triggers

`.github/CODEOWNERS` already claims:

- `/ios-native/` → `@Raven-ASHCO/apple`
- `/**/Security/**` → `@Raven-ASHCO/apple` + `@Raven-ASHCO/crypto`

`.github/workflows/raven-serverless.yml` path-filters include `ios-native/` and `RAVEN-WatchApp/` paths, and the workflow defines macOS lab jobs that assume those trees. Those path triggers (and the Apple-tree jobs they would run) are **inert** until the trees land on `main`.

## Landing plan (Eng Program)

Do **not** force-merge unrelated histories this sprint. Eng Program owns the landing plan (import strategy / subtree / fresh bring-up) before any Apple code lands on `main`.

## Related debt (out of scope here)

Phase B false-ACK / write-means-delivered debt is acknowledged separately. Coordinate with DTN + Protocol; no wire change without them. See:

- [`protocol/RAVEN_ACK_V1.md`](../../../protocol/RAVEN_ACK_V1.md) — known issue (write-means-delivered)
- [`protocol/RAVEN_DELIVERY_STATE_V1.md`](../../../protocol/RAVEN_DELIVERY_STATE_V1.md)

This note does not implement that fix.
