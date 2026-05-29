//
//  MeshEnvelope.swift
//  RAVEN
//
//  DTN Mesh Implementation - BLE Payload Envelope
//

import Foundation

/// Compact envelope for BLE mesh transmission
/// Optimized for minimum payload size while containing all DTN routing info
struct MeshEnvelope: Codable, Identifiable {
    var id: String { clientMessageId }

    // MARK: - Protocol Version
    //
    // 🔴 Bug fix (2026-05-15): bridge interop between v1.6 and v1.7
    // clients was silent — both decoders accepted each other's
    // envelopes only because every Phase-4 field was Optional. The
    // moment a v1.7 build adds a *required* field, every v1.6 sender
    // would fail to decode and the message would be dropped on the
    // floor. Carry an explicit wire version so the receiver can
    // gracefully strip fields the sender doesn't understand.
    //
    // - 16 = v1.6 baseline (text + media + geo + group key)
    // - 17 = v1.7 (adds ATSAM signaling, gateway score, adaptive spray)
    //
    // Decoders default to 16 when the field is missing (back-compat
    // with v1.6 senders), and senders SHOULD set it explicitly so
    // future negotiation logic can route accordingly.
    var protocolVersion: Int = 17

    // MARK: - Core Identifiers

    let clientMessageId: String      // UUID - never changes
    let roomId: String
    let senderId: String
    let senderName: String
    let recipientId: String

    // MARK: - Hashed Identity Tokens (round 26 — MESH-CRIT-2)
    //
    // 24-character lowercase-hex HMAC truncations of the real
    // `senderId` / `recipientId` keyed by a public domain-separation
    // salt. See `MeshIdentityToken` for the math. Both fields are
    // optional for v1.6 cross-compat: a v1.6 receiver decodes the
    // envelope, ignores these fields, and uses the raw IDs as before.
    //
    // A v1.7 sender ALWAYS populates these fields. When the peer is
    // confirmed `.modernATSAM` (we have a Noise session) the sender
    // ALSO nulls the raw `senderId` / `recipientId` on the wire —
    // a rogue mesh node sees only the opaque hashes. The v1.7
    // receiver then uses `MeshIdentityResolver` to recover the real
    // IDs from a locally-built `hash → userId` table.
    //
    // Until the v1.6 sunset flag-day flips, raw IDs are still emitted
    // alongside the hashes for non-modern peers, so deployment is
    // strictly additive and back-compatible.
    var senderIdHash: String? = nil
    var recipientIdHash: String? = nil
    
    // MARK: - Content
    
    let type: Int                    // MessageType raw value
    var text: String?                // Mutable so the per-group encryption layer can swap plaintext → ciphertext before broadcast.
    let timestamp: TimeInterval      // Unix timestamp
    
    // MARK: - DTN Controls
    
    var sprayCounter: Int            // Remaining copies to spray (starts at 5)
    var hopCount: Int                // Current hop number (starts at 0)
    var hopLimit: Int                // Max hops allowed (default 10)
    var routePath: [String]          // Device IDs that handled this message
    let originDeviceId: String       // Device that created the message
    var needsForwarding: Bool        // Should this be relayed?
    var ttlSeconds: Int = PremiumLimits.meshTTLSeconds
    
    // MARK: - Optional Media
    //
    // 🔴 ROUND 26 — hacker-audit Mesh F1 CRITICAL.
    // These plaintext fields used to ride EVERY mesh broadcast
    // alongside the sealed `text`. A passive BLE peer would JSON-
    // decode the SignedMeshPayload, read `mu`/`tu`/`fn`/`mt`/`fs`,
    // and curl the attachment from Cloud Storage with no auth
    // (the eternal-public-URL bug was the matching server-side
    // gap — both fixed in round 26).
    //
    // Senders now bundle these six fields into a single JSON
    // blob, seal it with `MessageContentSealer.seal` (1:1) or
    // `GroupKeyService.encrypt` (group), and emit `mediaSealed`
    // on the wire. The legacy plaintext fields are kept nullable
    // for inbound back-compat (older senders may still set them)
    // but ALL outbound paths in round 26+ null them out.

    var mediaUrl: String?
    var thumbnailUrl: String?
    var fileName: String?
    var mimeType: String?
    var fileSize: Int?
    var audioDuration: Int?

