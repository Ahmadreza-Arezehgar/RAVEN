//
//  MeshPostEnvelope.swift
//  RAVEN
//
//  Lightweight envelope for mesh post transmission
//  Separate from MeshEnvelope (messages) to keep payloads small
//

import Foundation

// MARK: - Mesh Post Envelope

/// Compact envelope for BLE mesh post transmission
/// Text-only posts for offline scenarios
struct MeshPostEnvelope: Codable, Identifiable {
    var id: String { postId }
    
    // MARK: - Payload Kind (for routing)
    
    let kind: String = "mesh_post_v1"
    
    // MARK: - Core Identifiers
    
    let postId: String              // UUID - idempotency key, never changes
    let authorId: String
    let authorUsername: String
    let authorAvatar: String?
    
    // MARK: - Content
    
    let createdAt: TimeInterval     // Unix timestamp
    let scope: String               // "local" | "friends" | "public"
    let text: String

    // MARK: - RavenShot opt-in (mesh-only social map)
    /// When set, the post is rendered as a pin on every nearby device's
    /// RavenShot map even with no internet. Carries the author's lat/lng
    /// so the receiving device can place the pin without consulting the
    /// server. The same fields exist on the regular `Post` model so the
    /// online-bridge path persists them identically.
    var showOnRavenShot: Bool = false
    var latitude: Double? = nil
    var longitude: Double? = nil
    
    // MARK: - DTN Controls
    //
    // Posts intentionally do NOT use PremiumLimits.meshHopLimit /
    // .meshTTLSeconds — those gate text messages by tier (free vs premium)
    // and keep the message hot-path light. Posts spread feed-wide and
    // benefit from broad propagation regardless of sender tier. Loop
    // protection still relies on the seenPosts dedup cache + routePath
    // check in MeshPostService.relayIfNeeded; ttlHops/ttlSeconds here are
    // just an upper bound so stale envelopes eventually decay.

    /// Practical max hop count for post relay (~unlimited in real BLE
    /// topologies; routePath de-dupes the same device).
    static let postTTLHops: Int = 64
    /// Practical max age for a mesh post envelope (1 week). Past this the
    /// envelope is considered stale and dropped.
    static let postTTLSeconds: Int = 7 * 24 * 60 * 60

    var ttlHops: Int = MeshPostEnvelope.postTTLHops
    var ttlSeconds: Int = MeshPostEnvelope.postTTLSeconds
    var hopCount: Int = 0           // Current hop number
    var routePath: [String] = []    // Device IDs that handled this post
    let originDeviceId: String      // Device that created the post
    var initialSend: String = "mesh" // DTN: "internet" or "mesh" (origin tag)
    
    // MARK: - Security (Ed25519 signature)
    var signature: String?
    var signerPublicKey: String?
    
    // MARK: - Compact Encoding Keys (for BLE efficiency)
    
    enum CodingKeys: String, CodingKey {
        case kind = "k"
        case postId = "pid"
        case authorId = "aid"
        case authorUsername = "aun"
        case authorAvatar = "aav"
        case createdAt = "ca"
        case scope = "sc"
        case text = "txt"
        case ttlHops = "th"
        case ttlSeconds = "ts"
        case hopCount = "hc"
        case routePath = "rp"
        case originDeviceId = "od"
        case initialSend = "is"
        case signature = "sig"
        case signerPublicKey = "spk"
        case showOnRavenShot = "rs"
        case latitude = "lat"
        case longitude = "lng"
    }
}

// MARK: - DTN Validation

extension MeshPostEnvelope {
    
    /// Check if this envelope should be processed (not expired/exhausted)
    var isValid: Bool {
        return hopCount < ttlHops
    }
    
    /// Check if this envelope has expired by time
    var isExpired: Bool {
        let createdDate = Date(timeIntervalSince1970: createdAt)
        let age = Date().timeIntervalSince(createdDate)
        return age > TimeInterval(ttlSeconds)
    }
    
    /// Check if this device has already handled the post
    func hasPassedThrough(deviceId: String) -> Bool {
        return routePath.contains(deviceId)
    }
    
