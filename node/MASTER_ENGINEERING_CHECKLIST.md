# RAVEN Serverless Terminal Messaging

## Master Engineering Checklist

**Project:** RAVEN
**Primary objective:** Build a secure, decentralized text-messaging network that can be used from Windows, macOS and Linux terminals and can exchange messages with Raven mobile clients.
**Terminal entry command:** `ash`
**Canonical components:** `raven-node`, `raven-core`, `raven-cli`
**Initial scope:** One-to-one text messages only
**Primary priority order:** Security → Correctness → Interoperability → Reliability → Performance → UX

---

# 1. Completion Rules

No checkbox may be marked complete merely because code or documentation exists.

For every completed item, provide:

* [ ] The commit SHA containing the work.
* [ ] The exact files changed.
* [ ] Unit or integration tests proving the behavior.
* [ ] Negative tests proving invalid behavior is rejected.
* [ ] Security implications.
* [ ] Compatibility implications for Windows, macOS, Linux and iOS.
* [ ] Known limitations.
* [ ] Reviewer name or review record.
* [ ] Status: `DRAFT`, `IMPLEMENTED`, `REVIEWED`, or `FROZEN`.
* [ ] Evidence that unrelated Raven functionality was not silently changed.
* [ ] Evidence that no secret, credential or private key was committed.

A task is not complete if it:

* [ ] Works only on localhost.
* [ ] Works only with mocked peers.
* [ ] Depends secretly on the existing Raven API server.
* [ ] Works only when sender and recipient are simultaneously online.
* [ ] Works on only one operating system.
* [ ] Has no negative or adversarial tests.
* [ ] Requires plaintext messages to pass through a relay or bridge.
* [ ] Has not been tested after process termination and restart.
* [ ] Has documentation that disagrees with the implementation.

---

# 2. Non-Negotiable Product Requirements

* [ ] Raven text messaging must not require a trusted central message server.
* [ ] Raven text messaging must not require a central user database.
* [ ] Raven text messaging must not require a central routing database.
* [ ] Raven text messaging must not require Raven-operated infrastructure.
* [ ] Raven-operated bootstrap, relay or store nodes may exist only as optional and replaceable peers.
* [ ] Community members must be able to operate equivalent bootstrap, relay and store nodes.
* [ ] The network must continue operating between known peers when Raven-operated nodes are unavailable.
* [ ] A user must be able to install Raven and launch the terminal messenger using `ash`.
* [ ] Windows, macOS and Linux computers must be able to run persistent Raven nodes.
* [ ] Raven terminal nodes must exchange messages with Raven mobile applications.
* [ ] Text messaging must work over Internet P2P connectivity.
* [ ] Text messaging must work over local Bluetooth connectivity where supported.
* [ ] A Raven Bridge must forward messages between Bluetooth and Internet transports.
* [ ] A single logical message must retain the same message identity across every transport.
* [ ] Relay, bridge, bootstrap, DHT and store nodes must not be trusted with message plaintext.
* [ ] Messages must be encrypted on the sender endpoint and decrypted only on authorized recipient endpoints.
* [ ] Offline recipients must be able to receive messages later through encrypted store-and-forward.
* [ ] A relay accepting an envelope must not be reported as final delivery.
* [ ] Final delivery must require an authenticated acknowledgement from an authorized recipient device.
* [ ] The first release must remain limited to one-to-one text messaging.
* [ ] Groups, media, calls, feeds and social features must not delay the text-messaging foundation.

---

# 3. Exact Meaning of “Serverless”

For this project, serverless means:

> No trusted central application server, no mandatory central messaging service and no single authoritative infrastructure operator.

It does not mean that no device may listen for incoming connections.

* [ ] Document this definition in `docs/SERVERLESS_MODEL.md`.
* [ ] Explain that a Raven node may technically perform server-like functions for another node.
* [ ] Explain that relay, DHT, bootstrap and store functions are network roles, not trusted authorities.
* [ ] Prove that a user can connect using manually supplied peer addresses without a Raven-owned bootstrap server.
* [ ] Prove that known peers can continue communicating when all Raven-operated infrastructure is blocked.
* [ ] Ensure no network role has access to end-to-end message keys.
* [ ] Ensure no network role can create a valid message on behalf of an endpoint.
* [ ] Ensure no network role can silently alter the recipient of an encrypted message.
* [ ] Ensure no central service assigns or owns the cryptographic Raven identity.
* [ ] Ensure no central service is required to validate a Raven identity.
* [ ] Ensure no central service is required to store conversation history.
* [ ] Ensure no central service is required to report delivery.
* [ ] Ensure optional services are explicitly labeled optional.
* [ ] Do not use “serverless” in marketing until the mandatory serverless tests pass.

---

# 4. V1 Scope

## Included

* [ ] Local identity creation.
* [ ] Device identity creation.
* [ ] Cryptographic Raven address.
* [ ] Optional user-selected `@alias`.
* [ ] Local contacts.
* [ ] One-to-one text messages.
* [ ] Conversation history.
* [ ] Internet P2P transport.
* [ ] NAT traversal.
* [ ] Relay fallback.
* [ ] Offline encrypted store-and-forward.
* [ ] Bluetooth transport.
* [ ] Bluetooth-to-Internet Bridge.
* [ ] Internet-to-Bluetooth Bridge.
* [ ] Terminal-to-terminal messaging.
* [ ] Terminal-to-mobile messaging.
* [ ] Mobile-to-terminal messaging.
* [ ] Delivery acknowledgements.
* [ ] Persistent outgoing queues.
* [ ] Persistent incoming messages.
* [ ] Node restart recovery.
* [ ] Blocking and basic message-request controls.
* [ ] Cross-platform installers.

## Explicitly Out of Scope

* [ ] Do not implement group messaging in V1.
* [ ] Do not implement audio or video calling in V1.
* [ ] Do not implement images, files or attachments in V1.
* [ ] Do not implement audio rooms in V1.
* [ ] Do not implement a social feed in V1.
* [ ] Do not implement RavenShot in V1.
* [ ] Do not implement cryptocurrency or tokens.
* [ ] Do not implement blockchain-based identity or aliases.
* [ ] Do not create global consensus for every message.
* [ ] Do not claim complete anonymity.
* [ ] Do not claim perfect metadata protection.
* [ ] Do not claim guaranteed background iOS delivery when the operating system does not permit it.
* [ ] Do not build an AI-based routing system in V1.
* [ ] Do not create new cryptographic primitives.

---

# 5. Repository and Baseline Safety

* [ ] Create a dedicated feature branch for the serverless messaging work.
* [ ] Record the branch name and starting commit.
* [ ] Record all existing uncommitted changes before modifying files.
* [ ] Separate unrelated Raven changes from the serverless messaging work.
* [ ] Do not overwrite or revert unrelated work without explicit approval.
* [ ] Produce a repository architecture map.
* [ ] Identify all current centralized messaging dependencies.
* [ ] Identify all current WebSocket messaging dependencies.
* [ ] Identify all current FastAPI messaging dependencies.
* [ ] Identify all current APNs dependencies.
* [ ] Identify all current authentication-server dependencies.
* [ ] Identify all current user-database dependencies.
* [ ] Identify all current contact-discovery dependencies.
* [ ] Identify all current message-storage dependencies.
* [ ] Identify all current BLE mesh implementations.
* [ ] Identify all existing message envelope formats.
* [ ] Identify all existing identity and device-key implementations.
* [ ] Identify all existing ATSAM implementations and claims.
* [ ] Identify all existing cross-platform protocol test vectors.
* [ ] Record contradictions between documentation and implementation.
* [ ] Run and record the complete baseline test suite.
* [ ] Record all pre-existing failing tests.
* [ ] Record all pre-existing warnings.
* [ ] Generate a software dependency inventory.
* [ ] Generate a software bill of materials.
* [ ] Scan the current branch for committed credentials.
* [ ] Scan full Git history for credentials and private keys.
* [ ] Rotate every credential that may previously have been exposed.
* [ ] Confirm no production database copy exists in the repository.
* [ ] Confirm no Apple signing certificate exists in the repository.
* [ ] Confirm no private Raven identity key exists in the repository.
* [ ] Confirm no `.env` file containing secrets exists in tracked history.
* [ ] Freeze unrelated feature development during protocol-freeze work.

---

# 6. Required Architecture Decisions

Create a written Architecture Decision Record for every major choice.

* [ ] ADR: Canonical implementation language.
* [ ] ADR: Canonical networking framework.
* [ ] ADR: Canonical wire serialization format.
* [ ] ADR: Canonical cryptographic libraries.
* [ ] ADR: User identity model.
* [ ] ADR: Device identity model.
* [ ] ADR: Transport peer identity model.
* [ ] ADR: Alias-resolution model.
* [ ] ADR: Asynchronous first-contact session establishment.
* [ ] ADR: Offline mailbox design.
* [ ] ADR: Store-node replication strategy.
* [ ] ADR: Bridge architecture.
* [ ] ADR: Bluetooth fragmentation and reassembly.
* [ ] ADR: Local database encryption.
* [ ] ADR: Local daemon IPC.
* [ ] ADR: Windows background-service model.
* [ ] ADR: macOS background-service model.
* [ ] ADR: Linux background-service model.
* [ ] ADR: Mobile light-node restrictions.
* [ ] ADR: Optional notification infrastructure.
* [ ] ADR: Update signing and binary distribution.
* [ ] ADR: Migration from existing centralized text messaging.

Recommended default unless rejected through a documented ADR:

* [ ] Use Rust for the canonical cross-platform Raven Node.
* [ ] Use `rust-libp2p` for Internet peer connectivity.
* [ ] Use QUIC as the preferred Internet transport.
* [ ] Use TCP as a compatibility fallback.
* [ ] Use Noise or the secure channel provided by the selected libp2p stack for transport security.
* [ ] Retain independent Raven end-to-end encryption above transport encryption.
* [ ] Use SQLite for local persistence.
* [ ] Use platform secure storage for local master keys.
* [ ] Use authenticated local IPC rather than a public localhost HTTP API.

---

# 7. Prior-Art and Standards Review

Before freezing architecture:

* [ ] Review Berty and Wesh Network.
* [ ] Review Briar and Briar Mailbox.
* [ ] Review Tox and terminal-based Tox clients.
* [ ] Review Jami and OpenDHT.
* [ ] Review libp2p peer discovery and NAT traversal.
* [ ] Review Noise Protocol patterns.
* [ ] Review Signal asynchronous session establishment.
* [ ] Review Signal Double Ratchet behavior.
* [ ] Review out-of-order and skipped-message handling.
* [ ] Review IETF Delay-Tolerant Networking concepts.
* [ ] Review IETF Bundle Protocol concepts.
* [ ] Review Messaging Layer Security only for future group design.
* [ ] Review Sybil and Eclipse attack literature for DHTs.
* [ ] Review mobile operating-system Bluetooth background restrictions.
* [ ] Record what Raven will reuse conceptually.
* [ ] Record what Raven will not copy.
* [ ] Record known failures or limitations of comparable systems.
* [ ] Confirm no “world’s first” claim is made without defensible evidence.

