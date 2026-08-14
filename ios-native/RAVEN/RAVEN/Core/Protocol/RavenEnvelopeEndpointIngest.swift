//
//  RavenEnvelopeEndpointIngest.swift
//  RAVEN — flagged destination handoff: BLE/LAN RVN1 → chat / PairInit / endpoint.
//
//  BridgeSubsystem never decrypts. FeatureFlag.ravenEnvelopeV1 OFF → no-op.
//

import Foundation

/// Endpoint-side disposition for an inbound RavenEnvelopeV1 (not Bridge forward).
public enum RavenEnvelopeEndpointIngest {

    public enum Disposition: Equatable {
        case flagOff
        case dropMalformed
        case dropNotMessage
        /// ACKs are endpoint ciphertext. Structural parsing alone can never
        /// authorize a delivery transition.
        case dropUnverifiedAck
        case deliverSealedBody(messageId: Data, sealedBody: Data, hybridPQ: Bool)
        case deliverPairInit(wire: Data)
        case deliverPairResponse(wire: Data)
        case deliverEndpointAck(packed: Data)
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
            switch RavenPairInitLanOob.classifyMessageCiphertext(env.messageCiphertext) {
            case .pairInit(let wire):
                return .deliverPairInit(wire: wire)
            case .pairResponse(let wire):
                return .deliverPairResponse(wire: wire)
            case .notPairInitOob:
                let hybrid = (env.flags & 1) != 0
                return .deliverSealedBody(
                    messageId: env.messageId,
                    sealedBody: env.messageCiphertext,
                    hybridPQ: hybrid
                )
            }
        case RavenEnvelopeV1.EnvType.ack.rawValue:
            if ATSAMEndpointTransactionV1.productionEnabled {
                return .deliverEndpointAck(packed: packed)
            }
            #if DEBUG
            print("TRACE_ACK_DROPPED status=WAITING_FOR_ENDPOINT_ACTOR endpointProduction=\(ATSAMEndpointTransactionV1.productionEnabled)")
            #endif
            return .dropUnverifiedAck
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
            return bridgeEnabled ? .ackRelay : .drop
        case RavenEnvelopeV1.EnvType.message.rawValue:
            if localIsDestination { return .deliverToEndpoint }
            if bridgeEnabled { return .bridgeForward }
            return .deliverToEndpoint
        default:
            return .drop
        }
    }

    /// Post sealed body for chat sealer / app ingest. Never decrypts here.
    @MainActor
    public static func publishSealedBody(
        messageId: Data,
        sealedBody: Data,
        hybridPQ: Bool,
        peerKey: String,
        senderUserId: String? = nil,
        packed: Data? = nil
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
        if let packed {
            info["packed"] = packed
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

    /// PairInit / PairResponse / sealed ACK dispatch from a packed RVN1 frame.
    @MainActor
    public static func publishPacked(
        packed: Data,
        peerKey: String
    ) {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return }
        switch classify(packed: packed, flagOn: true) {
        case .deliverPairInit(let wire):
            NotificationCenter.default.post(
                name: .ravenPairInitReceived,
                object: nil,
                userInfo: ["wire": wire, "peerKey": peerKey, "packed": packed]
            )
            #if DEBUG
            print("🕊️ [Endpoint] PairInit OOB bytes=\(wire.count) pairInit=\(ATSAMPairInitV1.productionEnabled)")
            #endif
        case .deliverPairResponse(let wire):
            NotificationCenter.default.post(
                name: .ravenPairResponseReceived,
                object: nil,
                userInfo: ["wire": wire, "peerKey": peerKey, "packed": packed]
            )
            #if DEBUG
            print("🕊️ [Endpoint] PairResponse OOB bytes=\(wire.count)")
            #endif
        case .deliverSealedBody(let messageId, let sealedBody, let hybridPQ):
            publishSealedBody(
                messageId: messageId,
                sealedBody: sealedBody,
                hybridPQ: hybridPQ,
                peerKey: peerKey,
                packed: packed
            )
        case .deliverEndpointAck(let ackPacked):
            NotificationCenter.default.post(
                name: .ravenEndpointAckReceived,
                object: nil,
                userInfo: ["packed": ackPacked, "peerKey": peerKey]
            )
        case .dropUnverifiedAck:
            break
        default:
            break
        }
    }
}

extension Notification.Name {
    /// Destination sealed body (not bridge).
    /// userInfo kind="message": messageId, sealedBody, hybridPQ, peerKey, senderUserId?
    static let ravenEnvelopeV1EndpointIngest = Notification.Name("ravenEnvelopeV1EndpointIngest")
    /// PairInit wire (RVPI1) for friend-request UI.
    static let ravenPairInitReceived = Notification.Name("ravenPairInitReceived")
    static let ravenPairResponseReceived = Notification.Name("ravenPairResponseReceived")
    static let ravenEndpointAckReceived = Notification.Name("ravenEndpointAckReceived")
}
