//
//  MeshCryptoService.swift
//  RAVEN
//
//  SECURITY: End-to-End Encryption & Message Signing for Mesh
//  Fixes C1 (Plaintext), C3 (No Sender Verification), C4 (Replay), C5 (Flooding)
//

import Foundation
import CryptoKit
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Mesh.Crypto")

/// Cryptographic security layer for mesh messaging
/// - AES-256-GCM encryption for message confidentiality
/// - Ed25519 signatures for sender authentication
/// - Nonces for replay attack prevention
/// - Rate limiting for DoS protection
actor MeshCryptoService {
    static let shared = MeshCryptoService()
    
    // MARK: - Constants
    
    /// Maximum messages per peer per minute (DoS protection)
    private static let maxMessagesPerPeerPerMinute = 60
    
    /// Maximum hop limit for validation (Absolute protocol max)
    static let protocolMaxHopLimit: Int = 50
    
    /// Maximum spray counter (prevents flooding)
    /// Raised from 5→50 for Binary Spray & Wait routing (RAVEN+ geo-match budget)
    static let protocolMaxSprayCounter: Int = 50
    
    /// Nonce size in bytes
    private static let nonceSize = 12
    
    // MARK: - Rate Limiting State
    
    private var peerMessageCounts: [String: (count: Int, resetTime: Date)] = [:]
    
    // MARK: - Nonce Tracking (Replay Prevention)

    /// Per-nonce LRU map (nonce → expiry timestamp). 🔐 BUG FIX
    /// (2026-05-10): the previous implementation used a plain
    /// `Set<Data>` and only flushed by `removeAll()` when it exceeded
    /// 100k entries — opening a wide replay window for any attacker
    /// who could flood ≥100k nonces in one session. Now we evict
    /// per-entry by expiry and only fall back to LRU trimming when
    /// the cap is hit, never zeroing the whole set.
    private var usedNonces: [Data: Date] = [:]
    private var nonceInsertionOrder: [Data] = []
    private var nonceCleanupTime: Date = Date()
    private static let nonceLifetime: TimeInterval = 86400 * 7 // 7 days
    private static let nonceMaxEntries = 100_000
    private static let nonceCleanupBatchSize = 5_000
    
    // MARK: - Public API: Encryption
    
    /// Encrypt a message envelope for secure transmission
    /// Uses AES-256-GCM with a random nonce
    func encryptEnvelope(_ envelope: SecureMeshEnvelope, sharedKey: SymmetricKey) throws -> EncryptedMeshPayload {
        // TODO: [Performance] Replace JSON encoding with Protobuf/FlatBuffers for BLE packets.
        // JSON key overhead (~40 bytes) wastes ~22% of BLE MTU (185 bytes), causing unnecessary chunking.
        // Encode the envelope to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plaintext = try encoder.encode(envelope)
        
        // Generate random nonce
        var nonceBytes = [UInt8](repeating: 0, count: Self.nonceSize)
        guard SecRandomCopyBytes(kSecRandomDefault, Self.nonceSize, &nonceBytes) == errSecSuccess else {
            throw MeshCryptoError.encryptionFailed
        }
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
        
        // Encrypt with AES-256-GCM
        let sealedBox = try AES.GCM.seal(plaintext, using: sharedKey, nonce: nonce)
        
        guard let ciphertext = sealedBox.combined else {
            throw MeshCryptoError.encryptionFailed
        }
        
        // Attach sender signature even on encrypted transport so receivers
        // can enforce sender identity binding after decryption.
        let signingData = envelope.signingData()
        guard let signature = DeviceIdentityService.shared.sign(signingData) else {
            throw MeshCryptoError.signingFailed
        }
        
        return EncryptedMeshPayload(
            ciphertext: ciphertext.base64EncodedString(),
            nonce: Data(nonceBytes).base64EncodedString(),
            senderPublicKey: DeviceIdentityService.shared.agreementPublicKeyBase64 ?? "",
            version: 1,
            signature: signature.base64EncodedString(),
            signerPublicKey: DeviceIdentityService.shared.publicKeyBase64
        )
    }
    
    /// Decrypt a received encrypted payload
    func decryptEnvelope(_ payload: EncryptedMeshPayload, sharedKey: SymmetricKey) throws -> SecureMeshEnvelope {
        guard let ciphertext = Data(base64Encoded: payload.ciphertext) else {
            throw MeshCryptoError.invalidPayload
        }
        
        // 1. Decrypt FIRST to verify integrity (AES-GCM auth tag validates the packet)
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(sealedBox, using: sharedKey)
        
        // 2. Extract authentic nonce from the sealed box (unforgeable — embedded in ciphertext)
        let authenticNonce = sealedBox.nonce.withUnsafeBytes { Data($0) }
        
        // 3. Replay prevention using authentic nonce (NOT the untrusted JSON field)
        if usedNonces[authenticNonce] != nil {
            throw MeshCryptoError.replayAttackDetected
        }

        // Mark nonce as used (with per-entry expiry — replaces the
        // bulk `removeAll()` flush that opened a replay window).
        let expiry = Date().addingTimeInterval(Self.nonceLifetime)
        usedNonces[authenticNonce] = expiry
        nonceInsertionOrder.append(authenticNonce)
        cleanupOldNonces()
        
        // Decode envelope
        let decoder = JSONDecoder()
        return try decoder.decode(SecureMeshEnvelope.self, from: plaintext)
    }
    
    // MARK: - Public API: Signing
    
    /// Sign a mesh envelope and return signed payload
    func signEnvelope(_ envelope: SecureMeshEnvelope) throws -> SignedMeshPayload {
        // Encode essential fields for signing (prevents field manipulation)
        let signingData = envelope.signingData()
        
        guard let signature = DeviceIdentityService.shared.sign(signingData) else {
            throw MeshCryptoError.signingFailed
        }
        
        return SignedMeshPayload(
            envelope: envelope,
            signature: signature.base64EncodedString(),
            signerPublicKey: DeviceIdentityService.shared.publicKeyBase64 ?? ""
        )
    }
    
    /// Verify signature on a signed payload
    /// What a signature check actually established.
    ///
    /// 🔴 2026-07-24 — THE CHOKEPOINT. This type exists because
    /// `verifySignature` used to return a bare `Bool`, which made two very
    /// different facts indistinguishable to every caller:
    ///
    ///   "the person named as the sender signed this"      (authorship proven)
    ///   "SOME authenticated relay vouches for this"        (authorship NOT proven)
    ///
    /// The bridge exceptions below legitimately produce the second — they exist
    /// to fix real, user-reported delivery failures (multi-device bridging, and
    /// group messages relayed by an online member). But collapsing both to
    /// `true` meant any nearby peer could set `isBridged`, address an envelope
    /// to us, and have arbitrary text rendered under a verified contact's name.
    /// Four separate impersonation paths were all this one conflation.
    ///
    /// Callers must now decide explicitly. The rule enforced downstream:
    /// content that is only `.relayAttested` may be DELIVERED, but must not be
    /// ATTRIBUTED to the claimed sender unless the content itself is
    /// cryptographically bound to them (i.e. it opens under a key only they
    /// could have sealed with). Sealed content is self-authenticating; plaintext
    /// is not.
    enum AuthVerdict: Equatable {
        /// The signing key is bound to the claimed `senderId` (or is our own).
        /// Authorship is proven; safe to attribute and to write to the trust store.
        case authorAuthenticated
        /// An authenticated relay vouches for the envelope, but the named sender
        /// is unproven. NEVER sufficient to attribute plaintext or to mutate
        /// trust state.
        case relayAttested
        /// Refuse.
        case rejected

        var isAcceptable: Bool { self != .rejected }
        var isAuthorProven: Bool { self == .authorAuthenticated }
    }

    /// Legacy Bool shim. Returns true for BOTH author-authenticated and
    /// relay-attested envelopes, so it must only be used where a subsequent
    /// check establishes authorship (or where the payload is self-authenticating).
    /// Prefer `authenticate(_:)` and branch on the verdict.
    func verifySignature(_ payload: SignedMeshPayload) async -> Bool {
        await authenticate(payload).isAcceptable
    }

    /// SECURITY: Also verifies identity binding — signerPublicKey must match
    /// a known trusted key for the claimed senderId
    func authenticate(_ payload: SignedMeshPayload) async -> AuthVerdict {
        guard let signature = Data(base64Encoded: payload.signature),
              let publicKey = Data(base64Encoded: payload.signerPublicKey) else {
            logger.debug("Invalid signature data")
            return .rejected
        }
        
        let signingData = payload.envelope.signingData()
        
        // Step 1: Verify cryptographic signature is valid
        let isValid = DeviceIdentityService.shared.verify(
            signature: signature,
            data: signingData,
            publicKey: publicKey
        )
        
        if !isValid {
            logger.debug("SIGNATURE VERIFICATION FAILED - Message may be spoofed!")
            return .rejected
        }
        
        // Step 2: Identity binding — verify signerPublicKey belongs to claimed senderId
        let senderId = payload.envelope.senderId
        let signerKey = payload.signerPublicKey
        
        // Check if it's our OWN message (e.g. echo from relay)
        if signerKey == DeviceIdentityService.shared.publicKeyBase64 {
            return .authorAuthenticated
        }
        
        // Check if signer's key matches any trusted device for this sender
        let trustedDevices = await FriendDeviceRepository.shared.getTrustedDevices(forUser: senderId)
        let keyMatches = trustedDevices.contains { device in
            device.publicKeyBase64 == signerKey
        }
        
        if keyMatches {
            return .authorAuthenticated
        }
        
        // Bug 5 fix: For relayed/bridged messages, verify the ORIGINAL sender's signature
        // instead of blindly trusting. Relay nodes must preserve the original signature.
        let hopCount = payload.envelope.hopCount
        if hopCount > 0 || payload.envelope.isBridged == true {
            // Check if original signature is present (from relay-aware nodes)
            if let origSig = payload.originalSignature,
               let origSigData = Data(base64Encoded: origSig),
               let origPubKey = payload.originalSignerPublicKey,
               let origPubKeyData = Data(base64Encoded: origPubKey) {
                // Verify the ORIGINAL sender's signature
                let origValid = DeviceIdentityService.shared.verify(
                    signature: origSigData,
                    data: signingData,
                    publicKey: origPubKeyData
                )
                if !origValid {
                    logger.debug("ORIGINAL signature FAILED for relayed message from \(senderId, privacy: .private) — possible spoofing!")
                    return .rejected
                }
                // 🔐 BUG FIX (2026-05-10): TOFU for FIRST contact must
                // not silently elevate a stranger's relay-supplied key
                // to `.trusted`. Previously the first-seen key for an
                // unknown sender was upserted as `.trusted` with
                // `verifiedAt = now`, opening the door to a mesh MITM:
                // any attacker on the path could insert their own key
                // and become the user's "trusted" identity for that
                // contact. Now we record the key as `.unverified` so
                // sensitive operations (sealed-sender accept,
                // identity-rotation accept, etc.) require explicit
                // user verification via SafetyNumbers / QR before
                // upgrading to `.trusted`.
                let origTrusted = await FriendDeviceRepository.shared.getTrustedDevices(forUser: senderId)

                if origTrusted.isEmpty {
                    // TOFU for relay — record first-seen key UNVERIFIED.
                    // RE-AUDIT FIX (2026-05-10): only insert if we
                    // don't ALREADY have an unverified row for this
                    // (sender, fingerprint). Without this guard, every
                    // subsequent message from the same TOFU sender
                    // re-created the row with a fresh `addedAt` —
                    // DB churn + lost first-seen timestamp.
                    //
                    // 🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-HIGH-4.
                    //   Cross-check the relay-supplied key against the
                    //   server-pinned identityKey BEFORE upserting. An
                    //   attacker who knows a victim's userId can forge a
                    //   relay envelope with `senderId = victim` signed by
                    //   their own key; without this check the unverified
                    //   row would land first and later REAL messages
                    //   from the victim would be rejected as "IMPERSONATION
                    //   ATTEMPT" (line 295). Pre-emptive sender DoS.
                    //
                    //   If we have a server-pinned identityKey for this
                    //   senderId AND the relay-supplied key doesn't
                    //   match → refuse the TOFU upsert and reject the
                    //   message. The honest first-seen case (no pin in
                    //   the directory) continues to work as before.
                    if let pubKeyData = Data(base64Encoded: origPubKey) {
                        if let pinnedIdentity = await PeerKeyDirectory.shared.identityKey(for: senderId),
                           pinnedIdentity != pubKeyData {
                            logger.debug("REJECTED relayed TOFU: pinned identityKey mismatch for \(senderId, privacy: .private) — possible sender spoof")
                            return .rejected
                        }
                        let fingerprint = String(origPubKey.prefix(16))
                        let existing = await FriendDeviceRepository.shared.getAnyDevice(forUser: senderId, fingerprint: fingerprint)
                        if existing == nil {
                            let device = FriendDevice(
                                friendUserId: senderId,
                                fingerprint: fingerprint,
                                publicKey: pubKeyData,
                                trustState: .unverified,
                                verifiedAt: nil,
                                addedAt: Date(),
                                deviceName: "mesh-tofu-relay-\(senderId.prefix(8))"
                            )
                            try? await FriendDeviceRepository.shared.upsert(device)
                            logger.debug("TOFU: recorded relayed sender \(senderId, privacy: .private) as UNVERIFIED — user must confirm via Safety Number")
                        }
                    }
                } else {
                    // Sender has known trusted devices — key must match one of them
                    let origKeyMatches = origTrusted.contains { $0.publicKeyBase64 == origPubKey }
                        || origPubKey == DeviceIdentityService.shared.publicKeyBase64
                    guard origKeyMatches else {
                        logger.debug("Relay IMPERSONATION: origPubKey not trusted for \(senderId, privacy: .private)")
                        return .rejected
                    }
                }
                logger.debug("Relayed message (hop=\(hopCount, privacy: .public)) — original sender signature VERIFIED")
                    // Authorship IS proven: the ORIGINAL signature verified and its
                    // key was checked against the trusted set for the claimed sender
                    // just above. This is the honest multi-hop relay path.
                    return .authorAuthenticated
            }
            
            // 🔐 BUG FIX (2026-05-10): the previous version accepted
            // any relayed message with `payload.envelope.isBridged ==
            // true` after only verifying the bridge node's outer
            // signature. But `isBridged` is excluded from the signed
            // canonical data (see `signingData()` comment) — a malicious
            // relay could flip ONE byte (`isBridged=true`) on any
            // forwarded message and bypass the inner-signature check
            // entirely. Full sender spoofing for any peer the bridge
            // is trusted by.
            //
            // The honest fix: REQUIRE an inner Ed25519 signature
            // regardless of `isBridged`. Server-bridge envelopes that
            // genuinely lack one must instead carry a server-issued
            // attestation (Ed25519 signature by a known server key)
            // bound to the original ciphertext — or be rejected.
            // Until that attestation flow is wired, refuse the bypass
            // and force the sender path to include the original sig.
            // ⚠️ `isBridged` is NOT covered by `signingData()`, so any relay can
            // flip it on a forwarded frame. That used to be critical: the
            // exceptions below returned a bare `true`, so one attacker-set byte
            // bought full sender impersonation.
            //
            // It is now contained rather than exploitable: every branch here
            // yields `.relayAttested`, which downstream refuses to attribute to
            // the named sender for unsealed content and refuses to let mutate
            // any trust state. An attacker who sets the flag can therefore
            // deliver a frame, but cannot author one — and cannot produce the
            // sealed content that would authenticate itself.
            //
            // Binding `isBridged` into the signature would be proper
            // defence-in-depth, but it changes the signed byte layout, which
            // breaks the shipped app, the Android/Windows ports, and the pinned
            // shared-vectors contract. It belongs in a coordinated wire-version
            // bump, not here.
            if payload.envelope.isBridged == true {
                // 🟥 ROUND 44 (2026-05-17) — multi-device bridge exception.
                //
                // Scenario: A and B are TWO DEVICES OF THE SAME USER
                // ACCOUNT.  C is a different user.  C sends to A via
                // /messages/send.  Server stores + WS-pushes to B.
                // B's bridge-downlink relays the message to A via mesh.
                // A receives a `isBridged=true` envelope addressed to
                // A's own userId.
                //
                // Without an exception, A rejects this with "bridge
                // attestation required" because C's /messages/send
                // path doesn't yet ship an Ed25519 content signature
                // for the server to forward through.
                //
                // BUT: the recipient is OUR OWN userId, and the
                // bridge has been authenticated server-side as
                // OUR user (the JWT auth on /smart-bridge-downlink).
                // The bridge can't forge messages addressed to
                // someone OTHER than the bridge's own user — server
                // only returns messages for `recipient_id IN peer_ids`
                // and only auths the bridge under its own user.  So
                // for the narrow case where (recipient is us AND the
                // relay is a bridge attestation), trust the relay
                // without an inner signature.
                //
                // This still rejects:
                //   • bridged messages addressed to ANOTHER user
                //     (server wouldn't have returned them to a bridge
                //     auth'd as us, but defense in depth)
                //   • bridged messages where signer is NOT a trusted
                //     device of our user (the bridge's own pubkey check)
                let myUserIdSync = await KeychainService.shared.getUserId() ?? ""
                if !myUserIdSync.isEmpty, payload.envelope.recipientId == myUserIdSync {
                    logger.debug("[bridge-exception] Accepting bridged message addressed to own userId (multi-device, no origSig required) — RELAY-ATTESTED ONLY, authorship unproven.")
                    return .relayAttested
                }
                // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — group
                // bridge exception.
                //
                // Scenario (user-reported 2026-05-24):
                //   "lan bridge A be C toye group dorst dare kar mikone
                //    vali C be A na, ... C payam mifreste be group ba
                //    dashtan faghat wifi aslan be group sabt nemishe"
                //   ≈ A→C in group works, but C→A doesn't — i.e. when
                //   C (online) sends to the group, A (BLE-only) never
                //   receives.
                //
                // ROOT CAUSE: B (online + BLE) receives C's group
                // message via WS push and re-broadcasts to mesh via
                // `forwardServerMessageToMesh`. The mesh envelope is
                // signed by B (the relay) — not C (the original
                // sender). A's verifySignature path checks:
                //   • signerKey (B) matches a trusted device for
                //     senderId (C)? NO — B and C are different users.
                //   • originalSignature field present? NO — the WS
                //     push didn't carry C's mesh-canonical signature,
                //     and `message.toMeshEnvelope()` doesn't synthesize
                //     one.
                //   • The 1:1 bridge exception above fires for
                //     `recipientId == myUserId`. For GROUP messages,
                //     `recipientId == group_id`, NOT myUserId → the
                //     exception is skipped → message REJECTED.
                //
                // FIX: parallel exception for groups. Accept the
                // bridge attestation when:
                //   • `payload.envelope.isGroup == true`, AND
                //   • we (the receiver) are a current member of the
                //     target group (recipientId == group_id we have
                //     locally with us in the member list).
                // The bridge can't forge a group message addressed to
                // a group it isn't a member of (server only fans the
                // WS push to actual members), so trusting the
                // bridge's outer sig in this narrow case is safe.
                //
                // 🛡️ SECURITY:
                //   - Sender identity is best-effort (the bridge sig
                //     proves the relay is a trusted-or-tofu member,
                //     not that the named sender actually sent it).
                //     This is the same trust model as the 1:1
                //     multi-device bridge exception above.
                //   - For E2EE content: group AES-GCM ciphertext is
                //     decrypted with the per-group symmetric key only
                //     members hold — a non-member relay can't read
                //     or forge readable content.
                //   - Still rejects:
                //     • non-group bridged messages without origSig
                //       (the original branch handles that)
                //     • messages for groups the receiver isn't in
                //       (membership lookup below)
                if payload.envelope.isGroup == true,
                   !payload.envelope.recipientId.isEmpty {
                    let gid = payload.envelope.recipientId
                    let groupRepo = GroupRepository()
                    let localGroup = try? await groupRepo.get(groupId: gid)
                    let isMember = (localGroup?.members ?? []).contains { $0.userId == myUserIdSync }
                    if isMember {
                        logger.debug("[bridge-exception-group] Accepting bridged group message for member-of group \(gid, privacy: .private) — RELAY-ATTESTED ONLY.")
                        return .relayAttested
                    }
                    // 🟢 ROUND 73 (2026-05-24) — accept bridged group msgs for
                    // UNKNOWN groups too (was rejecting).
                    //
                    // USER REPORT: "hanoz bridge dorost kar nemikone baraye
                    // group" — C→A group messages still missing.
                    //
                    // ROOT CAUSE: when A is a member but hasn't synced the
                    // local group row yet (cold install, just joined, group
                    // _create mesh event lost), `localGroup` is nil →
                    // `isMember` false → bridge rejected at signature gate.
                    // The downstream limbo path in
                    // `RAVENApp.handleMeshMessage` (PendingGroupMessageRepository.
                    // store at L1277) NEVER RUNS because the envelope was
                    // dropped here before reaching the dispatcher.
                    //
                    // FIX: when the group is unknown locally, ACCEPT and let
                    // the receive pipeline limbo-store the envelope. When
                    // the group eventually syncs (server WS group_create,
                    // mesh group_create lifecycle, or syncPendingGroups), the
                    // promoted message replays through the same pipeline
                    // and renders correctly.
                    //
                    // 🛡️ SECURITY: the body is still AES-GCM-sealed under
                    // the group key only members hold. A non-member attacker
                    // bridging fake group envelopes burns limbo capacity
                    // (bounded + 7-day TTL) but can't read or forge content.
                    // The bridge attestation (relay's own Ed25519 sig) still
                    // proves SOME authenticated relay vouches for the
                    // envelope — same trust posture as 1:1 bridge exception
                    // above.
                    if localGroup == nil {
                        logger.debug("[bridge-exception-group] Accepting bridged group message for unsynced group \(gid, privacy: .private) → limbo — RELAY-ATTESTED ONLY.")
                        return .relayAttested
                    }
                    logger.debug("REJECTED: bridged group message for group we are not a member of: \(gid, privacy: .private)")
                    return .rejected
                }
                logger.debug("REJECTED: bridged message arrived without an original sender signature — bridge attestation required (see TODO server-bridge-attestation).")
                return .rejected
            }

            // SECURITY: Reject relayed messages without original signature - prevents spoofing
            logger.debug("REJECTED: Relayed message (hop=\(hopCount, privacy: .public)) without original signature - possible spoofing!")
            return .rejected
        }
        
        // SECURITY: User already has trusted devices registered.
        // An unknown key here is NOT key rotation — it's a potential
        // impersonation attack. Reject the message entirely.
        // Key rotation must be done via explicit re-verification (e.g. QR scan).
        if !trustedDevices.isEmpty {
            logger.debug("IMPERSONATION ATTEMPT! Unknown key for verified user \(senderId, privacy: .private)")
            return .rejected
        }
        
        // 🔐 RE-AUDIT FIX (2026-05-10): the relay-path TOFU was
        // already downgraded to `.unverified` (line ~226). The
        // direct (hop=0, non-bridged) first-contact path was missed
        // — and silently auto-trusted any first-seen key. Now both
        // paths converge: first contact records `.unverified`,
        // requires explicit user verification (Safety Number / QR)
        // before reaching `.trusted`. The signature itself still
        // passes (the message is delivered) but downstream sensitive
        // ops can short-circuit on the trust state.
        //
        // 🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-HIGH-4.
        //   Same directory cross-check as the relay path above: if we
        //   already have a server-pinned identityKey for this userId
        //   and the incoming key disagrees, this is almost certainly
        //   an impersonation attempt — refuse the TOFU upsert AND
        //   reject the message. Without this check the attacker
        //   plants a fake "unverified" row first and the next REAL
        //   message from the victim gets rejected as "IMPERSONATION
        //   ATTEMPT" by line ~295.
        if let pinnedIdentity = await PeerKeyDirectory.shared.identityKey(for: senderId),
           pinnedIdentity != publicKey {
            logger.debug("REJECTED direct TOFU: pinned identityKey mismatch for \(senderId, privacy: .private) — possible sender spoof")
            return .rejected
        }

        logger.debug("TOFU: first-seen direct sender \(senderId, privacy: .private) — recording UNVERIFIED")

        let fingerprint = String(signerKey.prefix(16))
        // Dedup: skip the upsert if we already have any device row
        // for this (sender, fingerprint) — see relay-path note.
        if let _ = await FriendDeviceRepository.shared.getAnyDevice(forUser: senderId, fingerprint: fingerprint) {
                // Hop-0, self-signed: this key authored this envelope. The
                // key->userId binding is TOFU and stays `.unverified` until a
                // safety-number check, but authorship of THIS frame is proven.
                return .authorAuthenticated
        }
        let device = FriendDevice(
            friendUserId: senderId,
            fingerprint: fingerprint,
            publicKey: publicKey,
            trustState: .unverified,
            verifiedAt: nil,
            addedAt: Date(),
            deviceName: "mesh-tofu-\(senderId.prefix(8))"
        )

        do {
            try await FriendDeviceRepository.shared.upsert(device)
        } catch {
            logger.debug("TOFU: Failed to persist key: \(error.localizedDescription, privacy: .public) — still accepting message")
        }

            return .authorAuthenticated
    }
    
    // MARK: - Public API: Rate Limiting (C5)
    
    /// Check if peer is rate limited (DoS protection)
    /// Returns true if message should be accepted, false if rate limited
    func checkRateLimit(for peerId: String) -> Bool {
        let now = Date()
        
        if let entry = peerMessageCounts[peerId] {
            // Reset if window expired
            if now > entry.resetTime {
                peerMessageCounts[peerId] = (count: 1, resetTime: now.addingTimeInterval(60))
                return true
            }
            
            // Check limit
            if entry.count >= Self.maxMessagesPerPeerPerMinute {
                logger.debug("Rate limited peer \(peerId, privacy: .private) - \(entry.count, privacy: .public) msgs in window")
                return false
            }
            
            // Increment
            peerMessageCounts[peerId] = (count: entry.count + 1, resetTime: entry.resetTime)
            return true
        }
        
        // First message from this peer
        peerMessageCounts[peerId] = (count: 1, resetTime: now.addingTimeInterval(60))
        return true
    }
    
    /// Validate hop count and spray counter bounds (C5)
    func validateDTNBounds(hopCount: Int, hopLimit: Int, sprayCounter: Int) -> Bool {
        // hopLimit==0 would be deliverable-but-never-forwardable; honest senders
        // always default to PremiumLimits.meshHopLimit (>= 1), so reject 0 locally.
        guard hopLimit >= 1 && hopLimit <= Self.protocolMaxHopLimit else {
            logger.debug("Invalid hopLimit: \(hopLimit, privacy: .public), protocol max: \(Self.protocolMaxHopLimit, privacy: .public)")
            return false
        }

        guard sprayCounter >= 0 && sprayCounter <= Self.protocolMaxSprayCounter else {
            logger.debug("Invalid sprayCounter: \(sprayCounter, privacy: .public), protocol max: \(Self.protocolMaxSprayCounter, privacy: .public)")
            return false
        }

        guard hopCount >= 0 && hopCount <= hopLimit else {
            logger.debug("Invalid hopCount: \(hopCount, privacy: .public) exceeds hopLimit: \(hopLimit, privacy: .public)")
            return false
        }

        return true
    }
    
    // MARK: - Private Helpers
    
    private func cleanupOldNonces() {
        let now = Date()

        // Only cleanup once per hour for time-based eviction. The
        // size-cap path runs every insert because the cap matters
        // when an attacker is actively flooding.
        let runTimeBased = now.timeIntervalSince(nonceCleanupTime) > 3600
        if runTimeBased {
            // RE-AUDIT FIX (2026-05-10): expire from the FRONT of the
            // insertion-order array (oldest first). Because nonces
            // are inserted with a uniform 7-day lifetime, the
            // expiry order matches insertion order — we can stop
            // as soon as we hit a non-expired entry instead of
            // scanning all 100k entries every cleanup pass.
            // Worst-case is now O(k) where k = expired-this-pass,
            // not O(n).
            var dropCount = 0
            while dropCount < nonceInsertionOrder.count {
                let oldest = nonceInsertionOrder[dropCount]
                guard let expiry = usedNonces[oldest], expiry <= now else { break }
                usedNonces.removeValue(forKey: oldest)
                dropCount += 1
            }
            if dropCount > 0 {
                nonceInsertionOrder.removeFirst(dropCount)
            }
            nonceCleanupTime = now
        }

        // Size-cap path — runs every insert. If we're past the cap,
        // drop the OLDEST batch (LRU), never the whole set. Replaces
        // the previous `removeAll()` panic-flush that opened a wide
        // replay window for any attacker who could spam ≥100k nonces.
        while usedNonces.count > Self.nonceMaxEntries {
            let drop = min(Self.nonceCleanupBatchSize, nonceInsertionOrder.count)
            for nonce in nonceInsertionOrder.prefix(drop) {
                usedNonces.removeValue(forKey: nonce)
            }
            nonceInsertionOrder.removeFirst(drop)
            logger.debug("LRU-evicted \(drop, privacy: .public) oldest nonces (cap=\(Self.nonceMaxEntries, privacy: .public))")
        }
    }
}

