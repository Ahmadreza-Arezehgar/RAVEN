//
//  RavenEnvelopeChatWire.swift
//  RAVEN — thin product path: endpoint ingest → sealer / Delivered ticks.
//
//  Lives OUTSIDE BridgeSubsystem. Bridge stays key-free; this type owns:
//    • UUID ↔ RavenEnvelopeV1 message_id (16B) mapping
//    • Outbound registry reserved for a future session-authenticated ACK validator
//    • Observer for `.ravenEnvelopeV1EndpointIngest` → MessageContentSealer
//      authenticated decrypt/display
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

/// Canonical RavenAckV1 body codec shared with `raven_core::ack::Ack`.
///
/// Body layout:
/// `acked_message_id(16) || status(1) || ack_nonce(12) || created_at_ms(8 BE) || signature(64)`
/// where the Ed25519 signature covers:
/// `"rvn1/ack" || acked_message_id || status || ack_nonce || created_at_ms`.
enum RavenAckV1 {
    static let deliveredStatus: UInt8 = 1
    static let readStatus: UInt8 = 2
    private static let domain = Data("rvn1/ack".utf8)

    enum AckError: Error {
        case invalidMessageId
        case invalidNonce
        case invalidSignature
    }

    static func signingBytes(
        ackedMessageId: Data,
        status: UInt8,
        ackNonce: Data,
        createdAtMs: UInt64
    ) throws -> Data {
        guard ackedMessageId.count == 16 else { throw AckError.invalidMessageId }
        guard ackNonce.count == 12 else { throw AckError.invalidNonce }

        var out = Data(capacity: domain.count + 16 + 1 + 12 + 8)
        out.append(domain)
        out.append(ackedMessageId)
        out.append(status)
        out.append(ackNonce)
        out.appendUInt64BE(createdAtMs)
        return out
    }

    static func signedBody(
        ackedMessageId: Data,
        status: UInt8 = deliveredStatus,
        ackNonce: Data,
        createdAtMs: UInt64,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let signingBytes = try signingBytes(
            ackedMessageId: ackedMessageId,
            status: status,
            ackNonce: ackNonce,
            createdAtMs: createdAtMs
        )
        let signature = try signingKey.signature(for: signingBytes)
        guard signature.count == 64 else { throw AckError.invalidSignature }

        var body = Data(capacity: 16 + 1 + 12 + 8 + 64)
        body.append(ackedMessageId)
        body.append(status)
        body.append(ackNonce)
        body.appendUInt64BE(createdAtMs)
        body.append(signature)
        return body
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
        outboundByEnvelopeId[Data(ackedEnvelopeId)]
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

    // MARK: - Ingest observer

    private func onEndpointIngest(_ note: Notification) async {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        guard (note.userInfo?["kind"] as? String) == "message",
              let messageId = note.userInfo?["messageId"] as? Data,
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

        // LAN Mac→phone: Peer pub may be missing until Save — still show inbox row.
        if senderId.isEmpty,
           peerKey.hasPrefix("lan") || peerKey == "lan-mac-pull" {
            if let lan = RavenServerlessLanConfig.stored,
               let pub = RavenEnvelopeSenderResolver.pubFromHex(lan.peerPubHex) {
                senderId = DeviceIdentityService.deriveFingerprint(from: pub)
            } else {
                senderId = "mac-lan-unverified"
            }
        }

        // A destination ACK is cryptographic evidence of acceptance, not merely
        // evidence that an opaque frame reached this device. Unknown attribution,
        // plaintext/degraded frames, missing keys, and AEAD failures all stop here.
        guard !senderId.isEmpty,
              senderId != "mac-lan-unverified",
              !myId.isEmpty else {
            return
        }

        let senderAgreementKey = await PeerKeyDirectory.shared.agreementKey(for: senderId)
        let isNoiseBody = sealedBody.prefix(MessageContentSealer.sealedMagic.count)
                == MessageContentSealer.sealedMagic
            || sealedBody.prefix(MessageContentSealer.handshakeMagic.count)
                == MessageContentSealer.handshakeMagic
        guard !isNoiseBody || senderAgreementKey?.count == 32 else {
            // Stateless IK authenticates a static key, but without the pinned
            // expected key it cannot authenticate the claimed sender identity.
            return
        }

        let encoded = Self.sealerEncodedBody(sealedBody)
        guard let unsealed = await MessageContentSealer.unseal(
            encoded: encoded,
            senderUserId: senderId,
            recipientUserId: myId,
            senderAgreementPubKey: senderAgreementKey,
            msgId: clientMid
        ) else {
            return
        }
        switch unsealed.reason {
        case .noiseTransport, .atsamHybrid:
            break
        default:
            return
        }

        let alreadyCommitted = await committedMessageMatches(
            clientMessageId: clientMid,
            senderId: senderId,
            recipientId: myId,
            plaintext: unsealed.plaintext
        )
        let roomId = [senderId, myId].sorted().joined(separator: "_")
        if !alreadyCommitted {
            let now = Date()
            let msg = ChatMessage(
                id: clientMid,
                serverId: nil,
                roomId: roomId,
                senderId: senderId,
                senderName: "",
                recipientId: myId,
                text: unsealed.plaintext,
                timestamp: now,
                type: .text,
                status: .delivered,
                deliveryAuthority: .mesh,
                createdAt: now,
                deliveredAt: now,
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
            do {
                try await MessageRepository.shared.upsert(msg)
            } catch {
                // No durable repository acceptance means no Delivered ACK.
                return
            }
        }

        // Confirm the durable row contains this authenticated plaintext and
        // attribution. Mere ID existence is insufficient: an old placeholder
        // or a colliding row must never authorize an ACK.
        guard await committedMessageMatches(
            clientMessageId: clientMid,
            senderId: senderId,
            recipientId: myId,
            plaintext: unsealed.plaintext
        ) else {
            return
        }

        if !alreadyCommitted {
            NotificationCenter.default.post(
                name: MessageStore.meshMessageReceivedNotification,
                object: nil,
                userInfo: ["roomId": roomId, "messageId": clientMid]
            )
        }

        // Production hold: a Delivered ACK must itself be session-sealed and
        // atomically correlated by the originator. The old signed-but-plaintext
        // body leaked receipt metadata, so no ACK is emitted until that endpoint
        // protocol exists.
    }

    private func committedMessageMatches(
        clientMessageId: String,
        senderId: String,
        recipientId: String,
        plaintext: String
    ) async -> Bool {
        guard let rows = try? await MessageRepository.shared.getMessageByClientId(clientMessageId),
              let row = rows.first,
              row["sender_id"] as? String == senderId,
              row["recipient_id"] as? String == recipientId,
              row["text"] as? String == plaintext,
              row["type"] as? String == MessageType.text.rawValue,
              let status = row["status"] as? String,
              status == MessageStatus.delivered.rawValue || status == MessageStatus.read.rawValue else {
            return false
        }
        return true
    }

}
