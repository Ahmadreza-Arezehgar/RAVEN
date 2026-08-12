# RAVEN Address V1

**Version:** 1 (`rvn1`)
**Status:** Frozen. See [`SPEC.md`](SPEC.md) for scope and versioning policy.
**Audience:** re-implementers of address encoding/decoding and anything that
resolves a human-facing name to a routable identity.

---

## 1. Three concepts, not one

RAVEN deliberately separates three things that other systems often conflate
into "your username":

| Concept | What it is | Where it's defined | Mutable? |
|---|---|---|---|
| **Identity** | An Ed25519 keypair, held on-device | [`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md) | No — losing it loses the identity |
| **Address** | A deterministic, opaque locator derived from the identity's public key | this document | No — always the same string for the same key |
| **Alias** | A human-chosen, self-published pointer *to* an address | [`RAVEN_ALIAS_V1.md`](RAVEN_ALIAS_V1.md) | Yes — can be changed, contested, or expire |

The address is the protocol's "account number": stable, unambiguous, and the
only one of the three that cryptographic operations (signature verification,
session establishment, envelope authentication) actually bind to. The alias is
a convenience index on top of it — see §4.

## 2. `RavenAddressV1` — canonical encoding

```
payload  = version(0x01) || SHA-256(identity_ed25519_pub_raw_32)[:20]
canonical = Bech32m(BIP-350), HRP = "rvn"
```

That is: one version byte, followed by the first 20 bytes of the SHA-256 hash
of the identity's raw 32-byte Ed25519 public key — 21 bytes total — encoded
with Bech32m (the BIP-350 checksum variant, not the original BIP-173 Bech32).

**Worked example** (alice, RFC-8032 test key
`d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a`):

```
canonical: rvn1qysluvwl5922yctzd0u9gpr06gn3k7ldfvecule0
display:   rvn1:QYSL-UVWL-5922-YCTZ-D0U9-GPR0-6GN3-K7LD-FVEC-ULE0
```

**Vector:** `shared-vectors/rvn1/address/encode_alice.json`.

## 3. Display grouping

The display form is purely presentational — parsers MUST accept the canonical
lowercase Bech32m string, never the display form directly:

```
display = "rvn1:" + "-".join(4-char groups of UPPERCASE(canonical[4:]))
```

i.e. take the canonical string, drop the fixed `rvn1` prefix, uppercase the
remaining data characters, and re-join them in groups of 4 separated by `-`,
with a `rvn1:` label re-added at the front. This is for human transcription
and visual chunking only. Because the display form injects `:` and `-`
characters that are not in the Bech32 charset, it is **not** valid input to a
Bech32m decoder as-is — an implementation accepting pasted/typed display-form
input must first normalize it back to canonical (strip the `rvn1:` label and
all `-` characters, lowercase the rest, restore the `rvn1` prefix) before
decoding.

## 4. Parsing and validation

Decoding an address string MUST reject all of the following:

- **Bad checksum.** Bech32m's polymod check over the HRP + data fails. This
  catches any single-character corruption (or larger) with high probability —
  that is what the Bech32m checksum is for.
  **Vector:** `shared-vectors/rvn1/negative/address_bad_checksum.json` — takes
  alice's valid address and flips its final character (`...ule0` →
  `...uleq`), asserting `decode_result: reject`.
- **Wrong HRP.** The human-readable part must be exactly `rvn`. A
  syntactically valid Bech32m string for a *different* namespace (e.g. a
  Bitcoin `bc1...` address) is not a valid `RavenAddressV1` even though its
  own checksum verifies correctly against its own HRP — the HRP check is a
  separate, explicit gate, not implied by checksum validity.
- **Wrong length.** The decoded payload must be exactly 21 bytes (1 version
  byte + 20-byte hash). Anything shorter or longer is rejected regardless of
  checksum validity.

Implementations SHOULD also reject any `version` byte other than `0x01`
(the only value this document family defines), even though the reference
`decode()` returns the version byte to the caller rather than validating it
inline — that check belongs at the call site until a `v2` address format
exists.

## 5. Why alias lookup is discovery, not verification

Resolving an alias (`RAVEN_ALIAS_V1.md`) to a candidate address is
**discovery** — the same role DNS plays for hostnames. It is explicitly **not
verification**: a successful alias lookup proves only that *someone* published
a self-signed record claiming that alias, not that the party you're about to
talk to is who you think they are.

All cryptographic operations bind to the **address** (and, transitively, the
identity and device-certificate material behind it —
[`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md)), never to the alias string.
A resolved alias should be treated as a UI convenience and a starting point —
cross-checked via fingerprint comparison or an out-of-band channel before
being trusted — exactly the way a name in a phone contacts app is not itself
proof of identity. See [`RAVEN_ALIAS_V1.md`](RAVEN_ALIAS_V1.md) §"ambiguity
rule" for what a resolver must do when two identities claim the same alias.

## Reference implementation

`protocol/reference/raven_protocol/address.py`,
`protocol/reference/raven_protocol/bech32m.py`. Vectors:
`shared-vectors/rvn1/address/encode_alice.json`,
`shared-vectors/rvn1/negative/address_bad_checksum.json`.
