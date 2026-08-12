# RAVEN Threat Model — Serverless P2P (Phase A)

**Status:** Current. Supersedes `raven-security/THREAT_MODEL.md`, which is
retained only as a pre-pivot historical snapshot (see the header on that
file).

This document explains, in plain language, what RAVEN is designed to protect
and what it explicitly does not protect, for the serverless peer-to-peer
architecture: no trusted central server, delivery via mesh relays and
untrusted store-and-forward nodes, addressing via a DHT-backed alias layer,
and a single frozen wire object (`RavenEnvelopeV1`) carried unchanged across
every transport.

Honest scope statements are part of the security boundary, not a marketing
afterthought. A verdict of **partially protected** or **out of scope** next
to an adversary is not an admission of failure — it is the document doing
its job. Overclaiming is the actual defect.

Every citation below points at a committed, frozen spec in `protocol/` or a
byte-exact test vector in `shared-vectors/rvn1/`, or at a specific shipped
source file. If a citation and the shipped code ever disagree, the code is
wrong until proven otherwise — see §4.

---

## 1. Assets we protect

RAVEN's serverless design exists to protect:

1. **Message content.** What people say to each other, end-to-end, at rest
   in transit through every relay and store node, no exceptions.
2. **Recipient identity at the relay/store layer.** A relay or store node
   handling an envelope should not learn who it is addressed to.
3. **Nearby-peer discovery privacy.** Who is in radio/network range of whom,
   in the eyes of someone who is not the user's contact.
4. **Long-term content secrecy for opted-in (Vault Mode) messages.** A
   message a user marks Vault Mode should remain confidential against
   future computational advances (including large-scale quantum
   computation), provided the pad conditions are met.

RAVEN does **not** primarily exist to protect:

- The fact that some traffic exists, or its timing/volume/shape.
- A user's identity or data on a device the user has already lost physical
  control over while unlocked.
- Uniqueness of human-readable names (the alias namespace is deliberately
  not globally unique — see §3.13).

---

## 2. How to read the table

Every row below is one of the 17 adversary classes in scope for this
document. **Verdict** is one of:

- **Protected** — a concrete, cited mechanism defeats this adversary for the
  stated goal.
- **Partially protected** — some sub-case is defended with a cited
  mechanism; another sub-case is explicitly out of scope, stated with a
  reason.
- **Out of scope** — RAVEN does not defend against this today. The reason is
  stated, and, where one exists, the future-work item that would change the
  verdict.

| # | Adversary | Verdict | Mechanism / reason |
|---|---|---|---|
| 3.1 | Malicious relay | Protected | Two encryption layers; opaque envelope + rotating tag |
| 3.2 | Malicious store node | Protected | Store-node-cannot-derive routing tag |
| 3.3 | Malicious peer (direct connection) | Partially protected | Envelope pipeline + Noise auth; known pre-validation allocation gap |
| 3.4 | Passive ISP | Partially protected | Transport Noise hides envelope bytes; connection metadata still visible |
| 3.5 | Active MITM | Partially protected | QR pairing + safety number; wrong-person pairing is user's responsibility |
| 3.6 | Stolen locked device | Protected | Hardware-bound Keychain/Secure-Enclave key storage |
| 3.7 | Stolen unlocked device | Out of scope | Endpoint sets the floor |
| 3.8 | Sybil swarm | Partially protected | Peer/store diversity + replication budget; Peer ID ≠ identity; full defense is future work |
| 3.9 | Eclipse attacker | Partially protected | Same mitigations as Sybil; full defense is future work |
| 3.10 | Replay attacker | Protected | message_id dedup + anti_replay_nonce + TTL |
| 3.11 | Spam attacker | Partially protected | Contact-first + message requests + blocking; no central moderation (by design) |
| 3.12 | DHT poisoning | Partially protected | Signed/versioned/expiry-bound/size-limited records |
| 3.13 | Alias impersonation | Protected | Identity-signed alias, monotonic sequence, key-change warning |
| 3.14 | Downgrade attacker | Protected | Signed, authenticated capability negotiation |
| 3.15 | Malformed-packet attacker | Protected | Strict ordered incoming pipeline, reject-before-crypto |
| 3.16 | Local malware | Out of scope | Endpoint sets the floor |
| 3.17 | Traffic analyst | Out of scope | Explicit non-goal of the routing-tag design; future work |

---

## 3. Adversary detail

### 3.1 Malicious relay

