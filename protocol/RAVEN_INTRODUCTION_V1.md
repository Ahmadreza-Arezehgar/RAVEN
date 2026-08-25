# RavenIntroductionV1

**Version:** 1 (`rvn1`)  
**Status:** Discovery V1  
**Companion:** [`docs/RAVEN_DISCOVERY_V1.md`](../docs/RAVEN_DISCOVERY_V1.md)

Recipient-specific social introduction. Relays see opaque note ciphertext only.

| Field | Meaning |
|-------|---------|
| intro_id | 16 bytes |
| introducer_raven_id | Signer |
| subject_raven_id | Introduced identity |
| recipient_raven_id | Intended inbox |
| subject_display_name / subject_aliases | Advisory |
| note_ciphertext | E2EE to recipient |
| created_at / expires_at | unix ms |
| signature | Ed25519 by introducer |

**Domain:** `"rvn1/intro"`

Introductions never publish a friendship graph. Verification state for discovery: `INTRODUCED`.

## Reference

`raven_core::introduction::RavenIntroductionV1`