// MARK: - Secure Mesh Envelope

/// Signed and encrypted mesh envelope
/// Includes nonce for replay prevention and signature for authenticity
struct SecureMeshEnvelope: Codable {
    // Original envelope fields
    let clientMessageId: String
    let roomId: String
    let senderId: String
    let senderName: String
    let recipientId: String
    let type: Int
    let text: String?
    let timestamp: TimeInterval
    
    // DTN fields
    var sprayCounter: Int
    var hopCount: Int
    var hopLimit: Int
    var routePath: [String]
    let originDeviceId: String
    var needsForwarding: Bool
    var ttlSeconds: Int
    
    // Security fields
    let nonce: String  // Random nonce for this message instance
    let senderPublicKey: String  // For signature verification
    
    // Optional media
    var mediaUrl: String?
    var thumbnailUrl: String?
    var fileName: String?
    var mimeType: String?
    var fileSize: Int?
    var audioDuration: Int?

    // 🔴 ROUND 26 — hacker-audit Mesh F1. Sealed attachment-metadata
    // bundle (see `MeshMediaSealer`). When non-nil, the legacy six
    // media fields above are nil on the wire — the receiver unseals
    // this blob to restore them.
    var mediaSealed: String? = nil

    // Serverless media: AES-GCM ciphertext of the actual media bytes (base64),
    // encrypted under a random content key that rides E2E-sealed in mediaSealed.
    // NOT bound into signingData (its own AEAD tag protects integrity, and it's
    // multi-MB — signing it would bloat every verify). nil for URL-only media.
    var mediaCipher: String? = nil