---

# 8. Phase A — Protocol Freeze

No production implementation may be declared stable before the following specifications agree with one another.

* [ ] Create `RAVEN_IDENTITY_V1.md`.
* [ ] Create `RAVEN_ADDRESS_V1.md`.
* [ ] Create `RAVEN_DEVICE_CERTIFICATE_V1.md`.
* [ ] Create `RAVEN_ALIAS_RECORD_V1.md`.
* [ ] Create `RAVEN_ENVELOPE_V1.md`.
* [ ] Create `RAVEN_ACK_V1.md`.
* [ ] Create `RAVEN_ROUTING_TAG_V1.md`.
* [ ] Create `RAVEN_CAPABILITIES_V1.md`.
* [ ] Create `RAVEN_PREKEY_BUNDLE_V1.md`.
* [ ] Create `RAVEN_STORE_OBJECT_V1.md`.
* [ ] Create `RAVEN_BRIDGE_V1.md`.
* [ ] Create `RAVEN_BLE_FRAMING_V1.md`.
* [ ] Create `RAVEN_TRANSPORT_INTERFACE_V1.md`.
* [ ] Create `RAVEN_PROTOCOL_VERSIONING.md`.
* [ ] Create `RAVEN_ERROR_CODES_V1.md`.
* [ ] Create `RAVEN_DELIVERY_STATE_V1.md`.
* [ ] Create `RAVEN_THREAT_MODEL.md`.
* [ ] Create `RAVEN_INTEROPERABILITY_MATRIX.md`.

For every V1 protocol object:

* [ ] Define the exact fields.
* [ ] Define field order where relevant.
* [ ] Define byte order.
* [ ] Define canonical serialization.
* [ ] Define maximum field sizes.
* [ ] Define mandatory fields.
* [ ] Define optional fields.
* [ ] Define prohibited fields.
* [ ] Define version behavior.
* [ ] Define unknown-field behavior.
* [ ] Define signature domain separation.
* [ ] Define validation order.
* [ ] Define expiration behavior.
* [ ] Define replay behavior.
* [ ] Define malformed-input behavior.
* [ ] Define backward-compatibility behavior.
* [ ] Define forward-compatibility behavior.
* [ ] Produce positive test vectors.
* [ ] Produce negative test vectors.
* [ ] Produce mutation test vectors.
* [ ] Produce cross-platform test vectors.
* [ ] Produce human-readable examples.
* [ ] Produce binary or hex examples.

Protocol-freeze restrictions:

* [ ] Do not sign platform-generated JSON without deterministic canonicalization.
* [ ] Do not use display-formatted addresses inside signatures.
* [ ] Do not use user-selected aliases as cryptographic identity.
* [ ] Do not expose plaintext usernames in message envelopes.
* [ ] Do not expose plaintext recipient IDs unnecessarily.
* [ ] Do not allow silent algorithm negotiation.
* [ ] Do not allow unauthenticated downgrade negotiation.
* [ ] Do not freeze the protocol until all contradictions are recorded.
* [ ] Do not proceed to implementation until an independent reviewer approves the freeze packet.

---

# 9. Raven Identity

Raven must separate user, device and transport identities.

## User Identity

* [ ] Define a long-term Raven User Identity key.
* [ ] Generate the User Identity locally.
* [ ] Never request the identity private key from a central server.
* [ ] Never upload the identity private key.
* [ ] Never print the identity private key in Terminal.
* [ ] Never include the identity private key in logs.
* [ ] Never pass the identity private key through command-line arguments.
* [ ] Define how a User Identity authorizes devices.
* [ ] Define how a User Identity signs device certificates.
* [ ] Define how a User Identity revokes devices.
* [ ] Define how identity recovery works.
* [ ] Define what happens if recovery is impossible.
* [ ] Define the security implications of identity export.
* [ ] Define the security implications of a compromised unlocked endpoint.

## Device Identity

* [ ] Generate a separate identity for each device.
* [ ] Bind each Device Identity to the User Identity using a signed certificate.
* [ ] Include device-certificate version.
* [ ] Include creation time.
* [ ] Include expiration or rotation policy.
* [ ] Include device capabilities only when necessary.
* [ ] Do not include unnecessary hardware identifiers.
* [ ] Support multiple authorized devices per user.
* [ ] Encrypt messages separately for authorized recipient devices where required.
* [ ] Do not share one static private messaging key across all user devices.
* [ ] Implement device revocation.
* [ ] Implement device-addition authorization.
* [ ] Warn existing contacts when trusted device state changes materially.
* [ ] Reject messages signed by revoked devices after valid revocation information is known.
* [ ] Document limitations during network partitions.

## Transport Identity

* [ ] Separate libp2p Peer ID from Raven User Identity.
* [ ] Do not use Bluetooth MAC addresses as Raven identities.
* [ ] Do not use IP addresses as Raven identities.
* [ ] Define whether transport identities rotate.
* [ ] Define how rotated transport identities remain authorized.
* [ ] Ensure transport identity rotation does not break abuse controls.
* [ ] Minimize linkability between Raven identity and network addresses.
* [ ] Document remaining metadata leakage.

---

# 10. Raven Address

The canonical Raven address must be self-certifying and versioned.

* [ ] Use Bech32m for Raven Address V1 unless the approved ADR says otherwise.
* [ ] Use HRP `rvn`.
* [ ] Define the exact payload byte layout.
* [ ] Include an explicit address version.
* [ ] Include an explicit identity type where necessary.
* [ ] Include a cryptographic identity fingerprint or equivalent payload.
* [ ] Define the fingerprint algorithm.
* [ ] Define fingerprint length.
* [ ] Define checksum behavior.
* [ ] Define maximum address length.
* [ ] Generate canonical addresses in lowercase.
* [ ] Reject mixed-case Bech32m strings.
* [ ] Treat uppercase or grouped representations as display-only.
* [ ] Never sign the grouped display representation.
* [ ] Never store the grouped display representation as canonical identity.
* [ ] Compare decoded payloads, not formatted strings.
* [ ] Reject invalid checksums.
* [ ] Reject unsupported address versions.
* [ ] Reject malformed payload lengths.
* [ ] Provide positive address vectors.
* [ ] Provide invalid-checksum vectors.
* [ ] Provide mixed-case rejection vectors.
* [ ] Provide single-character mutation vectors.
* [ ] Provide insertion and deletion mutation tests.
* [ ] Test identical address behavior on Windows, macOS, Linux and iOS.

---

# 11. Aliases and Contacts

A human-readable alias is for discovery, not cryptographic trust.

* [ ] Allow a user to select an alias such as `@ahmad`.
* [ ] Define allowed alias characters.
* [ ] Define alias length limits.
* [ ] Define Unicode policy.
* [ ] Prefer a restricted normalized alias format to reduce spoofing.
* [ ] Define case sensitivity.
* [ ] Define normalization rules.
* [ ] Reject invisible-control characters in aliases.
* [ ] Detect Unicode confusable aliases.
* [ ] Never use alias text as the encryption recipient key.
* [ ] Map aliases to cryptographic Raven addresses using signed records.
* [ ] Include alias-record version.
* [ ] Include identity address.
* [ ] Include sequence number.
* [ ] Include expiration.
* [ ] Include signature.
* [ ] Verify alias signatures before displaying results.
* [ ] Reject expired alias records.
* [ ] Reject invalid sequence rollback.
* [ ] Detect multiple identities claiming the same alias.
* [ ] Never silently select one identity from ambiguous alias results.
* [ ] Display abbreviated Raven addresses when aliases are ambiguous.
* [ ] Display fingerprints when aliases are ambiguous.
* [ ] Warn when a trusted alias suddenly points to a different identity.
* [ ] Do not silently overwrite a verified contact.
* [ ] Support adding contacts using full Raven address.
* [ ] Support adding contacts using QR code.
* [ ] Support adding contacts using an alias.
* [ ] Support adding contacts using nearby Bluetooth pairing.
* [ ] Support fingerprint verification.
* [ ] Support contact blocking.
* [ ] Support message requests from unknown identities.
* [ ] Apply strict limits to unknown senders.
* [ ] Store contact lists locally.
* [ ] Do not publish the user’s contact list.
* [ ] Do not publish the user’s social graph.
* [ ] Encrypt contact synchronization between authorized user devices.
* [ ] Define safe contact export.
* [ ] Define safe contact import.

---

# 12. Asynchronous First Contact

A sender must be able to initiate an encrypted conversation while the recipient is offline.

* [ ] Define the asynchronous first-contact protocol.
* [ ] Define the signed recipient prekey bundle.
* [ ] Define identity key inclusion.
* [ ] Define signed prekey inclusion.
* [ ] Define one-time or limited-use prekey behavior.
* [ ] Define prekey expiration.
* [ ] Define prekey sequence numbers.
* [ ] Define rollback protection.
* [ ] Define replay protection.
* [ ] Define how prekey bundles are published without a central server.
* [ ] Define how prekey bundles are replicated.
* [ ] Define how stale bundles are removed.
* [ ] Define how depleted bundles are replenished.
* [ ] Define how concurrent senders are handled.
* [ ] Define behavior if a one-time prekey is reused due to distributed-state races.
* [ ] Authenticate all prekey records.
* [ ] Bind prekey records to the Raven identity.
* [ ] Reject unsigned prekey bundles.
* [ ] Reject expired prekey bundles.
* [ ] Reject unsupported algorithm suites.
* [ ] Prevent downgrade to weaker suites.
* [ ] Produce first-contact test vectors.
* [ ] Test sender online and recipient offline.
* [ ] Test both parties initially offline from one another.
* [ ] Test stale prekey replay.
* [ ] Test malicious prekey substitution.
* [ ] Test identity-key mismatch.
* [ ] Test first message through a relay.
* [ ] Test first message through store-and-forward.
* [ ] Test first message through a BLE Bridge.

---

# 13. Cryptographic Requirements

* [ ] Use established cryptographic primitives.
* [ ] Use maintained and reviewed cryptographic libraries.
* [ ] Do not implement low-level cryptographic primitives manually.
* [ ] Document every algorithm.
* [ ] Document every key type.
* [ ] Document every nonce source.
* [ ] Document every KDF input.
* [ ] Use domain separation for different cryptographic purposes.
* [ ] Use authenticated encryption for message content.
* [ ] Generate a fresh message key for every message.
* [ ] Support forward secrecy.
* [ ] Support post-compromise recovery where the selected ratchet provides it.
* [ ] Support lost messages.
* [ ] Support out-of-order messages.
* [ ] Bound skipped-message key storage.
* [ ] Prevent malicious skipped-key memory exhaustion.
* [ ] Authenticate ratchet headers as required.
* [ ] Define session-reset behavior.
* [ ] Define session-corruption recovery.
* [ ] Define key-change warnings.
* [ ] Define downgrade resistance.
* [ ] Use operating-system CSPRNG facilities through reviewed libraries.
* [ ] Fail closed if secure randomness is unavailable.
* [ ] Never reuse an AEAD nonce under the same key.
* [ ] Add nonce-reuse tests.
* [ ] Add corrupted-ciphertext tests.
* [ ] Add wrong-key tests.
* [ ] Add truncated-message tests.
* [ ] Add modified-header tests.
* [ ] Add replay tests.
* [ ] Add downgrade tests.
* [ ] Add cross-platform encryption vectors.
* [ ] Add cross-platform decryption vectors.
* [ ] Add cross-platform signature vectors.

