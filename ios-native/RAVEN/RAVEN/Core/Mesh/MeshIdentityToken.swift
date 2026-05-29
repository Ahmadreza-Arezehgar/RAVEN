//
//  MeshIdentityToken.swift
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-CRIT-2.
//
//  Closes the mesh-↔-server identity correlation hole.
//
//  Before: every mesh envelope carried `senderId` and `recipientId`
//  as RAVEN server primary-key userIds (opaque UUIDs that the server
//  side stores in the `users` table). A rogue mesh node — any peer
//  who joins the GATT service UUID — could decode the envelope and
//  read both IDs in plaintext. Cross-referencing with the public
//  server-side username lookup would then build the social graph
//  "userId X talks to userId Y from location L at time T", join to
//  username, and de-anonymise both ends.
//
//  After: the wire carries a 12-byte HMAC truncation of each ID
//  keyed by a public, install-stable salt. The hash is deterministic
//  per (salt, userId) so two devices that both know the salt + the
//  userId can recognise each other's hash. The salt is public — its
//  purpose is domain separation, not secrecy. The privacy property
//  we gain:
//
//    • A rogue mesh node sees `senderIdHash` / `recipientIdHash` —
//      opaque 96-bit values with no link to server userIds.
//    • Cross-channel correlation (mesh ↔ server account) requires
//      brute-forcing the hash against the global userId space.
//      With ~2^64 entropy in random UUID userIds and SHA-256 inside
//      the HMAC, that's computationally infeasible.
//    • Cross-mesh correlation ("hash X always talks to hash Y") is
//      still possible without epoch rotation — tracked separately
//      under MESH-CRIT-2-NEXT.
//
//  This file is the math primitive + local-lookup cache. The actual
//  wire-level gating (stripping raw IDs when the peer is confirmed
//  `.modernATSAM`) lives in `MessageRouter.swift` on outbound and
//  `BLEMeshEngine.swift` on inbound.

import Foundation
import CryptoKit

/// Domain-separation salt. Public — its purpose is to prevent the
/// same hash being used in unrelated protocols, not to provide
/// secrecy. Treat as a protocol constant; changing it is a wire
/// break that requires a flag-day coordinated upgrade.
private let MeshIdentitySalt: Data = Data("raven-mesh-identity-v1".utf8)

/// 96 bits of hash output. Truncating SHA-256 to 12 bytes keeps the
/// wire envelope compact while leaving the preimage space astronomically
/// larger than any realistic attacker can brute-force.
private let MeshIdentityHashBytes: Int = 12

// MARK: - Hash function

public enum MeshIdentityToken {

    /// Hash a userId to its wire-level token. Returns the lowercase
    /// hex representation (`24` characters) so it can ride inside
    /// the existing JSON-encoded `MeshEnvelope` without a binary
    /// escape layer.
    public static func hash(userId: String) -> String {
        guard !userId.isEmpty else { return "" }
        let key = SymmetricKey(data: MeshIdentitySalt)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(userId.utf8),
            using: key
        )
        return Data(mac).prefix(MeshIdentityHashBytes).hexLower
    }

    /// Same hash, but as `Data` for callers that want to compare
    /// bytewise without the hex round-trip.
    public static func hashBytes(userId: String) -> Data {
        guard !userId.isEmpty else { return Data() }
        let key = SymmetricKey(data: MeshIdentitySalt)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(userId.utf8),
            using: key
        )
        return Data(mac).prefix(MeshIdentityHashBytes)
    }
}

// MARK: - Receiver-side reverse lookup

/// Local cache of `userIdHash → userId` for every userId this device
/// knows about (self + contacts + recently-seen peers). The receive
/// path consults this when an inbound envelope omits raw IDs.
///
/// Concurrency: actor-isolated. Lookups are O(1) hash dictionary
/// reads. Refresh is event-driven (called when contacts change) so
/// we don't pay a per-envelope rebuild cost.
public actor MeshIdentityResolver {
    public static let shared = MeshIdentityResolver()

    private var map: [String: String] = [:]
    private init() {}

    /// Register one userId so its hash is recognisable on receive.
    /// Idempotent — duplicates are silently merged.
    public func register(userId: String) {
        guard !userId.isEmpty else { return }
        let h = MeshIdentityToken.hash(userId: userId)
        map[h] = userId
    }

    /// Bulk register — used after contact sync.
    public func registerAll(_ userIds: [String]) {
        for id in userIds where !id.isEmpty {
            map[MeshIdentityToken.hash(userId: id)] = id
        }
    }

    /// Resolve a hash back to its real userId. Returns nil if we've
    /// never registered this hash — caller should fall back to the
    /// envelope's raw `senderId`/`recipientId` (which is still
    /// populated during the v1.6 / v1.7 cross-compat phase).
    public func resolve(hash: String) -> String? {
        guard !hash.isEmpty else { return nil }
        return map[hash]
    }

    /// Diagnostics: how many userIds are registered. The receive
    /// path can short-circuit hash resolution if this is 0.
    public var size: Int { map.count }

    /// Reset (used on sign-out). Cheap because the map is small
    /// (one entry per contact, bounded by realistic address-book
    /// sizes).
    public func reset() { map.removeAll() }
}

// MARK: - Helpers

private extension Data {
    /// Lowercase hex encoding. Avoid `String(format:)` per byte —
    /// it's measurably slow for hot paths like per-envelope hashing.
    var hexLower: String {
        let alphabet: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0, count: count * 2)
        for (i, b) in self.enumerated() {
            out[i * 2]     = alphabet[Int(b >> 4)]
            out[i * 2 + 1] = alphabet[Int(b & 0x0F)]
        }
        return String(bytes: out, encoding: .ascii) ?? ""
    }
}
