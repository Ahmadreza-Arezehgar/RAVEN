//
//  RavenEnvelopeChatWire.swift
//  RAVEN — thin product path: endpoint ingest → sealer / Delivered ticks.
//
//  Lives OUTSIDE BridgeSubsystem. Bridge stays key-free; this type owns:
//    • UUID ↔ RavenEnvelopeV1 message_id (16B) mapping
//    • Outbound registry so sender can resolve ACK → clientMessageId
//    • Observer for `.ravenEnvelopeV1EndpointIngest` → MessageContentSealer
//      decrypt/display + opaque Delivered ACK emit
//    • applyDeliveredFromAck → MessageRepository + MeshACKReceived UI ticks
//
//  FeatureFlag.ravenEnvelopeV1 OFF → no-op.
//

import Foundation
import CryptoKit

/// Pure message_id helpers (not MainActor) — safe from MessageRouter / background tasks.
public enum RavenEnvelopeMessageId {
    /// Prefer raw UUID bytes when `clientMid` is a UUID; else SHA-256 prefix (legacy).
    public static func envelopeMessageId(fromClientMessageId mid: String) -> Data {
        if let uuid = UUID(uuidString: mid) {
            return withUnsafeBytes(of: uuid.uuid) { Data($0) }
        }
        return Data(SHA256.hash(data: Data(mid.utf8)).prefix(16))
    }

    /// Reverse of UUID-byte encoding. Returns nil if `messageId` is not 16 bytes.
    public static func clientMessageId(fromEnvelopeMessageId messageId: Data) -> String? {
        guard messageId.count == 16 else { return nil }
        let uuid: UUID = messageId.withUnsafeBytes { buf in
            UUID(uuid: buf.load(as: uuid_t.self))
        }
        return uuid.uuidString
    }

    /// Sealed body as base64 for `MessageContentSealer.unseal`.
    public static func sealerEncodedBody(_ sealedBody: Data) -> String {
        sealedBody.base64EncodedString()
    }
}

/// Endpoint chat wire-up (not bridge). Conversation keys stay in MessageContentSealer / ATSAM.
@MainActor
public final class RavenEnvelopeChatWire {
    public static let shared = RavenEnvelopeChatWire()

    /// envelope message_id (16B) → client message id (UUID string).
    private var outboundByEnvelopeId: [Data: String] = [:]
    private let maxOutbound = 512

    private var ingestObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Message id mapping (delegates to RavenEnvelopeMessageId)

    public static func envelopeMessageId(fromClientMessageId mid: String) -> Data {
        RavenEnvelopeMessageId.envelopeMessageId(fromClientMessageId: mid)
    }

    public static func clientMessageId(fromEnvelopeMessageId messageId: Data) -> String? {
        RavenEnvelopeMessageId.clientMessageId(fromEnvelopeMessageId: messageId)
    }

    public static func sealerEncodedBody(_ sealedBody: Data) -> String {
        RavenEnvelopeMessageId.sealerEncodedBody(sealedBody)
    }

    // MARK: - Outbound registry

    public func registerOutbound(clientMessageId: String, envelopeMessageId: Data) {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        guard envelopeMessageId.count == 16 else { return }
        if outboundByEnvelopeId.count >= maxOutbound,
           let first = outboundByEnvelopeId.keys.first {
            outboundByEnvelopeId.removeValue(forKey: first)
        }
        outboundByEnvelopeId[Data(envelopeMessageId)] = clientMessageId
    }

    public func resolveClientMessageId(ackedEnvelopeId: Data) -> String? {
        if let mid = outboundByEnvelopeId[Data(ackedEnvelopeId)] {
            return mid
        }
        return Self.clientMessageId(fromEnvelopeMessageId: ackedEnvelopeId)
    }

    public func hasPendingOutbound(envelopeMessageId: Data) -> Bool {
        outboundByEnvelopeId[Data(envelopeMessageId)] != nil
    }

    // MARK: - Lifecycle

