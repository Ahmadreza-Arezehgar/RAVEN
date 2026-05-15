// `MESH_PROTOCOL.md` §C — envelope structs.
//
// CodingKeys must match the iOS-wire short names that every other port keys
// off of. The default JSONEncoder (no `.sortedKeys`) preserves declaration
// order, which is what the wire expects for outer payloads. Inner plaintext
// inside the AES-GCM seal uses `.sortedKeys` — that's handled by callers,
// not by these structs.
import Foundation

// MARK: - §C.1 SecureMeshEnvelope (the DM body — signed or encrypted)

public struct SecureMeshEnvelope: Codable, Equatable {
    public var clientMessageId: String
    public var roomId: String
    public var senderId: String
    public var senderName: String
    public var recipientId: String
    public var type: Int
    public var text: String?
    public var timestampSec: Double
    public var sprayCounter: Int
    public var hopCount: Int
    public var hopLimit: Int
    public var routePath: [String]
    public var originDeviceId: String
    public var needsForwarding: Bool
    public var ttlSeconds: Int64
    public var nonceB64: String
    public var senderPublicKeyB64: String
    public var mediaUrl: String?
    public var thumbnailUrl: String?
    public var fileName: String?
    public var mimeType: String?
    public var fileSize: Int?
    public var audioDurationSec: Int?
    public var replyToMessageId: String?
    public var replyToTextPreview: String?
    public var replyToSenderName: String?
    public var isBridged: Bool
    public var isGroup: Bool
    public var geoFence: GeoFence?

    public init(
        clientMessageId: String, roomId: String, senderId: String, senderName: String,
        recipientId: String, type: Int, text: String? = nil, timestampSec: Double,
        sprayCounter: Int = 0, hopCount: Int = 0, hopLimit: Int = 0,
        routePath: [String] = [], originDeviceId: String, needsForwarding: Bool = false,
        ttlSeconds: Int64 = 0, nonceB64: String, senderPublicKeyB64: String,
        mediaUrl: String? = nil, thumbnailUrl: String? = nil, fileName: String? = nil,
        mimeType: String? = nil, fileSize: Int? = nil, audioDurationSec: Int? = nil,
        replyToMessageId: String? = nil, replyToTextPreview: String? = nil,
        replyToSenderName: String? = nil, isBridged: Bool = false, isGroup: Bool = false,
        geoFence: GeoFence? = nil
    ) {
        self.clientMessageId = clientMessageId; self.roomId = roomId
        self.senderId = senderId; self.senderName = senderName
        self.recipientId = recipientId; self.type = type; self.text = text
        self.timestampSec = timestampSec; self.sprayCounter = sprayCounter
        self.hopCount = hopCount; self.hopLimit = hopLimit; self.routePath = routePath
        self.originDeviceId = originDeviceId; self.needsForwarding = needsForwarding
        self.ttlSeconds = ttlSeconds; self.nonceB64 = nonceB64
        self.senderPublicKeyB64 = senderPublicKeyB64
        self.mediaUrl = mediaUrl; self.thumbnailUrl = thumbnailUrl
        self.fileName = fileName; self.mimeType = mimeType; self.fileSize = fileSize
        self.audioDurationSec = audioDurationSec
        self.replyToMessageId = replyToMessageId
        self.replyToTextPreview = replyToTextPreview
        self.replyToSenderName = replyToSenderName
        self.isBridged = isBridged; self.isGroup = isGroup; self.geoFence = geoFence
    }

    enum CodingKeys: String, CodingKey {
        case clientMessageId = "id"
        case roomId = "rm"
        case senderId = "sid"
        case senderName = "sn"
        case recipientId = "rid"
        case type = "t"
        case text = "txt"
        case timestampSec = "ts"
        case sprayCounter = "sc"
        case hopCount = "hc"
        case hopLimit = "hl"
        case routePath = "rp"
        case originDeviceId = "od"
        case needsForwarding = "nf"
        case ttlSeconds = "ttl"
        case nonceB64 = "n"
        case senderPublicKeyB64 = "spk"
        case mediaUrl = "mu"
        case thumbnailUrl = "tu"
        case fileName = "fn"
        case mimeType = "mt"
        case fileSize = "fs"
        case audioDurationSec = "ad"
        case replyToMessageId = "rtid"
        case replyToTextPreview = "rttp"
        case replyToSenderName = "rtsn"
        case isBridged = "ib"
        case isGroup = "ig"
        case geoFence = "gf"
    }
}