If ATSAM retains hybrid post-quantum pairing:

* [ ] Define the exact classical algorithm.
* [ ] Define the exact post-quantum algorithm.
* [ ] Define the exact hybrid combiner.
* [ ] Define failure behavior if one component fails.
* [ ] Prevent algorithm stripping.
* [ ] Prevent downgrade to classical-only mode without explicit authenticated policy.
* [ ] Produce deterministic interoperability vectors where possible.
* [ ] Produce malformed ML-KEM input tests.
* [ ] Produce hybrid-key mismatch tests.
* [ ] Obtain independent cryptographic review before production claims.

---

# 14. Key Storage

* [ ] Use macOS Keychain for protected local key material.
* [ ] Use appropriate Windows secure storage such as DPAPI-backed protection.
* [ ] Use Linux Secret Service or an approved secure local-keystore design.
* [ ] Restrict key-file permissions.
* [ ] Do not store private keys in plaintext configuration.
* [ ] Do not store private keys in environment variables.
* [ ] Do not pass private keys in process arguments.
* [ ] Do not include private keys in crash reports.
* [ ] Do not include private keys in diagnostic bundles.
* [ ] Define behavior when the secure store is locked.
* [ ] Define optional passphrase behavior.
* [ ] Define headless-server key-unlock behavior.
* [ ] Prevent unattended nodes from silently weakening key protection.
* [ ] Define encrypted identity backup.
* [ ] Require explicit confirmation before identity export.
* [ ] Protect exported identity material with authenticated encryption.
* [ ] Warn users that possession of exported identity material grants control.
* [ ] Test copied-database attacks.
* [ ] Test copied-config-directory attacks.
* [ ] Test wrong-user local access.
* [ ] Test locked-device behavior.

---

# 15. Canonical Raven Envelope

* [ ] Define one canonical `RavenEnvelopeV1`.
* [ ] Use the same logical envelope across Internet, relay, store and Bluetooth.
* [ ] Include protocol version.
* [ ] Include cryptographically random message ID.
* [ ] Include envelope type.
* [ ] Include opaque routing information.
* [ ] Include creation time.
* [ ] Include expiration.
* [ ] Include hop or forwarding controls.
* [ ] Include replication controls where required.
* [ ] Include encrypted ratchet/session header.
* [ ] Include ciphertext.
* [ ] Include authentication material.
* [ ] Include replay-prevention material.
* [ ] Minimize exposed metadata.
* [ ] Do not include plaintext message content.
* [ ] Do not include plaintext sender alias.
* [ ] Do not include plaintext recipient alias.
* [ ] Do not include plaintext conversation title.
* [ ] Do not include a permanent public mailbox name.
* [ ] Define maximum text-message size.
* [ ] Reject oversized envelopes before expensive processing.
* [ ] Define canonical serialization.
* [ ] Define strict parser behavior.
* [ ] Define unknown-field behavior.
* [ ] Define version-negotiation behavior.
* [ ] Define fragmentation as a transport concern, not a new logical message.
* [ ] Preserve one message ID across all fragments and transports.
* [ ] Test byte-identical cross-platform encoding where required.
* [ ] Test semantic interoperability where cryptographic signatures are randomized.
* [ ] Fuzz the envelope decoder.

---

# 16. Delivery States and Acknowledgements

Required internal states:

* [ ] `CREATED`
* [ ] `ENCRYPTED`
* [ ] `QUEUED`
* [ ] `ROUTE_DISCOVERING`
* [ ] `FORWARDED`
* [ ] `DELIVERED_TO_DEVICE`
* [ ] `READ`, only if encrypted read receipts are enabled later
* [ ] `EXPIRED`
* [ ] `FAILED`

Behavior:

* [ ] Persist a message before attempting network transmission.
* [ ] Do not report `DELIVERED_TO_DEVICE` when a relay accepts it.
* [ ] Do not report `DELIVERED_TO_DEVICE` when a store node accepts it.
* [ ] Do not report `DELIVERED_TO_DEVICE` when a Bridge forwards it.
* [ ] Generate an authenticated recipient-device acknowledgement.
* [ ] Encrypt acknowledgement content.
* [ ] Bind the acknowledgement to the original message ID.
* [ ] Reject forged acknowledgements.
* [ ] Reject replayed acknowledgements.
* [ ] Allow acknowledgements to return by a different route.
* [ ] Persist acknowledgement state atomically.
* [ ] Prevent duplicate conversation entries.
* [ ] Handle acknowledgement arrival before UI refresh.
* [ ] Handle acknowledgement arrival after application restart.
* [ ] Define expiration behavior if no acknowledgement is received.
* [ ] Display `Queued`, `Forwarded`, `Delivered`, and `Expired` accurately.
* [ ] Do not mislead users about guaranteed delivery.

---

# 17. Raven Node Core

* [ ] Implement a canonical `raven-node` process.
* [ ] Keep `raven-node` separate from the terminal UI.
* [ ] Keep `raven-node` running after Terminal closes.
* [ ] Support Windows.
* [ ] Support macOS.
* [ ] Support Linux.
* [ ] Support headless operation.
* [ ] Support user-controlled node roles.
* [ ] Support automatic node-role selection.
* [ ] Support client-only mode.
* [ ] Support relay mode.
* [ ] Support encrypted-store mode.
* [ ] Support Bridge mode.
* [ ] Support bootstrap/DHT mode where appropriate.
* [ ] Keep cryptographic endpoint logic separated from untrusted relay/Bridge logic.
* [ ] Implement explicit node state machines.
* [ ] Implement clean startup.
* [ ] Implement clean shutdown.
* [ ] Implement crash recovery.
* [ ] Implement database migration handling.
* [ ] Implement configuration validation.
* [ ] Implement bounded worker queues.
* [ ] Implement bounded connection counts.
* [ ] Implement bounded memory use.
* [ ] Implement bounded disk use.
* [ ] Implement bounded CPU-intensive operations.
* [ ] Implement graceful behavior when disk is full.
* [ ] Implement graceful behavior when secure storage is unavailable.
* [ ] Implement graceful behavior when Bluetooth hardware is absent.
* [ ] Implement graceful behavior when Internet is absent.
* [ ] Implement graceful behavior during network transitions.
* [ ] Do not expose a remote administrative interface by default.
* [ ] Do not expose a public localhost HTTP API by default.

---

# 18. Background Service Integration

## Windows

* [ ] Implement a per-user background process or properly scoped Windows Service.
* [ ] Apply restrictive service permissions.
* [ ] Use a named pipe with user-specific ACLs for CLI communication.
* [ ] Confirm another local user cannot control the node.
* [ ] Confirm another local user cannot read messages through IPC.
* [ ] Support clean installation.
* [ ] Support clean update.
* [ ] Support clean uninstall.
* [ ] Avoid requiring administrator access unless genuinely necessary.

## macOS

* [ ] Implement a user-scoped `launchd` service.
* [ ] Use a Unix-domain socket or equivalent protected IPC.
* [ ] Restrict socket permissions.
* [ ] Integrate with Keychain.
* [ ] Support signed and notarized distribution.
* [ ] Support clean uninstall.

## Linux

* [ ] Implement a user-scoped `systemd` service.
* [ ] Provide a non-systemd foreground/headless mode.
* [ ] Use a protected Unix-domain socket.
* [ ] Restrict socket and configuration permissions.
* [ ] Define integration with Secret Service or approved key storage.
* [ ] Support clean uninstall.
* [ ] Do not overwrite system shells or system binaries.

---

# 19. Local IPC Security

* [ ] Authenticate CLI-to-daemon communication.
* [ ] Use Unix peer credentials where available.
* [ ] Use Windows Named Pipe ACLs and client identity verification.
* [ ] Limit IPC to the owning user.
* [ ] Prevent cross-user message access.
* [ ] Prevent cross-user contact access.
* [ ] Prevent unauthorized identity export.
* [ ] Prevent unauthorized configuration changes.
* [ ] Version the IPC protocol.
* [ ] Validate all IPC input.
* [ ] Set message-size limits.
* [ ] Sanitize error responses.
* [ ] Do not send private keys through IPC unless the architecture explicitly requires it.
* [ ] Prefer keeping private-key operations inside the protected core.
* [ ] Fuzz the IPC parser.
* [ ] Test malicious local clients.
* [ ] Test stale CLI versions.
* [ ] Test daemon restart while CLI is open.

---

# 20. Terminal Command and Installation

The desired user-facing entry command is:

```bash
ash
```

There is a compatibility concern: `ash` is also used as the name of an existing Unix shell on some systems.

Therefore:

* [ ] Provide `raven` as the canonical unambiguous binary name.
* [ ] Provide `ash` as the desired Raven launcher where safe.
* [ ] Detect whether an `ash` command already exists.
* [ ] Never overwrite `/bin/ash`, BusyBox `ash`, or another existing system shell.
* [ ] Never alter a user’s default shell.
* [ ] Never replace an existing executable without explicit informed consent.
* [ ] Use a user-scoped launcher or shell function where necessary.
* [ ] Provide a clear fallback to `raven` when `ash` conflicts.
* [ ] Document command-conflict behavior.
* [ ] Test command installation on Windows PowerShell.
* [ ] Test command installation on Windows Terminal.
* [ ] Test command installation on macOS zsh.
* [ ] Test command installation on macOS bash.
* [ ] Test command installation on Linux bash.
* [ ] Test command installation on Linux zsh.
* [ ] Test installation on a Linux environment that already has `/bin/ash`.
* [ ] Ensure uninstall removes only Raven-created launchers.

---

# 21. Terminal First-Run Flow

When the user runs:

```bash
ash
```

for the first time:

* [ ] Detect whether a local Raven identity exists.
* [ ] Offer to create a new identity.
* [ ] Explain that identity is created locally.
* [ ] Generate user and device identity securely.
* [ ] Secure the local keystore.
* [ ] Generate the canonical Raven address.
* [ ] Allow an optional display name.
* [ ] Allow an optional alias.
* [ ] Check alias format locally.
* [ ] Publish a signed alias record only with explicit user consent.
* [ ] Never print private key material.
* [ ] Never print recovery secrets automatically.
* [ ] Offer a separate protected recovery/export flow.
* [ ] Display the Raven address.
* [ ] Display the identity fingerprint.
* [ ] Offer QR display where the terminal supports it.
* [ ] Confirm that `raven-node` is running.
* [ ] Confirm network state.
* [ ] Continue into the main menu.

---

# 22. Terminal Main Menu

The primary interactive menu must remain simple:

```text
RAVEN

1. Messages
2. Send New Message
3. Contacts
```

