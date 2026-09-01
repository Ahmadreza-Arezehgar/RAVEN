# Security Policy

## Reporting a vulnerability

Please report security issues privately. **Do not open a public GitHub issue.**

- Email: info@raven-messenger.com
- Subject: `[SECURITY] <short description>`
- Include: affected component and commit, reproduction steps, impact, and a
  suggested fix if you have one. Encrypted reports are welcome; ask for a key.

| Action | Target |
|---|---|
| Acknowledgement | within 48 hours |
| Initial assessment | within 5 business days |
| Fix or mitigation and coordinated disclosure | within 30 days, or an agreed timeline for protocol-level issues |

Researchers who report valid issues are credited with their permission.

## Scope

The **terminal product** is in scope:

| Component | Paths |
|---|---|
| Protocol core, crypto, stores, transport policy | `node/crates/raven-core/` |
| Daemon: LAN listener, same-user IPC, bridge harness | `node/crates/raven-node/` |
| Terminal client | `node/crates/ash/` |
| Experimental libp2p swarm / mailbox / NAT binaries | `node/crates/raven-swarm/` (feature-gated; still in scope) |
| Normative specifications, errata, reference codecs, vectors | `protocol/`, `protocol/reference/`, `shared-vectors/rvn1/` |
| Experimental A2A companion | `agent_team/` (see its README for its own threat model) |
| Build, release and CI scripts | `node/scripts/`, `scripts/`, `.github/workflows/` |

Especially valuable reports:

- Breaking the LAN path: Noise XX handshake, PairInit (X25519 + ML-KEM-768)
  transcript, indexed ATSAM session (ChaCha20-Poly1305), ACK, replay windows,
  or identity/contact pinning.
- Identity-store continuity: any way to fork a profile into two identities,
  downgrade to a plaintext seed, or bypass the Release refusals of lab backends.
- Relay/bridge abuse beyond the documented limits (unauthenticated hop and
  replication counters are a known, documented boundary — see
  `protocol/SECURITY_ERRATA_RVN1_2026-08-13.md` §8).
- A Release build that links any `*-lab`, `unsafe-demo-crypto`, or
  `debug-trace-delivery` feature.
- Local privilege boundaries: IPC socket/pipe authorization, file permissions,
  Windows DACL behaviour.
- RDAP: signature or replay bypass, Git-relay poisoning, `read_file` path-policy
  escape, or any path by which a peer's task obtains shell or write access
  without `--allow-shell`.

Application-era code (`ios-native/`, `RAVEN-*/`, `server/`, `news_bot/`,
`simulation/`) is legacy. Reports are still welcome, but fixes are not
guaranteed and those trees carry no security claims for the terminal product.

## Out of scope

- Denial of service against a node you do not own, and volumetric attacks.
- Social engineering of maintainers or users.
- Vulnerabilities in third-party dependencies without a RAVEN-specific impact
  (report upstream; tell us if RAVEN's usage makes it exploitable).
- Findings that require the operator to enable a documented unsafe override
  (`--open`, `--allow-shell`, `unsafe-demo-crypto`, `RAVEN_UNSAFE_*`,
  `RAVEN_LAB_TEST_A` in Debug) and stay within that override's documented
  authority.

## What we claim, and what we do not

- **Enabled today:** authenticated, end-to-end-encrypted 1:1 messaging between
  two terminals on the same LAN, with manual out-of-band identity pinning.
- **Not enabled:** Internet delivery, NAT traversal, DHT discovery, desktop BLE,
  automatic bridge routing, contact requests over the wire. These are
  fail-closed or experimental and must not be reported as "broken" — they are
  intentionally off.
- **No independent cryptographic review has been completed.** The primitives
  are standard; the composition is RAVEN's own.
- Lab constructions (Full Braid, incremental ML-KEM, SQLCipher durable profile)
  are compiled out of Release builds.
- Public documents in `Raven-offline-messenger/raven-security` predate parts of
  this tree; the errata and `node/FINAL_SERVERLESS_PROOF.md` are authoritative.

## Secret hygiene

Never commit identity seeds, `~/.raven-ash` state, `agent_team/.team/`,
`.env` files, tokens, or repository exports. `scripts/secret_history_scan.sh
--ci` runs in CI; if you find a secret in history, report it privately so it
can be rotated before any public rewrite.
