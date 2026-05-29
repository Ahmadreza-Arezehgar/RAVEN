// TransportTypes — connectivity / routing labels shared with the iOS
// build. Kept ABI-compatible so debug log strings and CodingKeys
// match across platforms.

import Foundation

enum TransportMode: String, Codable {
    case internetOnly = "INTERNET_ONLY"
    case meshOnly     = "MESH_ONLY"
    case hybrid       = "HYBRID"
}

enum NetState: String, Codable {
    case online   = "ONLINE"
    case offline  = "OFFLINE"
    case degraded = "DEGRADED"
}

/// How a message was delivered. Set on `Message.deliveryAuthority` when
/// a row is materialized from a mesh envelope.
enum DeliveryAuthority: String, Codable {
    case server      = "server"
    case mesh        = "mesh"
    case meshBridge  = "mesh_bridge"
}

enum DeliveryState: String, Codable {
    case created              = "CREATED"
    case sentServer           = "SENT_SERVER"
    case sentMesh             = "SENT_MESH"
    case deliveredToRecipient = "DELIVERED_TO_RECIPIENT"
    case ackedByServer        = "ACKED_BY_SERVER"
    case expired              = "EXPIRED"
    case failed               = "FAILED"
}

enum MeshMessageKind: String, Codable {
    case chat = "chat"
    case post = "post"
    case ack  = "ack"
}

/// Snapshot of a peer the BLE engine is currently connected to.
struct MeshPeer: Identifiable, Equatable {
    /// Cryptographic fingerprint (XXXX-XXXX-XXXX) — stable across BLE
    /// reconnects. nil before identity is exchanged.
    let fingerprint: String?
    /// Per-session BLE peripheral identifier. Always present.
    let deviceId: String
    /// Human-readable name advertised in `CBAdvertisementDataLocalNameKey`.
    let name: String?
    /// Last time the peer wrote anything to our message characteristic.
    let lastSeenAt: Date

    var id: String { deviceId }
}