public struct GeoFence: Codable, Equatable {
    public var h3Cell: String
    public var radiusInCells: Int
    public var deliverOnlyInside: Bool

    public init(h3Cell: String, radiusInCells: Int, deliverOnlyInside: Bool) {
        self.h3Cell = h3Cell; self.radiusInCells = radiusInCells
        self.deliverOnlyInside = deliverOnlyInside
    }
}

// MARK: - §C.1 SignedMeshPayload (DM, signed, unencrypted)

public struct SignedMeshPayload: Codable, Equatable {
    public var envelope: SecureMeshEnvelope
    public var signatureB64: String
    public var signerPublicKeyB64: String
    public var originalSignatureB64: String?
    public var originalSignerPublicKeyB64: String?

    public init(envelope: SecureMeshEnvelope, signatureB64: String, signerPublicKeyB64: String,
                originalSignatureB64: String? = nil, originalSignerPublicKeyB64: String? = nil) {
        self.envelope = envelope; self.signatureB64 = signatureB64
        self.signerPublicKeyB64 = signerPublicKeyB64
        self.originalSignatureB64 = originalSignatureB64
        self.originalSignerPublicKeyB64 = originalSignerPublicKeyB64
    }

    enum CodingKeys: String, CodingKey {
        case envelope = "e"
        case signatureB64 = "s"
        case signerPublicKeyB64 = "spk"
        case originalSignatureB64 = "os"
        case originalSignerPublicKeyB64 = "ospk"
    }
}

// MARK: - §C.2 EncryptedMeshPayload (DM, encrypted)
//
// NOTE per §I.2: outer `spk` is the **X25519 agreement key** for ECDH, NOT
// the Ed25519 signer. `ssk` is the optional Ed25519 signer pubkey for the
// embedded signature.

public struct EncryptedMeshPayload: Codable, Equatable {
    public var combinedCiphertextB64: String
    public var nonceB64: String
    public var agreementPublicKeyB64: String
    public var version: Int
    public var signatureB64: String?
    public var signerPublicKeyB64: String?

    public init(combinedCiphertextB64: String, nonceB64: String, agreementPublicKeyB64: String,
                version: Int = 1, signatureB64: String? = nil, signerPublicKeyB64: String? = nil) {
        self.combinedCiphertextB64 = combinedCiphertextB64; self.nonceB64 = nonceB64
        self.agreementPublicKeyB64 = agreementPublicKeyB64; self.version = version
        self.signatureB64 = signatureB64; self.signerPublicKeyB64 = signerPublicKeyB64
    }

    enum CodingKeys: String, CodingKey {
        case combinedCiphertextB64 = "c"
        case nonceB64 = "n"
        case agreementPublicKeyB64 = "spk"
        case version = "v"
        case signatureB64 = "s"
        case signerPublicKeyB64 = "ssk"
    }
}

// MARK: - §C.3 MeshPostEnvelope

public struct MeshPostEnvelope: Codable, Equatable {
    public var kind: String
    public var postId: String
    public var authorId: String
    public var authorUsername: String
    public var authorAvatar: String?
    public var createdAtSec: Double
    public var scope: String
    public var text: String
    public var ttlHops: Int
    public var ttlSeconds: Int64
    public var hopCount: Int
    public var routePath: [String]
    public var originDeviceId: String
    public var initialSend: String
    public var signatureB64: String?
    public var signerPublicKeyB64: String?
    public var showOnRavenShot: Bool?
    public var lat: Double?
    public var lng: Double?

