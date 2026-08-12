# RAVEN Prekey Bundle V1

**Version:** 1 (`rvn1`)  
**Status:** Binding for serverless first-contact (no central prekey server required)  
**Companions:** [`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md), [`ATSAM_PRIMITIVE_MAPPING_V1.md`](ATSAM_PRIMITIVE_MAPPING_V1.md), [`RAVEN_ALIAS_V1.md`](RAVEN_ALIAS_V1.md)

## 1. Purpose

A `RavenPrekeyBundleV1` lets a sender establish an ATSAM hybrid root (X25519 ‖ ML-KEM-768) with an offline recipient by obtaining a **signed**, time-bounded bundle that the recipient previously published to peers, bridges, DHT records, or out-of-band (QR / file). Relays MUST treat the bundle as opaque authenticated metadata — they never hold conversation roots.

## 2. Fields (canonical order)

| Field | Type | Mandatory | Notes |
|-------|------|-----------|-------|
| `version` | u8 | yes | `1` |
| `identity_ed25519_pub` | 32 B | yes | Raven user/device identity verifier |
| `device_id` | UTF-8 ≤ 64 B | yes | opaque device label (not a username) |
| `x25519_pub` | 32 B | yes | classical DH half |
| `mlkem768_ek` | 1184 B | yes | ML-KEM-768 encapsulation key (FIPS 203) |
| `signed_prekey_id` | u32 BE | yes | monotonic per identity |
| `one_time_prekey_id` | u32 BE | no | `0` = none |
| `one_time_x25519_pub` | 32 B | iff otp id ≠ 0 | single-use classical key |
| `created_at_ms` | u64 BE | yes | unix ms |
| `expires_at_ms` | u64 BE | yes | MUST be > created |
| `signature` | 64 B | yes | Ed25519 over signing bytes |

**Prohibited:** usernames, phone numbers, conversation IDs, plaintext mailbox tags, unsigned algorithm negotiation fields.

## 3. Signing bytes

```
"rvn1/prekey" || version(1) || identity_ed25519_pub(32) || lp(device_id)
  || x25519_pub(32) || mlkem768_ek(1184) || u32(signed_prekey_id)
  || u32(one_time_prekey_id) || [one_time_x25519_pub(32) if otp≠0]
  || u64(created_at_ms) || u64(expires_at_ms)
```

`lp(x) = u16_be(len) || x`. Signature domain is fixed — no silent downgrade to classical-only without an explicit `mlkem768_ek` of all zeros **and** a capability bit that receivers MUST treat as degraded (see mapping doc). Production senders SHOULD refuse all-zero EK.

## 4. Validation order

1. Length / version / field bounds  
2. `expires_at_ms > now` (clock skew tolerance ±5 min)  
3. Signature verify against `identity_ed25519_pub`  
4. Reject if `mlkem768_ek` length ≠ 1184  
5. Reject otp fields inconsistent with `one_time_prekey_id`  
6. Cache by `(identity_ed25519_pub, signed_prekey_id)`; prefer highest id that still validates

## 5. Publish / replicate (serverless)

Bundles MAY be:

- gossiped as signed DHT / discovery values (see [`RAVEN_TRANSPORT_INTERFACE_V1.md`](RAVEN_TRANSPORT_INTERFACE_V1.md))  
- carried OOB (QR, file, NFC)  
- stored under opaque store tags (never under username) — [`RAVEN_STORE_OBJECT_V1.md`](RAVEN_STORE_OBJECT_V1.md)

HTTP FastAPI prekey routes are **legacy optional**, not required for V1 serverless.

## 6. One-time prekey races

If two senders consume the same OTP due to distributed state, both sessions remain cryptographically distinct (different X25519 ephemeral + ML-KEM CT). Recipient MUST accept both; OTP reuse MUST be logged as a soft anomaly, not a hard fail that drops messages.

## 7. Vectors

| Id | Path | Notes |
|----|------|-------|
| Structural KAT | `shared-vectors/rvn1/prekey/bundle_structure_001.json` | signing-bytes hex + field sizes (EK may be deterministic test bytes) |
| Negative | `shared-vectors/rvn1/negative/prekey_bad_sig.json` | tampered signature → reject |

Rust: `raven_core::prekey_bundle`. iOS publish path remains `ATSAMPrekeyService` until fully migrated off HTTP.

## 8. Unknown / version behavior

Higher `version` → drop. Unknown trailing bytes after signature → reject (fixed layout). Forward-compat requires a version bump.