**Can do:** Run a mesh (BLE) or bridge (libp2p) relay node and forward
`RavenEnvelopeV1` traffic between strangers, with no trust relationship to
either party.

**Verdict: Protected.**

**Why:** RAVEN uses two independent encryption layers. Message content is
sealed by the recipient's session key before it ever reaches a relay
(`protocol/RAVEN_ENVELOPE_V1.md` §5, "No plaintext identities on the wire");
the recipient locator carried alongside it is not a stable identifier but a
rotating HMAC tag (`protocol/RAVEN_ROUTING_TAG_V1.md` §1–2) that changes
every message. A relay sees only `message_id` (meaningless CSPRNG),
`routing_tag` (rotates, unlinkable without `K_route`), and two opaque
ciphertext blobs. It cannot decrypt, cannot determine whether two envelopes
it has forwarded belong to the same conversation, and cannot forge
authorship: every immutable field is bound into the Ed25519 signature over
`signing_bytes` (`protocol/RAVEN_ENVELOPE_V1.md` §2), so a relay tampering
with `message_ciphertext` produces a signature that fails verification
(vector: `shared-vectors/rvn1/negative/envelope_tampered_body.json`,
`verify_result: reject`). A malicious relay also cannot forge a delivery
receipt on the recipient's behalf: `RavenAckV1` carries its own signature
under the acknowledging device's key, checked independently of the outer
envelope (`protocol/RAVEN_ACK_V1.md` §2; vector:
`shared-vectors/rvn1/negative/ack_wrong_signer.json`,
`verify_result: reject`).

**What still leaks:** Envelope size and forwarding timestamp at that relay.
That is a traffic-analysis question, addressed (and scoped out) at §3.17.

### 3.2 Malicious store node

**Can do:** Operate an offline-store relay that holds envelopes for
recipients who are not currently reachable, and inspect or tamper with
whatever it stores.

**Verdict: Protected.**

**Why:** A store node is architecturally the same untrusted party as a
relay (§3.1) — it never receives `K_route`, which lives only in the two
endpoints' key trees. `protocol/RAVEN_ROUTING_TAG_V1.md` §3 states this as a
design invariant: a store node can index and re-serve envelopes by the tag
bytes it observed, and recognize a previously-seen tag by byte equality, but
it can never compute the next tag in a sequence, confirm two different tags
belong to the same conversation, or map a tag back to an identity. Vector
`shared-vectors/rvn1/routing/tag_unlinkable_001.json` demonstrates that two
tags derived from the same `K_route` at adjacent counters are structurally
unrelated byte strings. Content and authentication protections are
identical to §3.1.

**What still leaks:** Same as §3.1 — size/timing at the store node, and how
long an envelope sat there before being claimed (queue-depth side channel).
Not separately defended in V1.

### 3.3 Malicious peer (direct connection)

**Can do:** Open a direct libp2p stream or BLE GATT connection to a node
without being an authorized contact, and send it arbitrary bytes.

**Verdict: Partially protected.**

**Why (protected sub-case):** Once a frame reaches the envelope pipeline,
every stage before decrypt is a rejection gate a malicious peer cannot
bypass: size → decode → version → structure → dedup → replay → TTL →
hop/replication → tag/session → authenticate → decrypt, in that order
(`protocol/RAVEN_ENVELOPE_V1.md` §6). A peer cannot get content decrypted or
persisted without passing signature authentication first; a peer without a
recognized session or the counterpart's private key cannot forge that
signature.

**Why (gap, explicitly acknowledged in the spec itself):**
`protocol/RAVEN_ENVELOPE_V1.md` §4 documents a known issue: the shipped
`ios-native/RAVEN/Libp2pBridge/bridge.go` checks a peer-declared length
prefix against the 24 MiB ceiling and then immediately allocates a buffer of
that full claimed length (`bridge.go:242-245`, `env := make([]byte, envLen)`)
**before** running any of the size→decode→version→structure checks above. A
malicious peer can open many concurrent streams each declaring a length near
24 MiB, forcing large allocations ahead of validation — a memory-exhaustion
vector distinct from, and not fixed by, the per-frame ceiling. This is
explicitly flagged as a Phase B fix, not something already closed.

### 3.4 Passive ISP

**Can do:** Observe all traffic between a device and the internet — e.g. a
network operator, an ISP, or a Wi-Fi hotspot operator — for internet-bridge
(libp2p) traffic.

**Verdict: Partially protected.**

