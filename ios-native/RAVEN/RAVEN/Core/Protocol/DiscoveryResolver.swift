//
//  DiscoveryResolver.swift
//  RAVEN — multi-lane discovery without central Raven DB (Discovery V1).
//
//  Finding a name ≠ verifying a person. @alias is NOT identity; rvn1… is.
//  Spec: docs/RAVEN_DISCOVERY_V1.md. FastAPI must not be used when serverless ON.
//

import Foundation

enum DiscoveryScope: String, Codable {
    case local = "LOCAL"
    case exactId = "EXACT_ID"
    case exactAlias = "EXACT_ALIAS"
    case myNetwork = "MY_NETWORK"
    case nearby = "NEARBY"
    case publicScope = "PUBLIC"
    case all = "ALL"
}

enum VerificationState: String, Codable, Equatable {
    case directlyVerified = "DIRECTLY_VERIFIED"
    case trustedContact = "TRUSTED_CONTACT"
    case introduced = "INTRODUCED"
    case scopedVerified = "SCOPED_VERIFIED"
    case nearbyVerified = "NEARBY_VERIFIED"
    case publicSignedProfile = "PUBLIC_SIGNED_PROFILE"
    case aliasConflict = "ALIAS_CONFLICT"
    case expiredOrStale = "EXPIRED_OR_STALE"
    case blocked = "BLOCKED"
}

enum DiscoverySource: String, Codable, Hashable {
    case localContacts = "LOCAL_CONTACTS"
    case exactRavenId = "EXACT_RAVEN_ID"
    case aliasDht = "ALIAS_DHT"
    case nearbyBle = "NEARBY_BLE"
    case socialIntroduction = "SOCIAL_INTRODUCTION"
    case publicProfileIndex = "PUBLIC_PROFILE_INDEX"
    case legacyServer = "LEGACY_SERVER"
}

struct DiscoveryIntroduction: Codable, Equatable {
    var introducerRavenId: String
    var subjectRavenId: String
}

struct DiscoveryResult: Codable, Equatable {
    var ravenId: String
    var displayName: String
    var aliases: [String]
    var profileDigest: String
    var sourceSet: [DiscoverySource]
    var verificationState: VerificationState
    var introductions: [DiscoveryIntroduction]
    var conflictCount: UInt32
    var sequence: UInt64
    var expiresAt: UInt64

    enum CodingKeys: String, CodingKey {
        case ravenId = "raven_id"
        case displayName = "display_name"
        case aliases
        case profileDigest = "profile_digest"
        case sourceSet = "source_set"
        case verificationState = "verification_state"
        case introductions
        case conflictCount = "conflict_count"
        case sequence
        case expiresAt = "expires_at"
    }

    /// Stable schema keys shared with terminal (`result_model_schema_keys`).
    static let schemaKeys: [String] = [
        "raven_id", "display_name", "aliases", "profile_digest", "source_set",
        "verification_state", "introductions", "conflict_count", "sequence", "expires_at",
    ]
}

struct LocalDiscoveryContact: Equatable {
    var ravenId: String
    var pubHex: String
    var petname: String
    var publicTag: String
    var displayName: String
    var pinned: Bool
    var directlyVerified: Bool
}

struct SignedAliasClaim: Equatable {
    var alias: String
    var identityAddress: String
    var sequence: UInt64
    var expiresAt: UInt64
    var ed25519PubHex: String
}

/// Thin DiscoveryResolver-equivalent for iOS (same result model as ash / raven-core).
final class DiscoveryResolver {
    var contacts: [LocalDiscoveryContact] = []
    var aliasClaims: [SignedAliasClaim] = []
    var blockedPubHex: Set<String> = []
    /// When true (serverless), LegacyServer lane is never consulted.
    var serverless: Bool = true
    var publicProfileIndexEnabled: Bool = false
    var nowMs: UInt64 = 0

    static func normalizeAlias(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        guard !s.isEmpty, s.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return s
    }