    /// Round 26 — when non-nil, holds the sealed envelope wrapping
    /// the attachment metadata JSON. The receiver unseals and
    /// populates the legacy fields above for the chat surface to
    /// render. When nil, the receiver falls back to the legacy
    /// plaintext fields. Defaults to nil so existing memberwise-
    /// init call-sites (MessageRouter, ChatMessage.toMeshEnvelope,
    /// etc.) compile without change — the sealer hooks in at the
    /// BLE chokepoints and populates this field in place.
    var mediaSealed: String? = nil
    
    // MARK: - Reply Context
    
    var replyToMessageId: String?
    var replyToTextPreview: String?
    var replyToSenderName: String?
    
    // MARK: - Bridge Flag
    
    var isBridged: Bool? = false  // True when relayed via server→BLE bridge
    
    // MARK: - Security: Relay Signature Chain
    
    var originalSignature: String?         // Original sender's Ed25519 signature (preserved through relay)
    var originalSignerPublicKey: String?   // Original sender's public key (preserved through relay)
    
    // MARK: - Group Flag (Bug 2 fix)
    
    var isGroup: Bool? = false   // True when message targets a group (recipientId = groupId)

    // MARK: - Group Key Version (per-group AES-GCM encryption)
    /// When set, the `text` field has been AES-GCM-encrypted with the group's
    /// symmetric key (version `groupKeyVersion`). Receivers look up the key
    /// via `GroupKeyService` and decrypt before display. Outsiders who learn
    /// the groupId cannot decrypt without the key.
    var groupKeyVersion: Int? = nil
    
    // MARK: - Geo Fence (Feature 3)

    var geoFence: GeoFence?  // Optional location restriction for delivery

    // MARK: - Payload-Type Discriminator
    //
    // 🟦 ROUND 46 (2026-05-17) — group lifecycle propagation over mesh.
    //
    // The original `type: Int` field is a MessageType for normal chat
    // payloads. For non-chat events (group create / member add / etc.)
    // we need a SEPARATE discriminator so the receiver doesn't try to
    // render the JSON payload as a chat bubble.
    //
    // Convention:
    //   • `nil`              — normal chat message; existing behaviour.
    //   • "group_create"     — `text` carries JSON-encoded
    //                          `GroupSyncPayload` with full group
    //                          metadata. Receiver materializes the
    //                          group locally via `GroupRepository`.
    //   • Future kinds:       "group_update", "member_add",
    //                          "member_remove", etc. Receivers that
    //                          don't recognise the kind ignore the
    //                          envelope (NO chat rendering).
    //
    // Wire key is the short `"pk"` for BLE efficiency. v1.6 / v1.7
    // receivers that decode an envelope without this field default to
    // `nil` (normal chat) — fully backward compatible. v1.6 receivers
    // that decode an envelope WITH this field set still see only an
    // unknown JSON `text` body and skip rendering (we use a type that
    // upstream renderers treat as non-displayable; see `MessageType
    // .groupSync` mapping in this file).
    var payloadKind: String? = nil

    // MARK: - Encoding Keys (Short for BLE efficiency)

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "pv"
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
        case mediaSealed = "msl"   // round 26 — sealed media metadata blob
        case replyToMessageId = "rtid"
        case replyToTextPreview = "rttp"
        case replyToSenderName = "rtsn"
        case isBridged = "ib"
        case isGroup = "ig"
        case groupKeyVersion = "gkv"
        case geoFence = "gf"
        case originalSignature = "os"
        case originalSignerPublicKey = "ospk"
        // Round 26 — MESH-CRIT-2 hashed identity tokens.
        case senderIdHash = "sih"
        case recipientIdHash = "rih"
        // Round 46 — group-lifecycle discriminator (group_create, etc.)
        case payloadKind = "pk"
    }
}

// MARK: - Codable conformance with v1.6 back-compat
//
// 🔴 Bug fix (2026-05-15): Codable's synthesized decoder would
// require `protocolVersion` (pv) to be present in every BLE
// envelope it ingests — that would break interop with v1.6
// senders, which never produced the field. The custom decoder
// below defaults a missing `pv` to 16 so v1.6 traffic still decodes,
// while v1.7 senders carry it explicitly.
//
// Decoder lives in an extension so Swift still synthesizes the
// memberwise initializer for the struct body — `MessageRouter` and
// `BLEMeshEngine` rely on the memberwise init to build outbound
// envelopes.

