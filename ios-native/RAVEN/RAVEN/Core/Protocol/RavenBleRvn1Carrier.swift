//
//  RavenBleRvn1Carrier.swift
//  RAVEN — Phase G start: BLE carry of raw RavenEnvelopeV1 behind the flag.
//
//  Default OFF (`FeatureFlag.ravenEnvelopeV1`). When off, callers MUST keep
//  MeshEnvelope / BLEMeshEngine JSON path unchanged.
//
//  When on, sealed content may ALSO ride BLE as packed `RVN1` bytes (same
//  object as LAN/TCP). This does NOT replace MeshEnvelope jobs.
//

import Foundation
import CryptoKit

public enum RavenBleRvn1Carrier {

    public static let magic = RavenEnvelopeV1.magic // RVN1

    /// True when flag is on AND BLE peers are nearby. Parallel with LAN — not exclusive.
    public static func shouldAttemptBle(
        wifiUp: Bool,
        peerOnLan: Bool,
        blePeersNearby: Bool
    ) -> Bool {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return false }
        _ = wifiUp
        _ = peerOnLan
        return blePeersNearby
    }

    /// O(1) magic peek — safe before JSON decode.
    public static func looksLikeRavenEnvelopeV1(_ data: Data) -> Bool {
        guard data.count >= RavenEnvelopeV1.prefixLength else { return false }
        return data.prefix(4).elementsEqual(magic) && data[4] == RavenEnvelopeV1.version
    }

    /// Pack already-sealed body into a signed RavenEnvelopeV1 (BLE or LAN).
    public static func packSealedForBle(
        sealedBody: Data,
        messageId: Data,
        routingTag: Data,
        signingKey: Curve25519.Signing.PrivateKey,
        hybridPQHint: Bool = false,
        hopLimit: UInt8 = 8,
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) -> Data {
        let env = RavenServerlessLanPath.packSealedMessage(
            sealedBody: sealedBody,
            messageId: messageId,
            routingTag: routingTag,
            signingKey: signingKey,
            hopLimit: hopLimit,
            replicationBudget: 3,
            hybridPQHint: hybridPQHint,
            nowMs: nowMs
        )
        return env.pack()
    }

    public enum InboundResult: Equatable {
        case flagOff
        case notRvn1
        case malformed
        case verified(messageId: Data, sealedBody: Data, hybridPQ: Bool)
        /// Structurally valid but signature not checked (no pubkey supplied).
        case structural(messageId: Data, sealedBody: Data, hybridPQ: Bool)
        /// Opaque ACK envelope (env_type=2) — body is ack record, not chat ciphertext.
        case ack(messageId: Data, ackedMessageId: Data, packed: Data)
        case badSignature
    }

    /// Unpack inbound BLE payload. Accepts Message and ACK. When
    /// `senderPublicKey` is provided for Message, require Ed25519 verify.
    /// Never decrypts sealed chat content.
    public static func ingest(
        _ data: Data,
        senderPublicKey: Curve25519.Signing.PublicKey? = nil
    ) -> InboundResult {
        guard FeatureFlag.isRavenEnvelopeV1Enabled else { return .flagOff }
        guard looksLikeRavenEnvelopeV1(data) else { return .notRvn1 }
        guard let env = RavenEnvelopeV1.unpack(data) else { return .malformed }
        if env.envType == RavenEnvelopeV1.EnvType.ack.rawValue {
            guard let acked = RavenEnvelopeEndpointIngest.opaqueAckedMessageId(from: env) else {
                return .malformed
            }
            if let pk = senderPublicKey {
                guard env.verify(publicKey: pk) else { return .badSignature }
            }
            return .ack(
                messageId: env.messageId,
                ackedMessageId: Data(acked),
                packed: data
            )
        }
        guard env.envType == RavenEnvelopeV1.EnvType.message.rawValue else {
            return .malformed
        }
        let hybrid = (env.flags & 1) != 0
        if let pk = senderPublicKey {
            guard env.verify(publicKey: pk) else { return .badSignature }
            return .verified(
                messageId: env.messageId,
                sealedBody: env.messageCiphertext,
                hybridPQ: hybrid
            )
        }
        return .structural(
            messageId: env.messageId,
            sealedBody: env.messageCiphertext,
            hybridPQ: hybrid
        )
    }
}

extension Notification.Name {
    /// Posted when a flagged BLE path accepts a RavenEnvelopeV1 (opaque body).
    /// userInfo: messageId (Data), sealedBody (Data), hybridPQ (Bool), verified (Bool),
    ///           packed (Data), peerDeviceId (String), envType (UInt8),
    ///           ackedMessageId (Data)? for ACK
    static let ravenEnvelopeV1BleReceived = Notification.Name("ravenEnvelopeV1BleReceived")
}