    public init(kind: String = "mesh_post_v1", postId: String, authorId: String,
                authorUsername: String, authorAvatar: String? = nil, createdAtSec: Double,
                scope: String, text: String, ttlHops: Int = 0, ttlSeconds: Int64 = 0,
                hopCount: Int = 0, routePath: [String] = [], originDeviceId: String = "",
                initialSend: String = "mesh", signatureB64: String? = nil,
                signerPublicKeyB64: String? = nil, showOnRavenShot: Bool? = nil,
                lat: Double? = nil, lng: Double? = nil) {
        self.kind = kind; self.postId = postId; self.authorId = authorId
        self.authorUsername = authorUsername; self.authorAvatar = authorAvatar
        self.createdAtSec = createdAtSec; self.scope = scope; self.text = text
        self.ttlHops = ttlHops; self.ttlSeconds = ttlSeconds; self.hopCount = hopCount
        self.routePath = routePath; self.originDeviceId = originDeviceId
        self.initialSend = initialSend; self.signatureB64 = signatureB64
        self.signerPublicKeyB64 = signerPublicKeyB64; self.showOnRavenShot = showOnRavenShot
        self.lat = lat; self.lng = lng
    }

    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case postId = "pid"
        case authorId = "aid"
        case authorUsername = "aun"
        case authorAvatar = "aav"
        case createdAtSec = "ca"
        case scope = "sc"
        case text = "txt"
        case ttlHops = "th"
        case ttlSeconds = "ts"
        case hopCount = "hc"
        case routePath = "rp"
        case originDeviceId = "od"
        case initialSend = "is"
        case signatureB64 = "sig"
        case signerPublicKeyB64 = "spk"
        case showOnRavenShot = "rs"
        case lat
        case lng
    }
}

// MARK: - §C.4 MeshACKEnvelope (long camelCase, unlike DM)

public struct MeshACKEnvelope: Codable, Equatable {
    public var originalMessageId: String
    public var senderId: String
    public var recipientId: String
    public var status: String // "delivered" | "read"
    public var timestampSec: Double
    public var pathUsed: String?
    public var hopCount: Int
    public var hopLimit: Int
    public var routePath: [String]
    public var originDeviceId: String
    public var isAck: Bool
    public var signatureB64: String
    public var signerPublicKeyB64: String

    public init(originalMessageId: String, senderId: String, recipientId: String,
                status: String, timestampSec: Double, pathUsed: String? = nil,
                hopCount: Int = 0, hopLimit: Int = 0, routePath: [String] = [],
                originDeviceId: String = "", isAck: Bool = true,
                signatureB64: String = "", signerPublicKeyB64: String = "") {
        self.originalMessageId = originalMessageId; self.senderId = senderId
        self.recipientId = recipientId; self.status = status
        self.timestampSec = timestampSec; self.pathUsed = pathUsed
        self.hopCount = hopCount; self.hopLimit = hopLimit; self.routePath = routePath
        self.originDeviceId = originDeviceId; self.isAck = isAck
        self.signatureB64 = signatureB64; self.signerPublicKeyB64 = signerPublicKeyB64
    }

    enum CodingKeys: String, CodingKey {
        case originalMessageId
        case senderId
        case recipientId
        case status
        case timestampSec = "timestamp"
        case pathUsed
        case hopCount
        case hopLimit
        case routePath
        case originDeviceId
        case isAck = "isACK"
        case signatureB64 = "signature"
        case signerPublicKeyB64 = "signerPublicKey"
    }
}

// MARK: - §C.5 StopCommand

public struct StopCommand: Codable, Equatable {
    public var type: String
    public var messageId: String
    public var timestampSec: Double
    public var signatureB64: String
    public var signerPublicKeyB64: String

    public init(messageId: String, timestampSec: Double,
                signatureB64: String = "", signerPublicKeyB64: String = "") {
        self.type = "STOP"
        self.messageId = messageId; self.timestampSec = timestampSec
        self.signatureB64 = signatureB64; self.signerPublicKeyB64 = signerPublicKeyB64
    }

    enum CodingKeys: String, CodingKey {
        case type
        case messageId
        case timestampSec = "timestamp"
        case signatureB64 = "signature"
        case signerPublicKeyB64 = "signerPublicKey"
    }
}

// MARK: - §C.6 MeshMessageFrame (generic feature frame; payload signed via JSON-canonical)

public struct MeshMessageFrame: Codable, Equatable {
    public var messageKind: String
    public var payloadJSON: String  // raw JSON of `p` field; kept as String to avoid decode loss
    public var senderId: String
    public var messageId: String
    public var hopCount: Int
    public var hopLimit: Int
    public var sprayCounter: Int
    public var timestampMs: Int64
    public var routePath: [String]
    public var ttlSeconds: Int64
    public var signatureB64: String
    public var signerPublicKeyB64: String
}
