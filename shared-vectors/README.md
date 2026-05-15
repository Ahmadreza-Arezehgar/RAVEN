# `shared-vectors/` — cross-platform RAVEN test fixtures

This directory holds **deterministic, byte-exact test vectors** for every wire-protocol layer in RAVEN: crypto primitives, signing canonicalization, envelope encode/decode, BLE chunking, mesh routing, and trust.

Consumers:

- **iOS / Mac Catalyst** — `RAVEN-iOS/RAVEN/Tests/MeshInteropVectorsTests.swift`
- **Android** — `RAVEN-Android/modules/mesh/src/test/kotlin/.../SharedVectorsTest.kt` (or via git submodule from `raven-android`)
- **Windows** — `RAVEN-Windows/tests/SharedVectorsTests.cs`
- **Watch (read-only)** — observation-only; vectors not consumed there.

If you change a vector, **every consumer breaks**. That's the point — wire-protocol changes are coordinated across the fleet.

## Layout

```
shared-vectors/
├── generate_v1.py            (regenerator — uses cryptography lib; deterministic)
├── README.md                 (this file)
├── VERSIONING.md             (rules for adding / changing vectors)
└── v1/
    ├── identities.json       (canonical Alice / Bob / Carol / Dave keys + fingerprints)
    ├── crypto/               (Ed25519, X25519, HKDF, AES-GCM, fingerprint, key rotation)
    ├── canonicalization/     (5 signing rules from §D)
    ├── envelopes/            (SignedMeshPayload, EncryptedMeshPayload, ACK, Post, Frame, Stop)
    ├── chunking/             (§B chunk + reassembly)
    ├── routing/              (dedup keys, spray, forward decision, pairing code)
    └── trust/                (TOFU friend-device states)
```

## Determinism

- **Fixed test keys** — RFC 8032 / RFC 7748-derived seeds. See `v1/identities.json`.
- **Fixed timestamp** — every vector uses `1700000000` (= 2023-11-14T22:13:20 Z) as its base epoch.
- **Fixed nonces** — counter-prefixed or RFC-derived; never random.
- **No "now"** — every output is reproducible. If you re-run `generate_v1.py` the files must be byte-identical.

## Regenerating

```sh
pip3 install --user cryptography
python3 shared-vectors/generate_v1.py
```

Then run `git diff shared-vectors/v1/` to confirm no changes.

If `git diff` shows changes after a regenerate, **one of these is true:**

1. The spec changed (intentional — coordinate with all consumers; bump to `v2/`).
2. A bug in `generate_v1.py` (revert the diff, fix the script).
3. A cryptography library version diff (Ed25519 / AES-GCM is deterministic — if outputs change, that's a serious red flag; pin the library version).

## Source of truth

The Kotlin scaffold at `RAVEN-Android/modules/mesh/` is the reference port targeting **v1**. The iOS app's current `MeshService.swift` is **out of sync with v1** (uses a different service UUID and a much simpler envelope). Bringing iOS up to v1 is tracked under [A1](https://github.com/Raven-offline-messenger/raven-android/issues/1).

Until iOS catches up, these vectors document what the wire **should** look like — not what it **does** look like on iOS today.
