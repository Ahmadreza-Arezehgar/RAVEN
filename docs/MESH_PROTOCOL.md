# RAVEN Mesh Wire-Protocol Specification

**Version:** 1 (matches iOS app v1.5)
**Status:** Single source of truth. Any deviation = interop failure.
**Audience:** anyone re-implementing the RAVEN mesh in another language (C# on Windows, Kotlin on Android, Rust, etc.).

> **Important:** This document describes the protocol **as currently shipped on iOS/Mac**. Several known quirks and bugs are surfaced in §I — read those before writing a port. Bug fixes that change the wire format must be coordinated as a `v2` upgrade (or the iOS app must keep `v1` compatibility).

---

## A. GATT spec

### Service UUID

```
12345678-1234-1234-1234-123456789ABC
```

This is the **fixed** RAVEN service UUID — same on iOS, macOS, and any other RAVEN port. A device discovered with this service UUID is a RAVEN peer.

### Characteristics

| UUID | Role | Properties | Permissions | Value |
|------|------|------------|-------------|-------|
| `12345678-1234-1234-1234-123456789ABD` | Message TX/RX | `notify`, `write`, `writeWithoutResponse` | readable + writeable | nil at advertise time |
| `12345678-1234-1234-1234-123456789ABE` | Device-info read | `read` | readable | UTF-8 of local fingerprint string |

- iOS uses both `.write` and `.writeWithoutResponse`; outgoing peripheral writes use `.withoutResponse` for flow control.
- Centrals receive frames via GATT `notify` (i.e. `updateValue(_:for:onSubscribedCentrals:)` from the peripheral side).

### Advertisement payload

```
CBAdvertisementDataServiceUUIDsKey = [serviceUUID]
CBAdvertisementDataLocalNameKey   = "RAVEN-<first8charsOfDeviceFingerprint>"
```

- No manufacturer data, no service data.
- Peer device-id is parsed from the LocalName by stripping the `RAVEN-` prefix.
- The fingerprint is the formatted string (see §D); the first 8 chars of that string go into the name.

### MTU expectations

- Per-packet payload size is computed dynamically:
  - Peripheral→central writes: `peripheral.maximumWriteValueLength(for: .withoutResponse) − 6 (header) − 1 (chunk-flag)`, floored to 20.
  - Peripheral→central notifies: `central.maximumUpdateValueLength − 1 (chunk-flag)`, floored to 20.
- Default fallback when peripheral is nil: 180 bytes.

### Scan options

- iOS: `CBCentralManagerScanOptionAllowDuplicatesKey = false`.
- Restoration identifiers: central=`com.raven.ble.central.restore`, peripheral=`com.raven.ble.peripheral.restore`.

---

## B. Wire frame format

Two layers stacked. Bottom is a binary fragmentation header; top is JSON.

### Fragmentation / chunk layer

Every BLE write/notify packet is prefixed with **1 flag byte**:

- `0x00` = unchunked; the rest of the packet is the JSON payload as-is.
- `0x01` = chunked; followed by a 6-byte header, then the chunk payload bytes.

Chunked header (offsets after the leading `0x01` flag byte):

| Offset | Size | Field | Encoding |
|--------|------|-------|----------|
| 0 | 4 | `messageHash` | `UInt32`, **little-endian** |
| 4 | 1 | `totalChunks` | `UInt8`, range 1–255 |
| 5 | 1 | `chunkIndex` | `UInt8`, 0-based |
| 6 | N | chunk payload | raw bytes of the JSON slice |

Constants:
- `headerSize = 6`
- `maxTotalChunks = 255`
- `maxPendingHashKeys = 64`

Reassembly key is `"<senderDeviceId>-<messageHash>"`. Reassembly buffer per `(peer, hash)`; flushed when all `totalChunks` have arrived. Stale reassembly buffers are GC'd after **30 seconds**.

> **⚠️ INTEROP-CRITICAL:** `messageHash` on iOS is `UInt32(truncatingIfNeeded: data.hashValue)` of the entire pre-chunk JSON. Swift's `Data.hashValue` is **per-process random-seeded** — it is NOT a stable cross-platform hash. A C# port MUST NOT recompute and validate it; treat it as an opaque chunk-group key per sender. When sending from C#, generate any 32-bit value (e.g. `Random` or first 4 bytes of `SHA-256(payload)`) and keep it constant across all chunks of one message.

Inter-chunk pacing: 15 ms sleep between sends. Up to 15 retries on `updateValue` returning false.

### Top-layer JSON

Every defragmented payload is a UTF-8 JSON object (`JSONEncoder` default ordering, **except** canonical-signed envelopes which use `.sortedKeys`).

Receiver dispatches on the presence of distinguishing keys:

| Detected key(s) | Frame type |
|---|---|
| `mk` | `MeshMessageFrame<P>` (feature frames) |
| `kind == "server_receipt_v1"` | server-receipt gossip |
| `k == "inv_bloom_v1"` | inventory Bloom |
| `k == "want_v1"` | want list |
| `k == "mesh_post_v1"` | post envelope |
| `type == "STOP"` | stop command |
| `isACK` present OR `status` present | ACK envelope |
| `c` and `spk` present | encrypted DM payload |
| `e` and `s` and `spk` present | signed (unencrypted) DM payload |

---

## C. Envelope JSON schemas

All field names below are the JSON keys actually on the wire (the short `CodingKeys` from Swift).

### C.1 `SignedMeshPayload` (DM, signed, unencrypted)

Top-level keys:

| JSON key | Type | Req | Meaning |
|---|---|---|---|
| `e` | object | yes | `SecureMeshEnvelope` (see below) |
| `s` | string | yes | base64 Ed25519 signature over `SecureMeshEnvelope.signingData()` |
| `spk` | string | yes | base64 Ed25519 public key of signer |
| `os` | string | optional | base64 original-sender signature (preserved across relays) |
| `ospk` | string | optional | base64 original-sender public key |

`SecureMeshEnvelope` (the `e` value):

| JSON key | Type | Req | Meaning |
|---|---|---|---|
| `id` | string | yes | clientMessageId (UUID) |
| `rm` | string | yes | roomId |
| `sid` | string | yes | senderId (userId) |
| `sn` | string | yes | senderName (may already be encrypted; UI sanitizes) |
| `rid` | string | yes | recipientId (userId or groupId) |
| `t` | int | yes | message type — see C.7 |
| `txt` | string | optional | text or AES-GCM ciphertext if `gkv` set |
| `ts` | number | yes | Unix timestamp seconds (double) |
| `sc` | int | yes | sprayCounter (Binary Spray remaining) |
| `hc` | int | yes | hopCount |
| `hl` | int | yes | hopLimit |
| `rp` | array<string> | yes | routePath of device fingerprints |
| `od` | string | yes | originDeviceId (origin's fingerprint) |
| `nf` | bool | yes | needsForwarding |
| `ttl` | int | yes | ttlSeconds |
| `n` | string | yes | base64 16-byte random envelope-instance nonce |
| `spk` | string | yes | sender's Ed25519 public key, base64 (envelope-internal) |
| `mu`, `tu`, `fn`, `mt`, `fs`, `ad` | str/str/str/str/int/int | optional | media: url / thumb / filename / mime / fileSize / audioDuration |
| `rtid`, `rttp`, `rtsn` | string | optional | reply context |
| `ib` | bool | optional | isBridged (server→BLE bridge) |
| `ig` | bool | optional | isGroup |
| `gf` | object | optional | GeoFence `{h3Cell, radiusInCells, deliverOnlyInside}` (signed) |

> The outer in-app `MeshEnvelope` struct also defines `gkv` (group-key version), but `SecureMeshEnvelope.CodingKeys` does NOT include it. **Known bug** — see §I.

### C.2 `EncryptedMeshPayload` (DM, encrypted)

| JSON key | Type | Req | Meaning |
|---|---|---|---|
| `c` | string | yes | base64 AES-256-GCM combined output (`nonce(12) ‖ ciphertext ‖ tag(16)`) |
| `n` | string | yes | base64 12-byte nonce — duplicated for dedup; receiver must use the **authentic** nonce embedded in `c` for replay tracking |
| `spk` | string | yes | sender's **X25519** agreement public key, base64 (used for ECDH) |
| `v` | int | yes | protocol version, currently `1` |
| `s` | string | optional | base64 Ed25519 signature over the embedded `SecureMeshEnvelope.signingData()` |
| `ssk` | string | optional | base64 **Ed25519** signer public key |

Plaintext inside the AES-GCM seal is the JSON of a `SecureMeshEnvelope` encoded with `.sortedKeys`.

### C.3 `MeshPostEnvelope` (broadcast post)

| JSON key | Type | Req | Meaning |
|---|---|---|---|
| `k` | string | yes | constant `"mesh_post_v1"` (frame discriminator) |
| `pid` | string | yes | postId (UUID) |
| `aid` | string | yes | authorId |
| `aun` | string | yes | authorUsername |
| `aav` | string | optional | authorAvatar URL |
| `ca` | number | yes | createdAt Unix seconds |
| `sc` | string | yes | scope: `"local"` \| `"friends"` \| `"public"` |
| `txt` | string | yes | post body (text only) |
| `th` | int | yes | ttlHops |
| `ts` | int | yes | ttlSeconds |
| `hc` | int | yes | hopCount |
| `rp` | array<string> | yes | routePath |
| `od` | string | yes | originDeviceId |
| `is` | string | yes | initialSend: `"internet"` \| `"mesh"` |
| `sig` | string | optional | Ed25519 signature, base64 |
| `spk` | string | optional | signer Ed25519 public key, base64 |
| `rs` | bool | optional | showOnRavenShot opt-in |
| `lat`, `lng` | number | optional | author coordinates (only when `rs` true) |

**Signing bytes** (UTF-8):

```
POST | postId | authorId | authorUsername | authorAvatar | text | <Int64 round(ca*1000)> | scope | signerPublicKey
```

- Literal pipe `|` (`0x7C`) delimiter.
- Missing optional `authorAvatar` and `signerPublicKey` are emitted as **empty** between delimiters (i.e. two pipes adjacent).

### C.4 `MeshACKEnvelope` (ACK)

| JSON key | Type | Req | Meaning |
|---|---|---|---|
| `originalMessageId` | string | yes | the DM being acknowledged |
| `senderId` | string | yes | the receiver of the original message (= ACK author) |
| `recipientId` | string | yes | the original sender (target of ACK) |
| `status` | string | yes | `"delivered"` or `"read"` |
| `timestamp` | number | yes | Unix seconds (double) |
| `pathUsed` | string | optional | `"server"` \| `"mesh"` \| `"mesh-bridge"` |
| `hopCount` | int | yes (default 0) | |
| `hopLimit` | int | yes (default `meshHopLimit`) | |
| `routePath` | array<string> | yes | |
| `originDeviceId` | string | yes | |
| `isACK` | bool | yes | always `true` |
| `signature` | string | yes (after `sign()`) | base64 Ed25519 |
| `signerPublicKey` | string | yes | base64 Ed25519 |

ACKs use **long camelCase** field names (no short codes), unlike DM/Post.
Unsigned ACKs are dropped at the receiver.

**Signing bytes** (UTF-8):

```
originalMessageId | senderId | recipientId | status | <Int64 round(timestamp*1000)>
```

ACK relay key for dedup: `"<originalMessageId>|<senderId>|<recipientId>|<status>"`.
Dedup id stored as `"ack:<relayKey>"`.

Relay rule: when forwarded, hopCount++, append device to routePath, **preserve original signature/signerPublicKey** (relays do not re-sign).

### C.5 `StopCommand`

| JSON key | Type | Req | Meaning |
|---|---|---|---|
| `type` | string | yes | constant `"STOP"` |
| `messageId` | string | yes | clientMessageId being stopped |
| `timestamp` | number | yes | Unix seconds |
| `signature` | string | yes | base64 Ed25519 |
| `signerPublicKey` | string | yes | base64 Ed25519 |

**Signing bytes** (UTF-8):

```
STOP | messageId | <Int64 round(timestamp*1000)>
```

Unsigned/invalid stops are dropped.

### C.6 `MeshMessageFrame<P>` (feature frames)

JSON keys: `mk`, `p`, `sid`, `mid`, `hc`, `hl`, `sc`, `ts` (`Int64` ms), `rp`, `ttl`, `s`, `spk`.

Signing uses **JSON-canonical** form: serialize the entire JSON object with `JSONSerialization` `options: [.sortedKeys]`, then **remove keys `s` and `spk`**, then UTF-8 the result. Sign that. (See §D.)

Dedup id: `"frame:<mid>"`.

### C.7 Message type integers

```
0 = text        (mesh-allowed)
1 = image
2 = file
3 = voice
4 = location    (mesh-allowed)
5 = postShare
6 = system      (mesh-allowed)
7 = video
8 = videoNote
9 = ephemeralPhoto
```

`enqueueForBroadcast` only allows types `{0, 4, 6}` for BLE (media is too big for mesh and waits for internet).

---

## D. Cryptography

### Identity keypairs

Two **separate** keypairs per device, generated and stored in iOS Keychain (Windows port: use Credential Manager + DPAPI or a SQLCipher-encrypted blob):

- **Ed25519** (signing) — Apple's `Curve25519.Signing.PrivateKey/PublicKey`.
  - Wire format for public key: `rawRepresentation` (32 bytes raw), base64-encoded.
- **X25519** (key agreement) — Apple's `Curve25519.KeyAgreement.PrivateKey/PublicKey`.
  - Wire format: same — raw 32 bytes, base64.

Keychain tags (iOS only; Windows uses different storage):
- `app.raven.device.privatekey` — Ed25519 priv
- `app.raven.device.publickey` — Ed25519 pub
- `app.raven.device.agreement.privatekey` — X25519 priv
- `app.raven.device.agreement.publickey` — X25519 pub

Accessibility on iOS: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

Keys generated lazily on first launch.

### Fingerprint (device identifier)

```
fp = SHA256(EdPub.rawBytes).first(9 bytes).base64
fp = strip '+' and '/' from fp, truncate to 12 chars
fp = insert '-' every 4 chars  →  "XXXX-XXXX-XXXX"
```

Used in `routePath`, `originDeviceId`, BLE LocalName prefix, etc.

### Key rotation

- 24 h grace window (`rotationGraceWindowSeconds = 86400`).
- Old pubkey kept in `prev*` slots.
- New pubkey is **attested** by signing `(newPub ‖ 8-byte LE float64 of nowEpoch)` with the OLD privkey.

### ECDH

```
sharedSecret = X25519(myPriv, peerPub)
key = HKDF-SHA-256(
  ikm:    sharedSecret,
  salt:   "RAVEN-MESH" (UTF-8, 10 bytes),
  info:   <empty>,
  length: 32 bytes,
)
```

The result is the **AES-256-GCM key**. Derived secrets are cached per peer pubkey (capped 1000 entries) and cleared when our own agreement key is rotated.

> **Forward-secrecy gap:** the same X25519 key is used forever; the salt is constant. Compromise of the agreement private key allows retroactive decryption of every message ever exchanged. Future protocol versions should add a per-session ephemeral key (Double Ratchet) — see §I.

### AES-GCM (encrypted DMs)

- Apple `AES.GCM.seal(...)` defaults.
- Nonce length: **12 bytes**, `SecRandomCopyBytes`.
- Tag length: **16 bytes** (Apple default).
- AAD: **empty** (no `authenticating:` argument).
- Combined output: `nonce(12) ‖ ciphertext ‖ tag(16)`. The `c` JSON field carries the entire combined blob, base64.
- The `n` JSON field is the standalone nonce (also base64); it is **untrusted** for replay tracking — receivers MUST extract the authentic nonce from inside the sealed box.
- Plaintext: `JSONEncoder` with `.sortedKeys` over `SecureMeshEnvelope`.

### Ed25519 signing — **three different signing rules**

Beware: this protocol uses three distinct "what is signed" formulations. Implementations must follow the right one per envelope type.

#### Rule 1 — DM (`SecureMeshEnvelope`) — explicit canonical pipe form

UTF-8 of pipe-delimited fields, **only immutable fields**, in this fixed order:

```
clientMessageId | roomId | senderId | senderName | recipientId | <type as decimal> |
nonce | senderPublicKey | <Int64 round(ts*1000)> | originDeviceId |
text | mediaUrl | thumbnailUrl | fileName | mimeType |
<fileSize or empty> | <audioDuration or empty> |
replyToMessageId | replyToTextPreview | replyToSenderName
```

If a geo-fence is present, append:

```
| <h3Cell> | <radiusInCells> | <deliverOnlyInside as Swift String of Bool>
```

(Swift bool string-form is `"true"` or `"false"`.)

Missing optionals are **empty** strings between pipes. Mutable DTN fields (`sc`, `hc`, `hl`, `rp`, `nf`, `ttl`, `ib`) are **excluded**.

#### Rule 2 — Post (`MeshPostEnvelope`) — pipe form

See §C.3.

#### Rule 3 — `MeshMessageFrame` — JSON canonical form

```
sigBytes = utf8( JSON(envelope, sortedKeys=true, drop_keys=["s","spk"]) )
```

Take the raw JSON object, remove keys `s` and `spk`, re-serialize with sorted keys, UTF-8 encode. Sign that.

#### Rules 4 & 5 — ACK and Stop

Pipe forms — see §C.4 and §C.5.

### HMAC

**Not used.** There are no HMAC calls in the codebase. Integrity is provided exclusively by:

1. AES-GCM authentication tag (16 bytes) for encrypted payloads.
2. Ed25519 signatures for envelope binding.

(The README/marketing mentions "HMAC-SHA-256" historically — that's stale. Update marketing or add HMAC if you want belt-and-suspenders integrity at the wrapper level.)

### Random

- `SecRandomCopyBytes(kSecRandomDefault, ..., ...)` for the AES-GCM 12-byte nonce and the 16-byte envelope nonce.
- `Curve25519.*.PrivateKey()` initializers use the system CSPRNG.
- **Windows port:** use `RandomNumberGenerator.Fill` (CNG-backed). Never use `Random` (LCG, predictable).

---

## E. Routing

### Mode selection

1. If `serverReachable` (application-layer probe — distinct from the OS NWPath/Reachability query) → **dual-path**: spawn server-send and concurrently call `enqueueMesh`. Same `clientMessageId` deduplicates server-side; first-delivery-wins.
2. Else → **mesh only**.

There is no "direct mesh vs bridge" decision at send time. Bridging happens implicitly when an online relay receives a mesh envelope and uplinks it.

Media (image/file/voice/location) is **never** sent via mesh; it stays in outbox until internet returns. DM mesh broadcast only allows types `{0, 4, 6}`.

### Spray-and-Wait (Binary)

- Initial spray budget `L`:
  - Free tier: 5
  - RAVEN+ tier: 50
  - Adaptive override possible via feature flag.
- On forwarding: `givenTokens = max(1, sprayCounter / 2)`; sender keeps the rest.
- When `sprayCounter == 0`, stop forwarding.
- "Wait phase" at `sprayCounter <= 1`: only forward to direct recipient (or group member) or trusted friend device, never strangers.
- Probabilistic gossip on top:
  - `p(forward) = peerCount<=2 ? 1.0 : min(1.0, max(0.25, 3.0/(peerCount+1)))`
  - Evaluated by hashing `(messageId, deviceFingerprint)` mod 1000.
  - Direct recipients always get 100%.
- Protocol-max sprayCounter: **50**.

### TTL

- `ttlSeconds` default: Free=86400 (1d), RAVEN+=259200 (3d).
- `hopLimit` default: Free=10, RAVEN+=50; protocol cap=50.
- `hopCount` rule: relays **increment** `hopCount` and append their fingerprint to `routePath` (no decrement scheme).
- Drop policy: envelope `isValid` requires `hopCount < hopLimit && sprayCounter > 0 && !isExpired`.

### Dedup keys

Stored in `MeshDedupRepository` (SQLite) with these exact strings:

| Frame | Key |
|---|---|
| Feature frame | `"frame:<mid>"` |
| Mesh post | raw `postId` (in-memory `processedMessages` map — no persistent prefix) |
| Stop | `"stop:<messageId>"` |
| ACK | `"ack:<originalMessageId>\|<senderId>\|<recipientId>\|<status>"` |
| Encrypted DM | `"enc:<base64-nonce-from-JSON>"`; also tracks `clientMessageId` after decrypt |
| Signed DM | raw `clientMessageId` |

Dedup TTL: **30 days** persistent; in-memory cache 10 000 entries with FIFO eviction. Cleanup interval: 6 hours.

### Replay window

- AES-GCM nonces tracked in-memory in `usedNonces`; cleared on size > 100 000 entries.
- `nonceLifetime = 86400 * 7` (7 days) is declared but never enforced — current implementation is size-bounded only.
- Dedup repository retention: 30 days.
- There is no explicit "too old" timestamp check on inbound DM envelopes other than `isExpired` against `ttlSeconds`.

### Forwarding rules

A relay forwards an envelope if **all** of these hold:

1. `envelope.needsForwarding && envelope.isValid` true.
2. `!hasPassedThrough(myDeviceFingerprint)` (loop avoidance via `routePath`).
3. Probabilistic-gossip elects this device (always for direct recipient locality).
4. Per-peer in spray loop:
   - peer not in `routePath`;
   - if `sprayCounter <= 1`, peer must be recipient, group-member, or trusted;
   - PRoPHET delivery-predictability allows it (or peer is recipient/trusted).
5. Rate-limit check: 60 msgs/peer/minute.

If no peers are connected, store in in-memory relay queue (max 30) and persist via `RelayQueueRepository` for later delivery.

---

## F. Trust model

`FriendDeviceRepository` stores per-userId trusted devices keyed by Ed25519 public key.

### Verification path

1. If signer key matches our own pubkey → **trust** (echo from relay).
2. Else lookup `getTrustedDevices(forUser: senderId)`:
   - Match → trust.
   - User has trusted devices but key doesn't match → **REJECT as impersonation** (no rotation auto-trust).
   - User has NO trusted devices → **TOFU**: auto-add the key as `.trusted` and accept.
3. For relayed messages (`hopCount > 0` or `isBridged`): the **original** signature/pubkey carried in `os`/`ospk` is verified against `signingData`; bridge-flagged messages without an original signature are accepted as long as the bridge-node's signature in `s`/`spk` is valid.

> **Known security bug:** the bridge-flagged path trusts whatever inner `senderId` the attacker claims, and the relay TOFU silently locks-in any first-claimed key. See §I.

### Pairing verification code

6-digit code:

```
code = SHA-256( min(pub1,pub2) ‖ max(pub1,pub2) ‖ nonce ).first(4 bytes) mod 1_000_000
```

Pubkeys sorted lexicographically by base64 → deterministic across both devices.

---

## G. ACK / receipts

Format: see §C.4. Path tracking fields:

- `pathUsed` — `"server"` / `"mesh"` / `"mesh-bridge"` (free-form string)
- `originDeviceId` — initiator's fingerprint
- `routePath` — hop-by-hop fingerprints
- `hopCount` / `hopLimit`

What is **NOT** signed: `pathUsed`, `hopCount`, `hopLimit`, `routePath`, `originDeviceId`, `isACK`. These mutate at relays. (Recommended fix: include `pathUsed` and `originDeviceId` in the signed payload — see §I.)

Outbound ACKs are signed by the receiving device. Relays preserve the original signature when forwarding. Inbound unsigned/invalid ACKs are rejected.

**Bridge uplink:** when a relay node has internet and sees a `delivered` ACK that isn't for itself, it POSTs `/api/messages/ack-delivered` with `pathUsed:"mesh-bridge"` and idempotency key `"ack-<relayKey>"`.

---

## H. Background / lifecycle

| Behaviour | Value |
|---|---|
| BLE central scanning | Continuous when powered on. Stop+100ms+restart pattern defeats iOS XPC duplicate-filter coalescing. `allowDuplicates=false` for battery. |
| BLE peripheral advertising | Continuous while engine active. iOS throttles in background. |
| Periodic cleanup timer | Every 15 s: stops, stale subscribers, stale chunks, stale sessions, bridge poll, PRoPHET prune. |
| iOS background-bridge mode | Best-effort, scheduled background tasks of ~25 s each. Does NOT keep BLE alive indefinitely (iOS limit). |
| Connection cooldown after fail | 60 s (sweep cancel) or 5 min (service-discovery failure). |
| Reassembly buffer GC | 30 s. |
| MPC service type | `"raven-mesh"` |
| MPC idle teardown | 10 s |
| MPC hard cap | 90 s |
| MPC bulk threshold | 4096 bytes |
| MPC msg tag bytes | `0xAC` = auth challenge; `0xDA` = data |
| MPC auth payload | Ed25519 sig over `"<sessionNonce>\|<unixSeconds>\|<fingerprint>"` UTF-8 |

### Windows-specific lifecycle notes (port guidance)

- Windows BLE peripheral mode IS supported via WinRT (`Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider`) since Windows 10 1607.
- Background operation: app must be running (foreground OR system tray). Windows does NOT have an iOS-style background-tasks API for unlimited BLE — relay needs the process alive.
- For "always-on relay": ship a small background service or use `RegisterStartupTask` + minimize-to-tray UX.

---

## I. Known issues / inconsistencies (read before porting)

1. **`messageHash` is unstable across implementations.** Swift `Data.hashValue` is per-process random-seeded. Treat it as opaque chunk-group key per sender. Don't recompute.

2. **Two fields share JSON key `spk`**:
   - In `EncryptedMeshPayload`, **outer** `spk` is the **X25519 agreement key** for ECDH; the embedded signature uses `ssk` for the **Ed25519** signer key.
   - In `SignedMeshPayload`, outer `spk` is **Ed25519**.
   - In `SecureMeshEnvelope` (the `e` value), inner `spk` is again the **Ed25519** sender key copied for binding.
   - Same JSON name carries different curve material in different layers — implementations MUST NOT reuse a single decoder.

3. **Envelope nonce length mismatch.**
   - `SecureMeshEnvelope.n` is **16 bytes** (envelope identifier).
   - The **AES-GCM nonce** is a **separate 12-byte** value inside the SealedBox (`c`).
   - The 12-byte one is the security-critical one. The 16-byte `n` is a JSON envelope identifier only and MUST NOT be used as a GCM nonce.

4. **Replay nonce cleanup is size-based only.** `nonceLifetime = 7 days` is declared but never consulted; `cleanupOldNonces` clears the whole set when > 100 000. After clearing, replays within the same `clientMessageId` would still be caught by `MeshDedupRepository` (30 days), but a port cannot rely on any time-based replay window here.

5. **Mesh post dedup uses `processedMessages` directly with no prefix**, unlike all other frame types which use `"<kind>:<id>"` keys via `MeshDedupRepository`. Two posts with the same `pid` + a DM with same client id could collide in this in-memory cache.

6. **`MeshEnvelope.gkv` (groupKeyVersion) is dropped on the wire** — `SecureMeshEnvelope.CodingKeys` does NOT include it. Group-key-encrypted text currently has no way to signal which group-key version was used. Group decryption likely fails across rotations.

7. **`pathUsed` values** are spelled `"server"`, `"mesh"`, `"mesh-bridge"`. Not constrained by an enum; treat as free-form string.

8. **DM JSON encoder ordering**: outer `SignedMeshPayload`/`EncryptedMeshPayload` use default `JSONEncoder` (insertion order undefined in JSON spec, but Apple emits in `CodingKeys` declaration order). The PLAINTEXT inside AES-GCM uses `.sortedKeys`. The Ed25519 signature is over the explicit `signingData()` byte form (NOT JSON) so encoder ordering doesn't affect signature interop. `MeshMessageFrame` is the only frame whose signature depends on JSON-canonical sorted-keys output.

9. **Ed25519 vs X25519 curve confusion warning**: comments throughout the iOS code say "Curve25519.Signing" (Ed25519) and "Curve25519.KeyAgreement" (X25519). They use different raw representations and cannot be substituted. The wire carries them in **different** base64 fields and they ARE different keys (separate keypairs in Keychain).

10. **Bridge bypass (security):** any envelope with `isBridged=true` skips signature verification of the inner `senderId`. An attacker can claim any sender ID. **This is a known vulnerability and should be fixed in v2 of the protocol** — require bridge envelopes to carry a `bridgeSignature` over `(senderId|messageId|recipientId|timestamp)` with a `bridgePublicKey` from a trusted bridge registry.

11. **Relay TOFU (security):** for relayed messages where the sender is unknown, the claimed key is auto-trusted. An attacker can spoof an unknown user's identity at first contact. v2 should treat relay-claimed keys as `.unverified` until confirmed via QR/SAS.

12. **No forward secrecy:** static X25519 key forever; constant HKDF salt `"RAVEN-MESH"`. v2 should adopt Double Ratchet or per-session ephemeral keys.

---

## J. Versioning policy

- The integer field `v` in `EncryptedMeshPayload` is the protocol version. Currently `1`.
- A new wire-incompatible release MUST bump `v` to `2`.
- Receivers seeing a higher `v` than they support should drop the envelope silently (or surface "update required").
- Implementations should declare in their handshake which protocol versions they support (future addition).

---

## K. Reference implementation

- **iOS / macOS Catalyst:** Swift, in `ios-native/RAVEN/RAVEN/Core/Mesh/` and `Core/Security/`.
- **macOS App Store:** Swift, in `RAVEN-MacApp/RAVEN/Core/Mesh/`.
- **Windows (.NET 8 / WinUI 3):** in `RAVEN-Windows/`.
- **Android:** Kotlin, seed at `RAVEN-Android/app/src/main/java/app/raven/mesh/`.

For interop tests:

- All implementations must round-trip a captured envelope from any other and produce identical decrypted plaintext.
- All must produce identical Ed25519 signatures over a fixed test vector (see `RAVEN-Windows/tests/InteropVectors.cs` once present).
- Cross-platform mesh test plan: §K.1 in `MESH_INTEROP_TEST_PLAN.md`.

---

## V2. Protocol version 2 (RAVEN Universal Mesh)

> **Status:** opt-in, advertised alongside v1 during migration. v1 above remains the canonical wire for shipping clients until v2 is enabled by default.

v2 fixes three pain points of v1:

1. **JSON overhead.** v1 envelopes are ~400 B for a "hi" text. v2 is 60 B header + payload. Saves ~85 % on BLE bandwidth and ~3× the throughput on the same MTU.
2. **No version field.** v1 had no `v` byte at the front, so any wire change forced a flag day. v2 stamps `0x02` in byte 0 — older clients that misread reject the frame deterministically.
3. **Constant HKDF salt.** v1's per-pair derivation isn't forward-secret. v2 carries a 16-byte `msg_id` used as the AEAD nonce input, and rotates per session via a Noise IK ratchet (separate spec, in §V2.crypto once shipped).

### V2.GATT spec

Distinct UUIDs from v1, so a peer that supports both advertises **both** in `CBAdvertisementDataServiceUUIDsKey` and the higher-versioned-protocol wins:

| UUID | Role |
|---|---|
| `12345678-2345-2345-2345-123456789ABC` | v2 service |
| `12345678-2345-2345-2345-123456789ABD` | v2 message TX/RX (notify + write + writeWithoutResponse) |
| `12345678-2345-2345-2345-123456789ABE` | v2 capabilities (read; 4-byte big-endian uint32 — see §V2.capabilities) |

Chunking is **unchanged from §B** — v2 envelopes ride the same 6-byte chunk header.

### V2.envelope (60-byte header, big-endian throughout)

```
 byte  field             encoding
 0     version           uint8 = 0x02
 1     type              uint8 — see §V2.types
 2     ttl               uint8 (0..maxTTL=15; relays decrement)
 3     flags             uint8 — see §V2.flags
 4..7  timestamp         uint32 BE — unix seconds (wraps 2106)
 8..23 msg_id            16 bytes — UUID v4 binary
24..39 sender_pid        16 bytes — SHA-256(sender_pubkey)[:16]
40..55 dest_pid          16 bytes — SHA-256(dest_pubkey)[:16]
                          OR all-0xFF for broadcast
56    hop_count          uint8 (relays increment)
57    spray_remaining    uint8 (Spray-and-Wait copy budget)
58..59 payload_len       uint16 BE
60..N payload            payload_len bytes (Noise-encrypted iff flags.encrypted)
N..N+64 signature        Ed25519 (only if flags.signature_present)
```

After encoding, the result is **padded** to the next of `{256, 512, 1024, 2048, 4096, 8192}` bytes with `0x00`. Receivers strip via `payload_len`.

### V2.types

| value | name | notes |
|---|---|---|
| 0 | text | UTF-8 chat |
| 1 | image | URL in payload (image fetched via /api/uploads or mesh-attached) |
| 2 | voice | URL or inline audio |
| 3 | file | generic file |
| 4 | location | lat/lng/altitude payload |
| 5 | system | server/system event |
| 6 | ack | "I delivered msg X" — relays gossip to cancel remaining copies |
| 7 | stop | "stop relaying msg X" — paired with ack for fast cancellation |
| 8 | post_share | quoted post |
| 9 | ephemeral | self-destruct on read |

### V2.flags

| bit | name | semantics |
|---|---|---|
| 0 | encrypted | payload is Noise-encrypted (caller must run AEAD) |
| 1 | bridged | uplinked to server bridge at least once |
| 2 | group | dest_pid is a group hash, not a user hash |
| 3 | ack_required | recipient must send back type=ack |
| 4 | needs_forwarding | carrier should keep relaying via Spray-and-Wait |
| 5 | signature_present | trailing 64 bytes are Ed25519 signature |
| 6,7 | reserved | MUST be 0 |

### V2.capabilities

Read from the capabilities characteristic — 4-byte big-endian uint32 bitfield:

| bit | name |
|---|---|
| 0 | v2_protocol |
| 1 | ble_transport |
| 2 | wifi_aware (iOS 26+ / Android 8+) |
| 3 | multipeer (Apple-only) |
| 4 | wifi_direct (Android / Windows) |
| 5 | server_bridge (online via /api/messages/uplink) |
| 6 | can_be_bridge (will uplink for offline peers) |
| 7..31 | reserved (MUST be 0) |

### V2.routing

Spray-and-Wait with binary spray:

- Sender stamps `spray_remaining = L` (default 4 free, 8 RAVEN+).
- On each new peer encounter, carrier hands out `floor(spray_remaining/2)` to the new peer and keeps the rest.
- When `spray_remaining == 1`, message is in **wait phase** — only direct delivery to the destination peer.
- Recipient on delivery emits `type=ack` (broadcast) → `type=stop` (broadcast) → carriers drop matching `msg_id` from their outbox.

### V2.peer ID derivation

```
peer_id = SHA-256(static_curve25519_pubkey)[:16]
```

Same on every platform.

### V2.test vectors

All four implementations MUST produce identical bytes for these inputs.

#### Vector 1: text "hello", encrypted flag, no signature

Inputs:
- type = `text` (0)
- ttl = 7
- flags = `encrypted` (0x01)
- timestamp = 0x12345678
- msg_id     = `10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F`
- sender_pid = `20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F`
- dest_pid   = `30 31 32 33 34 35 36 37 38 39 3A 3B 3C 3D 3E 3F`
- hop_count = 0
- spray_remaining = 4
- payload = ASCII "hello" (5 bytes: `68 65 6C 6C 6F`)

Expected encoded bytes (65 bytes, hex):

```
0200070112345678
101112131415161718191a1b1c1d1e1f
202122232425262728292a2b2c2d2e2f
303132333435363738393a3b3c3d3e3f
0004
0005
68656c6c6f
```

Verified equal across:
- iOS / Mac (Swift)
- Android (Java/Kotlin via `ByteBuffer.BIG_ENDIAN`)
- Windows (C# via `BinaryPrimitives.WriteUInt*BigEndian` — by inspection)

### V2.migration policy

- **Phase A (current):** v2 module shipped, off by default. Apps advertise only v1 service UUID.
- **Phase B:** opt-in flag in dev builds — apps advertise BOTH v1 + v2. Peers prefer v2.
- **Phase C:** v2 default for new pairs; v1 retained for legacy peers.
- **Phase D:** v1 retired. Bumping `EncryptedMeshPayload.v` to `2` finalizes the cutover.

Each phase requires a full interop test (§K.1). Do not fast-forward — clients in older app store builds will see corrupted frames if their peer skipped a phase.