extension MeshEnvelope {
    // 🔴 ROUND 31 (2026-05-19) — wire-input bounds.
    //
    // PREVIOUSLY: every numeric / string / array field on the wire
    // was decoded with no upper bound. A rogue BLE peer could send:
    //   • `hopCount = -1`             → bypassed the TTL gate
    //   • `hopLimit = Int.max`        → forwarded forever
    //   • `ttlSeconds = -1`           → envelope "always expired",
    //                                   triggering recovery re-broadcasts
    //   • `routePath = [<1MB strings × 100k>]` → 100 GB allocation
    //                                   while decoding one envelope
    //   • `senderName = <100MB string>` → OOM kill before validation
    //   • `fileSize = Int.max`        → integer-overflow buffer alloc
    // The decoder ALWAYS succeeded; downstream code had to guess.
    //
    // FIX: every wire field now has a hard cap enforced at decode
    // time, BEFORE anything else touches the envelope. The caps are
    // generous enough that legitimate use is never hit, tight enough
    // that an attacker can't weaponise a single envelope into a
    // DoS or a logic-bypass primitive.
    private enum Bounds {
        static let maxStringLen     = 8 * 1024          // 8 KB per text field
        static let maxIDLen         = 256                // userIds, deviceIds, etc.
        static let maxRoutePath     = 32                 // matches RAVEN's max mesh hops
        static let maxRouteHopLen   = 128                // each hop is a deviceId-like string
        static let maxHopLimit      = 32
        static let maxSprayCounter  = 1024
        static let maxFileSizeBytes = 2 * 1024 * 1024 * 1024  // 2 GB
        static let maxAudioSecs     = 30 * 60                 // 30 min voice cap
        static let maxTTLSecs       = 14 * 24 * 60 * 60       // 14 days
        static let timestampWindow  = 30 * 24 * 60 * 60       // ±30 days from now
    }