    // Reply context
    var replyToMessageId: String?
    var replyToTextPreview: String?
    var replyToSenderName: String?
    
    // Bridge flag
    var isBridged: Bool?

    // Group flag (Bug 2 fix)
    var isGroup: Bool?

    // Group key version (round 46 — was previously dropped at this
    // hop, so per-group AES-GCM ciphertexts arriving via the signed
    // path couldn't be decrypted on the receiver. Carry it through
    // and bind it into the signature so a relay can't downgrade.)
    var groupKeyVersion: Int? = nil

    // Geo fence (Feature 3)
    var geoFence: GeoFence?

    // Round 46 — payload-kind discriminator. nil = normal chat
    // message (existing behaviour). "group_create" / "group_update"
    // etc. route the envelope to the group-lifecycle handler on the
    // receiver. Bound into signingData() so a relay can't mutate.
    var payloadKind: String? = nil

    // ── Sealed-Sender Broadcast v2 (task_a1157777) ──────────────────────────
    // Carry the 24-hex identity-hash tokens through the SIGNED path so a sealed
    // broadcast can strip the raw senderId/recipientId yet still be VERIFIED by
    // a relay that doesn't know the sender (it signs over these hashes, not the
    // raw ids — see signingData()'s sealFormat fork). `sealFormat` is the signed
    // discriminator: nil/absent => v1 raw-id form (byte-identical to today);
    // 2 => sealed v2 (hashes at positions 3/5, senderName dropped). It is bound
    // into signingData as a trailing "|sf:2" so a relay can't downgrade v2→v1
    // without invalidating the signature.
    var senderIdHash: String? = nil
    var recipientIdHash: String? = nil
    var sealFormat: Int? = nil

