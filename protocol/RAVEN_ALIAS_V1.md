# RAVEN Alias V1

**Version:** 1 (`rvn1`)
**Status:** Frozen. See [`SPEC.md`](SPEC.md) for scope and versioning policy.
**Audience:** re-implementers of alias resolution/publication and anyone
building a DHT-backed alias store.

---

## 1. Record schema and signature

`RavenAliasRecordV1` is a self-signed claim: an identity publishing that a
human-readable string currently points at its own address.

| Field | Type | Meaning |
|---|---|---|
| `alias` | string | the human-chosen name, e.g. `"ahmad"` |
| `identity_address` | string | the `RavenAddressV1` this alias currently resolves to ([`RAVEN_ADDRESS_V1.md`](RAVEN_ADDRESS_V1.md)) |
| `sequence` | u64 | monotonically increasing per-alias counter |
| `expires_at` | u64 | unix ms |
| `signature` | 64 bytes | Ed25519, over the signing bytes below |

**Signing bytes** (`lp(x) = len_be2 || x`, `u64(n)` = 8-byte big-endian):

```
"rvn1/alias" || lp(alias) || lp(identity_address) || u64(sequence) || u64(expires_at_ms)
```

Signed by the **identity key of `identity_address` itself** — this is a
self-claim, not a third-party grant. Anyone can construct and sign a
`RavenAliasRecordV1` for any alias string they like, for their own address;
there is no registrar and no uniqueness enforcement at the signing layer (see
§3).

**Vector:** `shared-vectors/rvn1/alias/ahmad_seq42.json` — alice's identity
claiming alias `"ahmad"` at `sequence=42`.

## 2. Monotonic sequence freshness

A verifier or cache holding a record for a given alias at `sequence=N` MUST
reject any incoming record for the *same alias, same claiming identity* with
`sequence <= N`, even if the incoming record is validly signed. This defeats
replay of a stale-but-validly-signed older record — for example, an attacker
who captured an earlier signed record before the legitimate owner moved the
alias elsewhere, or before a key rotation, cannot use it to roll the alias
back.

**Vector:** `shared-vectors/rvn1/negative/alias_stale_sequence.json` — a
`sequence=41` record arriving after a `sequence=42` record is already cached
for the same alias; expected `resolver_action: reject_stale`.

## 3. The ambiguity rule

Because any identity can self-sign a claim on any alias string with no
registrar, **the alias namespace is not unique.** Two different
`identity_address` values can each publish a validly-signed, unexpired,
highest-known-`sequence` record claiming the exact same alias string — for
example if two people independently pick the same name, or if a DHT briefly
holds two independently-seeded copies during a network partition.

**A resolver that observes two live, conflicting claims for the same alias
string MUST surface this as an ambiguous or conflicting result — it MUST NOT
silently pick one.** Silent selection is exactly the failure mode that lets an
attacker who publishes a competing claim quietly redirect a lookup: if the
resolver's tie-break is deterministic and predictable (e.g. "prefer the
lexicographically smaller address" or "prefer whichever record arrived
first"), an attacker only needs to win that specific tie-break, not defeat any
cryptography.

**Key-change warning.** Separately from outright ambiguity: when a lookup for
a *previously resolved* alias returns a *different* `identity_address` (or the
same address's underlying device-certificate set has changed) than what was
last seen and pinned for that alias, implementations MUST surface a
key-change warning before delivering to or trusting the new identity — the
same "did the key change?" posture described for fingerprints in
[`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md) §3. An alias resolving to a new
address is exactly as significant, from a trust standpoint, as a contact's
fingerprint changing.

## 4. DHT publication constraints

A `RavenAliasRecordV1` published to (or served from) a DHT or any other
untrusted store MUST satisfy all of:

- **Signed.** Unsigned records MUST be discarded on receipt — there is
  nothing else binding the claim to the identity making it.
- **Versioned.** `sequence` *is* the version. Replacement in the store must be
  keyed by `(alias, identity_address)` with last-write-wins by `sequence`,
  never by wall-clock receipt order (§2) — receipt order is not trustworthy in
  a store with multiple untrusted writers.
- **Expiry-bound.** A resolver MUST treat a record as absent once past
  `expires_at`. This is what keeps an abandoned or unrenewed alias claim from
  squatting the name indefinitely.
- **Size-limited.** `alias` and `identity_address` are the only
  variable-length fields, each length-prefixed with a 2-byte big-endian
  length (a 65,535-byte theoretical cap per field). A store implementation
  SHOULD impose a much smaller practical cap — a value approaching that
  theoretical ceiling has no legitimate use as a human-typed alias, and
  admitting oversized values is a cheap amplification/storage-exhaustion
  vector against the store.

## Reference implementation

`protocol/reference/raven_protocol/alias.py`. Vectors:
`shared-vectors/rvn1/alias/ahmad_seq42.json`,
`shared-vectors/rvn1/negative/alias_stale_sequence.json`.