    private static func check(_ cond: Bool, _ what: @autoclosure () -> String) throws {
        guard cond else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "MeshEnvelope wire bound violated: " + what())
            )
        }
    }

    private static func capString(_ s: String?, max: Int) throws -> String? {
        guard let s = s else { return nil }
        try check(s.utf8.count <= max, "string too long (\(s.utf8.count) > \(max))")
        return s
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = (try c.decodeIfPresent(Int.self, forKey: .protocolVersion)) ?? 16
        try Self.check(self.protocolVersion >= 0 && self.protocolVersion <= 64, "protocolVersion out of range")
        self.clientMessageId = try Self.capString(try c.decode(String.self, forKey: .clientMessageId), max: Bounds.maxIDLen)!
        self.roomId = try Self.capString(try c.decode(String.self, forKey: .roomId), max: Bounds.maxIDLen)!
        self.senderId = try Self.capString(try c.decode(String.self, forKey: .senderId), max: Bounds.maxIDLen)!
        self.senderName = try Self.capString(try c.decode(String.self, forKey: .senderName), max: Bounds.maxStringLen)!
        self.recipientId = try Self.capString(try c.decode(String.self, forKey: .recipientId), max: Bounds.maxIDLen)!
        self.type = try c.decode(Int.self, forKey: .type)
        try Self.check(self.type >= 0 && self.type <= 1024, "type out of range")
        self.text = try Self.capString(try c.decodeIfPresent(String.self, forKey: .text), max: Bounds.maxStringLen)
        self.timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        let now = Date().timeIntervalSince1970
        try Self.check(
            self.timestamp.isFinite
                && self.timestamp >= now - Double(Bounds.timestampWindow)
                && self.timestamp <= now + Double(Bounds.timestampWindow),
            "timestamp outside ±30-day window"
        )
        self.sprayCounter = try c.decode(Int.self, forKey: .sprayCounter)
        try Self.check(self.sprayCounter >= 0 && self.sprayCounter <= Bounds.maxSprayCounter, "sprayCounter out of range")
        self.hopCount = try c.decode(Int.self, forKey: .hopCount)
        try Self.check(self.hopCount >= 0 && self.hopCount <= Bounds.maxHopLimit, "hopCount out of range")
        self.hopLimit = try c.decode(Int.self, forKey: .hopLimit)
        try Self.check(self.hopLimit >= 0 && self.hopLimit <= Bounds.maxHopLimit, "hopLimit out of range")
        self.routePath = try c.decode([String].self, forKey: .routePath)
        try Self.check(self.routePath.count <= Bounds.maxRoutePath, "routePath too long (\(self.routePath.count) hops)")
        for hop in self.routePath {
            try Self.check(hop.utf8.count <= Bounds.maxRouteHopLen, "routePath hop too long")
        }
        self.originDeviceId = try Self.capString(try c.decode(String.self, forKey: .originDeviceId), max: Bounds.maxIDLen)!
        self.needsForwarding = try c.decode(Bool.self, forKey: .needsForwarding)
        self.ttlSeconds = (try c.decodeIfPresent(Int.self, forKey: .ttlSeconds)) ?? PremiumLimits.meshTTLSeconds
        try Self.check(self.ttlSeconds > 0 && self.ttlSeconds <= Bounds.maxTTLSecs, "ttlSeconds out of range")
        self.mediaUrl = try Self.capString(try c.decodeIfPresent(String.self, forKey: .mediaUrl), max: 4 * 1024)
        self.thumbnailUrl = try Self.capString(try c.decodeIfPresent(String.self, forKey: .thumbnailUrl), max: 4 * 1024)
        self.fileName = try Self.capString(try c.decodeIfPresent(String.self, forKey: .fileName), max: 512)
        self.mimeType = try Self.capString(try c.decodeIfPresent(String.self, forKey: .mimeType), max: 128)
        self.fileSize = try c.decodeIfPresent(Int.self, forKey: .fileSize)
        if let size = self.fileSize {
            try Self.check(size >= 0 && size <= Bounds.maxFileSizeBytes, "fileSize out of range (\(size))")
        }
        self.audioDuration = try c.decodeIfPresent(Int.self, forKey: .audioDuration)
        if let dur = self.audioDuration {
            try Self.check(dur >= 0 && dur <= Bounds.maxAudioSecs, "audioDuration out of range (\(dur))")
        }
        // round 26 — sealed media metadata blob, populated by
        // `MeshMediaSealer.seal` before broadcast.
        self.mediaSealed = try c.decodeIfPresent(String.self, forKey: .mediaSealed)
        self.replyToMessageId = try c.decodeIfPresent(String.self, forKey: .replyToMessageId)
        self.replyToTextPreview = try c.decodeIfPresent(String.self, forKey: .replyToTextPreview)
        self.replyToSenderName = try c.decodeIfPresent(String.self, forKey: .replyToSenderName)
        self.isBridged = try c.decodeIfPresent(Bool.self, forKey: .isBridged) ?? false
        self.isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        self.groupKeyVersion = try c.decodeIfPresent(Int.self, forKey: .groupKeyVersion)
        self.geoFence = try c.decodeIfPresent(GeoFence.self, forKey: .geoFence)
        self.originalSignature = try c.decodeIfPresent(String.self, forKey: .originalSignature)
        self.originalSignerPublicKey = try c.decodeIfPresent(String.self, forKey: .originalSignerPublicKey)
        // Round 26 — MESH-CRIT-2 hashed identity tokens. Optional so
        // v1.6 envelopes without these fields decode cleanly.
        self.senderIdHash = try c.decodeIfPresent(String.self, forKey: .senderIdHash)
        self.recipientIdHash = try c.decodeIfPresent(String.self, forKey: .recipientIdHash)
        // Round 46 — payload-kind discriminator for group lifecycle
        // events (group_create, etc.). nil = normal chat message.
        self.payloadKind = try c.decodeIfPresent(String.self, forKey: .payloadKind)
    }
}

// MARK: - Group Sync Payload (Round 46)
//
// 🟦 ROUND 46 (2026-05-17) — Group lifecycle propagation.
//
// `GroupSyncPayload` is JSON-encoded into `MeshEnvelope.text` when
// `payloadKind == "group_create"` (or related lifecycle event).
// The receiver materializes the group locally via `GroupRepository`
// so mesh-only devices can join group conversations without ever
// hitting the server. Then any messages parked in
// `PendingGroupMessageRepository` for that group_id are promoted.
//
// Schema is intentionally a closed `Codable` shape — no `extra` /
// passthrough fields — so a malicious mesh peer can't smuggle
// arbitrary state via the envelope. Members are limited to 256
// rows to bound memory; the server enforces a much smaller cap
// at create time so this only matters for malformed messages.
//
// `version` lets us evolve the schema without re-keying the
// existing `payloadKind` discriminator. Receivers reject payloads
// with a `version` higher than they understand (forward-compat
// strict mode).
struct GroupSyncPayload: Codable {
    static let currentVersion: Int = 1
    static let maxMembers: Int = 256