**Why (protected sub-case):** The libp2p bridge host is configured with
`libp2p.DefaultSecurity` (Noise + TLS transport security) —
`ios-native/RAVEN/Libp2pBridge/bridge.go:135`. This means an on-path ISP
sees an encrypted transport stream, not `RavenEnvelopeV1` bytes in the
clear: it cannot read the routing tag, the ciphertext, or the magic bytes
without breaking the transport-layer Noise handshake. This is on top of, and
independent from, the message-level E2EE described in §3.1 — two layers, as
stated in §1's asset list.

**Why (out-of-scope sub-case):** Transport encryption hides *content*, not
*shape*. An ISP still observes which IP addresses a device connects to, at
what times, for how long, and how many bytes flow. `protocol/
RAVEN_ROUTING_TAG_V1.md` §4 states this explicitly as a non-goal: routing
tags resist linkage at the tag-value layer, not global traffic analysis.
Defeating this requires cover traffic / padding / timing obfuscation, which
is future work (the `coverTraffic` capability bit referenced in
`protocol/RAVEN_CAPABILITIES_V1.md` is a placeholder for this, not a shipped
defense). See §3.17.

### 3.5 Active MITM

**Can do:** Sit on the network path during pairing or session setup and
attempt to substitute their own key material for a legitimate contact's.

**Verdict: Partially protected.**

**Why (protected sub-case):** Pairing exchanges the two devices' static
public key material via an out-of-band channel — a QR code scanned in
person (`ios-native/RAVEN/RAVEN/Features/Settings/PairingView.swift`) rather
than over the network path an attacker controls — and produces a hybrid
X25519 + ML-KEM-768 shared root (`ios-native/RAVEN/RAVEN/Core/Security/
ATSAM/ATSAMHybridPairing.swift`). Every subsequent envelope from that
identity is signature-bound (`protocol/RAVEN_ENVELOPE_V1.md` §2); a network
MITM without the private key cannot forge a message that verifies. Protocol
feature/capability negotiation is likewise signed
(`protocol/RAVEN_CAPABILITIES_V1.md` §2), so an on-path attacker cannot flip
an unsigned bit to force a weaker mode — closing the specific gap the legacy
unsigned BLE `Capabilities` advertisement had (§3.14). Contacts also have a
human-comparable safety number for a manual "did the key change?" check
(`ios-native/RAVEN/RAVEN/Features/Settings/SafetyNumberView.swift`;
fingerprint scheme defined in `protocol/RAVEN_IDENTITY_V1.md` §3).

**Why (user-responsibility sub-case):** Cryptographic pairing verifies "the
key I now hold matches the key the other device holds" — it cannot verify
"the human on the other end is who I think they are." An attacker who
successfully impersonates a contact during the in-person QR exchange itself
(e.g. a fake QR code, a compromised video-call impersonation) defeats
pairing at the human layer, not the cryptographic layer. This is explicitly
the user's responsibility, matching the pre-pivot model's §3.4. We also note
`SafetyNumberView.swift`'s own comment marks automated QR-based safety
number re-verification as a TODO; today the safety-number check is a manual
compare-in-person-or-by-call flow, not an automated re-scan.

### 3.6 Stolen locked device

**Can do:** Gain physical possession of a device that is powered on but
locked (passcode/biometric not entered).

**Verdict: Protected.**

