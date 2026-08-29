# Raven Bridge V1 (local)

Opaque **cross-transport** forward of the same `RavenEnvelopeV1` between LAN/Internet and BLE (mock BLE = TCP length-prefix in CI).  
Bridge ≠ trusted server: never decrypts, never re-origins, never changes `message_id`.

> Security status: bridge mechanics are testable, but production messaging is
> blocked by [`../protocol/SECURITY_ERRATA_RVN1_2026-08-13.md`](../protocol/SECURITY_ERRATA_RVN1_2026-08-13.md).
> The bridge never parses sealed ACK content or declares recipient delivery.

Conceptual credit: MIT DTN store-carry-forward, Spray-and-Wait replication budgets, RFC 9171 lifetime/hop-safety lessons — **not** BPv7 wire format.

## Topology (A–B–C)

| Node | Radios | Role |
|------|--------|------|
| **A** | Internet/LAN ON, BLE OFF | Sender — seals A↔C E2EE, dials B LAN |
| **B** | LAN + BLE (mock) | **Bridge** — opaque forward + store-carry |
| **C** | Internet OFF, BLE ON (mock) | Recipient — decrypts, emits **only** Delivered ACK |

## Pull authentication and custody receipts

The current TCP/mock-BLE carrier registers an egress path only after an
explicit `RVNP` pull and mutual Ed25519 challenge/response. The bridge accepts
the puller's public key only when the matching `contacts.json` entry is
explicitly pinned; merely saving an unverified contact grants no carrier
access. The pulling client pins the bridge key with `--bridge-pub-hex`. Fresh
nonces bind both keys to the pull transcript.

An envelope handed to a pull connection remains `InFlight`. Channel enqueue is
not delivery. The next hop returns a domain-separated signed custody receipt
bound to the pull transcript and object digest only after its endpoint handler
reports an accepted outcome. Rejected, unsupported, or expired frames produce
no receipt. The unsafe lab endpoint additionally persists the exact encrypted
frame before acceptance; ACK acceptance follows its durable delivery-state
update. The bridge accepts a receipt only from the exact peer/session selected
for that attempt; a legitimate retry replaces that binding. These bindings are
process-local, so after restart an unreceipted durable row must pass retry
backoff and be handed to a fresh authenticated pull before a receipt can
advance it.

This receipt proves only authenticated next-hop custody, not recipient delivery
and not end-to-end ATSAM session establishment. The TCP/mock-BLE carrier remains
an experimental transport; message confidentiality/authenticity comes from the
opaque Raven envelope carried over it.

## Automated tests (no phones)

```bash
cd /path/to/hybrid_messenger/node
cargo build -p raven-core -p raven-node -p ash
cargo test -p raven-core --test bridge_v1          # cases 1–9
./scripts/two_node_demo.sh
./scripts/lan_path_smoke.sh
./scripts/bridge_abc_demo.sh                       # self-builds isolated unsafe lab binaries
```

### Cases covered by `bridge_v1`

1. BLE→Internet forward  
2. Internet→BLE reverse  
3. Store-carry when Internet down, flush later
4. Dup BLE+Internet → one delivery
5. Tampered ciphertext → auth fail
6. Replay → dedup drop
7. Crash after queue → recover
8. Expired offline → never forward
9. Per-peer rate limit (noisy hop dropped; quiet hop still forwards)
10. Recipient ACK reverse (BLE→LAN sealed and opaque, with no acknowledged-ID peek); destination dispatch remains separate from authenticated endpoint acceptance

## Abuse limits (V1 defaults)

| Limit | Default |
|-------|---------|
| Global pending queue | 512 |
| Max envelope bytes | 1 MiB |
| Per-peer pending | 64 |
| Per-peer enqueues / 60s | 30 |
| Per-peer bytes / 60s | 256 KiB |

`previous_hop` is an abuse-accounting key, not a Raven identity. TCP sources are
canonicalized to their IP address (ephemeral ports are discarded); other
authenticated or non-TCP adapters may supply an opaque peer identifier.

## BLE adapters

| Adapter | Where | Notes |
|---------|--------|-------|
| `mock_ble` | `raven-node bridge` (TCP) | CI / demos — keep forever |
| `ble_gatt` | iOS `BLEMeshEngine` + `RavenBleRvn1Carrier` | Flagged; MeshEnvelope default when flag OFF |

## Hardware BLE note

Software path is proven with **mock_ble** (TCP). Real GATT on device uses existing iOS `BLEMeshEngine` characteristic path for raw `RVN1` behind `FeatureFlag.ravenEnvelopeV1`.

**raven-node on macOS:** keep `mock_ble` for CI/demos. A CoreBluetooth / BlueZ GATT adapter is **not** wired into `raven-node` (would break headless CI and needs interactive Bluetooth entitlements). Use iOS hardware for GATT; use `bridge_abc_demo` for cross-transport ACK proof.

iOS phone-as-B:
- Optional LAN listen port → opaque BLE forward (`RavenEnvelopeBridgeService.forwardLanToBle`)
- Recipient ACK reverse: BLE ACK is routed as an opaque envelope toward active LAN paths; the bridge does not read `acked_message_id`. Only the originating endpoint can decrypt and apply it.
- Phone-as-C: destination classification must come from a recognized local routing tag/session, never a user-forced unconditional boolean. Unknown routes remain relay-only or are dropped.
- `RavenEnvelopeChatWire` may emit a sealed Delivered ACK only after authenticated decrypt and durable inbox/ratchet commit; sender delivery requires full outer + AEAD + inner ACK verification and exact pending-recipient binding.

### Hardware GATT smoke (iOS device, flag ON)

1. Two phones (or phone + Mac with iOS Simulator BLE limited): enable **RavenEnvelopeV1**
2. Phone B: Serverless LAN listen port > 0; BLE peers nearby; `localIsDestination = false`
3. Phone C: BLE only; install an authenticated session whose routing tag matches the test envelope
4. A (Mac test harness or phone): send a real session-sealed envelope to B LAN; expect C authenticated commit followed by a sealed ACK back to A
5. Confirm MeshEnvelope path still works with flag OFF

## ash terminal controls (does **not** stop bridging)

Policy file: `<data-dir>/node_policy.json` (no secrets).  
`raven-node bridge` hot-reloads it; closing ash leaves the node running.

```bash
DATA=$(mktemp -d)
./target/debug/ash --data-dir "$DATA" init
./target/debug/ash --data-dir "$DATA" node bridge on
./target/debug/ash --data-dir "$DATA" node store on
./target/debug/ash --data-dir "$DATA" node relay off
./target/debug/ash --data-dir "$DATA" status
./target/debug/ash --data-dir "$DATA" banner
```

Interactive menu → **4 Status** shows the same Bridge / transports / forward_q lines.

## Run bridge daemon (B)

```bash
./target/debug/raven-node bridge \
  --data-dir "$DATA_B" \
  --lan-listen 127.0.0.1:0 \
  --ble-listen 127.0.0.1:0 \
  --write-lan-addr /tmp/b.lan \
  --write-ble-addr /tmp/b.ble \
  --timeout-secs 0          # 0 = until killed; ash exit does not stop this
```

## Safety

- Never print seeds / private keys / plaintext
- Never log seeds, private keys, plaintext, or ciphertext. Current diagnostic logs do include listen addresses plus message/object identifier prefixes for smoke correlation; treat those values as metadata and apply normal log retention/access controls.
- Capability ads: `ble` / `internet` / `relay` / `store` / `bridge` — never “I know Bob”
- No GitHub push of demo data dirs
