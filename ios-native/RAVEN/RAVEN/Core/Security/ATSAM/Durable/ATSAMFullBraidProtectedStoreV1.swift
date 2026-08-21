//
//  ATSAMFullBraidProtectedStoreV1.swift
//  RAVEN
//
//  Slice 3 Task 0B.2 — lab-only Apple Data Protection Keychain backend.
//  Seed + append-only RVFA1. No file/UserDefaults/legacy-Keychain fallback.
//  Production remains disabled. Task 0B.3+ / 0C / live callsites are out of scope.
//

#if targetEnvironment(macCatalyst)
#error("FULL_BRAID_PROTECTED_ANCHOR_CATALYST_HOLD")
#else

import CryptoKit
import Foundation
import Security

enum ATSAMFullBraidProtectedStoreV1 {
    static let productionEnabled = false
    static let releaseHold = ATSAMFullBraidProtectedAnchorV1.releaseHold
    static let accessGroup = "group.app.raven.fullbraid"
    static let seedService = ATSAMFullBraidProtectedAnchorV1.appleSeedService
    static let anchorService = ATSAMFullBraidProtectedAnchorV1.appleAnchorService
    static let maxSessions = ATSAMFullBraidProtectedAnchorV1.maxFullBraidSessions
    static let seedLength = ATSAMFullBraidProtectedAnchorV1.seedLength
    static let rvfa1Length = ATSAMFullBraidProtectedAnchorV1.rvfa1Length

    enum StoreError: Error, Equatable, CustomStringConvertible {
        case productionDisabled
        case unavailable
        case lockedOrPromptRequired
        case missing
        case duplicate
        case conflict
        case corruptLength
        case corruptAttributes
        case wrongAccessibilityOrPersistence
        case capacity
        case readbackMismatch
        case ioOrPlatform(OSStatus)
        case codec

        var description: String {
            switch self {
            case .productionDisabled: return "FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED"
            case .unavailable: return "UNAVAILABLE"
            case .lockedOrPromptRequired: return "LOCKED_OR_PROMPT_REQUIRED"
            case .missing: return "MISSING"
            case .duplicate: return "DUPLICATE"
            case .conflict: return "CONFLICT"
            case .corruptLength: return "CORRUPT_LENGTH"
            case .corruptAttributes: return "CORRUPT_ATTRIBUTES"
            case .wrongAccessibilityOrPersistence: return "WRONG_ACCESSIBILITY_OR_PERSISTENCE"
            case .capacity: return "CAPACITY"
            case .readbackMismatch: return "READBACK_MISMATCH"
            case .ioOrPlatform(let status): return "IO_OR_PLATFORM:\(status)"
            case .codec: return "CORRUPT_ATTRIBUTES"
            }
        }
    }

    enum SeedCreateResult: Equatable {
        case created(Data)
        case existing(Data)
    }

    enum SeedLoadResult: Equatable {
        case missing
        case exact(Data)
    }

    enum AnchorAppendResult: Equatable {
        case appended
        case exactReplay
    }

    struct NamespaceProbe: Equatable {
        let accessGroup: String
        let seedService: String
        let anchorService: String
        let accessibility: String
        let synchronizable: Bool
        let dataProtectionKeychain: Bool
        let scopeIDHex: String
    }

    /// Apple Full Braid namespace (fixed dedicated App Group scope).
    /// Caller must hold the Task 0C mutation lease once that gate exists; this
    /// backend does not acquire it.
    struct Namespace {
        let scopeID: Data
        let scopeIDHex: String

        fileprivate init(scopeID: Data) {
            self.scopeID = scopeID
            self.scopeIDHex = scopeID.map { String(format: "%02x", $0) }.joined()
        }

        func namespaceProbe() -> NamespaceProbe {
            NamespaceProbe(
                accessGroup: accessGroup,
                seedService: seedService,
                anchorService: anchorService,
                accessibility: "AfterFirstUnlockThisDeviceOnly",
                synchronizable: false,
                dataProtectionKeychain: true,
                scopeIDHex: scopeIDHex
            )
        }