    /// Schema version. Always 1 for this rollout. Receivers reject
    /// payloads with `version > currentVersion`.
    let version: Int

    /// Lifecycle event type. "create" for the initial broadcast on
    /// `GroupService.createGroup`. Future: "update", "member_add",
    /// "member_remove", "name_change", "avatar_change".
    let event: String

    // MARK: - Group identity (mirrors models/Group.swift)

    let groupId: String
    let groupName: String
    let avatarUrl: String?
    let description: String?
    let createdBy: String
    let creatorUsername: String?
    /// Unix timestamp (seconds since epoch).
    let createdAt: TimeInterval
    let memberCount: Int

    let members: [Member]

    struct Member: Codable {
        let userId: String
        let username: String
        let avatarUrl: String?
        /// "admin" or "member"
        let role: String
        /// Unix timestamp (seconds since epoch)
        let joinedAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case userId      = "uid"
            case username    = "un"
            case avatarUrl   = "av"
            case role        = "rl"
            case joinedAt    = "ja"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version          = "v"
        case event            = "ev"
        case groupId          = "gid"
        case groupName        = "gn"
        case avatarUrl        = "av"
        case description      = "ds"
        case createdBy        = "cb"
        case creatorUsername  = "cu"
        case createdAt        = "ca"
        case memberCount      = "mc"
        case members          = "mb"
    }
}

extension GroupSyncPayload {
    /// Encode as compact JSON for embedding in `MeshEnvelope.text`.
    func encode() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from `MeshEnvelope.text`. Returns nil if version is
    /// newer than `currentVersion` (forward-compat strict mode) or
    /// if the bytes don't parse.
    static func decode(from text: String?) -> GroupSyncPayload? {
        guard let text = text,
              let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GroupSyncPayload.self, from: data),
              payload.version <= currentVersion,
              payload.members.count <= maxMembers
        else { return nil }
        return payload
    }
}

// MARK: - Group Key Mesh Payload (Round 74)
//
// 🟢 ROUND 74 (2026-05-24) — mesh-based group-key distribution.
//
// User-reported root cause: a BLE-only Device A receives encrypted
// group messages over mesh but cannot decrypt them because the
// group's AES-GCM symmetric key is server-only (GET /api/groups/
// {id}/key). BLE-only A has no way to fetch the key, so ciphertext
// renders as gibberish forever. The previous design comment on
// `GroupSyncPayload` (MeshEnvelope.swift:781-784) explicitly said
// the broadcast omits the key "every recipient can materialize
// without a per-pair key exchange" — but that left BLE-only
// members unable to decrypt anything.
//
// FIX: new `payloadKind == "group_key"` envelope carries the
// `version + keyB64` so a BLE-only member can ingest the key and
// decrypt subsequent group ciphertexts. Broadcast by the creator
// (immediately after group_create) and by any online member who
// just fetched a new key version from `/api/groups/{id}/key`.
//
// 🛡️ SECURITY trade-off:
//   - The key bytes are NOT additionally encrypted in this payload;
//     they ride the same mesh envelope as `group_create`, signed
//     with the broadcaster's Ed25519 key (relays can verify
//     authorship but NOT content). Mesh range is bounded by BLE
//     line-of-sight (~10–30 m), so the attacker must be physically
//     present to capture the key.
//   - The receiver enforces a membership gate: only ingest the
//     key if the local `GroupRepository` has us as a member of the
//     given groupId. A non-member who intercepts the key still
//     gets a usable group AES key, but they were already in range
//     and could have captured the ciphertext anyway — the bridge-
//     attestation comment on `bridgeMeshMessageToServer` makes the
//     same trade-off explicit.
//   - Follow-up (R75+): wrap the key with each recipient's ATSAM
//     root so non-recipients cannot read it. Tracked as a separate
//     task.
//
// SCHEMA: closed Codable, version-gated, member-list-bounded — same
// hardening posture as GroupSyncPayload.
struct GroupKeyMeshPayload: Codable {
    static let currentVersion: Int = 1

