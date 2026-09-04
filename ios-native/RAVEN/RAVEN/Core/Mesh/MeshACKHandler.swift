//
//  MeshACKHandler.swift
//  RAVEN
//
//  ACK-based delivery confirmation and deduplication for mesh messages
//

import Foundation
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Mesh.ACK")

/// Handles ACK processing and message deduplication for mesh networking
/// Key principle: "Dedup باید با MessageID + ACK از گیرنده حل شود"
actor MeshACKHandler {
    static let shared = MeshACKHandler()

    struct IncomingAuthorization: Sendable {
        let currentStatus: MessageStatus
    }
    
    private let mesh: any MeshTransportProtocol
    private let db = DatabaseService.shared

    /// A durable side-table records that a specific inbound row was reached
    /// only after its authenticated body opened successfully. A row in
    /// `messages` alone is not enough evidence: older builds persisted
    /// decrypt-failure placeholders and then ACKed them.
    private var authenticatedCommitTableReady = false
    
    // Track seen message IDs for deduplication
    // Key: clientMessageId, Value: timestamp when first seen
    private var seenMessageIds: [String: Date] = [:]
    
    // Max age for seen IDs cache (7 days)
    private let maxCacheAge: TimeInterval = 7 * 24 * 60 * 60
    
    init(mesh: any MeshTransportProtocol = BLEMeshEngine.shared) {
        self.mesh = mesh
    }
    
    // MARK: - Deduplication
    
    /// Check if this message has been seen before (for receiver-side dedup)
    /// Returns true if duplicate, false if new
    func isDuplicate(_ messageId: String) -> Bool {
        // Clean old entries periodically
        cleanExpiredEntries()
        
        // READ-ONLY: do NOT mark as seen here. Callers MUST call markAsSeen(_:)
        // only AFTER the message is durably persisted. Marking pre-persist
        // burned the ID for 7 days (maxCacheAge), so a re-sprayed copy of a
        // message whose insert later failed was silently dropped forever.
        return seenMessageIds[messageId] != nil
    }
    
    /// Mark a message as seen (call when processing incoming message)
    func markAsSeen(_ messageId: String) {
        seenMessageIds[messageId] = Date()
    }
    
    // MARK: - ACK Processing

    /// Pure identity binding used by the receive chokepoints and focused tests.
    /// A receipt may mutate local delivery state only when it names the exact
    /// recipient stored on an existing message authored by this account.
    nonisolated static func hasExactOutboundBinding(
        localUserId: String,
        ackSenderId: String,
        rowSenderId: String,
        rowRecipientId: String
    ) -> Bool {
        !localUserId.isEmpty
            && !ackSenderId.isEmpty
            && rowSenderId == localUserId
            && rowRecipientId == ackSenderId
    }

    /// The signer must be one of the exact recipient user's already-pinned
    /// Ed25519 device keys. A valid self-signature over a self-declared userId
    /// is deliberately insufficient.
    nonisolated static func signerKeyIsPinned(
        _ signerKey: Data,
        expectedRecipientKeys: [Data]
    ) -> Bool {
        signerKey.count == 32 && expectedRecipientKeys.contains(signerKey)
    }

    nonisolated static func statusAdvances(from current: MessageStatus, to next: MessageStatus) -> Bool {
        func rank(_ status: MessageStatus) -> Int {
            switch status {
            case .delivered: return 1
            case .read: return 2
            default: return 0
            }
        }
        return rank(next) > rank(current)
    }

    /// Reusable, read-only authorization gate for a locally-destined ACK.
    /// Nothing in this method mutates message/outbox/job/UI state.
    func authorizeIncomingACK(_ ack: MeshACKEnvelope) async -> IncomingAuthorization? {
        guard ack.isACK,
              !ack.originalMessageId.isEmpty, ack.originalMessageId.count <= 512,
              !ack.senderId.isEmpty, ack.senderId.count <= 512,
              !ack.recipientId.isEmpty, ack.recipientId.count <= 512,
              ack.timestamp.isFinite,
              ack.signature != nil,
              ack.isSignatureValid(),
              let signerB64 = ack.signerPublicKey,
              let signerKey = Data(base64Encoded: signerB64),
              signerKey.count == 32,
              let localUserId = await KeychainService.shared.getUserId(),
              ack.recipientId == localUserId else {
            return nil
        }

        let rows: [[String: Any]]
        do {
            rows = try await db.query(
                """
                SELECT sender_id, recipient_id, status
                FROM messages
                WHERE client_message_id = ?
                LIMIT 2
                """,
                params: [ack.originalMessageId]
            )
        } catch {
            logger.error("ACK authorization DB lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard rows.count == 1,
              let rowSenderId = rows[0]["sender_id"] as? String,
              let rowRecipientId = rows[0]["recipient_id"] as? String,
              let currentRaw = rows[0]["status"] as? String,
              let currentStatus = MessageStatus(rawValue: currentRaw),
              currentStatus != .scheduled,
              Self.hasExactOutboundBinding(
                localUserId: localUserId,
                ackSenderId: ack.senderId,
                rowSenderId: rowSenderId,
                rowRecipientId: rowRecipientId
              ) else {
            return nil
        }

        let expectedKeys: [Data]
        if ack.senderId == localUserId {
            expectedKeys = DeviceIdentityService.shared.publicKeyBase64
                .flatMap { Data(base64Encoded: $0) }
                .map { [$0] } ?? []
        } else {
            expectedKeys = await FriendDeviceRepository.shared
                .getTrustedDevices(forUser: ack.senderId)
                .map(\.publicKey)
        }
        guard Self.signerKeyIsPinned(signerKey, expectedRecipientKeys: expectedKeys) else {
            return nil
        }

        return IncomingAuthorization(currentStatus: currentStatus)
    }

    /// Persist proof that this exact inbound row was committed after an
    /// authenticated decrypt. The caller supplies the just-written model; we
    /// re-read every critical field so an attacker cannot pre-seed the same
    /// message ID with a different sender, recipient, body, type, or status.
    @discardableResult
    func recordAuthenticatedCommit(for message: ChatMessage) async -> Bool {
        guard !message.id.isEmpty,
              let localUserId = await KeychainService.shared.getUserId(),
              message.recipientId == localUserId,
              message.senderId != localUserId,
              await ensureAuthenticatedCommitTable() else {
            return false
        }

        // A prior proof remains authoritative if the row's immutable identity
        // binding still matches. This keeps legitimate retransmission ACKs
        // working after the message advances to read or its display text is
        // edited, without weakening first-commit verification below.
        do {
            let existingProof = try await db.query(
                """
                SELECT 1
                FROM mesh_authenticated_commits AS c
                INNER JOIN messages AS m ON m.client_message_id = c.message_id
                WHERE c.message_id = ?
                  AND c.original_sender_id = ?
                  AND c.local_recipient_id = ?
                  AND m.sender_id = ?
                  AND m.recipient_id = ?
                LIMIT 2
                """,
                params: [
                    message.id,
                    message.senderId,
                    localUserId,
                    message.senderId,
                    localUserId
                ]
            )
            if existingProof.count == 1 { return true }
        } catch {
            logger.error("Existing authenticated commit lookup failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let rows: [[String: Any]]
        do {
            rows = try await db.query(
                """
                SELECT room_id, sender_id, recipient_id, text, type, status
                FROM messages
                WHERE client_message_id = ?
                LIMIT 2
                """,
                params: [message.id]
            )
        } catch {
            logger.error("Authenticated commit verification failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        guard rows.count == 1 else { return false }
        let row = rows[0]
        let expectedRoomId = message.roomId ?? message.senderId
        let rowText = row["text"]
        let textMatches: Bool = {
            if let expected = message.text { return rowText as? String == expected }
            return rowText == nil || rowText is NSNull
        }()
        let persistedStatus = (row["status"] as? String).flatMap(MessageStatus.init(rawValue:))
        let statusMatches: Bool = {
            switch message.status {
            case .delivered:
                return persistedStatus == .delivered || persistedStatus == .read
            case .read:
                return persistedStatus == .read
            default:
                return persistedStatus == message.status
            }
        }()
        guard row["room_id"] as? String == expectedRoomId,
              row["sender_id"] as? String == message.senderId,
              row["recipient_id"] as? String == message.recipientId,
              textMatches,
              row["type"] as? String == message.type.rawValue,
              statusMatches else {
            return false
        }

        do {
            try await db.execute(
                """
                INSERT OR REPLACE INTO mesh_authenticated_commits
                    (message_id, original_sender_id, local_recipient_id, committed_at)
                VALUES (?, ?, ?, ?)
                """,
                params: [
                    message.id,
                    message.senderId,
                    localUserId,
                    Date().timeIntervalSince1970
                ]
            )
            let proof = try await db.query(
                """
                SELECT 1 FROM mesh_authenticated_commits
                WHERE message_id = ? AND original_sender_id = ? AND local_recipient_id = ?
                LIMIT 1
                """,
                params: [message.id, message.senderId, localUserId]
            )
            return proof.count == 1
        } catch {
            logger.error("Authenticated commit persistence failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Final send-side choke point. Delivery/read ACKs cannot be emitted merely
    /// because a caller knows a message ID; the exact inbound row must carry a
    /// durable authenticated-commit proof.
    func authorizeOutgoingACK(_ ack: MeshACKEnvelope) async -> Bool {
        guard ack.isACK,
              !ack.originalMessageId.isEmpty,
              let localUserId = await KeychainService.shared.getUserId(),
              ack.senderId == localUserId,
              ack.recipientId != localUserId,
              await ensureAuthenticatedCommitTable() else {
            return false
        }

        do {
            let rows = try await db.query(
                """
                SELECT m.sender_id, m.recipient_id, m.status
                FROM messages AS m
                INNER JOIN mesh_authenticated_commits AS c
                    ON c.message_id = m.client_message_id
                WHERE m.client_message_id = ?
                  AND m.sender_id = ?
                  AND m.recipient_id = ?
                  AND c.original_sender_id = ?
                  AND c.local_recipient_id = ?
                LIMIT 2
                """,
                params: [
                    ack.originalMessageId,
                    ack.recipientId,
                    localUserId,
                    ack.recipientId,
                    localUserId
                ]
            )
            guard rows.count == 1,
                  let persistedStatusRaw = rows[0]["status"] as? String,
                  let persistedStatus = MessageStatus(rawValue: persistedStatusRaw) else {
                return false
            }
            switch ack.status {
            case .delivered:
                return persistedStatus == .delivered || persistedStatus == .read
            case .read:
                return persistedStatus == .read
            }
        } catch {
            logger.error("Outgoing ACK authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    /// Handle incoming ACK from mesh (delivery/read confirmation)
    func handleIncomingACK(_ ack: MeshACKEnvelope) async {
        let messageId = ack.originalMessageId

        guard let authorization = await authorizeIncomingACK(ack) else {
            logger.debug("Rejected unauthorized ACK for \(messageId, privacy: .private)")
            return
        }

        logger.debug("Processing ACK for message \(messageId, privacy: .private) status=\(ack.status.rawValue, privacy: .public) from=\(ack.senderId, privacy: .private)")
        
        // Protocol Delivered/Read only from a verified ACK (RAVEN_ACK_V1 §3).
        let ackStatusByte: UInt8 = ack.status == .read
            ? RavenAckV1.readStatus
            : RavenAckV1.deliveredStatus
        guard let newStatus = EndpointDeliveryPolicy.afterVerifiedAck(status: ackStatusByte),
              Self.statusAdvances(from: authorization.currentStatus, to: newStatus) else {
            return
        }

        do {
            switch newStatus {
            case .delivered:
                try await MessageRepository.shared.markDelivered(
                    clientMessageId: messageId,
                    at: Date()
                )
            case .read:
                try await MessageRepository.shared.markRead(
                    clientMessageId: messageId,
                    at: Date()
                )
            default:
                try await MessageRepository.shared.updateStatus(
                    clientMessageId: messageId,
                    status: newStatus
                )
            }
            let committed = try await db.query(
                "SELECT status FROM messages WHERE client_message_id = ? LIMIT 1",
                params: [messageId]
            )
            guard committed.count == 1,
                  committed[0]["status"] as? String == newStatus.rawValue else {
                logger.error("ACK status update did not commit exactly; suppressing follow-on effects")
                return
            }
            logger.debug("Message \(messageId, privacy: .private) marked as \(newStatus.rawValue, privacy: .public)")
        } catch {
            logger.debug("Failed to update status: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Send ACK
    
    /// Send ACK back to sender (call when receiving a mesh message)
    func sendDeliveryACK(for messageId: String, toSenderId senderId: String) async {
        guard let myId = await KeychainService.shared.getUserId(), !myId.isEmpty else {
            logger.debug("Cannot send ACK - no user ID")
            return
        }

        var ack = MeshACKEnvelope(
            originalMessageId: messageId,
            senderId: myId,
            recipientId: senderId,
            status: .delivered,
            pathUsed: "mesh",
            originDeviceId: DeviceIdentityService.shared.fingerprint ?? ""
        )

        ack.sign()
        guard ack.signature != nil,
              ack.signerPublicKey != nil,
              ack.isSignatureValid() else {
            logger.debug("Refusing delivery ACK because local signing failed")
            return
        }
        guard await authorizeOutgoingACK(ack) else {
            logger.debug("Refusing delivery ACK without authenticated durable commit for \(messageId, privacy: .private)")
            return
        }
        logger.debug("Sending delivery ACK to \(senderId, privacy: .private) for message \(messageId, privacy: .private)")
        await mesh.sendACK(ack)
    }
    
    /// Send read ACK when user opens chat
    func sendReadACK(for messageId: String, toSenderId senderId: String) async {
        // Ghost Mode: suppress read receipts for premium users
        if PremiumLimits.ghostModeEnabled { return }
        
        guard let myId = await KeychainService.shared.getUserId(), !myId.isEmpty else {
            return
        }
        
        var ack = MeshACKEnvelope(
            originalMessageId: messageId,
            senderId: myId,
            recipientId: senderId,
            status: .read,
            pathUsed: "mesh",
            originDeviceId: DeviceIdentityService.shared.fingerprint ?? ""
        )

        ack.sign()
        guard ack.signature != nil,
              ack.signerPublicKey != nil,
              ack.isSignatureValid() else {
            logger.debug("Refusing read ACK because local signing failed")
            return
        }
        guard await authorizeOutgoingACK(ack) else {
            logger.debug("Refusing read ACK without authenticated durable commit for \(messageId, privacy: .private)")
            return
        }
        logger.debug("Sending read ACK to \(senderId, privacy: .private) for message \(messageId, privacy: .private)")
        await mesh.sendACK(ack)
    }
    
    // MARK: - Cleanup
    
    private func cleanExpiredEntries() {
        let now = Date()
        seenMessageIds = seenMessageIds.filter { _, date in
            now.timeIntervalSince(date) < maxCacheAge
        }
    }
    
    /// Clear all cached message IDs (for testing/reset)
    func reset() {
        seenMessageIds.removeAll()
    }

    private func ensureAuthenticatedCommitTable() async -> Bool {
        if authenticatedCommitTableReady { return true }
        do {
            try await db.execute(
                """
                CREATE TABLE IF NOT EXISTS mesh_authenticated_commits (
                    message_id TEXT PRIMARY KEY,
                    original_sender_id TEXT NOT NULL,
                    local_recipient_id TEXT NOT NULL,
                    committed_at REAL NOT NULL
                )
                """
            )
            try await db.execute(
                "CREATE INDEX IF NOT EXISTS idx_mesh_authenticated_commits_recipient ON mesh_authenticated_commits(local_recipient_id)"
            )
            authenticatedCommitTableReady = true
            return true
        } catch {
            logger.error("Authenticated commit table unavailable: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
