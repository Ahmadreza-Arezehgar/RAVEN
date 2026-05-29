# Legacy / reference

Files quarantined from the build until they're ported to the new
multi-module layout.

## mesh-protocol/

- `NoiseSession.kt` — Noise IK handshake reference (Kotlin 1.x).
- `RumProtocolV2.kt` — wire-format reference for the BLE mesh.

These compiled under Kotlin 1.x but use `const val` initialisers that
Kotlin 2.1's tightened constant-evaluation rules reject (e.g.
`const val ENCRYPTED: Byte = 1 shl 1` — the `shl` returns `Int` and
the const path no longer auto-narrows to `Byte`).

When Phase 4 ports the BLE mesh into a dedicated `:core:mesh` module,
these files will be moved into `core/mesh/src/main/kotlin/` and the
constants rewritten as either:

```kotlin
const val ENCRYPTED: Byte = 0b0000_0010
```

or wrapped in an `object` so they're plain `val`s rather than `const val`.
The wire format itself stays binary-identical to the iOS side; this is
only a Kotlin syntax migration.

Don't delete these files — they're the authoritative spec the new
module will be built from.
