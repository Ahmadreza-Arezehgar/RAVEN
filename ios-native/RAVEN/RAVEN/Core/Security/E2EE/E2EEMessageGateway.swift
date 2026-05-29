//
//  E2EEMessageGateway.swift
//  RAVEN
//
//  String-in / string-out adapter so the rest of the app can opt into
//  Double-Ratchet encryption without touching CryptoKit types.
//
//  Why this layer exists separately:
//   • E2EEService is the cryptographic core — it speaks `Data` and
//     `E2EEWirePacket`. That's correct for crypto but heavy for the
//     message-store hot path which mostly deals in strings.
//   • This gateway encodes/decodes the wire packet to a single
//     base64 string so the existing `ChatMessage.text` field can
//     carry it across server REST + mesh BLE without schema changes.
//
//  Integration recipe (sender):
//      let cipher = try await E2EEMessageGateway.shared.wrapOutgoing(
//          plaintext: message.text,
//          to: PeerAddress(userId: peerId, deviceId: peerDeviceId),
//          messageId: message.id
//      )
//      // …then send `cipher` via existing transport, marking the
//      // payload as `e2ee_v1`.
//
//  Integration recipe (receiver):
//      if message.payloadKind == "e2ee_v1" {
//          message.text = try await E2EEMessageGateway.shared.unwrapIncoming(
//              wireBase64: message.text,
//              from: PeerAddress(userId: senderId, deviceId: senderDeviceId),
//              messageId: message.id
//          )
//      }
//
//  Feature flag: callers should gate on `E2EEMessageGateway.isEnabled`
//  before invoking — turns the whole subsystem off for an easy
//  rollback during the canary phase.
//

import Foundation

actor E2EEMessageGateway {
    static let shared = E2EEMessageGateway()

    /// UserDefaults key for the master kill switch. Default: off.
    private static let featureFlagKey = "raven.e2ee.enabled"

    /// True once the gateway is ready and the feature flag is on.
    /// Other layers should treat this as the single source of truth
    /// for "is E2EE on for this device right now?".
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: featureFlagKey)
    }

    /// Flip the feature flag. Called from a debug menu in DEBUG and
    /// from server-driven config in release.
    nonisolated static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: featureFlagKey)
    }

    // MARK: - Wrap

    /// Encrypt outgoing plaintext into a base64-encoded wire packet.
    ///
    /// `messageId` is bound to the AEAD tag as Associated Data so a
    /// MITM cannot substitute a different message-id while the
    /// ciphertext stays valid.
    func wrapOutgoing(
        plaintext: String,
        to peer: PeerAddress,
        messageId: String
    ) async throws -> String {
        let plaintextData = Data(plaintext.utf8)
        let ad = Data(messageId.utf8)
        let packet = try await E2EEService.shared.encrypt(
            toPeer: peer,
            plaintext: plaintextData,
            associatedData: ad
        )
        let wireData = try JSONEncoder().encode(packet)
        return wireData.base64EncodedString()
    }

    // MARK: - Unwrap

    /// Decrypt an incoming base64 wire packet back to plaintext.
    /// Throws on:
    ///  • bad base64
    ///  • bad JSON
    ///  • bad AEAD tag (tamper / wrong key / replay outside skip window)
    ///  • missing session (peer never X3DH'd us — caller should
    ///    request a fresh session establishment)
    func unwrapIncoming(
        wireBase64: String,
        from peer: PeerAddress,
        messageId: String
    ) async throws -> String {
        guard let wireData = Data(base64Encoded: wireBase64) else {
            throw RatchetError.invalidHeader
        }
        let packet = try JSONDecoder().decode(E2EEWirePacket.self, from: wireData)
        let ad = Data(messageId.utf8)
        let plaintext = try await E2EEService.shared.decrypt(
            fromPeer: peer,
            wirePacket: packet,
            associatedData: ad
        )
        guard let str = String(data: plaintext, encoding: .utf8) else {
            throw RatchetError.decryptionFailed
        }
        return str
    }

    // MARK: - Convenience: opaque-blob mode

    /// Same as `wrapOutgoing` but for arbitrary `Data` (e.g. a
    /// JSON-encoded media metadata blob, not just chat text).
    func wrapOutgoingData(
        plaintext: Data,
        to peer: PeerAddress,
        messageId: String
    ) async throws -> Data {
        let packet = try await E2EEService.shared.encrypt(
            toPeer: peer,
            plaintext: plaintext,
            associatedData: Data(messageId.utf8)
        )
        return try JSONEncoder().encode(packet)
    }

    func unwrapIncomingData(
        wireData: Data,
        from peer: PeerAddress,
        messageId: String
    ) async throws -> Data {
        let packet = try JSONDecoder().decode(E2EEWirePacket.self, from: wireData)
        return try await E2EEService.shared.decrypt(
            fromPeer: peer,
            wirePacket: packet,
            associatedData: Data(messageId.utf8)
        )
    }
}
