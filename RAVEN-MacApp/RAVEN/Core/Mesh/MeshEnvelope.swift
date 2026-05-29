// MeshEnvelope — wire-format-compatible mesh payload.
//
// CodingKeys are deliberately identical to
// `ios-native/RAVEN/RAVEN/Core/Mesh/MeshEnvelope.swift` so a Mac App
// Store device can decode an envelope that was advertised by an iPhone
// running the production iOS build (and vice versa). The high-level
// fields are a strict subset:
//   • ChatMessage conversion is omitted (we don't have the iOS CDM here)
//   • spray-and-wait counters are tracked but the routing logic isn't
//     re-implemented; the Mac engine acts as a leaf node — sends to /
//     receives from peers but doesn't relay yet.

import Foundation

struct MeshEnvelope: Codable, Identifiable, Equatable {
    var id: String { clientMessageId }

    // Core identifiers
    let clientMessageId: String      // UUID — never changes across hops
    let roomId: String
    let senderId: String
    let senderName: String
    let recipientId: String

    // Content
    let type: Int                    // MessageType raw — 0 text, 1 image, 2 file, 3 voice, …
    var text: String?
    let timestamp: TimeInterval

    // DTN controls
    var sprayCounter: Int
    var hopCount: Int
    var hopLimit: Int
    var routePath: [String]
    let originDeviceId: String
    var needsForwarding: Bool
    var ttlSeconds: Int = 24 * 60 * 60

    // Optional media
    var mediaUrl: String?
    var thumbnailUrl: String?
    var fileName: String?
    var mimeType: String?
    var fileSize: Int?
    var audioDuration: Int?

    // Reply context
    var replyToMessageId: String?
    var replyToTextPreview: String?
    var replyToSenderName: String?

    // Bridge flag
    var isBridged: Bool? = false

    // Relay signature chain (preserved through hops)
    var originalSignature: String?
    var originalSignerPublicKey: String?

    // Group flag
    var isGroup: Bool? = false
    var groupKeyVersion: Int? = nil

    // Geo-fence pass-through. Mac doesn't enforce delivery boundaries
    // (per-device location is out of scope for the desktop client), but
    // we still decode + re-encode the field so a Mac that ever
    // re-emits an envelope to the mesh preserves the original
    // sender's geo policy. Wire format mirrors iOS's `GeoFence`.
    var geoFence: MeshGeoFence?

    enum CodingKeys: String, CodingKey {
        case clientMessageId = "id"
        case roomId = "rm"
        case senderId = "sid"
        case senderName = "sn"
        case recipientId = "rid"
        case type = "t"
        case text = "txt"
        case timestamp = "ts"
        case sprayCounter = "sc"
        case hopCount = "hc"
        case hopLimit = "hl"
        case routePath = "rp"
        case originDeviceId = "od"
        case needsForwarding = "nf"
        case ttlSeconds = "ttl"
        case mediaUrl = "mu"
        case thumbnailUrl = "tu"
        case fileName = "fn"
        case mimeType = "mt"
        case fileSize = "fs"
        case audioDuration = "ad"
        case replyToMessageId = "rtid"
        case replyToTextPreview = "rttp"
        case replyToSenderName = "rtsn"
        case isBridged = "ib"
        case isGroup = "ig"
        case groupKeyVersion = "gkv"
        case originalSignature = "os"
        case originalSignerPublicKey = "ospk"
        case geoFence = "gf"
    }
}

/// Minimal mirror of iOS's `GeoFence` so Mac can round-trip the field
/// without dragging in H3 / location enforcement. Field names + coding
/// match the iOS struct byte-for-byte — see
/// `ios-native/RAVEN/RAVEN/Core/Mesh/GeoFence.swift`.
struct MeshGeoFence: Codable, Equatable {
    let h3Cell: UInt64
    let radiusInCells: UInt8
    let deliverOnlyInside: Bool
}

extension MeshEnvelope {
    /// True if creation timestamp + TTL has passed.
    var isExpired: Bool {
        let created = Date(timeIntervalSince1970: timestamp)
        return Date() > created.addingTimeInterval(TimeInterval(ttlSeconds))
    }

    /// Should this envelope still be processed?
    var isValid: Bool {
        hopCount < hopLimit && sprayCounter > 0 && !isExpired
    }

    func hasPassedThrough(deviceId: String) -> Bool {
        routePath.contains(deviceId)
    }

    /// Encoded envelope size — used for chunking decisions.
    var estimatedSize: Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self).count) ?? 0
    }

    // MARK: - Convenience builders

    /// Build a fresh outgoing 1:1 text envelope for the local sender.
    static func makeTextDM(
        senderId: String,
        senderName: String,
        recipientId: String,
        text: String,
        replyToMessageId: String? = nil,
        replyToTextPreview: String? = nil,
        replyToSenderName: String? = nil
    ) -> MeshEnvelope {
        let originDeviceId = DeviceIdentityService.shared.fingerprint
            ?? UUID().uuidString
        return MeshEnvelope(
            clientMessageId: UUID().uuidString,
            roomId: recipientId,         // 1:1 → roomId == peer id
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            type: 0,                     // text
            text: text,
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: 5,
            hopCount: 0,
            hopLimit: 8,
            routePath: [],
            originDeviceId: originDeviceId,
            needsForwarding: true,
            replyToMessageId: replyToMessageId,
            replyToTextPreview: replyToTextPreview,
            replyToSenderName: replyToSenderName,
            isBridged: false,
            isGroup: false
        )
    }
}

// MARK: - Signing payload

extension MeshEnvelope {
    /// Canonical bytes signed by the sender. Drops the (mutable) hop /
    /// spray / routePath / signature fields so signatures survive relay.
    func signingData() -> Data {
        struct Canonical: Codable {
            let id: String
            let sid: String
            let rid: String
            let t: Int
            let txt: String?
            let ts: TimeInterval
            let od: String
            let rm: String
        }
        let c = Canonical(
            id: clientMessageId, sid: senderId, rid: recipientId,
            t: type, txt: text, ts: timestamp, od: originDeviceId, rm: roomId
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(c)) ?? Data()
    }
}