    /// Schema version. Receivers reject payloads with version >
    /// currentVersion (forward-compat strict mode).
    let version: Int

    /// Lifecycle event. "key" for the immediate post-create broadcast.
    /// Future: "rotate" for forward-secrecy rekeys.
    let event: String

    /// The group whose key this payload carries.
    let groupId: String

    /// The AES-GCM key version that `keyB64` corresponds to. Receivers
    /// store this in `GroupKeyService.byVersion[groupId][version]`.
    let keyVersion: Int

    /// 32-byte AES-256 key, base64-encoded. Receivers MUST validate
    /// length to prevent malformed-key DoS on the SymmetricKey ctor.
    let keyB64: String

    /// Userid of the broadcaster (signer of the outer mesh envelope).
    /// Receivers use this together with their local `GroupMember`
    /// list to gate ingestion (only accept keys from current members
    /// of the same group).
    let broadcastedBy: String

    /// Unix timestamp the broadcaster picked the key. Receivers may
    /// reject payloads older than ~24h to limit replay-add abuse on
    /// rotated keys.
    let issuedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case version       = "v"
        case event         = "ev"
        case groupId       = "gid"
        case keyVersion    = "kv"
        case keyB64        = "kb"
        case broadcastedBy = "bb"
        case issuedAt      = "ia"
    }
}

extension GroupKeyMeshPayload {
    func encode() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(from text: String?) -> GroupKeyMeshPayload? {
        guard let text = text,
              let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GroupKeyMeshPayload.self, from: data),
              payload.version <= currentVersion,
              !payload.groupId.isEmpty,
              payload.keyVersion >= 1,
              !payload.keyB64.isEmpty
        else { return nil }
        // Enforce the AES-256 key length. SymmetricKey(data:) accepts
        // any size, so a malicious broadcaster could ship a 1-byte
        // key and we'd later decrypt-fail silently.
        guard let raw = Data(base64Encoded: payload.keyB64), raw.count == 32 else {
            return nil
        }
        return payload
    }
}

// MARK: - Friend Request Mesh Payload (Round 50)
//
// 🟦 ROUND 50 (2026-05-17) — offline QR friend-add over mesh.
//
// User-reported bug: when two devices are both offline (or one is)
// and they scan each other's QR code, the friend request fails
// (`networkError(-1009)`) and the contact never gets added.
//
// Fix: when the scanner sends the friend request, ALSO broadcast a
// mesh envelope carrying this payload. The receiver materializes the
// scanner as a local friend (auto-accept, since QR scan is
// out-of-band mutual consent) AND stores the agreement+signing keys
// for E2EE. When connectivity returns, both sides also POST through
// `PendingFriendRequestQueue` so the server catches up with the
// friendship — but the mesh path makes the user experience instant
// even when totally offline.
//
// `payloadKind == "friend_request"` envelopes carry this payload as
// JSON in the `text` field. v1.6/v1.7-pre-round-50 receivers ignore
// the unknown payloadKind (Round-46 forward-compat path).
struct FriendRequestMeshPayload: Codable {
    static let currentVersion: Int = 1

    /// Schema version. Receivers reject payloads with version >
    /// currentVersion (forward-compat strict mode).
    let version: Int

    /// Sender identity (the scanner — the one initiating the add).
    let senderUserId: String
    let senderUsername: String
    let senderDisplayName: String?
    let senderAvatarUrl: String?

    /// Recipient userId. Mirrors the envelope's `recipientId`. Carried
    /// in the payload too so the receiver can verify they were the
    /// intended target (mesh relays could deliver the envelope to
    /// other peers along the spray path; non-targets should ignore).
    let recipientUserId: String

    /// Sender's X25519 ECDH agreement key (base64). Same value as the
    /// `agreementPubBase64` in the FriendQRPayload — the receiver
    /// caches it in PeerKeyDirectory so the very next DM seals
    /// RVNS1 from the first byte.
    let agreementPublicKeyB64: String?

    /// Sender's Ed25519 device signing key (base64). Lets the
    /// receiver pin the friend's device fingerprint in
    /// FriendDeviceRepository for trusted relay attribution.
    let signingPublicKeyB64: String?

