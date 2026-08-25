# RavenProfileRecordV1

**Version:** 1 (`rvn1`)  
**Status:** Discovery V1  
**Companion:** [`docs/RAVEN_DISCOVERY_V1.md`](../docs/RAVEN_DISCOVERY_V1.md)

## DHT key

```text
H("raven/profile/v1" || raven_id)
```

## Fields

| Field | Type | Notes |
|-------|------|-------|
| version | u8 | `1` |
| raven_id | string | Must match signer address |
| display_name | string | Not unique |
| public_aliases | string[] | Advisory labels |
| profile_image_digest | 32 bytes | Content-addressed; size-limited off-DHT |
| device_set_commitment | 32 bytes | |
| prekey_bundle_reference | 32 bytes | Opaque pointer |
| sequence | u64 | Monotonic per identity |
| issued_at / expires_at | u64 | unix ms |
| visibility | u8 | `0` = public signed |
| signature | 64 bytes | Ed25519 over signing bytes |

**Signing domain:** `"rvn1/profile" || …`

## Rules

- Signature must bind to `raven_id`.
- Newer `sequence` replaces older.
- Expired records are not current.
- No phone/email, no friendship graph, no private bio fields in DHT value.
- Valid signature ≠ person verified — only proves key control.

## Reference

`raven_core::profile_record::RavenProfileRecordV1`
