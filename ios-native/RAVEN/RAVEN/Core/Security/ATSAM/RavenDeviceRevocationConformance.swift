//
//  RavenDeviceRevocationConformance.swift
//  RAVEN
//
//  Deny-set union / quota / corrupt / auth-gate model for KATs only.
//

import Foundation

enum RavenDeviceRevocationConformance {
    static let corruptTruncated: UInt8 = 1
    static let corruptDigestMismatch: UInt8 = 2
    static let corruptBadSignature: UInt8 = 3

    static let surfaces = [
        "pair_init_v1", "pair_init_v2", "session", "message", "ack", "noise_bind",
    ]

    struct RevokedTarget: Equatable {
        var kind: String
        var valueHex: String
        var claimDigestHex: String
        var revocationIdHex: String
    }

    struct Journal {
        var kind: String
        var claimDigestHex: String
        var exactRecordBytes: Data
    }

    final class Store {
        let identityAddress: String
        var generation: UInt64 = 0
        var claims: [String: Data] = [:]
        var revoked: [RevokedTarget] = []
        var exhausted: [RavenDeviceRevocationV1.ExhaustedMarker] = []
        var corrupt: [RavenDeviceRevocationV1.CorruptMarker] = []
        var seenRevocationIds: [String: String] = [:]
        var collisions: [(id: String, first: String, second: String)] = []
        var maxClaims: Int
        var journal: Journal?

        init(identityAddress: String, maxClaims: Int) {
            self.identityAddress = identityAddress
            self.maxClaims = maxClaims
        }

        func storeHash() throws -> Data {
            try RavenDeviceRevocationV1.storeHash(
                generation: generation,
                claimWires: Array(claims.values),
                exhausted: exhausted,
                corrupt: corrupt
            )
        }
    }

    enum ApplyResult: String {
        case applied, exhausted, idempotent
    }

    static func apply(
        store: Store,
        wire: Data,
        identityEdPub: Data,
        pendingAlreadyWritten: Bool = false
    ) throws -> ApplyResult {
        let rec = try RavenDeviceRevocationV1.decode(wire)
        guard rec.identityAddress == store.identityAddress else {
            throw RavenDeviceRevocationV1.CodecError.badAddress
        }
        try RavenDeviceRevocationV1.verify(rec, identityEdPub: identityEdPub)
        let cd = RavenDeviceRevocationV1.claimDigest(wire)
        let cdHex = cd.hexString

        if pendingAlreadyWritten {
            guard let j = store.journal else {
                throw PendingBindingError.missingPending
            }
            if j.kind == "PENDING_REVOKE_EXHAUSTED" {
                throw PendingBindingError.directExhaustedConsumption
            }
            guard j.kind == "PENDING_REVOKE" else {
                throw PendingBindingError.missingPending
            }
            guard j.exactRecordBytes == wire else {
                throw PendingBindingError.pendingBytesMismatch
            }
            guard j.claimDigestHex == cdHex else {
                throw PendingBindingError.pendingDigestMismatch
            }
        } else if store.journal?.kind == "PENDING_REVOKE_EXHAUSTED" {
            throw PendingBindingError.directExhaustedConsumption
        }

        if store.claims[cdHex] != nil { return .idempotent }
        guard store.corrupt.isEmpty else {
            throw RavenDeviceRevocationV1.CodecError.verifyFailed
        }
        if store.claims.count >= store.maxClaims {
            let exh = RavenDeviceRevocationV1.ExhaustedMarker(
                identityAddress: store.identityAddress,
                claimDigest: cd,
                exactRecordBytes: wire
            )
            store.exhausted.removeAll { $0.claimDigest == cd }
            store.exhausted.append(exh)
            store.journal = Journal(
                kind: "PENDING_REVOKE_EXHAUSTED",
                claimDigestHex: cdHex,
                exactRecordBytes: wire
            )
            store.generation += 1
            return .exhausted
        }
        let rid = rec.revocationId.hexString
        if let first = store.seenRevocationIds[rid], first != cdHex {
            store.collisions.append((rid, first, cdHex))
        } else {
            store.seenRevocationIds[rid] = cdHex
        }
        store.claims[cdHex] = wire
        appendTargets(store: store, rec: rec, cd: cd)
        store.exhausted.removeAll { $0.claimDigest == cd }
        if pendingAlreadyWritten || store.journal?.kind == "PENDING_REVOKE" {
            store.journal = nil
        }
        store.generation += 1
        return .applied
    }

    enum PendingBindingError: Error, Equatable {
        case missingPending
        case pendingBytesMismatch
        case pendingDigestMismatch
        case directExhaustedConsumption

