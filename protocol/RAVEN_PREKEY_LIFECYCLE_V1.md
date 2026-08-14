# Raven Protected Prekey Lifecycle V1

**Version:** 1

**Status:** implemented in isolated Rust reference code; **production disabled**

**Companions:** [`RAVEN_PREKEY_BUNDLE_V1.md`](RAVEN_PREKEY_BUNDLE_V1.md),
[`RAVEN_PAIR_INIT_V1.md`](RAVEN_PAIR_INIT_V1.md), and
[`ATSAM_INDEXED_SESSION_PROFILE_V1.md`](ATSAM_INDEXED_SESSION_PROFILE_V1.md)

## 1. Scope and non-goals

This contract governs the responder's durable private lifecycle for signed
hybrid prekeys and the atomic claim of a validated `PairInitV1`. It freezes
rotation, distributed one-time-prekey race handling, protected persistence,
crash recovery, root handoff, retirement, and destruction.

It does **not** define or provide the confidential asynchronous PairInit
carrier. PairInit still exposes both addresses and public trust material when
transported directly. This actor has no live endpoint call site and does not
activate RVNA1 protocol `0x03`.

## 2. Protected and public state

The following state MUST exist only in an OS-protected backend:

- signed and one-time X25519 private keys;
- ML-KEM-768 decapsulation seeds;
- accepted-but-not-handed-off provisional roots;
- exact accepted claim keys and bounded replay tombstones; and
- the pending mutation journal, including an exact PairInit wire while a
  claim is being recovered.

Rust's platform contract is:

| Target | Protected backend |
|---|---|
| macOS | Keychain generic-password item |
| GNU/Linux (`glibc`) | Secret Service default collection |
| Windows | DPAPI ciphertext in an fsynced, atomically replaced local file |
| all other targets, including Linux `musl` | fail closed; no private-file fallback |

The protected state permanently binds the actor account to the first
`(identity_ed25519_pub, device_id)` lineage installed for its data-directory
namespace. Every later generation MUST match both fields exactly; an id from a
different responder cannot advance or retire that lineage. The actor's SQLite
file is only a `BEGIN IMMEDIATE` cross-process writer lock.
It MUST contain no private key, root, PairInit wire, identity/device value,
claim identifier, or anomaly subject. SQLite uses WAL and `synchronous=FULL`;
on Unix its file is owner-only mode `0600`.

## 3. Generation installation and rotation

A generation contains one signed X25519 key, one ML-KEM-768 key, and zero or
more one-time X25519 keys. Every signed bundle supplied for a generation MUST:

1. have a valid identity signature and current validity interval;
2. share the exact identity, opaque device id, signed-prekey id, signed X25519
   public key, and ML-KEM encapsulation key;
3. bind either one distinct nonzero OTP id/public key or the single no-OTP
   variant;
4. exactly match the supplied X25519 private keys and ML-KEM seed; and
5. have a lifetime no longer than 30 days.

The signed-prekey id MUST be nonzero and strictly greater than the highest id
ever durably installed. Installing a generation writes a protected rotation
journal first. Recovery retires the prior active generation and installs the
new generation exactly once. A crash before or after the final protected
write cannot roll the monotonic id backward.

Limits are normative for this profile: at most 4 retained generations and 32
signed bundle variants per generation. Rotation fails closed when this bound
would be exceeded; the caller must explicitly run safe expiry pruning first.

## 4. Exact PairInit claim key

Structural/trust/signature validation from `RAVEN_PAIR_INIT_V1.md` occurs
before any claim mutation. PairInit MUST have been valid against its exact
trust records at its signed creation instant, MUST have a lifetime of at most
7 days, MUST have `created_at_ms <= bundle.expires_at_ms`, and MUST still be
unexpired at current acceptance time. A retained generation may therefore
serve a still-valid in-flight PairInit after generation rotation, but retention
grace never extends PairInit's signed expiry. The exact claim key is:

```
(
  responder_identity_ed25519,
  responder_device_ed25519,
  signed_prekey_id,
  one_time_prekey_id,
  init_id,
  init_hash
)
```

The local opaque `claim_id` is SHA-256 over a fixed domain and all fields
above. It is never logged. The collision key for malicious `init_id` reuse is
`(responder identity, responder device, init_id)`:

- exact `init_id + init_hash` duplicate: idempotently return the existing
  pending handoff or completed tombstone;
- same collision key with a different valid signed hash: reject without
  mutation; and
- a different valid signed PairInit that shares the same OTP id: accept as a
  distinct claim, root, and session.

An OTP id alone is never a uniqueness constraint. The latter distributed race
increments only a saturating numeric anomaly counter. Implementations MUST NOT
log or expose identity, device, OTP id, key, transcript, claim, or session
values with that counter.

At most 512 accepted claims/tombstones are retained. New claims fail closed at
the bound; pruning cannot remove a root that is still inside its handoff
window.

## 5. Crash-safe claim and root handoff

Under the cross-process writer lock, acceptance ordering is exactly:

1. reload and recover protected state;
2. validate the full PairInit, exact retained generation and bundle digest;
3. write a protected journal containing the exact signed PairInit wire and
   acceptance time;
4. use the selected retained X25519 private key and ML-KEM seed with the exact
   `PairInitV1` transcript hash and ciphertext;
5. write a protected accepted claim containing the root, session id, replay
   binding, and pending-handoff state while clearing the journal; and
6. return a zeroizing root handoff object.

Recovery deterministically repeats steps 4-5 from the protected journal. It
does not create a second claim, reset session state, or increment the OTP
anomaly for an exact retry.

The session actor MUST durably commit the exact provisional session before it
calls `complete_claim(claim_id)`. Completion clears the lifecycle actor's root
copy and leaves a bounded replay tombstone. Completion and duplicate claims
are idempotent.

The root handoff cannot remain unbounded: its deadline is 24 hours after
durable claim acceptance. Replay tombstones and generation private material
remain independently bounded by bundle expiry plus the 7-day grace. An
explicit prune after the handoff deadline zeroizes an unclaimed root and marks
it abandoned. This is a local failed-bootstrap
outcome, not permission to report message delivery.

## 6. Retirement and destruction

Retirement and destruction are separate explicit operations:

- retirement only marks an active generation retired;
- private material remains retained until every bound bundle is past its
  signed expiry plus the 7-day grace; and
- destruction additionally requires that no accepted claim for the
  generation is still pending durable root handoff.

At the exact deadline material is still retained. Destruction is permitted
only when `now_ms > deadline`. Removing a generation drops and zeroizes its
X25519 and ML-KEM material. Completed/abandoned replay tombstones expire on the
same bounded schedule.

This policy intentionally trades literal immediate OTP destruction for
reliable offline delivery across stale, distributed bundle copies. It does
not silently merge competing sessions and does not retain private material
forever.

## 7. Reference and activation gates

Rust reference: `raven_core::prekey_lifecycle`. It is compiled with
`PREKEY_LIFECYCLE_PRODUCTION_ENABLED == false`, has no live call site, redacts
secret-bearing `Debug`, and is exercised by vector, replay, race, crash,
expiry, corruption, resource, and platform-configuration tests.

Production activation remains blocked on all other PairInit gates, including:

- a confidential asynchronous carrier and relationship-private rendezvous;
- an atomic integration contract with the protected indexed-session actor;
- equivalent Swift protected lifecycle behavior and cross-language state
  transition tests; and
- external protocol/security review.
