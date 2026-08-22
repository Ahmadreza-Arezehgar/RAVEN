# RAVEN Terminal (`raven`) — serverless messaging for macOS / Linux / Windows

A cross-platform terminal client for the RAVEN decentralized communication
network. It talks **the exact wire protocol of the iOS app** because it embeds
the same Go node (`ravenbridge.Node`) that is compiled into the iPhone app via
gomobile:

- libp2p transport (Noise, QUIC + TCP), Kademlia DHT discovery,
  Circuit Relay v2 + DCUtR hole-punching — **no central server**
- stream protocol `/raven/bridge/1.0.0`, frame:
  `[u32 BE len][base64 payload][u16 BE len][idempotency key]`
- payload: legacy `EncryptedMeshPayload` JSON — X25519 static-static ECDH →
  HKDF-SHA256(salt `RAVEN-MESH`) → AES-256-GCM, Ed25519-signed envelope

One binary provides every network role:

| Role | Command | What it does |
|---|---|---|
| Client | `chat` / `send` / `listen` / `fetch` | E2E messaging endpoint |
| Relay | `relay` | Circuit Relay v2 + DHT bootstrap for NAT traversal |
| Mailbox | `mailbox` | offline store-and-forward of opaque envelopes |
| Bridge | (iOS side) | BLE-mesh ↔ internet bridging happens on phones; a desktop `listen` node acts as the internet leg |

## Build

```sh
./build-terminal.sh [outdir]     # darwin/linux/windows × amd64/arm64
# or just your host:
go build -o raven ./cmd/raven
```

Requires Go ≥ 1.25. No cgo — fully static binaries.

## Identity & pairing

```sh
raven init            # create ~/.raven/identity.json  (Ed25519 + X25519)
raven whoami --qr     # fingerprint, libp2p PeerID, public keys + QR
```

The Ed25519 device key derives everything locally — display fingerprint
(`XXXX-XXXX-XXXX`, same derivation as `DeviceIdentityService`),
libp2p PeerID (`12D3Koo…`, identity multihash), and signatures.
**The private keys never leave the machine.**

### One-string invite codes (`rvn1i…`)

Everything needed to pin a contact now fits into **one copy-pasteable line** —
no more juggling address + pub_hex + fingerprint:

```sh
raven invite          # print your single-line contact code (~240 chars)
raven invite --qr     # same code as a scannable QR
raven words           # your four-word key face, e.g. "copper raven north lantern"
```

The code is Bech32m (BIP-350 — same checksum family as `rvn1…` addresses,
typo-detecting) carrying a TLV payload: Ed25519 identity key, X25519 agreement
key, issue time, display name, and an Ed25519 signature over the **same
`qr-v2:` transcript as the iPhone card**. Fingerprint, address and PeerID are
re-derived from the embedded key on receipt — never trusted from the string.
Codes expire after 24 h like cards. Parsers skip unknown TLV types, so future
fields (mailbox hints…) can ship without breaking old terminals.

Add someone by pasting whatever they sent you — bare code, quoted, trailing
punctuation, or wrapped in a share URL all work:

```sh
raven add --petname bob     # paste bob's rvn1i… line on Enter
```

Verify out loud when the channel is untrusted: both sides run
`raven words [CODE]` and compare the four words.

### Pair two terminals

```sh
# alice shows her code; bob pastes it:
raven invite                      # alice copies the rvn1i1… line
raven add --petname bob           # bob pastes it (old raven:// / JSON also accepted)
```

The long `raven://friend?v=2&d=…` card URI (printed by `whoami`) stays fully
supported — it is the identical signed payload in JSON clothes, and the format
the iPhone QR scanner consumes.

Cards carry both public keys and an Ed25519 signature over
`qr-v2:{userId}:{agreementPub}:{identityPub}:{ts}` — identical to the iOS
QR v2 format (24 h validity enforced). Fingerprints are re-derived from the
key, never trusted from the card.

### Pair with an iPhone

Two directions, both serverless:

1. **iPhone scans the terminal's QR** — run `raven whoami --qr`; scan with
   RAVEN iOS *Discover → Scan QR*. This pins both keys as verified trust on
   the phone (same path as phone-to-phone QR).
2. **Terminal adds the phone** — scan/copy the phone's card into
   `raven add`. (Camera-less desktops: use the card JSON.)

After pairing, messages flow fully E2EE. On the phone an unpinned sender is
still received (TOFU) but flagged "unverified"; pinned senders show normally.

## Messaging

```sh
export RAVEN_BOOTSTRAP=/ip4/<relay-ip>/tcp/4001/p2p/<relayPeerID>[,...]
export RAVEN_MAILBOX=/ip4/<mailbox-ip>/tcp/4002/p2p/<mailboxPeerID>  # optional

raven chat @bob        # interactive two-way chat
raven send bob "hi"    # one-shot (always also queues at mailboxes)
raven listen           # receive-only daemon (logs inbox.jsonl)
raven fetch            # drain mailbox nodes once
```

Delivery logic: direct/DHT route first, relay circuit fallback, mailbox copy
always deposited when configured (recipient picks it up with `fetch` /
automatically in `listen`).

## Running community infrastructure

Anyone can run the two always-on pieces — both are stateless-ish, dumb
couriers that cannot read traffic:

```sh
raven relay     # :4001 tcp+quic — DHT server + Circuit Relay v2 hop
raven mailbox   # :4002 tcp+quic — store-and-forward buckets (72 h TTL)
```

Stable dev identities are baked in (override with `RAVEN_RELAY_SEED_HEX`,
`RAVEN_MAILBOX_SEED_HEX`). Point phones at the relay via the
`raven.libp2p.bootstrap` UserDefaults key; point terminals via
`RAVEN_BOOTSTRAP`.

## Environment

| Var | Meaning |
|---|---|
| `RAVEN_DATA_DIR` | data dir (default `~/.raven`) |
| `RAVEN_BOOTSTRAP` | comma-separated relay multiaddrs |
| `RAVEN_MAILBOX` | comma-separated mailbox multiaddrs |
| `RAVEN_NAME` | display name placed into envelopes |

## Honest limitations (V1)

- Offline delivery needs someone running a mailbox node — pure P2P cannot
  hold mail for an absent peer. The protocol stores opaque blobs keyed by
  recipient PeerID; it sees metadata (who/when/how big), never content.
- iOS mailbox fetch is not wired yet (needs a Swift client using the same
  `/raven/mailbox/1.0.0`); today phones receive online or via BLE mesh.
- No forward secrecy yet: static-static ECDH matches the current shipping
  iOS mesh payload; the RVN1/ATSAM ratchet upgrade applies to both sides
  later through the same bridge (payload stays opaque).
- A hostile mailbox can drop messages (availability) but not read or forge
  them (AEAD + signature).