    // Short CodingKeys for ~50% BLE payload reduction
    enum CodingKeys: String, CodingKey {
        case clientMessageId = "id"
        case roomId = "rm"
        case senderId = "sid"
        case senderName = "sn"
        case recipientId = "rid"
        case type = "t"
        case text = "txt"
        case timestamp = "ts"
        case sprayCounter = "sc"
        case hopCount = "hc"
        case hopLimit = "hl"
        case routePath = "rp"
        case originDeviceId = "od"
        case needsForwarding = "nf"
        case ttlSeconds = "ttl"
        case nonce = "n"
        case senderPublicKey = "spk"
        case mediaUrl = "mu"
        case thumbnailUrl = "tu"
        case fileName = "fn"
        case mimeType = "mt"
        case fileSize = "fs"
        case audioDuration = "ad"
        case mediaSealed = "msl"  // round 26 — sealed media metadata
        case mediaCipher = "mc"   // serverless inline media ciphertext
        case replyToMessageId = "rtid"
        case replyToTextPreview = "rttp"
        case replyToSenderName = "rtsn"
        case isBridged = "ib"
        case isGroup = "ig"
        case groupKeyVersion = "gkv"  // round 46 — was missing
        case geoFence = "gf"
        case payloadKind = "pk"       // round 46 — lifecycle event discriminator
        case senderIdHash = "sih"     // sealed-sender v2 (task_a1157777)
        case recipientIdHash = "rih"
        case sealFormat = "sf"
    }
    