    public func start() {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else {
            stop()
            return
        }
        guard ingestObserver == nil else { return }
        ingestObserver = NotificationCenter.default.addObserver(
            forName: .ravenEnvelopeV1EndpointIngest,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                await self?.onEndpointIngest(note)
            }
        }
        #if DEBUG
        print("🕊️ [ChatWire] observing .ravenEnvelopeV1EndpointIngest (flag ON)")
        #endif
    }

    public func stop() {
        if let ingestObserver {
            NotificationCenter.default.removeObserver(ingestObserver)
            self.ingestObserver = nil
        }
    }

    // MARK: - Delivered ticks (sender)

    /// Apply real endpoint ACK → UI Delivered without bridge keys.
    @discardableResult
    public func applyDeliveredFromAck(ackedEnvelopeId: Data) async -> String? {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return nil }
        guard let clientMid = resolveClientMessageId(ackedEnvelopeId: ackedEnvelopeId) else {
            #if DEBUG
            print("🕊️ [ChatWire] ACK mid unresolved — skip Delivered")
            #endif
            return nil
        }
        await Self.applyDelivered(clientMessageId: clientMid)
        outboundByEnvelopeId.removeValue(forKey: Data(ackedEnvelopeId))
        return clientMid
    }

    public static func applyDelivered(clientMessageId: String) async {
        let rows = try? await DatabaseService.shared.query(
            "SELECT status FROM messages WHERE client_message_id = ? LIMIT 1",
            params: [clientMessageId]
        )
        if let current = rows?.first?["status"] as? String, current == "read" {
            return
        }
        try? await MessageRepository.shared.markDelivered(clientMessageId: clientMessageId, at: Date())
        try? await MessageRepository.shared.updateDeliveryAuthority(
            clientMessageId: clientMessageId,
            authority: .mesh
        )
        try? await OutboxRepository.shared.markDelivered(clientMessageId: clientMessageId, via: .mesh)
        await BLEMeshEngine.shared.broadcastStop(clientMessageId)
        try? await DeliveryJobRepository.shared.markStopped(messageId: clientMessageId)

        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("MeshACKReceived"),
                object: nil,
                userInfo: [
                    "messageId": clientMessageId,
                    "status": MessageStatus.delivered.rawValue
                ]
            )
        }
        #if DEBUG
        print("🕊️ [ChatWire] Delivered tick mid=\(clientMessageId.prefix(8))…")
        #endif
    }

    // MARK: - Ingest observer

    private func onEndpointIngest(_ note: Notification) async {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        let kind = (note.userInfo?["kind"] as? String) ?? "message"

        if kind == "ack",
           let acked = note.userInfo?["ackedMessageId"] as? Data {
            _ = await applyDeliveredFromAck(ackedEnvelopeId: acked)
            return
        }

        guard let messageId = note.userInfo?["messageId"] as? Data,
              let sealedBody = note.userInfo?["sealedBody"] as? Data else {
            return
        }
        let peerKey = (note.userInfo?["peerKey"] as? String) ?? ""
        let senderHint = note.userInfo?["senderUserId"] as? String

        await handleDestinationSealedBody(
            messageId: messageId,
            sealedBody: sealedBody,
            peerKey: peerKey,
            senderUserIdHint: senderHint
        )
    }

    /// Destination: unseal via MessageContentSealer, persist, emit opaque Delivered ACK.
    public func handleDestinationSealedBody(
        messageId: Data,
        sealedBody: Data,
        peerKey: String,
        senderUserIdHint: String?
    ) async {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }

        let clientMid = Self.clientMessageId(fromEnvelopeMessageId: messageId)
            ?? messageId.map { String(format: "%02x", $0) }.joined()
        let myId = await KeychainService.shared.getUserId() ?? ""

        // Prefer ingest hint (Bridge resolved via identity verify); then BLE peer map.
        var senderId = senderUserIdHint
            ?? BLEMeshEngine.shared.connectedPeers.first(where: { $0.deviceId == peerKey })?.userId
            ?? ""

        // Last resort: if hint missing but we have sealed body only, keep empty → no fake plaintext.
        // (Full env verify needs packed envelope — Bridge publishes senderUserId when resolvable.)

        let encoded = Self.sealerEncodedBody(sealedBody)
        var plaintext: String?
        var attributionProven = false

        if !senderId.isEmpty, !myId.isEmpty {
            let unsealed = await MessageContentSealer.unseal(
                encoded: encoded,
                senderUserId: senderId,
                recipientUserId: myId,
                senderAgreementPubKey: await PeerKeyDirectory.shared.agreementKey(for: senderId),
                msgId: clientMid
            )
            if let u = unsealed {
                switch u.reason {
                case .noiseTransport, .atsamHybrid:
                    attributionProven = true
                    plaintext = u.plaintext.isEmpty ? nil : u.plaintext
                default:
                    if !u.plaintext.isEmpty { plaintext = u.plaintext }
                }
            }
        }

        // Persist when sender is attributed (resolved fingerprint / directory / BLE).
        if !senderId.isEmpty, !myId.isEmpty {
            let exists = await MessageRepository.shared.exists(clientMessageId: clientMid)
            if !exists {
                let display = plaintext
                    ?? (attributionProven
                        ? "🔒 [Encrypted message — could not decrypt]"
                        : "🔒 Sealed Raven envelope — awaiting keys")
                let roomId = [senderId, myId].sorted().joined(separator: "_")
                let msg = ChatMessage(
                    id: clientMid,
                    serverId: nil,
                    roomId: roomId,
                    senderId: senderId,
                    senderName: "",
                    recipientId: myId,
                    text: display,
                    timestamp: Date(),
                    type: .text,
                    status: .delivered,
                    deliveryAuthority: .mesh,
                    createdAt: Date(),
                    deliveredAt: Date(),
                    readAt: nil,
                    hopCount: 0,
                    routePath: [],
                    sprayCounter: 0,
                    hopLimit: 0,
                    originDeviceId: peerKey,
                    needsForwarding: false,
                    attachmentUrl: nil,
                    thumbnailUrl: nil,
                    fileName: nil,
                    mimeType: nil,
                    fileSize: nil,
                    audioDurationSeconds: nil,
                    syncState: .localOnly,
                    localPath: nil,
                    uploadProgress: nil,
                    lastError: nil,
                    replyToMessageId: nil,
                    replyToTextPreview: nil,
                    replyToSenderName: nil,
                    replyToType: nil,
                    sendMode: nil,
                    scheduledAtUtc: nil
                )
                try? await MessageRepository.shared.upsert(msg)
                NotificationCenter.default.post(
                    name: MessageStore.meshMessageReceivedNotification,
                    object: nil,
                    userInfo: ["roomId": roomId, "messageId": clientMid]
                )
            }
        }

        // True recipient ACK — opaque; BridgeSubsystem never decrypts.
        await emitDeliveredAck(ackedMessageId: messageId, routingPeerKey: peerKey)
    }

    /// Pack Delivered ACK (raven-node layout) and enqueue on BLE for reverse relay.
    public func emitDeliveredAck(ackedMessageId: Data, routingPeerKey: String) async {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        guard ackedMessageId.count == 16 else { return }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed,
              let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            return
        }

        var body = Data()
        body.append(ackedMessageId)
        body.append(1) // STATUS_DELIVERED
        var nonce = Data(count: 12)
        nonce.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, buf.baseAddress!)
        }
        body.append(nonce)
        let created = UInt64(Date().timeIntervalSince1970 * 1000).bigEndian
        withUnsafeBytes(of: created) { body.append(contentsOf: $0) }
        // Placeholder 64B — envelope Ed25519 covers authenticity; body sig is opaque to relays.
        body.append(Data(repeating: 0, count: 64))

        var ackMid = Data(count: 16)
        ackMid.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        var routingTag = Data(count: 16)
        routingTag.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        var antiReplay = Data(count: 12)
        antiReplay.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, buf.baseAddress!)
        }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var env = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            messageId: ackMid,
            routingTag: routingTag,
            createdAtMs: nowMs,
            expiresAtMs: nowMs &+ 86_400_000,
            hopLimit: 8,
            replicationBudget: 1,
            antiReplayNonce: antiReplay,
            messageCiphertext: body
        )
        env.sign(with: signingKey)
        let packed = env.pack()
        await BLEMeshEngine.shared.enqueueRawRavenEnvelopeV1(packed)
        #if DEBUG
        let midHex = ackedMessageId.prefix(4).map { String(format: "%02x", $0) }.joined()
        print("🕊️ [ChatWire] emitted Delivered ACK acked=\(midHex)… peer=\(routingPeerKey)")
        #endif
        _ = routingPeerKey
    }
}