**Why:** Per-peer ATSAM root keys are Keychain-backed, not stored in
UserDefaults or any world-readable location
(`ios-native/RAVEN/RAVEN/Core/Security/ATSAM/ATSAMRootStorage.swift:5-16`,
"Per-peer storage for hybrid (X25519 + ML-KEM-768) ATSAM root keys ...
Keychain-backed so the root survives app restart AND device reboot ...
Keychain at-rest protection limits exposure"). The ML-KEM-768 decapsulation
key material is generated and can be held via Secure Enclave-backed storage
(`ios-native/RAVEN/RAVEN/Core/Security/ATSAM/ATSAMMLKem.swift:19`,
`SecureEnclave.MLKEM768.PrivateKey`). iOS Keychain/Secure Enclave protection
classes tie key availability to the device being unlocked, so a locked,
powered device does not expose key material to extraction.

**What still leaks:** Nothing beyond what the OS lock screen itself exposes
(notification previews, if enabled at the OS level — an OS/UX setting, not
a RAVEN protocol property).

### 3.7 Stolen unlocked device

**Can do:** Gain physical possession of a device that is unlocked, or
compel the owner to unlock it.

**Verdict: Out of scope.**

**Why:** Once an attacker holds an unlocked device, they can read anything
the legitimate user's UI can display, and any key material Keychain
protection classes release for an unlocked device. No protocol-level
mechanism can distinguish "the legitimate user is looking at this screen"
from "an attacker is looking at this screen." This mirrors the pre-pivot
model's §3.6 (coercion/lawful access) — the floor is set by the endpoint's
OS-level unlock security, not by RAVEN.

### 3.8 Sybil swarm

**Can do:** Create a large number of cheap, independently-addressed peer
identities and use them to dominate a target's connection slots, routing
table, or store-node selection.

**Verdict: Partially protected.**

**Why (protected sub-case):** Two structural mitigations exist. First, the
envelope carries an explicit `replication_budget` field, decremented on
each hop and required to stay above zero for a relay to keep forwarding
(`protocol/RAVEN_ENVELOPE_V1.md` byte layout, offset 65; incoming pipeline
step 8), which bounds how much any single hostile relay path can affect
overall delivery by capping fan-out rather than depending on any one node's
honesty. Second, `hop_limit` (offset 64) independently bounds propagation
depth.

**Why (out-of-scope sub-case, stated honestly):** RAVEN does not yet
implement peer scoring, per-remote connection-count limits, or diverse
peer/store selection policy that would make a Sybil swarm's cost outweigh
its benefit — no such mechanism exists in the codebase as of this document.
A libp2p Peer ID is a hash of a locally-generated keypair, not an
authenticated identity; nothing prevents an adversary from generating many
Peer IDs cheaply. Full Sybil resistance (peer reputation, resource-bound
identity issuance, or a trusted bootstrap set) is future work, tracked
alongside the DHT hardening in §3.12.

### 3.9 Eclipse attacker

**Can do:** Surround a target node with adversary-controlled peers so that
all of the target's DHT/mesh connections go through the attacker, enabling
selective censorship or feeding the target a manipulated view of the
network (e.g. poisoned alias records, withheld envelopes).

**Verdict: Partially protected.**

**Why:** The same structural bounds as §3.8 (`hop_limit`,
`replication_budget`) limit what a single controlled path can suppress
end-to-end for any one message, since a sender's envelope is not required
to route through only one peer relationship to reach a store node. But
RAVEN does not yet implement diverse/independent peer selection,
connection-count limits per subnet, or any other structural defense
specifically against eclipse positioning — this is the same gap as §3.8,
under a different attack goal (isolate rather than merely flood). We are
not claiming a defense that does not exist; full eclipse resistance is
future work.

### 3.10 Replay attacker

**Can do:** Capture a valid, signed envelope and resend it later, hoping to
cause duplicate delivery or reuse of stale state.

**Verdict: Protected.**

**Why:** The incoming pipeline enforces three independent layers before an
envelope can be committed (`protocol/RAVEN_ENVELOPE_V1.md` §6, steps 5–7):
`message_id` dedup against a bounded recently-seen set (silently drops exact
repeats); `anti_replay_nonce` checked against a per-sender/per-tag replay
window (catches a captured-and-resent ciphertext even if `message_id` were
altered); and `expires_at` TTL enforcement, dropped past expiry (vector:
`shared-vectors/rvn1/negative/envelope_expired.json`,
`relay_action: drop`). ACKs get the same protection at the application
layer on top of envelope-level dedup: a repeat `status=1`/`status=2` ack for
a message already at that state is a no-op, so a replayed ack cannot
re-trigger a "message read" notification (`protocol/RAVEN_ACK_V1.md` §4).

### 3.11 Spam attacker

**Can do:** Send unsolicited messages or connection/pairing attempts to
users who have not established a relationship with the sender.

**Verdict: Partially protected.**

**Why:** RAVEN's serverless design is contact-first: an unknown sender's
first message surfaces as a message request rather than landing directly in
an established conversation, and a recipient can block a contact or remove
them (removing per-pair key material — see the "swipe-to-remove a contact"
serverless key cleanup shipped in this branch). This raises the cost of
unsolicited contact relative to an open, discoverable inbox.

**Why not fully protected, stated plainly:** There is no central,
cross-user moderation layer, no shared spam-reputation service, and no
network-wide rate limiter — because there is no central operator to run
one. This is not an oversight; it is the direct, honest cost of removing
the central server. A traditional centralized messenger's server is
simultaneously its metadata-collection risk *and* an implicit anti-spam/
anti-abuse chokepoint (it can globally rate-limit an account, ban a
fingerprint, or throttle a sender across all recipients at once).
Decentralizing removes both at the same time. Per-identity local rate
limiting and per-contact blocking are local, per-recipient defenses, not a
network-wide one — a spammer blocked by one recipient is not thereby
blocked anywhere else.

### 3.12 DHT poisoning

**Can do:** Inject false, stale, or oversized records into the DHT used for
alias resolution, attempting to redirect lookups, exhaust store capacity, or
squat abandoned names.

**Verdict: Partially protected.**

**Why:** `protocol/RAVEN_ALIAS_V1.md` §4 requires every published alias
record to satisfy four constraints simultaneously: **signed** (unsigned
records are discarded on receipt — nothing else binds the claim to an
identity); **versioned** (`sequence` is the version; replacement in the
store is keyed by `(alias, identity_address)` with last-write-wins by
`sequence`, never by receipt order, because receipt order is not
trustworthy in a store with multiple untrusted writers); **expiry-bound**
(a resolver treats a record as absent past `expires_at`, preventing
indefinite squatting of an abandoned name); and **size-limited** (both
variable-length fields are length-prefixed, and a store SHOULD impose a
practical cap well below the 65,535-byte theoretical ceiling, since nothing
resembling a human-typed alias needs to approach it). A stale-record replay
specifically is covered by the same monotonic-sequence rule as §3.13 (vector
`shared-vectors/rvn1/negative/alias_stale_sequence.json`).

**What is not yet covered:** Broader DHT-level resistance — e.g. an
adversary who controls enough of the DHT's keyspace neighborhood to
withhold or selectively serve records regardless of their validity (a
Kademlia-style routing attack, closely related to §3.8/§3.9) — is future
work, not addressed by record-level signing alone.

### 3.13 Alias impersonation

**Can do:** Attempt to claim, hijack, or roll back a human-readable alias
that legitimately belongs to someone else.

**Verdict: Protected.**

**Why:** Every alias record is self-signed by the identity it claims to
belong to — signed by `identity_address`'s own Ed25519 identity key over
domain-separated bytes (`protocol/RAVEN_ALIAS_V1.md` §1) — so an attacker
without that private key cannot forge a claim for someone else's address. A
captured, validly-signed *older* record cannot be replayed to roll an alias
back: a verifier holding a record at `sequence=N` for an alias must reject
any incoming record for the same alias/identity with `sequence <= N`, even
if validly signed (`protocol/RAVEN_ALIAS_V1.md` §2; vector:
`shared-vectors/rvn1/negative/alias_stale_sequence.json`,
`resolver_action: reject_stale`). When a lookup for a previously-resolved
alias returns a *different* address than last seen and pinned, the spec
requires surfacing a key-change warning before delivering to or trusting
the new identity — treated with the same severity as a contact's
fingerprint changing (`protocol/RAVEN_ALIAS_V1.md` §3, cross-referencing
`protocol/RAVEN_IDENTITY_V1.md` §3). Conflicting live claims for the same
alias string (a namespace-ambiguity case, not impersonation of a specific
identity — the namespace has no registrar and is not unique by design) MUST
be surfaced as ambiguous, never silently resolved by a predictable
tie-break, since a predictable tie-break is itself attacker-exploitable.

### 3.14 Downgrade attacker

**Can do:** Sit on-path or control a relay and attempt to force two peers
into negotiating a weaker capability set than both actually support (e.g.
stripping a post-quantum-hybrid or delivery-authentication bit).

**Verdict: Protected.**

**Why:** `protocol/RAVEN_CAPABILITIES_V1.md` replaces the legacy unsigned
BLE `Capabilities` advertisement — which any on-path relay could read or
alter without either side detecting it (§2, citing
`ios-native/RAVEN/RAVEN/Core/Mesh/RUMProtocolV2.swift:155-218`) — with a
self-signed, identity-bound, time-bound record. A verifier caches the
freshest signed capability set seen for a given identity and refuses to
silently accept a lower-capability claim unless that claim is itself
freshly signed and unexpired (§3): an attacker cannot replay an old,
validly-signed, lower-capability record once its `expires_at_ms` has
passed, and cannot forge a new one without the identity's private key.

**Scope note carried forward honestly:** V1's capability record has no
monotonic sequence field (unlike alias records) — freshness relies on
`expires_at_ms` alone. Two differently-signed records with *overlapping*
validity windows have no defined tie-break in V1; the spec recommends
negotiating to the intersection of claimed bits until a future version adds
a sequence field. This is a stated scope gap, not a vector-backed guarantee.

### 3.15 Malformed-packet attacker

**Can do:** Send a structurally invalid, truncated, oversized, or
field-tampered `RavenEnvelopeV1` frame to a peer, relay, or store node.

**Verdict: Protected.**

**Why:** `protocol/RAVEN_ENVELOPE_V1.md` §6 mandates a strict, ordered
incoming pipeline — size → decode → version → structure → dedup → replay →
TTL → hop/replication → tag/session → **authenticate** → decrypt → commit →
ACK — where every stage before `authenticate` either passes a
structurally-valid frame forward or drops it, and nothing reaches session/
crypto logic before authentication succeeds. A zeroed magic byte is
rejected at decode (vector:
`shared-vectors/rvn1/negative/envelope_bad_magic.json`,
`unpack_result: reject`); a body altered after signing fails at the
authenticate stage because the appended `SHA-256(message_ciphertext)` no
longer matches what was signed (vector:
`shared-vectors/rvn1/negative/envelope_tampered_body.json`,
`verify_result: reject`); an expired envelope is dropped at the TTL stage
before authentication is even attempted (vector:
`shared-vectors/rvn1/negative/envelope_expired.json`,
`relay_action: drop`).

**Related but distinct gap:** a malformed *length prefix* specifically (as
opposed to a malformed envelope body) intersects with the bridge
allocate-before-validate issue described under §3.3 — that is a resource-
exhaustion concern about validation *order* at the transport layer, not a
case where a malformed envelope is incorrectly accepted.

### 3.16 Local malware

**Can do:** Run arbitrary code with the legitimate user's OS-level
privileges on the user's own device — a jailbreak, a malicious app with
excessive permissions, or a supply-chain-compromised dependency.

**Verdict: Out of scope.**

**Why:** Once an attacker can execute code as the user, they can read
whatever the app can read, including decrypted plaintext and any key
material the OS releases to a running, authorized process. No
application-layer protocol can defend against a fully compromised endpoint
— this is the same floor as §3.7, restated for a software rather than
physical attack vector. Endpoint integrity (OS sandboxing, code signing,
jailbreak detection) is the user's and the OS vendor's responsibility, not
a RAVEN protocol guarantee.

### 3.17 Traffic analyst

**Can do:** Observe connection metadata — who connects to whom, when, how
often, and how much data flows — across relays, store nodes, or the
internet bridge, without necessarily controlling any of them, and correlate
that shape over time.

**Verdict: Out of scope for V1.**

**Why:** `protocol/RAVEN_ROUTING_TAG_V1.md` §4 states this as an explicit
non-goal: routing tags resist linkage *at the tag-value layer* — an
observer cannot tell from tag bytes alone that two envelopes share a
recipient — but they do not resist *global traffic analysis*. An adversary
watching timing, volume, envelope size, and network position across the
system can still correlate flows through side channels the tag design does
not touch (e.g. "an envelope of size X leaves peer A one hop before an
envelope of similar size arrives at peer B"). This is the same underlying
gap named in §3.4 (passive ISP) and §3.8/§3.9 (Sybil/eclipse positioning
enabling better vantage points for exactly this kind of correlation).
Closing it requires cover traffic, batching, or timing obfuscation; the
`coverTraffic` capability bit referenced in
`protocol/RAVEN_CAPABILITIES_V1.md` exists as a negotiation placeholder for
this future work, not a shipped defense today.

---

## 4. How we treat this document

This file is part of the security boundary, not marketing copy, carrying
forward the same posture as its pre-pivot predecessor.

If a finding shows that a claim in this document does not match the
behavior of the shipped protocol or app, we will:

1. Fix the document to match reality first.
2. Then fix the implementation.
3. Acknowledge the gap publicly.

In that order. An outdated "protected" claim that no longer matches shipped
behavior is a more serious defect than an honestly-stated gap — fix the
claim before anyone relies on it.

Every **protected** or **partially protected** verdict above cites either a
frozen `protocol/*.md` section, a specific `shared-vectors/rvn1/` vector
file, or a specific shipped source file and line. Every **out of scope**
verdict states its reason. If a future change to `protocol/` or the shipped
apps invalidates a citation here, update this document in the same change —
do not let the citations drift from what is actually running.
