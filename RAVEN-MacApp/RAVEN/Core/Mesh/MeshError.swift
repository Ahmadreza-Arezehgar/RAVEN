// MeshError — error types for the BLE mesh layer.
//
// Mirror of `ios-native/RAVEN/RAVEN/Core/Mesh/MeshError.swift` so log
// messages and NotificationCenter posts use the same vocabulary as the
// iOS / Catalyst builds.

import Foundation

enum MeshError: LocalizedError {
    case saveFailed
    case broadcastFailed
    case connectionLost
    case expired
    case duplicateMessage
    case peerNotFound
    case bluetoothUnavailable
    case bluetoothDenied
    case identityUnavailable
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed: return "Failed to save message"
        case .broadcastFailed: return "Failed to send via mesh"
        case .connectionLost: return "Connection lost"
        case .expired: return "Message expired"
        case .duplicateMessage: return "Duplicate message detected"
        case .peerNotFound: return "Peer not found"
        case .bluetoothUnavailable: return "Bluetooth is not available"
        case .bluetoothDenied: return "Bluetooth permission denied"
        case .identityUnavailable: return "Device identity not initialized"
        case .encryptionFailed: return "Failed to encrypt mesh envelope"
        case .decryptionFailed: return "Failed to decrypt mesh envelope"
        }
    }
}

extension Notification.Name {
    /// Fired by `BLEMeshEngine` when a mesh networking error happens.
    /// userInfo: `["error": MeshError, "messageId": String?]`
    static let ravenMeshError = Notification.Name("RavenMeshError")

    /// Fired when a fully-decrypted mesh envelope arrives from a peer.
    /// userInfo: `["envelope": MeshEnvelope, "peerDeviceId": String]`
    static let ravenMeshEnvelopeReceived = Notification.Name("RavenMeshEnvelopeReceived")

    /// Fired when a v2 binary envelope arrives from a peer. Phase B
    /// only — the higher-layer ingest (chat/group routing, ack/STOP
    /// handling) lands in Phase C.
    /// userInfo: `["envelope": RUMProtocolV2.Envelope, "peerDeviceId": String]`
    static let ravenMeshV2EnvelopeReceived = Notification.Name("RavenMeshV2EnvelopeReceived")

    /// Fired when peer connectivity changes (connect / disconnect).
    /// userInfo: `["connectedPeerCount": Int, "advertising": Bool, "scanning": Bool]`
    static let ravenMeshStateChanged = Notification.Name("RavenMeshStateChanged")

    /// Fired when a signature-verified `MeshLoginApprovalEnvelope`
    /// arrives over BLE — the phone-side fallback when the desktop's
    /// `/qr-login/poll` couldn't reach the server. The QR sheet
    /// observes this notification and hands the envelope to
    /// `AuthService.completeBluetoothLogin(_:)`.
    /// userInfo: `["envelope": MeshLoginApprovalEnvelope, "peerDeviceId": String]`
    static let ravenBluetoothLoginApproved = Notification.Name("RavenBluetoothLoginApproved")

    /// **Phase 2** — fired when an end-to-end-encrypted
    /// `MeshLoginTokenEnvelope` arrives over BLE and successfully
    /// decrypts. The plaintext payload carries a real server JWT +
    /// refresh token, so the QR sheet hands it to
    /// `AuthService.completeQrLogin(...)` (NOT `completeBluetoothLogin`)
    /// — the desktop ends up with a full server-grade session.
    /// userInfo: `["sessionId": String, "payload": MeshLoginTokenPayload, "peerDeviceId": String]`
    static let ravenBluetoothLoginTokenReceived = Notification.Name("RavenBluetoothLoginTokenReceived")
}

extension MeshError {
    func post(messageId: String? = nil) {
        var info: [String: Any] = ["error": self]
        if let messageId { info["messageId"] = messageId }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ravenMeshError, object: nil, userInfo: info)
        }
    }
}