* [ ] Display the local alias or abbreviated Raven address.
* [ ] Display Internet connectivity state.
* [ ] Display Bluetooth state.
* [ ] Display peer count.
* [ ] Display pending outgoing-message count.
* [ ] Display unread conversation count.
* [ ] Provide keyboard selection.
* [ ] Provide arrow-key selection where supported.
* [ ] Provide numeric selection.
* [ ] Provide a clear exit action.
* [ ] Return to the main menu without terminating `raven-node`.
* [ ] Support terminals without color.
* [ ] Support terminals without advanced Unicode borders.
* [ ] Support narrow terminal widths.
* [ ] Support UTF-8 messages.
* [ ] Handle Persian and other RTL text safely.
* [ ] Sanitize bidirectional control characters where they could cause identity spoofing.
* [ ] Never interpret message text as terminal commands.
* [ ] Never render untrusted ANSI escape sequences.
* [ ] Escape or remove control characters from incoming messages.

---

# 23. Messages Menu

* [ ] Display conversations rather than a raw message dump.
* [ ] Sort conversations by latest valid message.
* [ ] Show contact display name.
* [ ] Show alias when known.
* [ ] Show abbreviated Raven address when alias is unavailable.
* [ ] Show last-message preview safely.
* [ ] Sanitize terminal control sequences in previews.
* [ ] Show timestamp.
* [ ] Show unread count.
* [ ] Show outgoing delivery state.
* [ ] Show blocked-contact state where relevant.
* [ ] Allow opening a conversation.
* [ ] Allow returning to the main menu.
* [ ] Handle thousands of conversations through pagination or search.
* [ ] Do not load the full database into memory unnecessarily.
* [ ] Do not expose encrypted internal fields.

---

# 24. Chat History

* [ ] Display incoming and outgoing messages distinctly.
* [ ] Display timestamps.
* [ ] Display delivery states accurately.
* [ ] Display identity-verification state.
* [ ] Display security warnings for changed contact keys.
* [ ] Load history incrementally.
* [ ] Preserve chronological order based on defined message-ordering rules.
* [ ] Handle out-of-order network arrival.
* [ ] Avoid trusting sender-provided wall-clock time blindly.
* [ ] Allow typing a reply directly.
* [ ] Provide `/back`.
* [ ] Provide `/info`.
* [ ] Provide `/verify`.
* [ ] Provide `/block`.
* [ ] Provide `/clear-local-history` only with explicit confirmation.
* [ ] Do not send local commands as message text accidentally.
* [ ] Do not execute text received from the peer.
* [ ] Sanitize hyperlinks and terminal sequences.
* [ ] Support copying the full Raven address safely.
* [ ] Support displaying the full fingerprint.

---

# 25. Send New Message

* [ ] Display existing contacts first.
* [ ] Allow contact selection by number.
* [ ] Allow entering a full Raven address.
* [ ] Allow entering an `@alias`.
* [ ] Resolve aliases through signed decentralized records.
* [ ] Display ambiguity when multiple identities claim an alias.
* [ ] Require confirmation before messaging an unverified identity.
* [ ] Display the Raven address and fingerprint before first contact.
* [ ] Do not silently trust alias lookup.
* [ ] Create the session locally.
* [ ] Encrypt the message locally.
* [ ] Persist the encrypted outgoing message before transmission.
* [ ] Queue the message if no route exists.
* [ ] Display `Queued` rather than `Failed` when temporary delivery is possible.
* [ ] Retry without requiring Terminal to remain open.
* [ ] Support canceling an unsent local queue item where technically possible.
* [ ] Clearly state when cancellation cannot retract copies already forwarded.

---

# 26. Secure Command-Line Usage

Do not encourage plaintext messages in process arguments.

The following may expose text through shell history or process inspection:

```bash
ash send @person "secret message"
```

Therefore:

* [ ] Make `ash send @person` open an interactive protected message prompt.
* [ ] Do not place the message body in process arguments by default.
* [ ] Do not place private keys, passphrases or recovery material in process arguments.
* [ ] Warn if a user explicitly uses an unsafe inline-message option.
* [ ] Consider disabling inline plaintext messages in production builds.
* [ ] Support controlled stdin input only through an explicit option.
* [ ] Document that shell pipelines may expose data to other processes.
* [ ] Do not echo passphrases.
* [ ] Clear sensitive input buffers where reasonably possible.
* [ ] Ensure crash reports do not capture message input.
* [ ] Ensure debug logs do not capture message input.

Recommended command set:

* [ ] `ash`
* [ ] `ash messages`
* [ ] `ash chat @alias`
* [ ] `ash send @alias`
* [ ] `ash contacts`
* [ ] `ash contact add`
* [ ] `ash contact verify`
* [ ] `ash id`
* [ ] `ash status`
* [ ] `ash doctor`
* [ ] `ash node status`
* [ ] `ash node config`
* [ ] `ash node peers`
* [ ] `ash node bridge on`
* [ ] `ash node bridge off`
* [ ] `ash node relay on`
* [ ] `ash node relay off`
* [ ] `ash node store on`
* [ ] `ash node store off`
* [ ] `ash backup`
* [ ] `ash restore`

---

# 27. Local Database and Persistent Queues

* [ ] Use an encrypted local database.
* [ ] Store contacts.
* [ ] Store conversation metadata.
* [ ] Store message ciphertext or protected local message records.
* [ ] Store delivery states.
* [ ] Store ratchet/session state securely.
* [ ] Store outgoing queue state.
* [ ] Store incoming deduplication state.
* [ ] Store acknowledgement state.
* [ ] Store device certificates.
* [ ] Store alias cache with expiration.
* [ ] Store peer metadata conservatively.
* [ ] Avoid storing unnecessary network metadata.
* [ ] Persist outgoing messages before sending.
* [ ] Commit incoming messages atomically before acknowledging.
* [ ] Make queue operations crash-safe.
* [ ] Make database migrations transactional.
* [ ] Test power loss during database writes.
* [ ] Test process termination during queue updates.
* [ ] Test duplicate acknowledgement arrival.
* [ ] Test database recovery.
* [ ] Test disk-full behavior.
* [ ] Define maximum database size.
* [ ] Define history-retention controls.
* [ ] Define best-effort secure deletion limitations.
* [ ] Prevent copied database files from trivially exposing plaintext.
* [ ] Do not use one global unprotected key file.

---

# 28. Internet P2P Networking

* [ ] Implement direct peer connectivity.
* [ ] Implement QUIC transport.
* [ ] Implement TCP fallback.
* [ ] Implement IPv4 support.
* [ ] Implement IPv6 support.
* [ ] Implement connection encryption.
* [ ] Authenticate peer transport identities.
* [ ] Keep Raven E2EE independent of transport encryption.
* [ ] Implement explicit Raven protocol IDs.
* [ ] Implement protocol capability negotiation.
* [ ] Authenticate sensitive capability negotiation.
* [ ] Prevent protocol downgrade.
* [ ] Implement connection timeouts.
* [ ] Implement stream timeouts.
* [ ] Implement idle connection cleanup.
* [ ] Implement reconnect backoff.
* [ ] Implement peer scoring.
* [ ] Implement per-peer resource limits.
* [ ] Implement malformed-frame rejection.
* [ ] Implement maximum-frame limits.
* [ ] Implement local LAN discovery.
* [ ] Authenticate peers after discovery.
* [ ] Do not treat discovery as trust.
* [ ] Test direct communication without a central server.
* [ ] Test communication after Raven-owned nodes are blocked.

---

# 29. DHT and Peer Discovery

* [ ] Implement a Kademlia-style DHT or approved equivalent.
* [ ] Use the DHT for discovery, not as a plaintext message database.
* [ ] Define all record types.
* [ ] Sign all identity-sensitive DHT records.
* [ ] Version all DHT records.
* [ ] Expire all DHT records.
* [ ] Limit DHT record sizes.
* [ ] Reject invalid signatures.
* [ ] Reject rollback records.
* [ ] Reject malformed records.
* [ ] Rate-limit DHT publication.
* [ ] Rate-limit DHT lookup.
* [ ] Protect against DHT poisoning.
* [ ] Protect against record flooding.
* [ ] Maintain peer diversity.
* [ ] Avoid selecting every peer from one operator or network region.
* [ ] Do not store plaintext messages in the DHT.
* [ ] Do not store contact lists in the DHT.
* [ ] Do not store conversation history in the DHT.
* [ ] Do not store stable presence records without explicit privacy review.
* [ ] Document what alias lookups reveal.
* [ ] Document what peer discovery reveals.

---

# 30. Bootstrap Nodes

* [ ] Define bootstrap-node behavior.
* [ ] Keep bootstrap nodes untrusted.
* [ ] Do not grant bootstrap nodes identity authority.
* [ ] Do not grant bootstrap nodes message-decryption capability.
* [ ] Ship multiple bootstrap addresses from independent operators where possible.
* [ ] Allow users to add custom bootstrap peers.
* [ ] Allow users to remove Raven-provided bootstrap peers.
* [ ] Support direct startup from a manually supplied peer.
* [ ] Cache known peers locally.
* [ ] Avoid permanent dependence on DNS controlled by one organization.
* [ ] Test network startup with Raven bootstrap nodes unavailable.
* [ ] Test network startup using only community bootstrap nodes.
* [ ] Test network startup using only a manual peer address.

---

# 31. NAT Traversal

* [ ] Detect whether a node is publicly reachable.
* [ ] Advertise only valid reachable addresses.
* [ ] Implement AutoNAT or approved equivalent.
* [ ] Implement Circuit Relay v2 or approved equivalent.
* [ ] Implement relay reservations.
* [ ] Implement DCUtR or approved direct-connection upgrade.
* [ ] Implement hole punching.
* [ ] Fall back safely when hole punching fails.
* [ ] Limit relay reservations.
* [ ] Limit relayed bandwidth.
* [ ] Limit relayed streams.
* [ ] Test public-to-public.
* [ ] Test public-to-NAT.
* [ ] Test NAT-to-public.
* [ ] Test NAT-to-NAT.
* [ ] Test carrier-grade NAT conditions where possible.
* [ ] Test restrictive firewall conditions.
* [ ] Test relay loss.
* [ ] Test relay reconnection.
* [ ] Test IP address changes.
* [ ] Test Wi-Fi-to-cellular transitions on mobile.
* [ ] Test Wi-Fi-to-offline transitions.
* [ ] Test route upgrade from relay to direct connection.

---

# 32. Offline Store-and-Forward