        var fixtureCode: String {
            switch self {
            case .missingPending: return "missing_pending"
            case .pendingBytesMismatch: return "pending_bytes_mismatch"
            case .pendingDigestMismatch: return "pending_digest_mismatch"
            case .directExhaustedConsumption: return "direct_exhausted_consumption"
            }
        }
    }

    static func expandQuota(store: Store, newMax: Int) throws {
        guard newMax >= store.maxClaims else {
            throw RavenDeviceRevocationV1.CodecError.badLength
        }
        store.maxClaims = newMax
    }

    static func convertExhaustedToPending(store: Store) throws {
        guard let j = store.journal, j.kind == "PENDING_REVOKE_EXHAUSTED" else {
            throw RavenDeviceRevocationV1.CodecError.badLength
        }
        store.journal = Journal(
            kind: "PENDING_REVOKE",
            claimDigestHex: j.claimDigestHex,
            exactRecordBytes: j.exactRecordBytes
        )
    }

    static func reverifyJournal(store: Store, identityEdPub: Data) throws -> (String, UInt8?) {
        guard let j = store.journal else {
            throw RavenDeviceRevocationV1.CodecError.badLength
        }
        let wire = j.exactRecordBytes
        func fail(_ reason: String, _ code: UInt8) -> (String, UInt8?) {
            store.corrupt.append(
                RavenDeviceRevocationV1.CorruptMarker(
                    scope: store.identityAddress,
                    reasonCode: code
                )
            )
            store.journal = nil
            store.generation += 1
            return ("corrupt", code)
        }
        if wire.count < 54 {
            return fail("truncated", corruptTruncated)
        }
        let rec: RavenDeviceRevocationV1.Record
        do {
            rec = try RavenDeviceRevocationV1.decode(wire)
        } catch {
            return fail("truncated", corruptTruncated)
        }
        let cd = RavenDeviceRevocationV1.claimDigest(wire)
        if cd.hexString != j.claimDigestHex {
            return fail("digest_mismatch", corruptDigestMismatch)
        }
        do {
            try RavenDeviceRevocationV1.verify(rec, identityEdPub: identityEdPub)
        } catch {
            return fail("bad_signature", corruptBadSignature)
        }
        return ("ok", nil)
    }

    struct AuthResult {
        var authorized: Bool
        var reason: String
        var surface: String
        var matchedKind: String?
    }

    static func authorize(
        store: Store,
        deviceId: Data?,
        deviceEdPub: Data?,
        deviceXPub: Data?,
        deviceCertHash: Data?,
        surface: String
    ) -> AuthResult {
        if !store.corrupt.isEmpty {
            return AuthResult(
                authorized: false,
                reason: "REVOCATION_STORE_CORRUPT",
                surface: surface,
                matchedKind: nil
            )
        }
        if store.exhausted.contains(where: { $0.identityAddress == store.identityAddress }) {
            return AuthResult(
                authorized: false,
                reason: "IDENTITY_REVOKE_EXHAUSTED",
                surface: surface,
                matchedKind: nil
            )
        }
        let checks: [(String, Data?)] = [
            ("device_id", deviceId),
            ("device_ed_pub", deviceEdPub),
            ("device_x_pub", deviceXPub),
            ("device_cert_hash", deviceCertHash),
        ]
        for (kind, val) in checks {
            guard let val else { continue }
            let hx = val.hexString
            if store.revoked.contains(where: { $0.kind == kind && $0.valueHex == hx }) {
                return AuthResult(
                    authorized: false,
                    reason: "revoked_target",
                    surface: surface,
                    matchedKind: kind
                )
            }
        }
        return AuthResult(authorized: true, reason: "ok", surface: surface, matchedKind: nil)
    }

    private static func appendTargets(
        store: Store,
        rec: RavenDeviceRevocationV1.Record,
        cd: Data
    ) {
        let cdHex = cd.hexString
        let rid = rec.revocationId.hexString
        let entries: [(String, Data)] = [
            ("device_id", rec.deviceId),
            ("device_ed_pub", rec.deviceEdPub),
            ("device_x_pub", rec.deviceXPub),
            ("device_cert_hash", rec.deviceCertHash),
        ]
        for (kind, value) in entries {
            let hx = value.hexString
            if !store.revoked.contains(where: { $0.kind == kind && $0.valueHex == hx }) {
                store.revoked.append(
                    RevokedTarget(
                        kind: kind,
                        valueHex: hx,
                        claimDigestHex: cdHex,
                        revocationIdHex: rid
                    )
                )
            }
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