    func search(query: String, scope: DiscoveryScope) -> [DiscoveryResult] {
        // Serverless discovery must never call FastAPI.
        if serverless {
            // no-op: LegacyServerProvider off
        }
        var out: [DiscoveryResult] = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let runLocal = scope == .local || scope == .all || scope == .myNetwork
        let runId = scope == .exactId || scope == .all || scope == .publicScope
        let runAlias = scope == .exactAlias || scope == .all || scope == .publicScope
        let runNearby = scope == .nearby || scope == .all

        if runLocal {
            out.append(contentsOf: searchLocal(q))
        }
        if runId && q.hasPrefix("rvn1") {
            out.append(contentsOf: searchExactId(q))
        }
        if runAlias {
            out.append(contentsOf: searchExactAlias(q))
        }
        if runNearby {
            // Nearby results are injected by BLE confirm path; empty by default.
        }
        // PublicProfileIndex OFF in V1.
        _ = publicProfileIndexEnabled
        return merge(out)
    }

    private func searchLocal(_ query: String) -> [DiscoveryResult] {
        let q = query.trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
        var out: [DiscoveryResult] = []
        for c in contacts {
            if blockedPubHex.contains(c.pubHex.lowercased()) {
                out.append(DiscoveryResult(
                    ravenId: c.ravenId, displayName: "", aliases: [], profileDigest: "",
                    sourceSet: [.localContacts], verificationState: .blocked,
                    introductions: [], conflictCount: 0, sequence: 0, expiresAt: 0
                ))
                continue
            }
            let match = c.ravenId.caseInsensitiveCompare(query) == .orderedSame
                || c.petname.lowercased().contains(q)
                || c.publicTag.lowercased() == q
                || c.displayName.lowercased().contains(q)
            guard match, !q.isEmpty || query.hasPrefix("rvn1") else { continue }
            out.append(DiscoveryResult(
                ravenId: c.ravenId,
                displayName: c.petname.isEmpty ? c.displayName : c.petname,
                aliases: c.publicTag.isEmpty ? [] : [c.publicTag],
                profileDigest: "",
                sourceSet: [.localContacts],
                verificationState: (c.directlyVerified || c.pinned) ? .directlyVerified : .trustedContact,
                introductions: [],
                conflictCount: 0,
                sequence: 0,
                expiresAt: UInt64.max
            ))
        }
        return out
    }

    private func searchExactId(_ query: String) -> [DiscoveryResult] {
        if let c = contacts.first(where: { $0.ravenId == query }) {
            if blockedPubHex.contains(c.pubHex.lowercased()) {
                return [DiscoveryResult(
                    ravenId: query, displayName: "", aliases: [], profileDigest: "",
                    sourceSet: [.exactRavenId], verificationState: .blocked,
                    introductions: [], conflictCount: 0, sequence: 0, expiresAt: 0
                )]
            }
        }
        return [DiscoveryResult(
            ravenId: query, displayName: "", aliases: [], profileDigest: "",
            sourceSet: [.exactRavenId], verificationState: .publicSignedProfile,
            introductions: [], conflictCount: 0, sequence: 0, expiresAt: 0
        )]
    }

    private func searchExactAlias(_ query: String) -> [DiscoveryResult] {
        guard let want = Self.normalizeAlias(query) else { return [] }
        let live = aliasClaims.filter {
            Self.normalizeAlias($0.alias) == want && $0.expiresAt >= nowMs
        }
        guard !live.isEmpty else { return [] }
        let conflict = live.count > 1 ? UInt32(live.count) : 0
        return live.map { claim in
            DiscoveryResult(
                ravenId: claim.identityAddress,
                displayName: "",
                aliases: [want],
                profileDigest: "",
                sourceSet: [.aliasDht],
                verificationState: conflict > 0 ? .aliasConflict : .publicSignedProfile,
                introductions: [],
                conflictCount: conflict,
                sequence: claim.sequence,
                expiresAt: claim.expiresAt
            )
        }
    }

    private func merge(_ results: [DiscoveryResult]) -> [DiscoveryResult] {
        var byId: [String: DiscoveryResult] = [:]
        for r in results {
            if r.verificationState == .aliasConflict {
                byId[r.ravenId] = r
                continue
            }
            if var e = byId[r.ravenId] {
                for s in r.sourceSet where !e.sourceSet.contains(s) {
                    e.sourceSet.append(s)
                }
                if e.displayName.isEmpty { e.displayName = r.displayName }
                for a in r.aliases where !e.aliases.contains(a) { e.aliases.append(a) }
                e.conflictCount = max(e.conflictCount, r.conflictCount)
                byId[r.ravenId] = e
            } else {
                byId[r.ravenId] = r
            }
        }
        return byId.values.sorted { $0.ravenId < $1.ravenId }
    }
}
