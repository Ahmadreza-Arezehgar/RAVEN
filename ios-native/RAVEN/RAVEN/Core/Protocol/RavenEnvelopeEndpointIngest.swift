//
//  RavenEnvelopeEndpointIngest.swift
//  RAVEN — flagged destination handoff: BLE/LAN RVN1 → chat sealer boundary.
//
//  BridgeSubsystem never decrypts. This type only classifies + extracts the
//  opaque sealed body for MessageContentSealer / ATSAM (conversation keys stay
//  outside the bridge). FeatureFlag.ravenEnvelopeV1 OFF → no-op.
//

import Foundation

/// Endpoint-side disposition for an inbound RavenEnvelopeV1 (not Bridge forward).
public enum RavenEnvelopeEndpointIngest {

    public enum Disposition: Equatable {
        case flagOff
        case dropMalformed
        case dropNotMessage
        case deliverSealedBody(messageId: Data, sealedBody: Data, hybridPQ: Bool)
        /// ACK arrived at true originator endpoint (after bridge reverse).
        case acceptAck(ackedMessageId: Data, packed: Data)
    }

    /// Pure classification — no crypto, no I/O.
    public static func classify(
        packed: Data,
        flagOn: Bool
    ) -> Disposition {
        guard flagOn else { return .flagOff }
        guard RavenBleRvn1Carrier.looksLikeRavenEnvelopeV1(packed),
              let env = RavenEnvelopeV1.unpack(packed) else {
            return .dropMalformed
        }
        switch env.envType {
        case RavenEnvelopeV1.EnvType.message.rawValue:
            let hybrid = (env.flags & 1) != 0
            return .deliverSealedBody(
                messageId: env.messageId,
                sealedBody: env.messageCiphertext,
                hybridPQ: hybrid
            )
        case RavenEnvelopeV1.EnvType.ack.rawValue:
            guard let acked = opaqueAckedMessageId(from: env) else {
                return .dropMalformed
            }
            return .acceptAck(ackedMessageId: acked, packed: packed)
        default:
            return .dropNotMessage
        }
    }

    /// Multi-role: destination beats bridge so phone-as-B never steals C's body.
    public enum RoleDisposition: Equatable {
        case deliverToEndpoint
        case bridgeForward
        case ackRelay
        case drop
    }

    public static func classifyRole(
        envType: UInt8,
        localIsDestination: Bool,
        bridgeEnabled: Bool
    ) -> RoleDisposition {
        switch envType {
        case RavenEnvelopeV1.EnvType.ack.rawValue:
            return bridgeEnabled ? .ackRelay : .deliverToEndpoint
        case RavenEnvelopeV1.EnvType.message.rawValue:
            if localIsDestination { return .deliverToEndpoint }
            if bridgeEnabled { return .bridgeForward }
            return .deliverToEndpoint
        default:
            return .drop
        }
    }

    /// Peek acked_message_id from opaque ACK body (no conversation decrypt).
    /// Layout: acked_id(16) || status(1) || nonce(12) || created_at(8) || …
    public static func opaqueAckedMessageId(from env: RavenEnvelopeV1) -> Data? {
        guard env.envType == RavenEnvelopeV1.EnvType.ack.rawValue,
              env.messageCiphertext.count >= 16 else { return nil }
        return env.messageCiphertext.prefix(16)
    }

    /// Post sealed body for chat sealer / app ingest. Never decrypts here.
    @MainActor
    public static func publishSealedBody(
        messageId: Data,
        sealedBody: Data,
        hybridPQ: Bool,
        peerKey: String,
        senderUserId: String? = nil
    ) {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        var info: [AnyHashable: Any] = [
            "kind": "message",
            "messageId": messageId,
            "sealedBody": sealedBody,
            "hybridPQ": hybridPQ,
            "peerKey": peerKey
        ]
        if let senderUserId, !senderUserId.isEmpty {
            info["senderUserId"] = senderUserId
        }
        NotificationCenter.default.post(
            name: .ravenEnvelopeV1EndpointIngest,
            object: nil,
            userInfo: info
        )
        #if DEBUG
        let midHex = messageId.prefix(4).map { String(format: "%02x", $0) }.joined()
        print("🕊️ [Endpoint] sealed-body ingest mid=\(midHex)… bytes=\(sealedBody.count)")
        #endif
    }

    /// Originator endpoint: opaque ACK after bridge reverse — drives Delivered ticks.
    @MainActor
    public static func publishAck(ackedMessageId: Data, packed: Data) {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        NotificationCenter.default.post(
            name: .ravenEnvelopeV1EndpointIngest,
            object: nil,
            userInfo: [
                "kind": "ack",
                "ackedMessageId": ackedMessageId,
                "packed": packed
            ]
        )
        #if DEBUG
        let midHex = ackedMessageId.prefix(4).map { String(format: "%02x", $0) }.joined()
        print("🕊️ [Endpoint] ACK ingest acked=\(midHex)…")
        #endif
    }
}

extension Notification.Name {
    /// Destination sealed body OR originator ACK (not bridge).
    /// userInfo kind="message": messageId, sealedBody, hybridPQ, peerKey, senderUserId?
    /// userInfo kind="ack": ackedMessageId, packed
    static let ravenEnvelopeV1EndpointIngest = Notification.Name("ravenEnvelopeV1EndpointIngest")
}