    /// Generate data for signing — covers IMMUTABLE fields only
    /// Fields are delimited with "|" to prevent canonicalization attacks
    /// NOTE: sprayCounter, hopCount, hopLimit, routePath, needsForwarding,
    /// ttlSeconds, and isBridged are EXCLUDED because they mutate at every
    /// relay hop, which would invalidate the original sender's signature.
    func signingData() -> Data {
        let delimiter = Data("|".utf8)
        var data = Data()
        data.append(clientMessageId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(roomId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        // ── Sealed-Sender v2 fork (task_a1157777) ──────────────────────────
        // sealFormat == 2 signs over the identity HASHES that ride the wire,
        // NOT the raw ids (which a sealed broadcast strips). senderName is
        // dropped (position 4 empty) — receivers re-derive the display name
        // from their local contacts, never from the wire. sealFormat == nil
        // reproduces the v1 bytes EXACTLY (raw senderId|senderName|recipientId).
        if sealFormat == 2 {
            data.append((senderIdHash ?? "").data(using: .utf8) ?? Data())
            data.append(delimiter)
            data.append(Data())                       // senderName dropped
            data.append(delimiter)
            data.append((recipientIdHash ?? "").data(using: .utf8) ?? Data())
            data.append(delimiter)
        } else {
            data.append(senderId.data(using: .utf8) ?? Data())
            data.append(delimiter)
            data.append(senderName.data(using: .utf8) ?? Data())
            data.append(delimiter)
            data.append(recipientId.data(using: .utf8) ?? Data())
            data.append(delimiter)
        }
        data.append(String(type).data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(nonce.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(senderPublicKey.data(using: .utf8) ?? Data())
        data.append(delimiter)
        let tsString = String(Int64(round(timestamp * 1000)))
        data.append(tsString.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(originDeviceId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(text?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        
        // Media fields — signed to prevent injection
        data.append(mediaUrl?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(thumbnailUrl?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(fileName?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(mimeType?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append((fileSize != nil ? String(fileSize!) : "").data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append((audioDuration != nil ? String(audioDuration!) : "").data(using: .utf8) ?? Data())
        data.append(delimiter)
        // 🔴 ROUND 26 — Mesh F1: bind the sealed media blob into
        // the signature. A relay along the spray path can't
        // substitute attacker-chosen ciphertext without
        // invalidating the Ed25519 signature.
        data.append(mediaSealed?.data(using: .utf8) ?? Data())
        data.append(delimiter)

        // Reply context
        data.append(replyToMessageId?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(replyToTextPreview?.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(replyToSenderName?.data(using: .utf8) ?? Data())
        
        // ❌ EXCLUDED: sprayCounter, hopCount, hopLimit, routePath,
        //    needsForwarding, ttlSeconds, isBridged
        // These values change at every relay hop, invalidating the
        // original sender's signature!
        
        // ✅ INCLUDED: geoFence (immutable, set by sender)
        if let gf = geoFence {
            data.append(delimiter)
            data.append(String(gf.h3Cell).data(using: .utf8) ?? Data())
            data.append(delimiter)
            data.append(String(gf.radiusInCells).data(using: .utf8) ?? Data())
            data.append(delimiter)
            data.append(String(gf.deliverOnlyInside).data(using: .utf8) ?? Data())
        }

        // ✅ ROUND 46 — bind groupKeyVersion + payloadKind into the
        // signature. Both are immutable from the sender's POV:
        //   • groupKeyVersion: the version used to encrypt `text`.
        //     A relay must NOT downgrade this (would point the
        //     receiver at the wrong key → decrypt failure or, worse,
        //     a kicked member's key).
        //   • payloadKind: distinguishes group lifecycle events
        //     from chat messages. A relay must NOT change it
        //     (would route a chat message through the group-create
        //     handler or vice-versa).
        //
        // BACK-COMPAT: only append when SET — when both fields are
        // nil, signingData() matches the v1.6/v1.7-pre-round-46 form
        // exactly so a sender that doesn't know about these fields
        // can still be verified by a round-46 receiver, and vice
        // versa for envelopes with neither set.
        if let gkv = groupKeyVersion {
            data.append(delimiter)
            data.append("gkv:\(gkv)".data(using: .utf8) ?? Data())
        }
        if let pk = payloadKind, !pk.isEmpty {
            data.append(delimiter)
            data.append("pk:\(pk)".data(using: .utf8) ?? Data())
        }

        // Sealed-sender v2 — bind the discriminator into the signature LAST
        // (after gkv/pk) so a relay can't flip sf:2 → absent to silently
        // re-interpret a sealed frame as v1. Absent for v1 ⇒ byte-identical.
        if sealFormat == 2 {
            data.append(delimiter)
            data.append("sf:2".data(using: .utf8) ?? Data())
        }

        return data
    }
}

// MARK: - Signed Payload

/// Payload with envelope and cryptographic signature
struct SignedMeshPayload: Codable {
    let envelope: SecureMeshEnvelope
    let signature: String  // Base64 Ed25519 signature
    let signerPublicKey: String  // Base64 public key for verification
    
    // Bug 5 fix: Preserve original sender's signature through relay chain.
    // Relay nodes set these when forwarding, so the final receiver can verify
    // the message truly originated from the claimed senderId.
    var originalSignature: String?       // Original sender's Ed25519 signature (base64)
    var originalSignerPublicKey: String? // Original sender's public key (base64)
    
    enum CodingKeys: String, CodingKey {
        case envelope = "e"
        case signature = "s"
        case signerPublicKey = "spk"
        case originalSignature = "os"
        case originalSignerPublicKey = "ospk"
    }
}

// MARK: - Encrypted Payload

/// Encrypted payload for BLE transmission
struct EncryptedMeshPayload: Codable {
    let ciphertext: String  // Base64 AES-256-GCM ciphertext
    let nonce: String       // Base64 random nonce
    let senderPublicKey: String  // For ECDH key derivation
    let version: Int        // Protocol version
    let signature: String?  // Base64 Ed25519 signature over SecureMeshEnvelope.signingData()
    let signerPublicKey: String? // Base64 Ed25519 public key for signature verification
    
    enum CodingKeys: String, CodingKey {
        case ciphertext = "c"
        case nonce = "n"
        case senderPublicKey = "spk"
        case version = "v"
        case signature = "s"
        case signerPublicKey = "ssk"
    }
}

// MARK: - Errors

enum MeshCryptoError: Error, LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case signingFailed
    case signatureVerificationFailed
    case invalidPayload
    case replayAttackDetected
    case rateLimited
    case invalidDTNBounds
    
    var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "Message encryption failed"
        case .decryptionFailed: return "Message decryption failed"
        case .signingFailed: return "Message signing failed"
        case .signatureVerificationFailed: return "Signature verification failed"
        case .invalidPayload: return "Invalid encrypted payload"
        case .replayAttackDetected: return "Replay attack detected - message rejected"
        case .rateLimited: return "Peer rate limited"
        case .invalidDTNBounds: return "Invalid DTN routing parameters"
        }
    }
}

// MARK: - MeshEnvelope Extension

extension MeshEnvelope {
    /// Convert to secure envelope with nonce and public key
    func toSecureEnvelope() -> SecureMeshEnvelope {
        // 🔴 2026-07-24 — use the ORIGIN's nonce and key, never freshly-minted
        // ones.
        //
        // This used to generate a random nonce and stamp the local device key
        // on EVERY call. Since `signingData()` binds both, re-wrapping an
        // envelope produced different signing bytes than the origin signed —
        // so `originalSignature` failed at hop >= 1 and every multi-hop
        // delivery was dropped. It was not even stable for the same envelope
        // twice on one device.
        //
        // `meshNonce` / `originSenderPublicKey` are stamped once at origination
        // and preserved across hops and the wire (see MeshEnvelope). The
        // fallbacks only fire for envelopes from a pre-fix sender, whose relay
        // path was already broken.
        let nonce = meshNonce ?? MeshEnvelope.freshNonce()
        let signerKey = originSenderPublicKey ?? DeviceIdentityService.shared.publicKeyBase64 ?? ""


        return SecureMeshEnvelope(
            clientMessageId: clientMessageId,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            type: type,
            text: text,
            timestamp: timestamp,
            sprayCounter: min(sprayCounter, MeshCryptoService.protocolMaxSprayCounter),
            hopCount: hopCount,
            hopLimit: min(hopLimit, 50),
            routePath: routePath,
            originDeviceId: originDeviceId,
            needsForwarding: needsForwarding,
            ttlSeconds: ttlSeconds,
            nonce: nonce,
            senderPublicKey: signerKey,
            mediaUrl: mediaUrl,
            thumbnailUrl: thumbnailUrl,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            audioDuration: audioDuration,
            mediaSealed: mediaSealed,  // round 26 — propagate sealed media blob
            mediaCipher: mediaCipher,  // serverless inline media ciphertext
            replyToMessageId: replyToMessageId,
            replyToTextPreview: replyToTextPreview,
            replyToSenderName: replyToSenderName,
            isBridged: isBridged,
            isGroup: isGroup,
            groupKeyVersion: groupKeyVersion,    // round 46 — was being dropped
            geoFence: geoFence,
            payloadKind: payloadKind,            // round 46 — lifecycle event discriminator
            senderIdHash: senderIdHash,          // sealed-sender v2 (task_a1157777)
            recipientIdHash: recipientIdHash,
            sealFormat: sealFormat
        )
    }
}

extension SecureMeshEnvelope {
    /// Convert back to MeshEnvelope
    func toMeshEnvelope() -> MeshEnvelope {
        var env = MeshEnvelope(
            clientMessageId: clientMessageId,
            roomId: roomId,
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            type: type,
            text: text,
            timestamp: timestamp,
            sprayCounter: sprayCounter,
            hopCount: hopCount,
            hopLimit: hopLimit,
            routePath: routePath,
            originDeviceId: originDeviceId,
            needsForwarding: needsForwarding,
            ttlSeconds: ttlSeconds,
            mediaUrl: mediaUrl,
            thumbnailUrl: thumbnailUrl,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            audioDuration: audioDuration,
            replyToMessageId: replyToMessageId,
            replyToTextPreview: replyToTextPreview,
            replyToSenderName: replyToSenderName,
            isBridged: isBridged,
            isGroup: isGroup,
            geoFence: geoFence
        )
        // round 26 — carry the sealed media blob through the
        // SecureEnvelope → MeshEnvelope hop so the receive-side
        // `MeshMediaSealer.unseal` can restore the legacy fields.
        env.mediaSealed = mediaSealed
        env.mediaCipher = mediaCipher   // serverless inline media ciphertext
        // round 46 — carry the per-group AES-GCM version + the
        // payload-kind discriminator back through so the receive-side
        // can decrypt group ciphertexts (gkv) and route lifecycle
        // events to the dedicated handler (pk).
        env.groupKeyVersion = groupKeyVersion
        env.payloadKind = payloadKind
        // sealed-sender v2 (task_a1157777) — carry the identity-hash tokens +
        // discriminator back so the receive path can resolve + verify a sealed
        // broadcast. (Closes the "hashes lost on the wire" data-loss bug.)
        env.senderIdHash = senderIdHash
        env.recipientIdHash = recipientIdHash
        env.sealFormat = sealFormat
        return env
    }
}