* [ ] Design store-and-forward as a first-class protocol.
* [ ] Allow sender and recipient to be online at different times.
* [ ] Store only encrypted envelopes.
* [ ] Never give store nodes content keys.
* [ ] Use opaque mailbox or rendezvous tags.
* [ ] Do not use usernames as mailbox names.
* [ ] Do not use full Raven addresses as public mailbox names.
* [ ] Do not use permanent stable recipient tags.
* [ ] Derive rotating mailbox tags from shared secret material.
* [ ] Define tag epochs.
* [ ] Define tag overlap for clock skew.
* [ ] Define tag rotation behavior.
* [ ] Define retrieval behavior.
* [ ] Define message replication.
* [ ] Avoid relying on one store node.
* [ ] Select store nodes with operator and network diversity.
* [ ] Define message TTL.
* [ ] Define maximum stored-message size.
* [ ] Define maximum storage per peer.
* [ ] Define maximum total storage.
* [ ] Define maximum replication factor.
* [ ] Define cleanup after authenticated acknowledgement.
* [ ] Define cleanup after expiration.
* [ ] Define behavior when no acknowledgement returns.
* [ ] Define clock-skew tolerance.
* [ ] Define retry scheduling.
* [ ] Protect store nodes from disk exhaustion.
* [ ] Protect store nodes from identity-churn abuse.
* [ ] Protect store nodes from mailbox enumeration.
* [ ] Document that E2EE does not completely hide timing or traffic volume.
* [ ] Test sender online and recipient offline.
* [ ] Test sender later offline and recipient later online.
* [ ] Test all originally selected store nodes disappearing.
* [ ] Test one malicious store node.
* [ ] Test duplicate store copies.
* [ ] Test expired objects.
* [ ] Test forged retrieval requests.
* [ ] Test forged acknowledgements.
* [ ] Test retrieval after node restart.

---

# 33. Raven Bridge Definition

A Raven Bridge is:

> An untrusted cross-transport forwarding function inside Raven Node that receives the same opaque end-to-end encrypted Raven envelope through one transport and forwards or stores it for another transport without decrypting, re-originating or changing the logical message identity.

* [ ] Document Bridge behavior in `RAVEN_BRIDGE_V1.md`.
* [ ] Separate Bridge from endpoint decryption logic.
* [ ] Separate Bridge from plaintext conversation logic.
* [ ] Keep the same message ID through the Bridge.
* [ ] Keep the same encrypted application payload through the Bridge.
* [ ] Do not decrypt and re-encrypt at the Bridge.
* [ ] Do not create a new logical message at the Bridge.
* [ ] Do not expose aliases to the Bridge unnecessarily.
* [ ] Do not expose contact relationships to the Bridge unnecessarily.
* [ ] Do not trust the Bridge.
* [ ] Allow a device to be both endpoint and Bridge while maintaining role separation.
* [ ] Prevent the Bridge subsystem from automatically accessing endpoint message keys.
* [ ] Support BLE-to-Internet forwarding.
* [ ] Support Internet-to-BLE forwarding.
* [ ] Support LAN-to-Internet forwarding.
* [ ] Support Internet-to-LAN forwarding where implemented.
* [ ] Support Store-Carry-Bridge behavior.
* [ ] Persist Bridge queues before acknowledging custody where custody is defined.
* [ ] Re-evaluate routes when connectivity changes.
* [ ] Prevent forwarding loops.
* [ ] Prevent immediate return to the previous peer.
* [ ] Use deduplication.
* [ ] Use TTL.
* [ ] Use hop or replication controls.
* [ ] Apply Bridge bandwidth quotas.
* [ ] Apply Bridge storage quotas.
* [ ] Apply Bridge connection limits.
* [ ] Apply per-peer rate limits.
* [ ] Redact Bridge logs.
* [ ] Advertise generic Bridge capabilities without personal information.
* [ ] Allow users to disable Bridge mode.
* [ ] Allow automatic Bridge mode.
* [ ] Prefer plugged-in stable nodes for heavy Bridge work.
* [ ] Reduce Bridge work on battery-constrained devices.

---

# 34. Transport Adapter Architecture

Implement one router over multiple transport adapters.

* [ ] Implement a central `MessageRouter`.
* [ ] Implement a `Transport` interface.
* [ ] Implement `InternetTransport`.
* [ ] Implement `BleTransport`.
* [ ] Implement `LanTransport` where applicable.
* [ ] Represent relay as transport/path behavior rather than a new message type.
* [ ] Represent store-and-forward as routing behavior rather than plaintext application logic.
* [ ] Make transport adapters accept canonical Raven envelopes.
* [ ] Do not create incompatible `BluetoothMessage` and `InternetMessage` models.
* [ ] Report transport availability.
* [ ] Report peer discovery.
* [ ] Report send success or failure.
* [ ] Report path cost where useful.
* [ ] Report energy constraints where useful.
* [ ] Keep route selection outside platform UI code.
* [ ] Keep route selection outside BLE-specific code.
* [ ] Make future transports addable without changing message cryptography.
* [ ] Test one envelope crossing multiple adapters.
* [ ] Test transport changes during transmission.
* [ ] Test simultaneous transport availability.
* [ ] Test duplicate arrival from multiple adapters.

---

# 35. Routing Policy

* [ ] Define route-selection policy.
* [ ] Prefer an authenticated direct endpoint route where appropriate.
* [ ] Prefer local direct transport where appropriate.
* [ ] Attempt direct Internet P2P.
* [ ] Attempt NAT traversal.
* [ ] Use relay fallback.
* [ ] Use store-and-forward when the recipient is unavailable.
* [ ] Use BLE opportunistic forwarding when available.
* [ ] Re-evaluate queued messages when a new path appears.
* [ ] Do not permanently bind a message to one transport.
* [ ] Avoid unnecessary replication.
* [ ] Avoid indiscriminate flooding.
* [ ] Preserve privacy when comparing routes.
* [ ] Do not require plaintext content for routing.
* [ ] Bound every route attempt.
* [ ] Back off after repeated failures.
* [ ] Expire messages at TTL.
* [ ] Allow acknowledgement to use a different route.
* [ ] Record route type locally without storing unnecessary peer relationships.
* [ ] Test route failover.
* [ ] Test route upgrade.
* [ ] Test route downgrade.
* [ ] Test all routes unavailable.
* [ ] Test route becoming available after hours.

---

# 36. Bluetooth Transport

**Sprint 0 inventory (this repo, `main`):** software path is **`mock_ble` only** — TCP `u32 BE len || RavenEnvelopeV1` in `raven-core::ble_adapter`. **RBF1 GATT framing is not implemented** (spec only: `protocol/RAVEN_BLE_FRAMING_V1.md`; held for Sprint 1 with shared-vectors). **No BlueZ or CoreBluetooth live radio.** Desktop radio stays mock-only; `BleStatus` is fail-closed. Physical three-device proof remains **`BLOCKED_HARDWARE`** (`docs/PHYSICAL_BLE_THREE_DEVICE.md`). iOS GATT is **unverified / absent on `main`** (0 `.swift`; `ios-native` not in this tree). Implementation SoT until B8 export (not merged): `feature/raven-serverless-v1` — `ios-native/RAVEN/RAVEN/Core/Mesh/BLEMeshEngine.swift` (+ `BLEMeshEngine+AdaptiveSpray.swift`), `ios-native/RAVEN/RAVEN/Core/Protocol/RavenBleRvn1Carrier.swift`, `ios-native/RAVEN/RAVENTests/RavenBleRvn1CarrierTests.swift`. `FeatureFlag.ravenEnvelopeV1` default OFF (Phase G / experimental). **Do not invent or check off as present on `main`. Do not treat any row below as a hardware or RBF1 DoD.**

Legend: `software` = mock_ble / policy in this repo (not a live-radio pass). `missing` = RBF1, BlueZ, CoreBluetooth radio, or physical test. Boxes are **not** hardware/RBF1 completion.

* [x] Use Bluetooth only as a transport. — software (`mock_ble` adapter boundary; no radio wiring)
* [x] Keep Raven E2EE active over Bluetooth. — software (opaque `RVN1` on mock_ble; bridge must not decrypt)
* [x] Do not treat physical proximity as trust. — software (policy; no proximity-as-auth)
* [x] Do not use Bluetooth MAC addresses as user identity. — software (`TransportKind` never uses MAC)
* [ ] Use privacy-preserving peer advertisements. — missing (no live advertisements)
* [ ] Avoid broadcasting stable public identity keys. — missing (no live advertisements)
* [ ] Use rotating discovery tokens where designed. — missing (no live discovery radio)
* [ ] Authenticate peers after discovery. — missing (no live GATT discovery)
* [ ] Define BLE service identifiers. — missing (legacy mesh UUIDs in docs only; RBF1 / live radio not implemented)
* [ ] Define characteristic identifiers. — missing (same; RBF1 held for Sprint 1)
* [ ] Define maximum frame size. — missing (RBF1 spec only; not implemented)
* [ ] Define fragmentation. — missing (RBF1 spec only; mock_ble is whole-envelope TCP, not GATT chunks)
* [ ] Define reassembly. — missing (RBF1 not implemented)
* [ ] Define fragment ordering. — missing (RBF1 not implemented)
* [ ] Define fragment integrity. — missing (RBF1 not implemented)
* [ ] Define fragment timeout. — missing (RBF1 not implemented)
* [ ] Define retry behavior. — missing (no live radio)
* [ ] Define connection-loss behavior. — missing (no live radio)
* [ ] Define duplicate-fragment behavior. — missing (RBF1 not implemented)
* [ ] Define malformed-fragment behavior. — missing (RBF1 not implemented)
* [ ] Define concurrent-peer limits. — missing (no live radio)
* [ ] Define scanning schedule. — missing (no live radio)
* [ ] Define advertising schedule. — missing (no live radio)
* [ ] Minimize battery consumption. — missing (no live radio)
* [ ] Handle Bluetooth being disabled. — missing (no live radio; desktop mock-only)
* [x] Handle Bluetooth hardware being absent. — software (`mock_ble` + fail-closed `BleStatus`; not a radio driver)
* [ ] Handle permission denial. — missing (no live radio / TCC / BlueZ)
* [ ] Handle intermittent Bluetooth. — missing (no live radio)
* [ ] Handle recurring iOS disconnects. — missing (iOS GATT unverified / absent on `main`; SoT `feature/raven-serverless-v1` until B8)
* [ ] Handle Windows Bluetooth differences. — missing (no Windows GATT radio)
* [ ] Handle macOS Bluetooth differences. — missing (CoreBluetooth compile seam only; radio **BLOCKED_HARDWARE**)
* [ ] Handle Linux BlueZ differences. — missing (no BlueZ live radio)
* [ ] Test real hardware. — **BLOCKED_HARDWARE**
* [ ] Test BLE direct terminal-to-mobile. — **BLOCKED_HARDWARE** (software stand-in: mock_ble only)
* [ ] Test BLE mobile-to-terminal. — **BLOCKED_HARDWARE**
* [ ] Test BLE multi-hop where V1 supports it. — **BLOCKED_HARDWARE** (mock_ble software multi-hop is not physical)
* [ ] Test BLE-to-Internet Bridge. — **BLOCKED_HARDWARE** (software stand-in: `bridge_abc_demo` / mock_ble)
* [ ] Test Internet-to-BLE Bridge. — **BLOCKED_HARDWARE** (same software stand-in; not live GATT)
* [ ] Test duplicate delivery through BLE and Internet. — **BLOCKED_HARDWARE**
* [ ] Fuzz BLE frame parsing. — missing (mock_ble length-prefix unit tests only; RBF1 fuzz not implemented)

---

# 37. Bluetooth Forwarding Policy

