//
//  ATSAMFullBraidProtectedAnchorV1.swift
//  RAVEN
//
//  Slice 3 Task 0B.1 — lab-only protected seed / RVFA1 codec freeze.
//  No Keychain / Secret Service / CredMan backends (0B.2+). Production off.
//

import CryptoKit
import Foundation

enum ATSAMFullBraidProtectedAnchorV1 {
    static let productionEnabled = false
    static let rvfa1Length = 204
    static let rvfa1PrefixLength = 172
    static let seedLength = 32
    static let initialAnchorSeq: UInt64 = 1
    static let rvfa1Schema: UInt16 = 1
    static let appleAppID = Data("app.raven.ios".utf8)
    static let appleLogicalRoot = Data("group.app.raven.fullbraid".utf8)
    static let terminalAppID = Data("app.raven.node".utf8)
    static let appleSeedService = "app.raven.atsam.full-braid.store.v1"
    static let appleAnchorService = "app.raven.atsam.full-braid.anchor.v1"
    static let linuxApplication = "app.raven.node"
    static let linuxProtocol = "atsam-full-braid-v1"
    static let windowsTargetPrefix = "Raven/ATSAM/FullBraid/v1"
    static let windowsCredMaxBlob = 2560
    static let maxFullBraidSessions = 4096
    static let releaseHold = "FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED"
    static let errorCodes = [
        "UNAVAILABLE",
        "LOCKED_OR_PROMPT_REQUIRED",
        "MISSING",
        "DUPLICATE",
        "CONFLICT",
        "CORRUPT_LENGTH",
        "CORRUPT_ATTRIBUTES",
        "WRONG_ACCESSIBILITY_OR_PERSISTENCE",
        "CAPACITY",
        "READBACK_MISMATCH",
        "IO_OR_PLATFORM",
    ]

    private static let scopeDomain = Data("ATSAM/v2/full-braid/durable/platform-scope".utf8)
    private static let recordDomain = Data("ATSAM/v2/full-braid/durable/record".utf8)
    private static let infoState = Data("ATSAM/v2/full-braid/durable/state-aead".utf8)
    private static let infoIndex = Data("ATSAM/v2/full-braid/durable/index".utf8)
    private static let infoSQL = Data("ATSAM/v2/full-braid/durable/sqlcipher".utf8)
    private static let infoLocal = Data("ATSAM/v2/full-braid/durable/domain-local".utf8)
    private static let infoAnchor = Data("ATSAM/v2/full-braid/durable/anchor".utf8)
    private static let infoSQLSalt = Data("ATSAM/v2/full-braid/durable/sqlcipher-salt".utf8)
    private static let infoStateRecord = Data("ATSAM/v2/full-braid/durable/state-record".utf8)
    private static let infoStage = Data("ATSAM/v2/full-braid/durable/domain-stage".utf8)
    private static let zeroSalt = Data(count: 32)
    private static let zero32 = Data(count: 32)
    private static let magic = Data([0x52, 0x56, 0x46, 0x41, 0x31, 0x00, 0x00, 0x00]) // RVFA1\0\0\0
    private static let forbiddenAppleRoots: [Data] = [
        Data("group.app.raven.shared".utf8),
        Data("group.app.raven.ios".utf8),
    ]

    enum CodecError: Error, Equatable {
        case badLength(String)
        case forbiddenAppleRoot
        case badMagic
        case badSchema
        case badStatus
        case badRole
        case badHMAC
        case providedHMACMismatch
        case emptyScopeComponent
    }

    enum Status: UInt8 {
        case head = 1
        case deleting = 2
        case tombstone = 3
    }

    enum AppendDecision: String {
        case appended = "Appended"
        case exactReplay = "ExactReplay"
        case corrupt = "Corrupt"
    }

    struct DerivedKeys {
        var kState: Data
        var kIndex: Data
        var kSQL: Data
        var kLocal: Data
        var kAnchor: Data
        var kSQLSalt: Data

        mutating func zeroize() {
            kState.resetBytes(in: 0..<kState.count)
            kIndex.resetBytes(in: 0..<kIndex.count)
            kSQL.resetBytes(in: 0..<kSQL.count)
            kLocal.resetBytes(in: 0..<kLocal.count)
            kAnchor.resetBytes(in: 0..<kAnchor.count)
            kSQLSalt.resetBytes(in: 0..<kSQLSalt.count)
        }
    }

    struct Rvfa1: Equatable {
        var status: Status
        var role: UInt8
        var recordKey: Data
        var sessionID: Data
        var anchorSeq: UInt64
        var generation: UInt64
        var clearedStateDigest: Data
        var clearedStoreRevision: UInt64
        var transitionID: Data
        var horizonMS: UInt64
        /// Empty/all-zero means compute on encode; any other value must match.
        var hmac: Data
    }

    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let saltData = salt.isEmpty ? Data(count: 32) : salt
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: saltData,
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func scopeID(platformAppID: Data, logicalRootID: Data) throws -> Data {
        guard !platformAppID.isEmpty, !logicalRootID.isEmpty else {
            throw CodecError.emptyScopeComponent
        }
        if forbiddenAppleRoots.contains(logicalRootID) {
            throw CodecError.forbiddenAppleRoot
        }
        var material = Data()
        material.append(scopeDomain)
        material.append(u32be(UInt32(platformAppID.count)))
        material.append(platformAppID)
        material.append(u32be(UInt32(logicalRootID.count)))
        material.append(logicalRootID)
        return Data(SHA256.hash(data: material))
    }

