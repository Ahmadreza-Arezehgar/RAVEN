# RAVEN Task 0B.3 R0 — secret-service 2.0.2 provenance pin
#
# Status: dependency / source / crypto boundary for Independent R0 review only.
# Forbidden: plain no-prompt fallback, R1 backend rewrite, 0B.4+, 0C, production,
# commit / push / stage.

## Upstream identity

| Field | Value |
|---|---|
| crates.io package | `secret-service` |
| version | `2.0.2` |
| downloaded `.crate` SHA-256 | `e1da5c423b8783185fd3fecd1c8796c267d2c089d894ce5a93c280a5d3f780a2` |
| Plan git pin (reference) | `https://github.com/open-source-cooperative/secret-service-rs.git` tag `v2.0.2` / commit `778d9f36d32464e410eeb0bd304b33f85bd831bf` |
| Published homepage in crate | `https://github.com/hwchen/secret-service-rs.git` |
| License | MIT OR Apache-2.0 |
| `LICENSE-APACHE` SHA-256 | `a60eea817514531668d7e00765731449fe14d059d3249e0bc93b36de45f759f2` |
| `LICENSE-MIT` SHA-256 | `0d13fdf5615ccc7e7123b58b5c88b0d2bbabe345cd70b94e094ee44034db5be6` |

Tree extracted from the pinned `.crate` (not a live network git checkout at build time).

## Zeroizable bigint dependency

Raven replaces only the ephemeral DH arithmetic owner with
`num-bigint-dig 0.9.1` using its `zeroize` feature. The Cargo checksum is
`a7f9a86e097b0d187ad0e65667c2f58b9254671e86e7dbb78036b16692eae099`;
the license is MIT OR Apache-2.0. A deterministic KAT compares public keys and
the shared secret byte-for-byte with upstream `num::BigUint` arithmetic. DH
parameters, session negotiation, HKDF, AES-CBC, and D-Bus wire types are
unchanged.

## Raven delta

See `RAVEN_DELTA.md` and `RAVEN_PATCH_MANIFEST`. `RAVEN_PATCH_DIGEST`
is a frozen, read-only digest list; the verifier never regenerates it.

### Re-freeze 2026-08 (authorized)

The 2026-08 independent R0 review authorized one semantic change to the
frozen fork: `create_item_no_prompt` lost its caller-controlled `replace`
flag (destructive-overwrite risk) and is now add-only by construction.
`RAVEN_PATCH_DIGEST` was regenerated for exactly this authorized delta; the
verifier rejects any further drift. See `RAVEN_DELTA.md` § Re-freeze.

Verification downloads the exact crates.io archive, validates its SHA-256,
rejects unsafe archive members, compares every unmodified upstream file, and
rejects extra/missing/symlinked/non-regular fork entries:

`node/scripts/verify_secret_service_2_0_2_raven_noprompt.sh`

## Hard-stop proofs before R1

1. Negotiate DH with GNOME Keyring; never use `plain` for no-prompt APIs.
2. Create/get exact binary secret without executing Prompt.Prompt.
3. Return the created item's actual collection path.
4. Prompt-required → typed `PromptRequired`, no UI.
5. Session/secret buffers zeroized on drop / error paths.

GNOME Keyring may report `text/plain` after Raven requests
`application/octet-stream`. R0 records this provider result while still
proving exact encrypted bytes. This does **not** relax the protected-anchor R1
schema: R1 remains blocked until its content-type normalization policy is
explicitly approved. References: the freedesktop Secret Service type contract
(`https://specifications.freedesktop.org/secret-service/latest/types.html`)
and GNOME Keyring release notes documenting its `text/plain` behavior
(`https://github.com/GNOME/gnome-keyring/blob/main/NEWS`).

Run: `node/scripts/linux_secret_service_r0_hard_stop.sh`