    /// Create a forwarded copy with updated DTN counters
    func forwarded(by deviceId: String) -> MeshPostEnvelope {
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
}

// MARK: - Signature Support

extension MeshPostEnvelope {
    /// Canonical data for signing: POST|postId|authorId|authorUsername|authorAvatar|text|timestamp|scope|signerPublicKey
    func signingData() -> Data {
        let delimiter = Data("|".utf8)
        var data = Data()
        data.append("POST".data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(postId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(authorId.data(using: .utf8) ?? Data())
        data.append(delimiter)
        data.append(authorUsername.data(using: .utf8) ?? Data())
        data.append(delimiter)
        if let authorAvatar = authorAvatar {
            data.append(authorAvatar.data(using: .utf8) ?? Data())
        }
        data.append(delimiter)
        data.append(text.data(using: .utf8) ?? Data())
        data.append(delimiter)
        let tsString = String(Int64(round(createdAt * 1000)))
        data.append(tsString.data(using: .utf8) ?? Data())
        
        // BUG FIX [P2]: Include scope in signature to prevent visibility tampering
        data.append(delimiter)
        data.append(scope.data(using: .utf8) ?? Data())
        
        // BUG FIX [P1]: Bind signerPublicKey to signature to prevent key impersonation
        data.append(delimiter)
        if let spk = signerPublicKey {
            data.append(spk.data(using: .utf8) ?? Data())
        }
        
        return data
    }
    
    /// Sign this envelope with the device's Ed25519 key
    mutating func sign() {
        // BUG FIX [P1]: Set the public key BEFORE generating the signature payload
        signerPublicKey = DeviceIdentityService.shared.publicKeyBase64
        
        if let sig = DeviceIdentityService.shared.sign(signingData()) {
            signature = sig.base64EncodedString()
        }
    }
    
    /// Verify the envelope's signature against the signer's public key
    func isSignatureValid() -> Bool {
        guard let sigBase64 = signature, let sig = Data(base64Encoded: sigBase64),
              let pubKeyBase64 = signerPublicKey, let pubKey = Data(base64Encoded: pubKeyBase64) else {
            return false
        }
        return DeviceIdentityService.shared.verify(signature: sig, data: signingData(), publicKey: pubKey)
    }
}

// MARK: - Post Conversion

extension MeshPostEnvelope {
    
    /// Convert to a Post model for local display/storage
    func toPost() -> Post {
        var post = Post(
            id: postId,
            authorId: authorId,
            authorUsername: authorUsername,
            authorAvatar: authorAvatar,
            content: text,
            imageUrl: nil,
            timestamp: Date(timeIntervalSince1970: createdAt),
            editedAt: nil,
            likes: 0,
            comments: 0,
            reposts: 0,
            viewCount: 0,
            isLocal: scope == "local",
            isLiked: false,
            isReposted: false,
            visibility: scope,
            distanceM: nil,
            postType: "text",  // Mesh posts are always text
            roomId: nil,
            source: .nearby,
            initialSend: initialSend
        )
        // Mesh-only RavenShot — propagate the author's coordinates so the
        // receiver can render the pin on the social map even with no internet.
        post.latitude = latitude
        post.longitude = longitude
        post.showOnRavenShot = showOnRavenShot
        return post
    }
}

extension Post {
    
    /// Convert a text-only Post to MeshPostEnvelope for broadcast
    /// Returns nil if post has media (text-only enforcement)
    func toMeshPostEnvelope(originDeviceId: String) -> MeshPostEnvelope? {
        // ENFORCEMENT: Only text posts can be broadcast via mesh
        guard imageUrl == nil || imageUrl?.isEmpty == true else {
            #if DEBUG
            print("⚠️ [MeshPost] Cannot broadcast post with media")
            #endif
            return nil
        }
        
        guard !content.isEmpty else {
            #if DEBUG
            print("⚠️ [MeshPost] Cannot broadcast empty post")
            #endif
            return nil
        }
        
        return MeshPostEnvelope(
            postId: id,
            authorId: authorId,
            authorUsername: authorUsername,
            authorAvatar: authorAvatar,
            createdAt: timestamp.timeIntervalSince1970,
            scope: visibility ?? "public",
            text: content,
            // 🌐 Mesh-only RavenShot: carry the opt-in flag + coords so
            // peers can pin the post on their map even with no internet.
            showOnRavenShot: showOnRavenShot ?? false,
            latitude: latitude,
            longitude: longitude,
            originDeviceId: originDeviceId,
            initialSend: initialSend ?? "mesh"
        )
    }
}