    static func appleScopeID() -> Data {
        try! scopeID(platformAppID: appleAppID, logicalRootID: appleLogicalRoot)
    }

    static func terminalScopeID(canonicalRootBytes: Data) throws -> Data {
        try scopeID(platformAppID: terminalAppID, logicalRootID: canonicalRootBytes)
    }

    static func deriveStoreKeys(seed32: Data) throws -> DerivedKeys {
        guard seed32.count == seedLength else { throw CodecError.badLength("seed") }
        return DerivedKeys(
            kState: hkdf(ikm: seed32, salt: zeroSalt, info: infoState, length: 32),
            kIndex: hkdf(ikm: seed32, salt: zeroSalt, info: infoIndex, length: 32),
            kSQL: hkdf(ikm: seed32, salt: zeroSalt, info: infoSQL, length: 32),
            kLocal: hkdf(ikm: seed32, salt: zeroSalt, info: infoLocal, length: 32),
            kAnchor: hkdf(ikm: seed32, salt: zeroSalt, info: infoAnchor, length: 32),
            kSQLSalt: hkdf(ikm: seed32, salt: zeroSalt, info: infoSQLSalt, length: 16)
        )
    }

    static func recordKey(kIndex: Data, sessionID: Data) throws -> Data {
        guard kIndex.count == 32 else { throw CodecError.badLength("k_index") }
        guard sessionID.count == 32 else { throw CodecError.badLength("session_id") }
        var message = Data()
        message.append(recordDomain)
        message.append(sessionID)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: kIndex)))
    }

    static func encodeRVFA1(_ fields: Rvfa1, kAnchor: Data) throws -> Data {
        guard kAnchor.count == 32 else { throw CodecError.badLength("k_anchor") }
        let prefix = try prefixBytes(fields)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: prefix, using: SymmetricKey(data: kAnchor)))
        let provided = fields.hmac
        if !(provided.isEmpty || provided == zero32 || provided == tag) {
            throw CodecError.providedHMACMismatch
        }
        var out = prefix
        out.append(tag)
        guard out.count == rvfa1Length else { throw CodecError.badLength("rvfa1") }
        return out
    }

    static func decodeRVFA1(_ raw: Data, kAnchor: Data) throws -> Rvfa1 {
        guard raw.count == rvfa1Length else { throw CodecError.badLength("rvfa1") }
        guard kAnchor.count == 32 else { throw CodecError.badLength("k_anchor") }
        guard raw.prefix(8) == magic else { throw CodecError.badMagic }
        let schema = u16be(raw, 8)
        guard schema == rvfa1Schema else { throw CodecError.badSchema }
        guard let status = Status(rawValue: raw[10]) else { throw CodecError.badStatus }
        let role = raw[11]
        guard role <= 1 else { throw CodecError.badRole }
        let prefix = raw.prefix(rvfa1PrefixLength)
        let tag = Data(raw.suffix(from: rvfa1PrefixLength))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: prefix, using: SymmetricKey(data: kAnchor)))
        guard tag.count == 32, constantTimeEqual(tag, expected) else { throw CodecError.badHMAC }
        return Rvfa1(
            status: status,
            role: role,
            recordKey: Data(raw[12..<44]),
            sessionID: Data(raw[44..<76]),
            anchorSeq: u64be(raw, 76),
            generation: u64be(raw, 84),
            clearedStateDigest: Data(raw[92..<124]),
            clearedStoreRevision: u64be(raw, 124),
            transitionID: Data(raw[132..<164]),
            horizonMS: u64be(raw, 164),
            hmac: tag
        )
    }

    private static func recordInvariantsOK(_ item: Rvfa1, kIndex: Data) throws -> Bool {
        let expected = try recordKey(kIndex: kIndex, sessionID: item.sessionID)
        if item.recordKey != expected { return false }
        let isInitial = item.anchorSeq == initialAnchorSeq
        switch item.status {
        case .head:
            if item.horizonMS != 0 { return false }
            if isInitial {
                return item.transitionID == zero32
            }
            return item.transitionID != zero32
        case .deleting:
            if isInitial || item.horizonMS == 0 || item.transitionID == zero32 {
                return false
            }
            return true
        case .tombstone:
            if isInitial || item.horizonMS == 0 || item.transitionID != zero32 {
                return false
            }
            return true
        }
    }

    private static func statusTransitionOK(prev: Status?, next: Status) -> Bool {
        switch prev {
        case nil:
            return next == .head
        case .head:
            return next == .head || next == .deleting
        case .deleting:
            return next == .tombstone
        case .tombstone:
            return false
        }
    }

    private static func establishedChainOK(_ sameRecord: [Rvfa1]) -> Bool {
        if sameRecord.isEmpty { return true }
        let ordered = sameRecord.sorted { $0.anchorSeq < $1.anchorSeq }
        guard ordered[0].anchorSeq == initialAnchorSeq else { return false }
        guard statusTransitionOK(prev: nil, next: ordered[0].status) else { return false }
        for (idx, item) in ordered.enumerated() {
            let expected = initialAnchorSeq &+ UInt64(idx)
            guard item.anchorSeq == expected else { return false }
            if idx > 0 {
                guard statusTransitionOK(prev: ordered[idx - 1].status, next: item.status) else {
                    return false
                }
            }
        }
        return true
    }

    static func classifyAppend(
        existingRaw: [Data],
        candidateRaw: Data,
        kAnchor: Data,
        kIndex: Data
    ) -> AppendDecision {
        let candidate: Rvfa1
        do {
            candidate = try decodeRVFA1(candidateRaw, kAnchor: kAnchor)
            guard try recordInvariantsOK(candidate, kIndex: kIndex) else { return .corrupt }
        } catch {
            return .corrupt
        }

        var seen: [Data: Data] = [:]
        var sameRecord: [Rvfa1] = []
        for raw in existingRaw {
            let item: Rvfa1
            do {
                item = try decodeRVFA1(raw, kAnchor: kAnchor)
                guard try recordInvariantsOK(item, kIndex: kIndex) else { return .corrupt }
            } catch {
                return .corrupt
            }
            let key = identityKey(recordKey: item.recordKey, anchorSeq: item.anchorSeq)
            if seen[key] != nil {
                return .corrupt
            }
            seen[key] = raw
            if item.recordKey != candidate.recordKey {
                continue
            }
            if item.sessionID != candidate.sessionID || item.role != candidate.role {
                return .corrupt
            }
            sameRecord.append(item)
        }

        guard establishedChainOK(sameRecord) else { return .corrupt }

        let candidateKey = identityKey(recordKey: candidate.recordKey, anchorSeq: candidate.anchorSeq)
        if let existing = seen[candidateKey] {
            return existing == candidateRaw ? .exactReplay : .corrupt
        }
        if sameRecord.isEmpty {
            guard candidate.anchorSeq == initialAnchorSeq else { return .corrupt }
            guard statusTransitionOK(prev: nil, next: candidate.status) else { return .corrupt }
            return .appended
        }
        let highestItem = sameRecord.max(by: { $0.anchorSeq < $1.anchorSeq })!
        if highestItem.anchorSeq == UInt64.max {
            return .corrupt
        }
        guard candidate.anchorSeq == highestItem.anchorSeq &+ 1 else { return .corrupt }
        guard statusTransitionOK(prev: highestItem.status, next: candidate.status) else {
            return .corrupt
        }
        return .appended
    }

    static func openRollbackClass(
        anchorGeneration: UInt64,
        anchorDigest: Data,
        anchorRevision: UInt64,
        fileGeneration: UInt64,
        fileDigest: Data,
        fileRevision: UInt64
    ) -> String {
        if anchorGeneration > fileGeneration {
            return "container_behind_anchor"
        }
        if anchorGeneration < fileGeneration {
            return "anchor_behind_container"
        }
        if anchorDigest != fileDigest {
            return "digest_mismatch"
        }
        if anchorRevision > fileRevision {
            return "container_behind_anchor"
        }
        if anchorRevision < fileRevision {
            return "anchor_behind_container"
        }
        return "aligned"
    }

    private static func prefixBytes(_ fields: Rvfa1) throws -> Data {
        guard fields.role <= 1 else { throw CodecError.badRole }
        guard fields.recordKey.count == 32 else { throw CodecError.badLength("record_key") }
        guard fields.sessionID.count == 32 else { throw CodecError.badLength("session_id") }
        guard fields.clearedStateDigest.count == 32 else { throw CodecError.badLength("cleared_state_digest") }
        guard fields.transitionID.count == 32 else { throw CodecError.badLength("transition_id") }
        var out = Data()
        out.reserveCapacity(rvfa1PrefixLength)
        out.append(magic)
        out.append(u16be(rvfa1Schema))
        out.append(fields.status.rawValue)
        out.append(fields.role)
        out.append(fields.recordKey)
        out.append(fields.sessionID)
        out.append(u64be(fields.anchorSeq))
        out.append(u64be(fields.generation))
        out.append(fields.clearedStateDigest)
        out.append(u64be(fields.clearedStoreRevision))
        out.append(fields.transitionID)
        out.append(u64be(fields.horizonMS))
        guard out.count == rvfa1PrefixLength else { throw CodecError.badLength("prefix") }
        return out
    }

    private static func identityKey(recordKey: Data, anchorSeq: UInt64) -> Data {
        var key = Data()
        key.append(recordKey)
        key.append(u64be(anchorSeq))
        return key
    }

    private static func u16be(_ value: UInt16) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 2)
    }

    private static func u32be(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private static func u64be(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 8)
    }

    private static func u16be(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func u64be(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}
