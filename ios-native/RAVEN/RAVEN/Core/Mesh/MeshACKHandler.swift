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
    
    private let mesh: any MeshTransportProtocol
    
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
    
    /// Handle incoming ACK from mesh (delivery/read confirmation)
    func handleIncomingACK(_ ack: MeshACKEnvelope) async {
        let messageId = ack.originalMessageId

        logger.debug("Processing ACK for message \(messageId, privacy: .private) status=\(ack.status.rawValue, privacy: .public) from=\(ack.senderId, privacy: .private)")
        
        // Update message status based on ACK
        let newStatus: MessageStatus
        switch ack.status {
        case .delivered:
            newStatus = .delivered
        case .read:
            newStatus = .read
        }
        
        do {
            try await MessageRepository.shared.updateStatus(
                clientMessageId: messageId,
                status: newStatus
            )
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

        let ack = MeshACKEnvelope(
            originalMessageId: messageId,
            senderId: myId,
            recipientId: senderId,
            status: .delivered,
            pathUsed: "mesh",
            originDeviceId: DeviceIdentityService.shared.fingerprint ?? ""
        )

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
        
        let ack = MeshACKEnvelope(
            originalMessageId: messageId,
            senderId: myId,
            recipientId: senderId,
            status: .read,
            pathUsed: "mesh",
            originDeviceId: DeviceIdentityService.shared.fingerprint ?? ""
        )
        
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
}
