//
//  MeshError.swift
//  RAVEN
//
//  Bug #7 fix: Proper error handling for mesh networking operations
//

import Foundation

/// Mesh networking error types with user-friendly descriptions
enum MeshError: LocalizedError {
    case saveFailed
    case broadcastFailed
    case connectionLost
    case expired
    case duplicateMessage
    case peerNotFound
    case bluetoothUnavailable
    
    var errorDescription: String? {
        switch self {
        case .saveFailed: return "Failed to save message"
        case .broadcastFailed: return "Failed to send via mesh"
        case .connectionLost: return "Connection lost"
        case .expired: return "Message expired"
        case .duplicateMessage: return "Duplicate message detected"
        case .peerNotFound: return "Peer not found"
        case .bluetoothUnavailable: return "Bluetooth is not available"
        }
    }
}

// MARK: - Mesh Error Notification

extension Notification.Name {
    /// Posted when a mesh network error occurs
    /// UserInfo contains: "error" (MeshError), optionally "messageId" (String)
    static let meshError = Notification.Name("meshError")

    /// Posted when a v2 binary envelope arrives over BLE. Phase B only —
    /// chat ingest / ack / STOP handling lands in Phase C.
    /// UserInfo: `["envelope": RUMProtocolV2.Envelope, "peerDeviceId": String]`
    static let ravenMeshV2EnvelopeReceived = Notification.Name("RavenMeshV2EnvelopeReceived")
}

// MARK: - Convenience Poster

extension MeshError {
    /// Post this error to NotificationCenter for UI handling
    func post(messageId: String? = nil) {
        var userInfo: [String: Any] = ["error": self]
        if let messageId = messageId {
            userInfo["messageId"] = messageId
        }
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .meshError,
                object: nil,
                userInfo: userInfo
            )
        }
    }
}