* [ ] Use a bounded Spray-and-Wait-style or approved forwarding policy.
* [ ] Define an initial replication budget.
* [ ] Define how replication budget is split or reduced.
* [ ] Define forwarding eligibility.
* [ ] Define TTL.
* [ ] Define hop limit.
* [ ] Prevent unlimited message propagation.
* [ ] Prevent forwarding back to the previous peer.
* [ ] Maintain bounded deduplication state.
* [ ] Avoid forwarding expired messages.
* [ ] Avoid forwarding envelopes already acknowledged.
* [ ] Avoid consuming excessive mobile battery.
* [ ] Test moving-device Store-Carry-Forward.
* [ ] Test laptop receives via BLE while offline and forwards after later Internet connection.
* [ ] Test multiple nearby Bridges.
* [ ] Test one malicious nearby peer.
* [ ] Test BLE spam resistance.

---

# 38. Mobile Compatibility

* [ ] Treat mobile devices as light nodes by default.
* [ ] Do not require a mobile device to be an always-on DHT server.
* [ ] Do not require a mobile device to be an always-on relay.
* [ ] Do not require a mobile device to be an always-on store node.
* [ ] Use the same Raven identity and envelope specifications.
* [ ] Use the same cross-platform cryptographic vectors.
* [ ] Support mobile-to-terminal text messages.
* [ ] Support terminal-to-mobile text messages.
* [ ] Support direct Internet P2P when the OS permits it.
* [ ] Support relay fallback.
* [ ] Support offline mailbox retrieval.
* [ ] Support BLE proximity delivery.
* [ ] Support BLE Bridge delivery.
* [ ] Resume queues after application wake.
* [ ] Resume sessions after application restart.
* [ ] Handle mobile IP changes.
* [ ] Handle Wi-Fi and cellular transitions.
* [ ] Handle mobile background restrictions honestly.
* [ ] Document that iOS cannot guarantee unlimited background network execution.
* [ ] Do not claim instant background delivery without proving it.
* [ ] Do not make APNs mandatory for message delivery.
* [ ] If an optional wake/notification service is used, keep it message-blind.
* [ ] Never include plaintext message content in push payloads.
* [ ] Make optional notification infrastructure replaceable.
* [ ] Ensure messages remain retrievable when notification infrastructure fails.
* [ ] Test delivery when the mobile application is open.
* [ ] Test delivery when the application is backgrounded.
* [ ] Test delivery after the application is reopened.
* [ ] Test delivery with notification services blocked.
* [ ] Test delivery with Raven-operated servers blocked.

---

# 39. Multi-Device User Support

* [ ] Support one Raven User Identity with multiple authorized devices.
* [ ] Maintain separate device keys.
* [ ] Maintain separate device sessions where required.
* [ ] Deliver messages to authorized recipient devices.
* [ ] Define whether every device must receive every message.
* [ ] Define synchronization of delivered/read states.
* [ ] Encrypt device-to-device synchronization.
* [ ] Do not store plaintext synchronization centrally.
* [ ] Support adding a device using an existing authorized device.
* [ ] Support adding a device using a protected recovery mechanism.
* [ ] Support device revocation.
* [ ] Propagate revocation records.
* [ ] Prevent a revoked device from adding another device.
* [ ] Warn contacts of material identity changes.
* [ ] Test phone plus terminal under one identity.
* [ ] Test two terminals under one identity.
* [ ] Test a lost-device revocation.
* [ ] Test a revoked device during network partition.
* [ ] Document partition-related limitations.

---

# 40. Deduplication and Replay Protection

* [ ] Generate cryptographically random message IDs.
* [ ] Preserve message IDs across transports.
* [ ] Maintain a bounded deduplication cache.
* [ ] Maintain replay counters or nonce state as required.
* [ ] Detect duplicates arriving through different relays.
* [ ] Detect duplicates arriving through Internet and Bluetooth.
* [ ] Display one conversation message only.
* [ ] Avoid ratchet corruption from duplicate messages.
* [ ] Reject replayed alias records.
* [ ] Reject replayed device certificates.
* [ ] Reject replayed acknowledgements.
* [ ] Reject replayed store retrieval requests.
* [ ] Expire replay-cache entries safely.
* [ ] Bound replay-cache memory.
* [ ] Test immediate replay.
* [ ] Test replay after restart.
* [ ] Test replay near expiration.
* [ ] Test replay through a different transport.
* [ ] Test high-volume duplicate attacks.

---

# 41. Out-of-Order Messages

* [ ] Support out-of-order message arrival.
* [ ] Bound skipped-message key storage.
* [ ] Preserve conversation ordering rules separately from network arrival.
* [ ] Do not trust sender wall-clock time as the sole ordering source.
* [ ] Define deterministic tie-breaking.
* [ ] Test `M3, M1, M4, M2` delivery order.
* [ ] Test delayed first message.
* [ ] Test missing messages.
* [ ] Test duplicated out-of-order messages.
* [ ] Test out-of-order messages after process restart.
* [ ] Test out-of-order messages across Internet and BLE.
* [ ] Test attacker-controlled large counter jumps.
* [ ] Reject resource-exhaustion attempts.

---

# 42. Abuse and Spam Controls

* [ ] Implement per-peer connection limits.
* [ ] Implement per-peer message-rate limits.
* [ ] Implement per-identity message-request limits.
* [ ] Implement relay bandwidth limits.
* [ ] Implement Bridge bandwidth limits.
* [ ] Implement store storage limits.
* [ ] Implement DHT publication limits.
* [ ] Implement DHT query limits.
* [ ] Implement malformed-packet penalties.
* [ ] Implement peer scoring based on observable network behavior.
* [ ] Do not treat peer score as cryptographic identity trust.
* [ ] Support blocking.
* [ ] Support unknown-sender message requests.
* [ ] Default unknown senders to strict quotas.
* [ ] Define contact-only mode.
* [ ] Define contacts-plus-requests mode.
* [ ] Define anyone mode only with clear warnings.
* [ ] Protect against Sybil peers.
* [ ] Protect against Eclipse attacks.
* [ ] Protect against DHT poisoning.
* [ ] Protect against alias squatting and ambiguity.
* [ ] Protect against relay reservation abuse.
* [ ] Protect against connection exhaustion.
* [ ] Protect against memory exhaustion.
* [ ] Protect against disk exhaustion.
* [ ] Protect against CPU exhaustion.
* [ ] Protect against slow-client attacks.
* [ ] Protect against oversized frames.
* [ ] Protect against terminal escape-sequence attacks.
* [ ] Protect against Unicode alias spoofing.
* [ ] Do not introduce cryptocurrency as a spam-control requirement.
* [ ] Consider proof-of-work only after measuring a demonstrated need.
* [ ] Document all abuse-control limitations.

---

# 43. Privacy and Metadata

* [ ] Document what message content is protected.
* [ ] Document what metadata remains visible.
* [ ] Document what a relay can observe.
* [ ] Document what a Bridge can observe.
* [ ] Document what a store node can observe.
* [ ] Document what a DHT node can observe.
* [ ] Document what a bootstrap node can observe.
* [ ] Minimize stable routing identifiers.
* [ ] Rotate mailbox tags.
* [ ] Avoid plaintext aliases in envelopes.
* [ ] Avoid stable contact identifiers in BLE advertisements.
* [ ] Avoid logging complete IP-to-identity mappings.
* [ ] Avoid logging permanent Bluetooth identifiers.
* [ ] Avoid centrally collecting message graphs.
* [ ] Avoid centrally collecting contact graphs.
* [ ] Avoid centrally collecting precise location.
* [ ] Avoid centrally collecting message timestamps tied to identities.
* [ ] Make telemetry opt-in.
* [ ] Keep operational metrics local by default.
* [ ] Redact message IDs from routine logs where feasible.
* [ ] Redact routing tags from routine logs.
* [ ] Consider message-size padding buckets.
* [ ] Measure padding overhead.
* [ ] Do not claim traffic-analysis resistance beyond evidence.
* [ ] Do not claim anonymity merely because messages are encrypted.

---

# 44. Logging and Diagnostics

* [ ] Never log plaintext messages.
* [ ] Never log private keys.
* [ ] Never log session keys.
* [ ] Never log ratchet chain keys.
* [ ] Never log recovery material.
* [ ] Never log passphrases.
* [ ] Never log complete contact lists.
* [ ] Never log inline plaintext command arguments.
* [ ] Redact authentication material.
* [ ] Redact routing tags.
* [ ] Redact stable peer identifiers where feasible.
* [ ] Use structured log levels.
* [ ] Make debug logging explicitly opt-in.
* [ ] Add automatic log rotation.
* [ ] Bound log-disk usage.
* [ ] Provide `ash doctor`.
* [ ] Make `ash doctor` detect network state.
* [ ] Make `ash doctor` detect daemon state.
* [ ] Make `ash doctor` detect database state.
* [ ] Make `ash doctor` detect secure-keystore state.
* [ ] Make `ash doctor` detect Bluetooth availability.
* [ ] Make `ash doctor` detect NAT classification.
* [ ] Make `ash doctor` detect relay availability.
* [ ] Do not include secrets in diagnostic exports.
* [ ] Require user confirmation before creating a diagnostic bundle.
* [ ] Show exactly what a diagnostic bundle contains.

---

# 45. Security Threat Model

Model at least:

* [ ] Passive network observer.
* [ ] Active network attacker.
* [ ] Malicious relay.
* [ ] Malicious Bridge.
* [ ] Malicious store node.
* [ ] Malicious bootstrap node.
* [ ] Malicious DHT peer.
* [ ] Compromised Raven-operated infrastructure.
* [ ] Sybil swarm.
* [ ] Eclipse attacker.
* [ ] Alias impersonator.
* [ ] Prekey-substitution attacker.
* [ ] Replay attacker.
* [ ] Downgrade attacker.
* [ ] Spam attacker.
* [ ] Storage-exhaustion attacker.
* [ ] CPU-exhaustion attacker.
* [ ] Malformed-packet attacker.
* [ ] Malicious local process.
* [ ] Another local operating-system user.
* [ ] Lost locked device.
* [ ] Lost unlocked device.
* [ ] Endpoint malware.
* [ ] Compromised dependency.
* [ ] Compromised update channel.
* [ ] Traffic-analysis adversary.

For each threat:

* [ ] State what Raven protects.
* [ ] State what Raven partially protects.
* [ ] State what Raven does not protect.
* [ ] Identify the implementation component.
* [ ] Identify the test proving the mitigation.
* [ ] Identify residual risk.
* [ ] Avoid unsupported marketing claims.

---

# 46. Parser and Fuzzing Requirements

Fuzz:

* [ ] Raven envelope parser.
* [ ] Address decoder.
* [ ] Alias-record decoder.
* [ ] Device-certificate decoder.
* [ ] Prekey-bundle decoder.
* [ ] Acknowledgement decoder.
* [ ] Routing-tag decoder.
* [ ] Store-object decoder.
* [ ] DHT-record decoder.
* [ ] Internet-frame decoder.
* [ ] BLE-frame decoder.
* [ ] IPC parser.
* [ ] Configuration parser.
* [ ] QR contact parser.
* [ ] Database migration inputs.

For every parser:

* [ ] Set input-size limits.
* [ ] Reject malformed length fields.
* [ ] Reject integer overflow.
* [ ] Reject recursion or nesting abuse.
* [ ] Reject unsupported versions.
* [ ] Avoid panics.
* [ ] Avoid unbounded allocation.
* [ ] Avoid expensive cryptographic work before structural validation.
* [ ] Add a persistent fuzz corpus.
* [ ] Run fuzz smoke tests in CI.
* [ ] Run longer fuzz campaigns before release.

---

# 47. Cross-Platform Interoperability

* [ ] Produce canonical shared vectors.
* [ ] Run vectors in Rust.
* [ ] Run vectors in Swift.
* [ ] Run vectors in Windows implementation bindings.
* [ ] Run vectors in every mobile implementation.
* [ ] Verify address encoding consistency.
* [ ] Verify identity fingerprint consistency.
* [ ] Verify signature verification consistency.
* [ ] Verify envelope serialization consistency.
* [ ] Verify acknowledgement consistency.
* [ ] Verify alias-record consistency.
* [ ] Verify routing-tag consistency.
* [ ] Verify BLE framing consistency.
* [ ] Verify first-contact session consistency.
* [ ] Verify message decryption across platforms.
* [ ] Verify out-of-order handling across platforms.
* [ ] Verify duplicate handling across platforms.
* [ ] Verify unsupported-version rejection across platforms.
* [ ] Verify malformed-input rejection across platforms.

Required communication matrix:

* [ ] Windows terminal → Windows terminal.
* [ ] Windows terminal → macOS terminal.
* [ ] Windows terminal → Linux terminal.
* [ ] macOS terminal → Windows terminal.
* [ ] macOS terminal → Linux terminal.
* [ ] Linux terminal → Windows terminal.
* [ ] Linux terminal → macOS terminal.
* [ ] Windows terminal → iPhone.
* [ ] macOS terminal → iPhone.
* [ ] Linux terminal → iPhone.
* [ ] iPhone → Windows terminal.
* [ ] iPhone → macOS terminal.
* [ ] iPhone → Linux terminal.

---

# 48. Mandatory Network Tests

* [ ] Two isolated nodes on one machine.
* [ ] Two physical computers on one LAN.
* [ ] Two computers on separate Internet connections.
* [ ] Both computers behind NAT.
* [ ] Both computers behind restrictive NAT.
* [ ] Direct route unavailable and relay available.
* [ ] Relay disappears during transmission.
* [ ] Direct path becomes available after relay use.
* [ ] Sender loses Internet during send.
* [ ] Recipient loses Internet during send.
* [ ] Sender changes IP address.
* [ ] Recipient changes IP address.
* [ ] Sender restarts.
* [ ] Recipient restarts.
* [ ] Bridge restarts.
* [ ] Store node restarts.
* [ ] Bootstrap nodes unavailable.
* [ ] Raven-operated domains blocked.
* [ ] Manual-peer startup.
* [ ] Community-bootstrap-only startup.
* [ ] Bluetooth-only delivery.
* [ ] Bluetooth-to-Internet delivery.
* [ ] Internet-to-Bluetooth delivery.
* [ ] Store-Carry-Bridge delivery.
* [ ] Multiple simultaneous paths.
* [ ] Duplicate path delivery.
* [ ] Out-of-order path delivery.
* [ ] Message expiration.
* [ ] Clock skew.
* [ ] Disk full.
* [ ] High packet loss.
* [ ] High latency.
* [ ] Intermittent connection.
* [ ] Repeated sleep and wake.

---

# 49. Mandatory Security Tests

* [ ] Relay attempts to decrypt.
* [ ] Bridge attempts to decrypt.
* [ ] Store node attempts to decrypt.
* [ ] Relay changes ciphertext.
* [ ] Bridge changes ciphertext.
* [ ] Store node changes ciphertext.
* [ ] Relay duplicates ciphertext.
* [ ] Bridge duplicates ciphertext.
* [ ] Store node replays ciphertext.
* [ ] Attacker forges sender identity.
* [ ] Attacker substitutes recipient prekeys.
* [ ] Attacker replays old alias record.
* [ ] Attacker publishes conflicting alias.
* [ ] Attacker forces algorithm downgrade.
* [ ] Attacker sends oversized envelope.
* [ ] Attacker sends malformed BLE fragments.
* [ ] Attacker opens excessive relay streams.
* [ ] Attacker fills store capacity.
* [ ] Attacker creates thousands of peer IDs.
* [ ] Attacker surrounds a node with malicious peers.
* [ ] Malicious local process attempts IPC.
* [ ] Another local user attempts database access.
* [ ] Incoming message contains terminal control sequences.
* [ ] Incoming message contains dangerous bidirectional Unicode controls.
* [ ] Incoming alias uses confusable Unicode.
* [ ] CLI receives malformed daemon response.
* [ ] Node receives stale protocol version.
* [ ] Update package signature is invalid.
* [ ] Dependency integrity is invalid.

---

# 50. Reliability and Scale Tests

* [ ] Send 10,000 sequential text messages in a controlled valid-path environment.
* [ ] Confirm zero silent losses.
* [ ] Confirm zero duplicate UI entries.
* [ ] Confirm zero undecryptable valid messages.
* [ ] Confirm zero false delivery acknowledgements.
* [ ] Test 100 concurrent conversations.
* [ ] Test 1,000 simulated nodes.
* [ ] Measure peer-discovery time.
* [ ] Measure DHT convergence.
* [ ] Measure direct-delivery latency.
* [ ] Measure relay-delivery latency.
* [ ] Measure offline-delivery latency.
* [ ] Measure Bridge delivery.
* [ ] Measure duplicate traffic.
* [ ] Measure average hops.
* [ ] Measure p50 delivery latency.
* [ ] Measure p95 delivery latency.
* [ ] Measure p99 delivery latency.
* [ ] Measure idle memory.
* [ ] Measure active memory.
* [ ] Measure CPU usage.
* [ ] Measure disk usage.
* [ ] Measure relay bandwidth.
* [ ] Measure Bridge bandwidth.
* [ ] Measure BLE battery impact.
* [ ] Test node churn.
* [ ] Test 50% simulated node loss.
* [ ] Test store-node churn.
* [ ] Test bootstrap churn.
* [ ] Test database growth.
* [ ] Test long-running operation for at least seven days.
* [ ] Investigate every silent failure.

---

# 51. Terminal-Specific Security Tests

* [ ] Incoming message containing ANSI clear-screen sequence.
* [ ] Incoming message containing fake shell prompt text.
* [ ] Incoming message containing terminal-title escape sequence.
* [ ] Incoming message containing clipboard escape sequence.
* [ ] Incoming message containing backspace controls.
* [ ] Incoming message containing carriage-return manipulation.
* [ ] Incoming message containing bidirectional override characters.
* [ ] Alias containing zero-width characters.
* [ ] Alias visually impersonating another alias.
* [ ] Long message causing terminal overflow.
* [ ] Narrow terminal width.
* [ ] Terminal without Unicode.
* [ ] Terminal without color.
* [ ] PowerShell encoding behavior.
* [ ] Windows console UTF-8 behavior.
* [ ] Persian/RTL message display.
* [ ] Copying fingerprint without hidden characters.
* [ ] Pasting untrusted text.
* [ ] Shell-history inspection.
* [ ] Process-list inspection.
* [ ] Crash dump inspection.
* [ ] Log-file inspection.

---

# 52. Packaging and Distribution

## General

* [ ] Produce signed release artifacts.
* [ ] Publish SHA-256 hashes.
* [ ] Publish signature verification instructions.
* [ ] Generate an SBOM for each release.
* [ ] Produce reproducible builds where feasible.
* [ ] Pin security-sensitive dependencies.
* [ ] Scan dependencies for known vulnerabilities.
* [ ] Define update policy.
* [ ] Sign updates.
* [ ] Reject unsigned updates.
* [ ] Do not make an update server part of the messaging protocol.
* [ ] Allow manual offline update.
* [ ] Preserve user data during update.
* [ ] Support rollback after failed update.
* [ ] Do not roll back protocol security silently.

## Windows

* [ ] Produce a signed installer.
* [ ] Install the CLI.
* [ ] Install the background node.
* [ ] Configure appropriate PATH entries.
* [ ] Configure appropriate service startup.
* [ ] Apply restrictive file permissions.
* [ ] Provide clean uninstall.
* [ ] Test standard-user installation.
* [ ] Test upgrade.
* [ ] Test uninstall without deleting identity unless explicitly requested.

## macOS

* [ ] Produce a signed and notarized package.
* [ ] Install the CLI.
* [ ] Install the `launchd` service.
* [ ] Integrate with Keychain.
* [ ] Apply restrictive file permissions.
* [ ] Provide clean uninstall.
* [ ] Test Apple Silicon.
* [ ] Test supported Intel systems if included.
* [ ] Test upgrade.
* [ ] Test uninstall without deleting identity unless explicitly requested.

## Linux

* [ ] Produce a portable binary.
* [ ] Provide package formats selected by ADR.
* [ ] Provide user-scoped systemd installation.
* [ ] Provide foreground/headless mode.
* [ ] Provide container deployment for infrastructure nodes.
* [ ] Apply restrictive file permissions.
* [ ] Detect existing `ash` shell conflicts.
* [ ] Never overwrite system `ash`.
* [ ] Test common distributions.
* [ ] Test Alpine or another environment where `ash` already exists.
* [ ] Provide clean uninstall.
* [ ] Preserve identity unless explicitly requested.

---

# 53. Node Operator Controls

* [ ] Allow relay on/off.
* [ ] Allow encrypted store on/off.
* [ ] Allow Bridge on/off.
* [ ] Allow Bluetooth forwarding on/off.
* [ ] Allow automatic mode.
* [ ] Allow client-only mode.
* [ ] Allow storage-size limit.
* [ ] Allow bandwidth-per-day limit.
* [ ] Allow connection limit.
* [ ] Allow relay reservation limit.
* [ ] Allow maximum message TTL.
* [ ] Allow custom bootstrap peers.
* [ ] Allow disabling Raven-provided bootstrap peers.
* [ ] Display current role.
* [ ] Display current resource use.
* [ ] Display queue size.
* [ ] Display peer count.
* [ ] Display direct/relay reachability.
* [ ] Do not expose other users’ message content.
* [ ] Do not expose sensitive routing mappings.
* [ ] Apply safe defaults.
* [ ] Reduce forwarding on battery power where appropriate.
* [ ] Prefer stable plugged-in infrastructure nodes where appropriate.

---

# 54. Migration from Existing Raven Messaging

* [ ] Keep the existing working Raven application operational during development.
* [ ] Build the decentralized text path alongside the existing path.
* [ ] Put the new path behind an explicit feature flag initially.
* [ ] Do not silently route new-protocol messages through the old central server.
* [ ] Label legacy server delivery clearly in internal diagnostics.
* [ ] Define identity migration.
* [ ] Define contact migration.
* [ ] Define conversation-history migration.
* [ ] Define device-key migration.
* [ ] Avoid silently treating old usernames as new cryptographic identities.
* [ ] Avoid mixing incompatible envelope formats.
* [ ] Create protocol adapters only where secure and necessary.
* [ ] Test old and new clients during migration.
* [ ] Define minimum compatible client versions.
* [ ] Define rollback behavior.
* [ ] Preserve user data during rollback.
* [ ] Do not make the serverless path default until release gates pass.
* [ ] Remove the mandatory central text-message route only after decentralized delivery is proven.
* [ ] Keep unrelated server-backed Raven features separate from V1 text-messaging claims.
* [ ] Update website and README only after implementation matches the claim.

