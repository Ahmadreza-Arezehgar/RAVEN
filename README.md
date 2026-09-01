# RAVEN — serverless terminal messaging

RAVEN is an open-source, terminal-first, end-to-end-encrypted messenger written
in Rust. Two people run `ash` (also installed as `raven`) on their own
machines; a local `raven-node` daemon carries the traffic. No Raven-operated
message server, account database, or phone number is involved.

This README describes **what the code does today**. Anything that is designed
but gated, experimental, or unproven is labelled that way. The authoritative
status documents are [`node/SERVERLESS_MODEL.md`](node/SERVERLESS_MODEL.md),
[`node/FINAL_SERVERLESS_PROOF.md`](node/FINAL_SERVERLESS_PROOF.md) and
[`protocol/SECURITY_ERRATA_RVN1_2026-08-13.md`](protocol/SECURITY_ERRATA_RVN1_2026-08-13.md);
when a marketing page, an older repository, or a stale document disagrees with
them, they win.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![Primary UI](https://img.shields.io/badge/primary-terminal-black.svg)](node/)
[![Status](https://img.shields.io/badge/status-active_hardening-orange.svg)](node/SERVERLESS_MODEL.md)

Website: [raven-messager.com](https://raven-messager.com/) · Security policy: [`SECURITY.md`](SECURITY.md)

---

## What works today

| Capability | Status | Where |
|---|---|---|
| Terminal ↔ terminal on the **same LAN**: TCP + Noise XX handshake, hybrid X25519 + ML-KEM-768 PairInit, ChaCha20-Poly1305 indexed session, signed ACK, committed inbox | **Implemented and compile-time enabled** (`LAN_DIRECT_PRODUCTION_ENABLED`) | `node/crates/raven-core/src/lan_*.rs`, `pair_init.rs`, `atsam_indexed_session.rs`; `node/crates/ash/src/pair_init_lab.rs` |
| Identity: Ed25519 device key, `rvn1…` bech32m address, fingerprint, out-of-band contact pinning | Implemented | `identity.rs`, `address.rs`, `ash contact add` |
| Protected identity storage | macOS Keychain and Windows DPAPI: create + load. GNU/Linux Secret Service: **load only** — creating a fresh identity in a Release build is intentionally blocked (R0/R1 hold) | `identity_store.rs`, `node/IDENTITY_SEED_STORAGE.md` |
| Peer discovery on the LAN (mDNS / Bonjour) | **Not implemented** — you type the peer's `host:port` once and it is saved on the contact | — |
| Store-carry-forward bridge (A → B → C over an untrusted relay) | Policy, queue and a deterministic A–B–C harness exist; **`ash send` does not select a bridge automatically** | `bridge.rs`, `forward_queue.rs`, `node/BRIDGE_V1.md` |
| Internet delivery, NAT traversal (AutoNAT / DCUtR / relay), public DHT | **Experimental, fail-closed by default**; separate `raven-swarm*` binaries behind feature flags and runtime opt-in | `node/crates/raven-swarm/`, `node/NAT_TRAVERSAL.md`, `node/adr/0002-internet-transport.md` |
| Offline mailbox (libp2p store) | Experimental feature flag; opaque put/get only, no session layer | `raven-swarm-mailbox-experimental` |
| Bluetooth LE on desktop | **Mock only** (TCP loopback stand-in for CI); no radio | `ble_adapter.rs` |
| Contact request over the wire | Codec exists; **fail-closed** until the generic ATSAM production tripwires open | `contact_request.rs` |
| Hybrid ratchet v2 / “Full Braid”, incremental ML-KEM, SQLCipher durable store | **Lab only**; `compile_error!` in Release builds | `full-braid-lab`, `mlkem768-incremental-lab` features |
| External cryptographic review, signed/notarized installers | **Not yet** | `node/EXTERNAL_REVIEW_PACKET.md`, `node/SIGNING_NOTARIZATION_CHECKLIST.md` |

Cryptographic primitives are standard (Ed25519, X25519, ML-KEM-768 via
RustCrypto `ml-kem`, ChaCha20-Poly1305, HKDF-SHA256, Noise XX via `snow`). The
**composition** — PairInit transcript, indexed ATSAM session profile, Noise
static keys derived from the identity seed — is RAVEN's own and has not had an
independent review. Treat it accordingly.

## Platforms

| | macOS | GNU/Linux | Windows |
|---|---|---|---|
| Build | `cargo build --locked --release -p ash -p raven-node` | same | same (MSVC) |
| Identity store | Keychain. `ash` and `raven-node` are separate binaries, so Keychain may prompt when the daemon first reads the identity `ash` created; the launchd installer refuses by default until that handoff is proven | Secret Service **load only**; a fresh Release `ash init` fails closed. Debug builds can use `RAVEN_IDENTITY_BACKEND=locked-file` for lab/CI profiles | DPAPI-protected seed file |
| Local IPC | Unix socket (0600 + peer uid) | Unix socket (0600 + `SO_PEERCRED`) | Named pipe (current user SID + session check) |
| Interactive menu | arrow-key menu on a TTY | arrow-key menu on a TTY | numbered line menu |
| Packaging | no signed/notarized build yet | install scripts held (R1) | unsigned CI artifact only; no MSI; two-profile native gate not yet proven |

Details: [`node/INSTALL_macOS.md`](node/INSTALL_macOS.md),
[`node/INSTALL_Linux.md`](node/INSTALL_Linux.md),
[`node/INSTALL_Windows.md`](node/INSTALL_Windows.md), [`node/WINDOWS.md`](node/WINDOWS.md).

## Quick start (two machines, one LAN)

Rust 1.98 (`node/rust-toolchain.toml`) is required. Messages travel on stdin —
`ash send --text` is refused so plaintext never lands in shell history.

```bash
cd node
cargo build --locked --release -p ash -p raven-node
export PATH="$PWD/target/release:$PATH"

# 1. Create an identity on each machine and exchange the PUBLIC fields
#    (address, pub_hex, fingerprint) over a channel you already trust.
ash init
ash whoami

# 2. Pin each other. Verify the fingerprint out of band before pinning.
ash contact add --address <PEER_RVN1> --pub-hex <PEER_PUB_HEX> \
  --petname "Bob" --tag bob --lan-dial <PEER_LAN_IP>:7420 --verify-fp <PEER_FINGERPRINT>

# 3. Receive (starts or reuses the local raven-node service)
ash listen

# 4. Send from a second terminal; read on the other side
printf '%s\n' 'hello from alice' | ash send --contact @bob
ash inbox
```

`ash` with no subcommand opens the interactive menu (Chat/Send, Inbox, Status,
Listen, Contacts, Mailbox, Nearby, Tutorial). `ash status` and `ash doctor` are
read-only. The default LAN listener is `0.0.0.0:7420`; authentication is the
Noise handshake plus your contact pin, not the port, so keep the port on a
network you trust and use a host firewall. The full walkthrough, including the
deterministic loopback proofs, is [`node/TERMINAL_DEMO.md`](node/TERMINAL_DEMO.md).

## Repository layout

| Path | Role |
|---|---|
| [`node/`](node/) | **The product.** Cargo workspace: `raven-core` (protocol, crypto, stores, transport policy), `raven-node` (daemon: LAN listener, IPC, bridge harness), `ash` (terminal, also built as `raven`), `raven-swarm` (experimental libp2p). Status docs and ADRs live here. |
| [`protocol/`](protocol/) | Normative RVN1 / ATSAM specifications, errata, interoperability notes. Start at [`protocol/SPEC.md`](protocol/SPEC.md). |
| [`protocol/reference/`](protocol/reference/) | Python reference codecs and generators for the frozen wire formats. |
| [`shared-vectors/rvn1/`](shared-vectors/rvn1/) | Deterministic cross-language test vectors (Rust ↔ Python ↔ Swift). Vectors for gated features carry `production_enabled: false` / `lab_only: true`. |
| [`agent_team/`](agent_team/) | RDAP — an **experimental** A2A agent-delegation companion that reuses the `rvn1` identity format and Ed25519 signatures. It is not the node's keystore or an E2EE carrier; read its README before running it. |
| [`docs/`](docs/) | Design documents, checklists, migration notes. [`docs/legacy/`](docs/legacy/) holds the application-era README and FAQ for history. |
| `ios-native/`, `RAVEN-iOS/`, `RAVEN-MacApp/`, `RAVEN-WatchApp/`, `RAVEN-Android/`, `RAVEN-Windows/` | Application-era clients. Legacy / secondary; not built by the terminal CI gate except the iOS protocol tests in their own workflow. |
| `server/`, `news_bot/`, `simulation/`, `x_banner/`, `raiven_landing/` | Application-era FastAPI backend, social-feed tooling and marketing assets. Legacy; the binding [product boundary](protocol/RAVEN_MESSAGING_PRODUCT_BOUNDARY_V1.md) excludes public-social features from RAVEN. |

Never committed: identity seeds, `~/.raven-ash` state, `agent_team/.team/`,
`node/target/`, proof-run artifacts, repository exports, `.env` files.

## Continuous integration

| Workflow | Gate |
|---|---|
| `raven-serverless.yml` — Raven Serverless Node | The shipping path: fmt, clippy, RustSec audit, `raven-core`/`ash`/`raven-node` tests on Linux, macOS and Windows, LAN handshake KATs, the two-node LAN smoke, bridge + fuzz smoke, the 1,000-node adversarial DTN simulation, Python vector regeneration diff, Release feature-gate refusals, SBOM. The Linux job runs a headless Secret Service so identity-absence proofs can succeed on a hosted runner. |
| `raven-lab-gates.yml` — Raven Lab Gates | Feature-gated lab crypto (Full Braid, SQLCipher durable profile, incremental ML-KEM on portable/AVX2/NEON). Informational; a lab regression does not block the terminal gate. |
| `raven-ios-protocol.yml` — Raven iOS Protocol | Legacy iOS protocol XCTests and the Go libp2p bridge they embed. |
| `raven-agent-team.yml` — Raven A2A Agent Team | RDAP selftest on three OSes with hash-locked dependencies. |
| `build-raven-windows.yml` | Unsigned, review-only `raven.exe` / `ash.exe` / `raven-node.exe` artifact. |

## Protocol and vectors

The wire codecs for RVN1 envelopes, addresses, ACKs, routing tags, device
certificates, prekeys and PairInit V1 are frozen and covered by
[`node/PROTOCOL_FREEZE_HASHES_V1.md`](node/PROTOCOL_FREEZE_HASHES_V1.md).
Everything in `protocol/` marked *NOT YET APPROVED* (hybrid ratchet v2, Full
Braid, private discovery, sovereign/social drafts) is a design document, not a
shipping format. The companion repositories
[`Raven-offline-messenger/raven-security`](https://github.com/Raven-offline-messenger/raven-security)
and
[`Raven-offline-messenger/raven-atsam-protocol`](https://github.com/Raven-offline-messenger/raven-atsam-protocol)
are snapshots that predate parts of this tree; this repository is the source of
truth.

```bash
cd node
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
cd ../protocol/reference && python3 -m pip install -r requirements.txt && python3 -m pytest -q
```

## Security

Report vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md).
Do not open public issues for them.

Boundaries worth knowing before you rely on RAVEN:

- Only the LAN-direct path is enabled. Nothing in this tree delivers a message
  across the Internet yet.
- Relays and bridges forward opaque `RavenEnvelopeV1` bytes and never hold
  plaintext, but hop and replication counters are **not** authenticated
  (errata §8).
- The session protocol is custom and unreviewed; lab features are compiled out
  of Release builds and CI asserts the refusals.
- Windows and Linux carry additional holds listed in the platform table above.

## License

Source code is licensed under the **GNU Affero General Public License v3.0 or
later** — the full text is in [`LICENSE`](LICENSE); the copyright notice and the
accompanying trademark and asset terms are in [`NOTICE`](NOTICE),
[`TRADEMARK.md`](TRADEMARK.md) and [`ASSET_LICENSE.md`](ASSET_LICENSE.md). The
RAVEN name, logo and product artwork are not licensed for use as the identity
of a modified product.

## Contributing and contact

Pull requests and audits are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md)
and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). General and security contact:
info@raven-messenger.com.

© 2026 Ash Robotic Industry.