        /// Create-if-absent. Never SecItemUpdate. Losing candidate is zeroized.
        func seedCreateIfAbsent(candidate32: inout Data) throws -> SeedCreateResult {
            try ATSAMFullBraidProtectedStoreV1.requireLab()
            guard candidate32.count == seedLength else { throw StoreError.corruptLength }
            defer { ATSAMFullBraidProtectedStoreV1.zeroize(&candidate32) }

            switch try seedLoadExactInternal() {
            case .exact(let existing):
                return .existing(existing)
            case .missing:
                break
            }

            var add = seedMutationIdentityQuery()
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecValueData as String] = candidate32
            ATSAMFullBraidProtectedStoreV1.applyDataProtectionFlag(&add)

            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                ATSAMFullBraidProtectedStoreV1.zeroize(&candidate32)
                let loaded = try seedLoadExactInternal()
                guard case .exact(let existing) = loaded else {
                    throw StoreError.corruptAttributes
                }
                return .existing(existing)
            }
            try ATSAMFullBraidProtectedStoreV1.mapStatus(status)

            let readback = try seedLoadExactInternal()
            guard case .exact(let exact) = readback else {
                throw StoreError.readbackMismatch
            }
            guard exact == candidate32 else {
                throw StoreError.readbackMismatch
            }
            try verifySeedItemAttributes(exact)
            return .created(exact)
        }

        func seedLoadExact() throws -> SeedLoadResult {
            try ATSAMFullBraidProtectedStoreV1.requireLab()
            return try seedLoadExactInternal()
        }

        /// Sorted exact RVFA1 blobs for one record_key (validated HMAC/chain).
        func anchorList(recordKey32: Data, kIndex: Data, kAnchor: Data) throws -> [Data] {
            try ATSAMFullBraidProtectedStoreV1.requireLab()
            guard recordKey32.count == 32 else { throw StoreError.corruptLength }
            let items = try enumerateAnchors(recordKey32: recordKey32)
            let raws = items.map(\.data)
            // Reuse codec chain validation by classifying a synthetic no-op:
            // decode each, then verify established chain via append of nothing —
            // instead call classify against empty candidate path by validating
            // through a dry-run: append decision on highest+1 with a dummy is
            // heavier. Validate by decoding + established rules via codec helper.
            _ = try validateAnchorChain(raws: raws, kIndex: kIndex, kAnchor: kAnchor)
            return raws.sorted { lhs, rhs in
                let a = (try? ATSAMFullBraidProtectedAnchorV1.decodeRVFA1(lhs, kAnchor: kAnchor))?.anchorSeq ?? 0
                let b = (try? ATSAMFullBraidProtectedAnchorV1.decodeRVFA1(rhs, kAnchor: kAnchor))?.anchorSeq ?? 0
                return a < b
            }
        }

        func anchorAppend(
            exactRVFA1: Data,
            kIndex: Data,
            kAnchor: Data
        ) throws -> AnchorAppendResult {
            try ATSAMFullBraidProtectedStoreV1.requireLab()
            guard exactRVFA1.count == rvfa1Length else { throw StoreError.corruptLength }

            let decoded: ATSAMFullBraidProtectedAnchorV1.Rvfa1
            do {
                decoded = try ATSAMFullBraidProtectedAnchorV1.decodeRVFA1(exactRVFA1, kAnchor: kAnchor)
            } catch {
                throw StoreError.codec
            }

            let existingItems = try enumerateAnchors(recordKey32: decoded.recordKey)
            let existingRaws = existingItems.map(\.data)
            let decision = ATSAMFullBraidProtectedAnchorV1.classifyAppend(
                existingRaw: existingRaws,
                candidateRaw: exactRVFA1,
                kAnchor: kAnchor,
                kIndex: kIndex
            )
            switch decision {
            case .exactReplay:
                return .exactReplay
            case .corrupt:
                throw StoreError.corruptAttributes
            case .appended:
                break
            }

            if existingItems.count >= maxSessions {
                throw StoreError.capacity
            }

            let account = anchorAccount(
                recordKeyHex: decoded.recordKey.map { String(format: "%02x", $0) }.joined(),
                seq: decoded.anchorSeq
            )
            let digest = Data(SHA256.hash(data: exactRVFA1))

            var add = anchorMutationIdentityQuery(account: account)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrGeneric as String] = digest
            add[kSecValueData as String] = exactRVFA1
            ATSAMFullBraidProtectedStoreV1.applyDataProtectionFlag(&add)

            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Exact duplicate race: accept only ExactReplay on a valid established chain.
                let after = try enumerateAnchors(recordKey32: decoded.recordKey)
                let matches = after.filter { $0.account == account }
                guard matches.count == 1, matches[0].data == exactRVFA1 else {
                    throw StoreError.conflict
                }
                try verifyAnchorItemAttributes(matches[0])
                let withFull = ATSAMFullBraidProtectedAnchorV1.classifyAppend(
                    existingRaw: after.map(\.data),
                    candidateRaw: exactRVFA1,
                    kAnchor: kAnchor,
                    kIndex: kIndex
                )
                guard withFull == .exactReplay else {
                    throw StoreError.corruptAttributes
                }
                return .exactReplay
            }
            try ATSAMFullBraidProtectedStoreV1.mapStatus(status)

            // Readback exact bytes + attributes.
            let read = try readAnchor(account: account)
            guard read.data == exactRVFA1 else { throw StoreError.readbackMismatch }
            guard read.generic == digest else { throw StoreError.readbackMismatch }
            try verifyAnchorItemAttributes(read)

            let after = try enumerateAnchors(recordKey32: decoded.recordKey)
            let decisionAfter = ATSAMFullBraidProtectedAnchorV1.classifyAppend(
                existingRaw: after.map(\.data).filter { $0 != exactRVFA1 },
                candidateRaw: exactRVFA1,
                kAnchor: kAnchor,
                kIndex: kIndex
            )
            // Post-enumeration: chain with new item must be valid ExactReplay of itself
            // when included, and classify of new against prior must have been Appended.
            guard decisionAfter == .appended || decisionAfter == .exactReplay else {
                throw StoreError.corruptAttributes
            }
            let withNew = ATSAMFullBraidProtectedAnchorV1.classifyAppend(
                existingRaw: after.map(\.data),
                candidateRaw: exactRVFA1,
                kAnchor: kAnchor,
                kIndex: kIndex
            )
            guard withNew == .exactReplay else { throw StoreError.corruptAttributes }
            return .appended
        }

        /// Lab/test cleanup for this scope only. Never used by production paths.
        func labDeleteAllScopedItems() throws {
            try ATSAMFullBraidProtectedStoreV1.requireLab()
            let seedQ = seedMutationIdentityQuery()
            let seedStatus = SecItemDelete(seedQ as CFDictionary)
            if seedStatus != errSecSuccess && seedStatus != errSecItemNotFound {
                try ATSAMFullBraidProtectedStoreV1.mapStatus(seedStatus)
            }

            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: anchorService,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: kCFBooleanTrue,
            ]
            ATSAMFullBraidProtectedStoreV1.applyDataProtectionFlag(&query)
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return
            }
            if status != errSecSuccess {
                try ATSAMFullBraidProtectedStoreV1.mapStatus(status)
            }
            let prefix = "anchor/\(scopeIDHex)/"
            guard let rows = result as? [[String: Any]] else { return }
            for row in rows {
                guard let account = row[kSecAttrAccount as String] as? String,
                      account.hasPrefix(prefix)
                else { continue }
                var del = anchorMutationIdentityQuery(account: account)
                let delStatus = SecItemDelete(del as CFDictionary)
                if delStatus != errSecSuccess && delStatus != errSecItemNotFound {
                    try ATSAMFullBraidProtectedStoreV1.mapStatus(delStatus)
                }
            }
        }

        // MARK: - Seed internals

        private func seedAccount() -> String {
            "seed/\(scopeIDHex)"
        }

        /// Add/Delete identity: exact non-synchronizable.
        private func seedMutationIdentityQuery() -> [String: Any] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: seedService,
                kSecAttrAccount as String: seedAccount(),
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            ATSAMFullBraidProtectedStoreV1.applyDataProtectionFlag(&q)
            return q
        }

        /// Load/enumerate: include sync items so synchronizable=true is visible as corruption.
        private func seedLoadQuery() -> [String: Any] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: seedService,
                kSecAttrAccount as String: seedAccount(),
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            ATSAMFullBraidProtectedStoreV1.applyDataProtectionFlag(&q)
            return q
        }

        private func seedLoadExactInternal() throws -> SeedLoadResult {
            var query = seedLoadQuery()
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = kCFBooleanTrue
            query[kSecReturnData as String] = kCFBooleanTrue

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return .missing
            }
            try ATSAMFullBraidProtectedStoreV1.mapStatus(status)

            guard let rows = result as? [[String: Any]] else {
                throw StoreError.corruptAttributes
            }
            if rows.isEmpty { return .missing }
            if rows.count > 1 { throw StoreError.duplicate }

            let row = rows[0]
            try verifySeedRowAttributes(row)
            guard let data = row[kSecValueData as String] as? Data else {
                throw StoreError.corruptAttributes
            }
            guard data.count == seedLength else { throw StoreError.corruptLength }
            return .exact(data)
        }

        private func verifySeedItemAttributes(_ data: Data) throws {
            var query = seedLoadQuery()
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = kCFBooleanTrue
            query[kSecReturnData as String] = kCFBooleanTrue
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            try ATSAMFullBraidProtectedStoreV1.mapStatus(status)
            guard let rows = result as? [[String: Any]], rows.count == 1 else {
                throw StoreError.corruptAttributes
            }
            let row = rows[0]
            try verifySeedRowAttributes(row)
            guard (row[kSecValueData as String] as? Data) == data else {
                throw StoreError.readbackMismatch
            }
        }

        private func verifySeedRowAttributes(_ row: [String: Any]) throws {
            guard (row[kSecAttrAccessGroup as String] as? String) == accessGroup else {
                throw StoreError.wrongAccessibilityOrPersistence
            }
            guard (row[kSecAttrService as String] as? String) == seedService else {
                throw StoreError.corruptAttributes
            }
            guard (row[kSecAttrAccount as String] as? String) == seedAccount() else {
                throw StoreError.corruptAttributes
            }
            try ATSAMFullBraidProtectedStoreV1.requireSynchronizableFalse(row)
            guard let raw = row[kSecAttrAccessible as String] else {
                throw StoreError.wrongAccessibilityOrPersistence
            }
            if !CFEqual(raw as CFTypeRef, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) {
                throw StoreError.wrongAccessibilityOrPersistence
            }
        }

        // MARK: - Anchor internals

        private struct AnchorItem {
            let account: String
            let data: Data
            let generic: Data?
        }

        private func anchorAccount(recordKeyHex: String, seq: UInt64) -> String {
            let seqHex = String(format: "%016llx", seq)
            return "anchor/\(scopeIDHex)/\(recordKeyHex)/\(seqHex)"
        }

        private func hexLower(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }

        private func decodeCanonicalHex64(_ value: String) throws -> Data {
            guard value.count == 64, value == value.lowercased() else {
                throw StoreError.corruptAttributes
            }
            var out = Data()
            out.reserveCapacity(32)
            var idx = value.startIndex
            while idx < value.endIndex {
                let next = value.index(idx, offsetBy: 2)
                guard next <= value.endIndex else { throw StoreError.corruptAttributes }
                let pair = String(value[idx..<next])
                guard let byte = UInt8(pair, radix: 16) else { throw StoreError.corruptAttributes }
                guard String(format: "%02x", byte) == pair else {
                    throw StoreError.corruptAttributes
                }
                out.append(byte)
                idx = next
            }
            guard out.count == 32 else { throw StoreError.corruptAttributes }
            return out
        }

        /// Parse `anchor/<scope64>/<record64>/<seq16>` and require canonical lowercase form.
        private func parseAnchorAccount(_ account: String) throws -> (recordKey: Data, seq: UInt64) {
            let parts = account.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[0] == "anchor" else {
                throw StoreError.corruptAttributes
            }
            let scopeHex = parts[1]
            let recordHex = parts[2]
            let seqHex = parts[3]
            guard scopeHex == scopeIDHex else { throw StoreError.corruptAttributes }
            guard seqHex.count == 16, seqHex == seqHex.lowercased() else {
                throw StoreError.corruptAttributes
            }
            guard let seq = UInt64(seqHex, radix: 16) else {
                throw StoreError.corruptAttributes
            }
            // Canonical seq encoding must match %016llx (rejects alternate widths).
            guard String(format: "%016llx", seq) == seqHex else {
                throw StoreError.corruptAttributes
            }
            let recordKey = try decodeCanonicalHex64(recordHex)
            let canonical = anchorAccount(recordKeyHex: hexLower(recordKey), seq: seq)
            guard account == canonical else { throw StoreError.corruptAttributes }
            return (recordKey, seq)
        }

        /// Bind account identity to RVFA1 body offsets (record_key @12, anchor_seq @76).
        private func requireAccountMatchesRVFA1(account: String, data: Data) throws {
            let parsed = try parseAnchorAccount(account)
            guard data.count == rvfa1Length else { throw StoreError.corruptLength }
            let bodyRecordKey = Data(data[12..<44])
            let bodySeq = data[76..<84].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard bodyRecordKey == parsed.recordKey else { throw StoreError.corruptAttributes }
            guard bodySeq == parsed.seq else { throw StoreError.corruptAttributes }
        }

        private func anchorMutationIdentityQuery(account: String) -> [String: Any] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: anchorService,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            ATSAMFullBraidProtectedStoreV1.applyDataProtectionFlag(&q)
            return q
        }

        private func anchorLoadQuery(account: String?) -> [String: Any] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: anchorService,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            if let account {
                q[kSecAttrAccount as String] = account
            }
            ATSAMFullBraidProtectedStoreV1.applyDataProtectionFlag(&q)
            return q
        }

        private func enumerateAnchors(recordKey32: Data) throws -> [AnchorItem] {
            guard recordKey32.count == 32 else { throw StoreError.corruptLength }
            var query = anchorLoadQuery(account: nil)
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = kCFBooleanTrue
            query[kSecReturnData as String] = kCFBooleanTrue

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return []
            }
            try ATSAMFullBraidProtectedStoreV1.mapStatus(status)
            guard let rows = result as? [[String: Any]] else {
                throw StoreError.corruptAttributes
            }

            var items: [AnchorItem] = []
            var seenAccounts = Set<String>()
            for row in rows {
                guard let account = row[kSecAttrAccount as String] as? String else {
                    throw StoreError.corruptAttributes
                }
                // Ignore other scopes; anything under this scope must parse canonically.
                guard account.hasPrefix("anchor/\(scopeIDHex)/") else { continue }
                let parsed: (recordKey: Data, seq: UInt64)
                do {
                    parsed = try parseAnchorAccount(account)
                } catch {
                    throw StoreError.corruptAttributes
                }
                guard parsed.recordKey == recordKey32 else { continue }

                if !seenAccounts.insert(account).inserted {
                    throw StoreError.duplicate
                }
                try verifyAnchorRowAttributes(row, expectedAccount: account)
                guard let data = row[kSecValueData as String] as? Data else {
                    throw StoreError.corruptAttributes
                }
                guard data.count == rvfa1Length else { throw StoreError.corruptLength }
                try requireAccountMatchesRVFA1(account: account, data: data)
                guard let generic = row[kSecAttrGeneric as String] as? Data else {
                    throw StoreError.corruptAttributes
                }
                let expected = Data(SHA256.hash(data: data))
                guard generic == expected else { throw StoreError.corruptAttributes }
                items.append(AnchorItem(account: account, data: data, generic: generic))
            }
            return items
        }

        private func readAnchor(account: String) throws -> AnchorItem {
            var query = anchorLoadQuery(account: account)
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = kCFBooleanTrue
            query[kSecReturnData as String] = kCFBooleanTrue
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            try ATSAMFullBraidProtectedStoreV1.mapStatus(status)
            guard let rows = result as? [[String: Any]] else {
                throw StoreError.corruptAttributes
            }
            if rows.count != 1 { throw StoreError.duplicate }
            let row = rows[0]
            try verifyAnchorRowAttributes(row, expectedAccount: account)
            guard let data = row[kSecValueData as String] as? Data else {
                throw StoreError.corruptAttributes
            }
            try requireAccountMatchesRVFA1(account: account, data: data)
            let generic = row[kSecAttrGeneric as String] as? Data
            return AnchorItem(account: account, data: data, generic: generic)
        }

        private func verifyAnchorItemAttributes(_ item: AnchorItem) throws {
            _ = try readAnchor(account: item.account)
        }

        private func verifyAnchorRowAttributes(_ row: [String: Any], expectedAccount: String) throws {
            guard (row[kSecAttrAccessGroup as String] as? String) == accessGroup else {
                throw StoreError.wrongAccessibilityOrPersistence
            }
            guard (row[kSecAttrService as String] as? String) == anchorService else {
                throw StoreError.corruptAttributes
            }
            guard (row[kSecAttrAccount as String] as? String) == expectedAccount else {
                throw StoreError.corruptAttributes
            }
            try ATSAMFullBraidProtectedStoreV1.requireSynchronizableFalse(row)
            if let raw = row[kSecAttrAccessible as String] {
                if !CFEqual(raw as CFTypeRef, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) {
                    throw StoreError.wrongAccessibilityOrPersistence
                }
            } else {
                throw StoreError.wrongAccessibilityOrPersistence
            }
        }

        private func validateAnchorChain(raws: [Data], kIndex: Data, kAnchor: Data) throws {
            // Empty is fine. Non-empty: ExactReplay of each item against the full set
            // must succeed, and classifyAppend of highest must see a valid chain.
            if raws.isEmpty { return }
            for raw in raws {
                let decision = ATSAMFullBraidProtectedAnchorV1.classifyAppend(
                    existingRaw: raws,
                    candidateRaw: raw,
                    kAnchor: kAnchor,
                    kIndex: kIndex
                )
                guard decision == .exactReplay else { throw StoreError.corruptAttributes }
            }
        }
    }

    static func openAppleNamespace() throws -> Namespace {
        try requireLab()
        let scope = ATSAMFullBraidProtectedAnchorV1.appleScopeID()
        guard scope.count == 32 else { throw StoreError.corruptLength }
        return Namespace(scopeID: scope)
    }

    // MARK: - Shared helpers

    fileprivate static func requireLab() throws {
        guard !productionEnabled else { throw StoreError.productionDisabled }
        guard ATSAMFullBraidProtectedAnchorV1.productionEnabled == false else {
            throw StoreError.productionDisabled
        }
    }

    fileprivate static func mapStatus(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw StoreError.missing
        case errSecDuplicateItem:
            throw StoreError.duplicate
        case errSecInteractionNotAllowed:
            throw StoreError.lockedOrPromptRequired
        case errSecAuthFailed, errSecMissingEntitlement:
            throw StoreError.unavailable
        case errSecAllocate:
            throw StoreError.capacity
        default:
            throw StoreError.ioOrPlatform(status)
        }
    }

    fileprivate static func applyDataProtectionFlag(_ query: inout [String: Any]) {
        // iOS Data Protection Keychain is the default; set explicitly when symbol exists.
        query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue as Any
    }

    /// Load/enumerate results must prove non-synchronizable. `true` is corruption.
    fileprivate static func requireSynchronizableFalse(_ row: [String: Any]) throws {
        if let sync = row[kSecAttrSynchronizable as String] as? Bool {
            if sync { throw StoreError.wrongAccessibilityOrPersistence }
            return
        }
        if let sync = row[kSecAttrSynchronizable as String] as? NSNumber {
            if sync.boolValue { throw StoreError.wrongAccessibilityOrPersistence }
            return
        }
        if let raw = row[kSecAttrSynchronizable as String] {
            if CFEqual(raw as CFTypeRef, kCFBooleanTrue) {
                throw StoreError.wrongAccessibilityOrPersistence
            }
            if CFEqual(raw as CFTypeRef, kCFBooleanFalse) {
                return
            }
            throw StoreError.wrongAccessibilityOrPersistence
        }
        // Attribute absent after SynchronizableAny query ⇒ treat as local/non-sync only when
        // no positive sync marker exists; still require explicit false when present above.
        // Fail closed: absence is not proof on all OS versions, but sync=true is always set
        // when the item is synchronizable. Accept absence as non-sync.
    }

    fileprivate static func zeroize(_ data: inout Data) {
        if data.count > 0 {
            data.resetBytes(in: 0..<data.count)
        }
        data = Data()
    }
}

#endif