---

# 55. Open-Source Readiness

* [ ] Use an approved open-source license.
* [ ] Keep the standard license text separate from trademark rules.
* [ ] Create `TRADEMARK.md`.
* [ ] Create `ASSET_LICENSE.md`.
* [ ] Update `CONTRIBUTING.md`.
* [ ] Update `SECURITY.md`.
* [ ] Create responsible-disclosure instructions.
* [ ] Define supported versions.
* [ ] Define vulnerability-response process.
* [ ] Publish the protocol specifications.
* [ ] Publish test vectors.
* [ ] Publish negative test vectors.
* [ ] Publish interoperability instructions.
* [ ] Publish node-operator documentation.
* [ ] Publish terminal-user documentation.
* [ ] Publish serverless architecture documentation.
* [ ] Publish the honest threat model.
* [ ] Publish known limitations.
* [ ] Remove secrets from history where technically and legally appropriate.
* [ ] Rotate every exposed secret.
* [ ] Add automated secret scanning.
* [ ] Add dependency scanning.
* [ ] Add license scanning.
* [ ] Add signed releases.
* [ ] Add reproducible-build guidance.
* [ ] Invite external protocol review.
* [ ] Invite external cryptographic review.
* [ ] Do not claim that public source code automatically means audited security.

---

# 56. Documentation Required Before Release

* [ ] `README.md`
* [ ] `SERVERLESS_MODEL.md`
* [ ] `THREAT_MODEL.md`
* [ ] `PROTOCOL.md`
* [ ] `IDENTITY.md`
* [ ] `ADDRESSING.md`
* [ ] `ALIASES.md`
* [ ] `DEVICE_MANAGEMENT.md`
* [ ] `ENVELOPE.md`
* [ ] `ACKNOWLEDGEMENTS.md`
* [ ] `OFFLINE_DELIVERY.md`
* [ ] `BRIDGE.md`
* [ ] `BLUETOOTH.md`
* [ ] `NAT_TRAVERSAL.md`
* [ ] `NODE_OPERATOR.md`
* [ ] `CLI_REFERENCE.md`
* [ ] `INSTALL_WINDOWS.md`
* [ ] `INSTALL_MACOS.md`
* [ ] `INSTALL_LINUX.md`
* [ ] `MOBILE_LIMITATIONS.md`
* [ ] `PRIVACY_LIMITATIONS.md`
* [ ] `INTEROPERABILITY.md`
* [ ] `TEST_VECTORS.md`
* [ ] `SECURITY.md`
* [ ] `CONTRIBUTING.md`
* [ ] `TRADEMARK.md`
* [ ] `ASSET_LICENSE.md`
* [ ] `RELEASE_PROCESS.md`

---

# 57. CI Requirements

Every protocol or security change must run:

* [ ] Rust formatting.
* [ ] Rust linting.
* [ ] Rust unit tests.
* [ ] Windows tests.
* [ ] macOS tests.
* [ ] Linux tests.
* [ ] Protocol-vector tests.
* [ ] Negative-vector tests.
* [ ] Address tests.
* [ ] Alias tests.
* [ ] Envelope tests.
* [ ] Acknowledgement tests.
* [ ] Queue crash-recovery tests.
* [ ] Database migration tests.
* [ ] IPC tests.
* [ ] Network integration tests.
* [ ] NAT topology tests where available.
* [ ] BLE parser tests.
* [ ] Fuzz smoke tests.
* [ ] Dependency vulnerability scan.
* [ ] Secret scan.
* [ ] License scan.
* [ ] SBOM generation.
* [ ] Build-artifact signing verification.
* [ ] Documentation/spec consistency checks where possible.

No merge if:

* [ ] A P0 test fails.
* [ ] A cryptographic vector fails.
* [ ] An interoperability vector fails.
* [ ] Secret scanning fails.
* [ ] A new critical/high dependency vulnerability is unreviewed.
* [ ] Protocol documentation and implementation disagree.
* [ ] A security-sensitive change lacks independent review.

---

# 58. Phase Exit Gates

## Phase A — Protocol Freeze

* [ ] All V1 specifications exist.
* [ ] All specifications agree.
* [ ] Canonical serialization is frozen.
* [ ] Raven Address V1 is frozen.
* [ ] Identity hierarchy is frozen.
* [ ] Alias semantics are frozen.
* [ ] Envelope V1 is frozen.
* [ ] Acknowledgement V1 is frozen.
* [ ] Routing-tag V1 is frozen.
* [ ] Prekey Bundle V1 is frozen.
* [ ] Store Object V1 is frozen.
* [ ] Bridge V1 is frozen.
* [ ] BLE framing is frozen.
* [ ] Positive vectors exist.
* [ ] Negative vectors exist.
* [ ] Cross-platform vectors exist.
* [ ] Threat model exists.
* [ ] Independent review completed.
* [ ] No unresolved P0/P1 protocol contradiction.
* [ ] Freeze packet generated with file hashes.
* [ ] Development stops for approval before Phase B.

## Phase B — Two-Node Core

* [ ] Two nodes create identities.
* [ ] Two nodes establish an authenticated session.
* [ ] Two nodes exchange encrypted text.
* [ ] Messages persist across restart.
* [ ] Acknowledgements work.
* [ ] No central server is used.
* [ ] Negative cryptographic tests pass.

## Phase C — Terminal Client

* [ ] `ash` or safe fallback launches Raven.
* [ ] Main menu works.
* [ ] Messages works.
* [ ] Chat history works.
* [ ] Send New Message works.
* [ ] Contacts works.
* [ ] Terminal closes without stopping `raven-node`.
* [ ] Plaintext is not exposed through process arguments by default.

## Phase D — Internet P2P

* [ ] Direct Internet delivery works.
* [ ] DHT discovery works.
* [ ] Manual-peer discovery works.
* [ ] Bootstrap independence is proven.
* [ ] NAT detection works.
* [ ] Relay fallback works.
* [ ] Hole punching works where network conditions permit.

## Phase E — Offline Delivery

* [ ] Recipient may be offline at send time.
* [ ] Store nodes see only ciphertext.
* [ ] Rotating mailbox tags work.
* [ ] Replication works.
* [ ] TTL works.
* [ ] Recipient later retrieves and decrypts.
* [ ] Sender receives authenticated delivery acknowledgement.
* [ ] No central server is required.

## Phase F — Bridge and Bluetooth

* [ ] BLE terminal-to-mobile works.
* [ ] BLE mobile-to-terminal works.
* [ ] BLE-to-Internet Bridge works.
* [ ] Internet-to-BLE Bridge works.
* [ ] Same message ID survives transport change.
* [ ] Bridge cannot decrypt.
* [ ] Duplicate cross-transport delivery is suppressed.
* [ ] Store-Carry-Bridge works.

## Phase G — Cross-Platform Release Candidate

* [ ] Windows package works.
* [ ] macOS package works.
* [ ] Linux package works.
* [ ] iOS interoperability works.
* [ ] No P0 issue remains.
* [ ] No unresolved P1 security issue remains.
* [ ] External review completed.
* [ ] Release documentation completed.

---

# 59. Final Serverless Proof Test

The following demonstration must be reproducible and recorded.

* [ ] Start with a fresh Linux or Windows computer.
* [ ] Install Raven without configuring a central messaging server.
* [ ] Run `ash` or the documented safe fallback.
* [ ] Generate a local Raven identity.
* [ ] Display the local Raven address.
* [ ] Add a mobile Raven contact using `@alias`, Raven address or QR.
* [ ] Verify the contact identity.
* [ ] Turn the mobile recipient completely offline.
* [ ] Send a text message from Terminal.
* [ ] Confirm the message is encrypted locally.
* [ ] Confirm the message enters the persistent outgoing queue.
* [ ] Confirm no Raven central API receives the message.
* [ ] Confirm encrypted copies are forwarded to decentralized store nodes.
* [ ] Close Terminal.
* [ ] Confirm `raven-node` continues operating.
* [ ] Take the sending terminal node offline.
* [ ] Bring the mobile recipient online later.
* [ ] Retrieve the encrypted message.
* [ ] Authenticate and decrypt on the mobile endpoint.
* [ ] Display the plaintext message on the mobile endpoint.
* [ ] Generate an encrypted authenticated acknowledgement.
* [ ] Deliver the acknowledgement to the sender node.
* [ ] Reopen Terminal.
* [ ] Confirm status changed to `Delivered`.
* [ ] Reply from mobile.
* [ ] Receive the reply in Terminal.
* [ ] Disable Internet on the mobile device.
* [ ] Place a Raven Bridge computer nearby.
* [ ] Send another mobile message over Bluetooth.
* [ ] Forward the same encrypted envelope through the Bridge to the Internet.
* [ ] Receive the message on a remote terminal.
* [ ] Send a remote reply through Internet to the Bridge.
* [ ] Forward it from the Bridge to the mobile device over Bluetooth.
* [ ] Confirm no Bridge plaintext access.
* [ ] Confirm no duplicate messages.
* [ ] Confirm the same message identity is preserved across transports.
* [ ] Shut down Raven-operated bootstrap, relay and store nodes.
* [ ] Repeat communication using community or manually configured peers.
* [ ] Confirm no mandatory central Raven message server exists.

---

# 60. Final Definition of Done

Raven Serverless Terminal Messaging V1 is complete only when:

* [ ] A normal user can install it on Windows, macOS or Linux.
* [ ] A normal user can launch it from Terminal.
* [ ] The user can create identity locally.
* [ ] The user can add and verify contacts.
* [ ] The user can send and receive text messages.
* [ ] The user can read conversation history.
* [ ] The user can message mobile Raven users.
* [ ] Mobile Raven users can message terminal users.
* [ ] Messages work without a central message server.
* [ ] Offline recipient delivery works.
* [ ] NAT traversal works.
* [ ] Relay fallback works.
* [ ] Bluetooth delivery works.
* [ ] Bridge delivery works in both directions.
* [ ] Bridge, relay and store nodes cannot decrypt messages.
* [ ] Messages survive process restart.
* [ ] Duplicate messages are suppressed.
* [ ] Out-of-order messages decrypt correctly.
* [ ] Delivery states are accurate.
* [ ] All protocol vectors pass on every supported platform.
* [ ] All required adversarial tests pass.
* [ ] No unresolved P0 issue remains.
* [ ] No unresolved P1 security issue remains.
* [ ] External protocol and security review has been completed.
* [ ] Open-source licensing and documentation are complete.
* [ ] The implementation matches the public description.

The final architectural invariant is:

> **One Raven message, one canonical encrypted envelope, one cryptographic identity model and any available route—direct Internet, relay, encrypted store, local network or Bluetooth Bridge—without requiring a trusted central Raven message server.**