    /// Unix timestamp the request was issued. Receivers may reject
    /// requests older than ~7 days to limit replay-add abuse.
    let issuedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case version             = "v"
        case senderUserId        = "su"
        case senderUsername      = "sh"
        case senderDisplayName   = "sn"
        case senderAvatarUrl     = "sa"
        case recipientUserId     = "ru"
        case agreementPublicKeyB64 = "ak"
        case signingPublicKeyB64   = "sk"
        case issuedAt            = "ts"
    }
}

extension FriendRequestMeshPayload {
    /// Encode as compact JSON for embedding in `MeshEnvelope.text`.
    func encode() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from `MeshEnvelope.text`. Returns nil if the version is
    /// newer than what we understand, the bytes don't parse, or the
    /// request is older than 7 days (anti-replay).
    static func decode(from text: String?) -> FriendRequestMeshPayload? {
        guard let text = text,
              let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(FriendRequestMeshPayload.self, from: data),
              payload.version <= currentVersion
        else { return nil }
        // Anti-replay window: reject requests older than 7 days.
        let age = Date().timeIntervalSince1970 - payload.issuedAt
        guard age < (7 * 24 * 60 * 60), age > -300 /* allow ~5min clock skew */
        else { return nil }
        return payload
    }
}

// MARK: - DTN Validation

extension MeshEnvelope {
    
    /// Check if message has expired based on TTL
    var isExpired: Bool {
        let created = Date(timeIntervalSince1970: timestamp)
        return Date() > created.addingTimeInterval(TimeInterval(ttlSeconds))
    }
    
    /// Check if this envelope should be processed (not expired/exhausted)
    var isValid: Bool {
        return hopCount < hopLimit && sprayCounter > 0 && !isExpired
    }
    
    /// Check if this device has already handled the message
    func hasPassedThrough(deviceId: String) -> Bool {
        return routePath.contains(deviceId)
    }
    
    /// Create a forwarded copy with updated DTN counters.
    /// NOTE: sprayCounter is NOT decremented here — it is managed by
    /// the Binary Spray & Wait logic in processValidatedEnvelope.
    func forwarded(by deviceId: String) -> MeshEnvelope {
        var copy = self
        copy.hopCount += 1
        copy.routePath.append(deviceId)
        return copy
    }
    
    /// Estimated payload size in bytes
    var estimatedSize: Int {
        guard let data = try? JSONEncoder().encode(self) else { return 0 }
        return data.count
    }
    
    // MARK: - Transport Routing
    
    /// Payload size category for transport selection (BLE vs MPC)
    enum PayloadCategory {
        case small   // < 4 KB — BLE optimal
        case medium  // 4 KB – 1 MB — MPC preferred
        case large   // > 1 MB — MPC required
    }
    
    /// Determine the best transport for this envelope based on payload size
    var payloadCategory: PayloadCategory {
        let size = estimatedSize
        // 4 KB threshold — matches MPCTransportService.bulkThreshold
        if size < 4096 { return .small }
        if size < 1_048_576 { return .medium }
        return .large
    }
}

// MARK: - ChatMessage Conversion

extension ChatMessage {
    
    /// Convert ChatMessage to compact MeshEnvelope for BLE transmission.
    ///
    /// Round 14 (2026-05-16) — hacker-audit finding C16. The
    /// `replyToTextPreview` field used to ride the wire in plain
    /// text alongside the (sometimes-encrypted) `text` body. That
    /// defeats the point of encrypting `text` for a chain of
    /// replies — the previous message's content leaks through every
    /// forwarded reply.
    ///
    /// New behaviour: we always strip the preview from the outbound
    /// envelope. The receiver looks the preview up locally from
    /// their own DB using `replyToMessageId`. Senders who're
    /// replying to a message the receiver doesn't have yet (joined-
    /// later, expired, etc.) just see "Reply to a previous message"
    /// without the preview — a minor UX loss; the privacy gain
    /// closes the leak.
    ///
    /// Sender name on the reply IS kept because it's already in
    /// every mesh envelope's sender field at the protocol layer.
    func toMeshEnvelope() -> MeshEnvelope {
        return MeshEnvelope(
            clientMessageId: id,
            roomId: roomId ?? "",
            senderId: senderId,
            senderName: senderName,
            recipientId: recipientId,
            type: type.index,
            text: text,
            timestamp: timestamp.timeIntervalSince1970,
            sprayCounter: sprayCounter,
            hopCount: hopCount,
            hopLimit: hopLimit,
            routePath: routePath,
            originDeviceId: originDeviceId,
            needsForwarding: needsForwarding,
            mediaUrl: attachmentUrl,
            thumbnailUrl: thumbnailUrl,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize,
            audioDuration: audioDurationSeconds,
            replyToMessageId: replyToMessageId,
            replyToTextPreview: nil,                 // round 14 — never on the wire
            replyToSenderName: replyToSenderName
        )
    }
    
