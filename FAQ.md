# RAVEN FAQ — terminal product

Short answers about the serverless terminal messenger in [`node/`](node/).
Historical questions about the 2026 iOS application (accounts, Sign in with
Apple, server-stored media, BLE chat rooms) live in
[`docs/legacy/FAQ_APP_ERA.md`](docs/legacy/FAQ_APP_ERA.md) and do not apply.

## What is RAVEN right now?

A Rust command-line messenger. You run `ash` (or `raven`) in a terminal; a
local `raven-node` daemon holds the LAN listener. Two machines on the same
network exchange end-to-end-encrypted messages after each side has pinned the
other's identity. There is no Raven server, no account, no phone number.

## Does it work over the Internet?

Not yet. Internet dial, NAT traversal and the libp2p mailbox exist as
experimental, feature-gated code that refuses to run unless explicitly enabled,
and nothing in `ash send` selects them. See
[`node/NAT_TRAVERSAL.md`](node/NAT_TRAVERSAL.md).

## Does it work over Bluetooth or a mesh?

On the desktop, no — the BLE adapter is a software mock used by CI. The
store-carry-forward bridge (A → B → C over an untrusted relay) is implemented as
a policy layer and a deterministic harness, but `ash send` does not pick a
bridge automatically. Legacy iOS BLE code is in `ios-native/` and is not part of
the terminal product.

## How do two machines find each other?

Manually. You exchange address, public key and fingerprint out of band, pin the
contact with `ash contact add … --verify-fp`, and give the peer's `host:port`
once (`--lan-dial`). There is no mDNS/Bonjour discovery yet.

## Which platforms?

macOS, GNU/Linux and Windows build and run the same binaries. Identity storage
differs: macOS Keychain and Windows DPAPI can create and load identities;
GNU/Linux can only load an existing Secret Service identity in a Release build
— fresh creation is deliberately blocked until the reviewed backend lands.
Debug builds accept `RAVEN_IDENTITY_BACKEND=locked-file` for lab profiles. See
the platform table in [`README.md`](README.md).

## What cryptography is used?

Ed25519 identities; Noise XX (`snow`) for the LAN transport; a hybrid X25519 +
ML-KEM-768 PairInit; ChaCha20-Poly1305 with HKDF-SHA256 for the indexed
session; HMAC-SHA256 routing tags. The primitives are standard; the way RAVEN
composes them (PairInit transcript, indexed session profile, Noise static key
derived from the identity seed) is its own and has not been independently
reviewed.

## Is the code that ships the same code that is tested?

Lab features (Full Braid ratchet, incremental ML-KEM, SQLCipher durable store,
demo crypto) are compiled out of Release builds with `compile_error!`, and CI
asserts that a Release build with those features fails. The four generic ATSAM
"production" tripwires are still `false`; the LAN slice is enabled by its own
compile-time constant (`LAN_DIRECT_PRODUCTION_ENABLED`).

## Where does my identity live? Is there a recovery phrase?

The Ed25519 seed lives in the platform store (Keychain / DPAPI / Secret
Service) for the profile's `--data-dir`. There is no cloud backup and no
recovery phrase; `ash device sync-export` produces a sealed out-of-band blob for
multi-device use. Losing the store means losing the identity.

## Why does `ash send --text` refuse to work?

Message bodies are read from stdin only, so plaintext never ends up in shell
history or process listings. Pipe the text: `printf '%s\n' 'hi' | ash send --contact @bob`.

## What is `agent_team/` (RDAP)?

An experimental Agent-to-Agent (A2A) delegation companion for LLM agents. It
reuses the `rvn1` address format and Ed25519 signatures, but it has its own key
store, sends over plaintext HTTP by default, and does not use the node's ATSAM
session. It is not "messaging over RAVEN" yet; its README states the gap.

## What about the older repositories and the website?

`Raven-offline-messenger/RAVEN` is a May 2026 snapshot of the iOS app and
FastAPI server. `raven-atsam-protocol` and `raven-security` are earlier
protocol/documentation snapshots. This repository is the source of truth; the
[errata](protocol/SECURITY_ERRATA_RVN1_2026-08-13.md) override any older claim.

## How do I report a security issue?

Privately, per [`SECURITY.md`](SECURITY.md). Never in a public issue.

## License?

AGPL-3.0-or-later for the code ([`LICENSE`](LICENSE), [`NOTICE`](NOTICE)).
The RAVEN name and artwork are reserved ([`TRADEMARK.md`](TRADEMARK.md),
[`ASSET_LICENSE.md`](ASSET_LICENSE.md)).