    /// Create ChatMessage from received MeshEnvelope.
    ///
    /// 🔴 ROUND 26 — hacker-audit Mesh F2 + F3 fixes.
    /// • A malicious relay can craft an inbound envelope with a
    ///   forged `replyToTextPreview` ("rttp"). The chat surface
    ///   then renders an attacker-chosen quoted preview above an
    ///   otherwise-legitimate sealed message — phishing primitive
    ///   against users who trust the on-screen quote. The fix:
    ///   ALWAYS drop the wire-side preview and force the chat
    ///   surface to look up the parent message locally by
    ///   `replyToMessageId`. Round 14 stripped on send; round 26
    ///   strips on receive too.
    /// • `senderName` is plaintext on the wire and not bound to
    ///   the AEAD tag — a relay can swap it. Force a contacts-
    ///   directory lookup by `senderId` instead of trusting the
    ///   on-wire string. If we don't have the contact cached
    ///   yet, the chat surface shows the senderId prefix until
    ///   the next contacts sync.
    static func fromMeshEnvelope(_ env: MeshEnvelope, authority: DeliveryAuthority = .mesh) -> ChatMessage {
        // Round 26 — Mesh F3: never trust the wire-side
        // senderName. The receiver's chat surface looks up the
        // friendly display name from the local contacts cache by
        // senderId.
        let safeSenderName = ""
        
        return ChatMessage(
            id: env.clientMessageId,
            serverId: nil,
            roomId: env.roomId,
            senderId: env.senderId,
            senderName: safeSenderName,
            recipientId: env.recipientId,
            text: env.text,
            timestamp: Date(timeIntervalSince1970: env.timestamp),
            type: MessageType.from(index: env.type),
            status: .delivered,
            deliveryAuthority: authority,
            createdAt: Date(timeIntervalSince1970: env.timestamp),
            deliveredAt: Date(),
            readAt: nil,
            // DTN fields
            hopCount: env.hopCount,
            routePath: env.routePath,
            sprayCounter: env.sprayCounter,
            hopLimit: env.hopLimit,
            originDeviceId: env.originDeviceId,
            needsForwarding: env.needsForwarding,
            // Media
            attachmentUrl: env.mediaUrl,
            thumbnailUrl: env.thumbnailUrl,
            fileName: env.fileName,
            mimeType: env.mimeType,
            fileSize: env.fileSize,
            audioDurationSeconds: env.audioDuration,
            syncState: .localOnly,
            localPath: nil,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: env.replyToMessageId,
            // 🔴 ROUND 26 — Mesh F2: forged-preview phishing.
            // Always nil — chat surface looks up the parent
            // message locally via `replyToMessageId`.
            replyToTextPreview: nil,
            replyToSenderName: nil,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil
        )
    }
}

// MARK: - MessageType Helpers

extension MessageType {
    var index: Int {
        switch self {
        case .text: return 0
        case .image: return 1
        case .file: return 2
        case .voice: return 3
        case .location: return 4
        case .postShare: return 5
        case .system: return 6
        case .video: return 7
        case .videoNote: return 8
        case .ephemeralPhoto: return 9
        // Polls are server-only (groups), never relayed via mesh — but the
        // exhaustiveness check still requires a case. Pin to a high index
        // that won't collide with future additions.
        case .poll: return 10
        // Contact-card shares are an online (server-routed) feature — same
        // reason as polls, kept here for exhaustiveness.
        case .contactCard: return 11
        }
    }
    
    static func from(index: Int) -> MessageType {
        switch index {
        case 0: return .text
        case 1: return .image
        case 2: return .file
        case 3: return .voice
        case 4: return .location
        case 5: return .postShare
        case 6: return .system
        case 7: return .video
        case 8: return .videoNote
        case 9: return .ephemeralPhoto
        default: return .text
        }
    }
}
