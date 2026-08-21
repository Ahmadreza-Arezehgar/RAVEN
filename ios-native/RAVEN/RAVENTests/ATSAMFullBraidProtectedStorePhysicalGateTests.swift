//
//  ATSAMFullBraidProtectedStorePhysicalGateTests.swift
//  RAVENTests — Task 0B.2 physical Keychain gate harness (lab-only).
//
//  Multi-phase, no inter-phase cleanup. Host evidence stores public digests only
//  (never seed bytes). Phase order is enforced by the operator script; this
//  harness still fails closed without a complete run/device-bound expectation
//  bundle for B/C/D/resume.
//
//  Env (forward with TEST_RUNNER_ prefix from xcodebuild):
//    RAVEN_FB_PHYSICAL_GATE_PHASE = A|A_RESUME|B|C|D|cleanup|recovery_cleanup
//    RAVEN_FB_PHYSICAL_GATE_RUN_ID / DEVICE_UDID (required for all phases)
//    RAVEN_FB_PHYSICAL_GATE_EXPECT_SEED_DIGEST / SEQ1 / SEQ2 / CHAIN / SCOPE
//    RAVEN_FB_PHYSICAL_GATE_PLATFORM_HOLD = frozen hold code only (Phase D)
//    RAVEN_FB_PHYSICAL_GATE_ALLOW_SIMULATOR = 1 (lab dry-run only; operator script never sets)
//
//  Operator script:
//    node/scripts/ios_full_braid_protected_anchor_physical_gate.sh
//

import CryptoKit
import Foundation
import Security
import XCTest
@testable import RAVEN

#if !targetEnvironment(macCatalyst)

enum ATSAMFullBraidProtectedStorePhysicalGateV1 {
    static let harnessID = "raven.atsam.full-braid.physical-gate.v1"
    static let resultPrefix = "RAVEN_FB_PHYSICAL_GATE_JSON:"

    /// Frozen Phase D documented-hold codes. Free-form text is rejected.
    static let frozenPlatformHolds: Set<String> = [
        "FULL_BRAID_PHYSICAL_GATE_HOLD_MAIN_APP_CANNOT_RUN_BEFORE_FIRST_UNLOCK_V1",
    ]

    /// Public fixed session material (not a secret). Seed remains Keychain-only.
    static let sessionID: Data = Data(SHA256.hash(data: Data("\(harnessID)/session".utf8)))

    struct Expectation {
        var runID: String?
        var deviceUDID: String?
        var seedDigest: String?
        var seq1Digest: String?
        var seq2Digest: String?
        var chainDigest: String?
        var scopeHex: String?
        var platformHold: String?
    }

    struct PhaseResult: Encodable {
        let harness: String
        let phase: String
        let ok: Bool
        let run_id: String
        let device_udid: String
        let scope_id_hex: String
        let seed_digest_sha256: String?
        let record_key_digest_sha256: String?
        let seq1_digest_sha256: String?
        let seq2_digest_sha256: String?
        let chain_digest_sha256: String?
        let outcome: String
        let detail: String?
        let production_enabled: Bool
        let release_hold: String
        let platform_hold_code: String?
    }

    static func env(_ key: String) -> String? {
        let v = ProcessInfo.processInfo.environment[key]
        guard let v, !v.isEmpty else { return nil }
        return v
    }

    static func digestHex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    static func chainDigest(seqDigests: [String]) -> String {
        let joined = seqDigests.joined(separator: "|").data(using: .utf8) ?? Data()
        return digestHex(joined)
    }

    static func loadExpectation() -> Expectation {
        Expectation(
            runID: env("RAVEN_FB_PHYSICAL_GATE_RUN_ID"),
            deviceUDID: env("RAVEN_FB_PHYSICAL_GATE_DEVICE_UDID"),
            seedDigest: env("RAVEN_FB_PHYSICAL_GATE_EXPECT_SEED_DIGEST"),
            seq1Digest: env("RAVEN_FB_PHYSICAL_GATE_EXPECT_SEQ1_DIGEST"),
            seq2Digest: env("RAVEN_FB_PHYSICAL_GATE_EXPECT_SEQ2_DIGEST"),
            chainDigest: env("RAVEN_FB_PHYSICAL_GATE_EXPECT_CHAIN_DIGEST"),
            scopeHex: env("RAVEN_FB_PHYSICAL_GATE_EXPECT_SCOPE_HEX"),
            platformHold: env("RAVEN_FB_PHYSICAL_GATE_PLATFORM_HOLD")
        )
    }

    static func requireRunDevice(_ expect: Expectation) throws -> (runID: String, deviceUDID: String) {
        guard let runID = expect.runID, !runID.isEmpty else {
            XCTFail("missing RAVEN_FB_PHYSICAL_GATE_RUN_ID")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
        guard let device = expect.deviceUDID, !device.isEmpty else {
            XCTFail("missing RAVEN_FB_PHYSICAL_GATE_DEVICE_UDID")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
        return (runID, device)
    }

    /// Complete Phase-C evidence bundle bound to the same run/device.
    static func requirePhaseCEvidenceBundle(_ expect: Expectation) throws -> (
        runID: String,
        deviceUDID: String,
        scopeHex: String,
        seedDigest: String,
        seq1Digest: String,
        seq2Digest: String,
        chainDigest: String
    ) {
        let rd = try requireRunDevice(expect)
        guard let scope = expect.scopeHex, scope.count == 64,
              let seed = expect.seedDigest, seed.count == 64,
              let seq1 = expect.seq1Digest, seq1.count == 64,
              let seq2 = expect.seq2Digest, seq2.count == 64,
              let chain = expect.chainDigest, chain.count == 64
        else {
            XCTFail("Phase D/C requires complete Phase-C evidence (scope/seed/seq1/seq2/chain digests)")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
        let recomputed = chainDigest(seqDigests: [seq1, seq2])
        try requireEqual(recomputed, chain, "chain digest must bind seq1|seq2")
        return (rd.runID, rd.deviceUDID, scope, seed, seq1, seq2, chain)
    }

    static func emit(_ result: PhaseResult) throws {
        guard result.ok else {
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
        let data = try JSONEncoder().encode(result)
        guard let line = String(data: data, encoding: .utf8) else {
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
        fputs("\(resultPrefix)\(line)\n", stdout)
        fflush(stdout)
        fputs("\(resultPrefix)\(line)\n", stderr)
        fflush(stderr)
    }

    /// Fail-fast: XCTAssert continues after failure and can emit ok=true — never use for result-governing checks.
    static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard condition() else {
            XCTFail(message, file: file, line: line)
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
    }

    static func requireEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard actual == expected else {
            let detail = message.isEmpty
                ? "expected \(expected), got \(actual)"
                : "\(message) (expected \(expected), got \(actual))"
            XCTFail(detail, file: file, line: line)
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
    }

    static func requireAppended(
        _ result: ATSAMFullBraidProtectedStoreV1.AnchorAppendResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try requireEqual(result, .appended, "anchorAppend must return .appended", file: file, line: line)
    }

    static func requireDeviceOrLabAllow() throws {
        #if targetEnvironment(simulator)
        if env("RAVEN_FB_PHYSICAL_GATE_ALLOW_SIMULATOR") != "1" {
            throw XCTSkip("physical gate requires a real iPhone (or ALLOW_SIMULATOR=1 dry-run)")
        }
        #endif
    }

    static func openNS() throws -> ATSAMFullBraidProtectedStoreV1.Namespace {
        try ATSAMFullBraidProtectedStoreV1.openAppleNamespace()
    }

    static func loadSeedExact(_ ns: ATSAMFullBraidProtectedStoreV1.Namespace) throws -> Data {
        switch try ns.seedLoadExact() {
        case .exact(let seed):
            return seed
        case .missing:
            throw ATSAMFullBraidProtectedStoreV1.StoreError.missing
        }
    }

    static func withKeys<T>(
        seed: Data,
        _ body: (ATSAMFullBraidProtectedAnchorV1.DerivedKeys, Data) throws -> T
    ) throws -> T {
        var keys = try ATSAMFullBraidProtectedAnchorV1.deriveStoreKeys(seed32: seed)
        defer { keys.zeroize() }
        let recordKey = try ATSAMFullBraidProtectedAnchorV1.recordKey(
            kIndex: keys.kIndex,
            sessionID: sessionID
        )
        return try body(keys, recordKey)
    }

    static func encodeHead(
        recordKey: Data,
        anchorSeq: UInt64,
        generation: UInt64,
        clearedDigestLabel: String,
        clearedStoreRevision: UInt64,
        transitionLabel: String?,
        kAnchor: Data
    ) throws -> Data {
        let cleared = Data(SHA256.hash(data: Data("\(harnessID)/cleared/\(clearedDigestLabel)".utf8)))
        let transition: Data
        if let transitionLabel {
            transition = Data(SHA256.hash(data: Data("\(harnessID)/transition/\(transitionLabel)".utf8)))
        } else {
            transition = Data(count: 32)
        }
        return try ATSAMFullBraidProtectedAnchorV1.encodeRVFA1(
            .init(
                status: .head,
                role: 0,
                recordKey: recordKey,
                sessionID: sessionID,
                anchorSeq: anchorSeq,
                generation: generation,
                clearedStateDigest: cleared,
                clearedStoreRevision: clearedStoreRevision,
                transitionID: transition,
                horizonMS: 0,
                hmac: Data(count: 32)
            ),
            kAnchor: kAnchor
        )
    }

    // MARK: - Scope emptiness / preflight (SynchronizableAny)

    /// Enumerate seed + all anchor accounts under this scope with SynchronizableAny.
    static func countScopedItems(_ ns: ATSAMFullBraidProtectedStoreV1.Namespace) throws -> (
        seedRows: Int,
        anchorAccounts: [String]
    ) {
        let seedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ATSAMFullBraidProtectedStoreV1.seedService,
            kSecAttrAccount as String: "seed/\(ns.scopeIDHex)",
            kSecAttrAccessGroup as String: ATSAMFullBraidProtectedStoreV1.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
        var seedResult: CFTypeRef?
        let seedStatus = SecItemCopyMatching(seedQuery as CFDictionary, &seedResult)
        let seedRows: Int
        switch seedStatus {
        case errSecItemNotFound:
            seedRows = 0
        case errSecSuccess:
            if let rows = seedResult as? [[String: Any]] {
                seedRows = rows.count
            } else if seedResult != nil {
                seedRows = 1
            } else {
                seedRows = 0
            }
        default:
            XCTFail("seed SynchronizableAny query failed: \(seedStatus)")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.ioOrPlatform(seedStatus)
        }

        let anchorQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ATSAMFullBraidProtectedStoreV1.anchorService,
            kSecAttrAccessGroup as String: ATSAMFullBraidProtectedStoreV1.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
        var anchorResult: CFTypeRef?
        let anchorStatus = SecItemCopyMatching(anchorQuery as CFDictionary, &anchorResult)
        var accounts: [String] = []
        switch anchorStatus {
        case errSecItemNotFound:
            break
        case errSecSuccess:
            let prefix = "anchor/\(ns.scopeIDHex)/"
            if let rows = anchorResult as? [[String: Any]] {
                for row in rows {
                    if let account = row[kSecAttrAccount as String] as? String,
                       account.hasPrefix(prefix)
                    {
                        accounts.append(account)
                    }
                }
            }
        default:
            XCTFail("anchor SynchronizableAny query failed: \(anchorStatus)")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.ioOrPlatform(anchorStatus)
        }
        return (seedRows, accounts)
    }

    static func requireScopeEmpty(_ ns: ATSAMFullBraidProtectedStoreV1.Namespace, context: String) throws {
        let counted = try countScopedItems(ns)
        try require(counted.seedRows == 0, "\(context): seed rows remain under SynchronizableAny")
        try require(
            counted.anchorAccounts.isEmpty,
            "\(context): anchor leftovers under SynchronizableAny: \(counted.anchorAccounts)"
        )
    }

    // MARK: - Phases

    /// New physical run: clean preflight + require SecItemAdd Created (not Existing).
    static func runPhaseA(expect: Expectation) throws -> PhaseResult {
        let rd = try requireRunDevice(expect)
        let ns = try openNS()
        try requireScopeEmpty(ns, context: "Phase A preflight")

        var candidate = Data(count: 32)
        let status = candidate.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ATSAMFullBraidProtectedStoreV1.StoreError.ioOrPlatform(status)
        }
        let created = try ns.seedCreateIfAbsent(candidate32: &candidate)
        let seed: Data
        switch created {
        case .created(let s):
            seed = s
        case .existing:
            XCTFail("Phase A requires Created after clean preflight; got Existing — use A_RESUME or recovery_cleanup")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.duplicate
        }
        let seedDigest = digestHex(seed)
        return try withKeys(seed: seed) { keys, recordKey in
            let seq1 = try encodeHead(
                recordKey: recordKey,
                anchorSeq: 1,
                generation: 1,
                clearedDigestLabel: "seq1",
                clearedStoreRevision: 7,
                transitionLabel: nil,
                kAnchor: keys.kAnchor
            )
            try requireAppended(
                try ns.anchorAppend(exactRVFA1: seq1, kIndex: keys.kIndex, kAnchor: keys.kAnchor)
            )
            let listed = try ns.anchorList(
                recordKey32: recordKey,
                kIndex: keys.kIndex,
                kAnchor: keys.kAnchor
            )
            try requireEqual(listed.count, 1)
            try requireEqual(listed[0], seq1)
            let seq1Digest = digestHex(seq1)
            let chain = chainDigest(seqDigests: [seq1Digest])
            return PhaseResult(
                harness: harnessID,
                phase: "A",
                ok: true,
                run_id: rd.runID,
                device_udid: rd.deviceUDID,
                scope_id_hex: ns.scopeIDHex,
                seed_digest_sha256: seedDigest,
                record_key_digest_sha256: digestHex(recordKey),
                seq1_digest_sha256: seq1Digest,
                seq2_digest_sha256: nil,
                chain_digest_sha256: chain,
                outcome: "CREATED_SEED_AND_SEQ1",
                detail: nil,
                production_enabled: ATSAMFullBraidProtectedStoreV1.productionEnabled,
                release_hold: ATSAMFullBraidProtectedStoreV1.releaseHold,
                platform_hold_code: nil
            )
        }
    }

    /// Idempotent resume of Phase A evidence for the same run/device (exact replay only).
    static func runPhaseAResume(expect: Expectation) throws -> PhaseResult {
        let rd = try requireRunDevice(expect)
        guard let expectSeed = expect.seedDigest, expectSeed.count == 64,
              let expectSeq1 = expect.seq1Digest, expectSeq1.count == 64,
              let expectScope = expect.scopeHex, expectScope.count == 64
        else {
            XCTFail("A_RESUME requires scope/seed/seq1 digests from the same run")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
        let ns = try openNS()
        try requireEqual(ns.scopeIDHex, expectScope)
        let seed = try loadSeedExact(ns)
        let seedDigest = digestHex(seed)
        try requireEqual(seedDigest, expectSeed)

        return try withKeys(seed: seed) { keys, recordKey in
            let listed = try ns.anchorList(
                recordKey32: recordKey,
                kIndex: keys.kIndex,
                kAnchor: keys.kAnchor
            )
            try requireEqual(listed.count, 1, "A_RESUME expects exactly seq1 present")
            let seq1Digest = digestHex(listed[0])
            try requireEqual(seq1Digest, expectSeq1)
            try requireEqual(
                try ns.anchorAppend(exactRVFA1: listed[0], kIndex: keys.kIndex, kAnchor: keys.kAnchor),
                .exactReplay
            )
            let chain = chainDigest(seqDigests: [seq1Digest])
            return PhaseResult(
                harness: harnessID,
                phase: "A_RESUME",
                ok: true,
                run_id: rd.runID,
                device_udid: rd.deviceUDID,
                scope_id_hex: ns.scopeIDHex,
                seed_digest_sha256: seedDigest,
                record_key_digest_sha256: digestHex(recordKey),
                seq1_digest_sha256: seq1Digest,
                seq2_digest_sha256: nil,
                chain_digest_sha256: chain,
                outcome: "RESUMED_SEED_AND_SEQ1_EXACT",
                detail: nil,
                production_enabled: false,
                release_hold: ATSAMFullBraidProtectedStoreV1.releaseHold,
                platform_hold_code: nil
            )
        }
    }

    static func runPhaseB(expect: Expectation) throws -> PhaseResult {
        let rd = try requireRunDevice(expect)
        guard let expectSeed = expect.seedDigest, expectSeed.count == 64,
              let expectSeq1 = expect.seq1Digest, expectSeq1.count == 64,
              let expectScope = expect.scopeHex, expectScope.count == 64
        else {
            XCTFail("Phase B requires Phase A evidence digests")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
        let ns = try openNS()
        try requireEqual(ns.scopeIDHex, expectScope)
        let seed = try loadSeedExact(ns)
        let seedDigest = digestHex(seed)
        try requireEqual(seedDigest, expectSeed)

        return try withKeys(seed: seed) { keys, recordKey in
            let listed = try ns.anchorList(
                recordKey32: recordKey,
                kIndex: keys.kIndex,
                kAnchor: keys.kAnchor
            )
            try requireEqual(listed.count, 1, "Phase B expects exactly seq1 before append")
            let seq1Digest = digestHex(listed[0])
            try requireEqual(seq1Digest, expectSeq1)

            let seq2 = try encodeHead(
                recordKey: recordKey,
                anchorSeq: 2,
                generation: 2,
                clearedDigestLabel: "seq2",
                clearedStoreRevision: 8,
                transitionLabel: "seq1-to-seq2",
                kAnchor: keys.kAnchor
            )
            try requireAppended(
                try ns.anchorAppend(exactRVFA1: seq2, kIndex: keys.kIndex, kAnchor: keys.kAnchor)
            )
            let after = try ns.anchorList(
                recordKey32: recordKey,
                kIndex: keys.kIndex,
                kAnchor: keys.kAnchor
            )
            try requireEqual(after.count, 2)
            let d1 = digestHex(after[0])
            let d2 = digestHex(after[1])
            try requireEqual(d1, expectSeq1)
            let chain = chainDigest(seqDigests: [d1, d2])
            return PhaseResult(
                harness: harnessID,
                phase: "B",
                ok: true,
                run_id: rd.runID,
                device_udid: rd.deviceUDID,
                scope_id_hex: ns.scopeIDHex,
                seed_digest_sha256: seedDigest,
                record_key_digest_sha256: digestHex(recordKey),
                seq1_digest_sha256: d1,
                seq2_digest_sha256: d2,
                chain_digest_sha256: chain,
                outcome: "RELAUNCH_MATCH_AND_APPEND_SEQ2",
                detail: nil,
                production_enabled: false,
                release_hold: ATSAMFullBraidProtectedStoreV1.releaseHold,
                platform_hold_code: nil
            )
        }
    }

    static func runPhaseC(expect: Expectation) throws -> PhaseResult {
        let rd = try requireRunDevice(expect)
        guard let expectSeed = expect.seedDigest, expectSeed.count == 64,
              let expectSeq1 = expect.seq1Digest, expectSeq1.count == 64,
              let expectSeq2 = expect.seq2Digest, expectSeq2.count == 64,
              let expectChain = expect.chainDigest, expectChain.count == 64,
              let expectScope = expect.scopeHex, expectScope.count == 64
        else {
            XCTFail("Phase C requires Phase B evidence digests")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }
        let ns = try openNS()
        try requireEqual(ns.scopeIDHex, expectScope)
        let seed = try loadSeedExact(ns)
        let seedDigest = digestHex(seed)
        try requireEqual(seedDigest, expectSeed)

        return try withKeys(seed: seed) { keys, recordKey in
            let listed = try ns.anchorList(
                recordKey32: recordKey,
                kIndex: keys.kIndex,
                kAnchor: keys.kAnchor
            )
            try requireEqual(listed.count, 2)
            let d1 = digestHex(listed[0])
            let d2 = digestHex(listed[1])
            try requireEqual(d1, expectSeq1)
            try requireEqual(d2, expectSeq2)
            let chain = chainDigest(seqDigests: [d1, d2])
            try requireEqual(chain, expectChain)
            return PhaseResult(
                harness: harnessID,
                phase: "C",
                ok: true,
                run_id: rd.runID,
                device_udid: rd.deviceUDID,
                scope_id_hex: ns.scopeIDHex,
                seed_digest_sha256: seedDigest,
                record_key_digest_sha256: digestHex(recordKey),
                seq1_digest_sha256: d1,
                seq2_digest_sha256: d2,
                chain_digest_sha256: chain,
                outcome: "LOCK_UNLOCK_MATCH_NO_REWRITE",
                detail: nil,
                production_enabled: false,
                release_hold: ATSAMFullBraidProtectedStoreV1.releaseHold,
                platform_hold_code: nil
            )
        }
    }

    static func runPhaseD(expect: Expectation) throws -> PhaseResult {
        // Bind to complete Phase-C evidence BEFORE any Keychain probe (blocks empty-state false PASS).
        let bundle = try requirePhaseCEvidenceBundle(expect)
        let ns = try openNS()
        try requireEqual(ns.scopeIDHex, bundle.scopeHex)

        let holdRaw = expect.platformHold
        if let holdRaw {
            guard frozenPlatformHolds.contains(holdRaw) else {
                XCTFail("PLATFORM_HOLD must be a frozen code; got free-form text")
                throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
            }
        }

        do {
            let seed = try loadSeedExact(ns)
            let seedDigest = digestHex(seed)
            try requireEqual(seedDigest, bundle.seedDigest)

            return try withKeys(seed: seed) { keys, recordKey in
                let listed = try ns.anchorList(
                    recordKey32: recordKey,
                    kIndex: keys.kIndex,
                    kAnchor: keys.kAnchor
                )
                try requireEqual(listed.count, 2)
                let d1 = digestHex(listed[0])
                let d2 = digestHex(listed[1])
                try requireEqual(d1, bundle.seq1Digest)
                try requireEqual(d2, bundle.seq2Digest)
                let chain = chainDigest(seqDigests: [d1, d2])
                try requireEqual(chain, bundle.chainDigest)

                guard let hold = holdRaw else {
                    XCTFail(
                        "Keychain accessible; BFU not observed. Reboot before first unlock, "
                            + "or set PLATFORM_HOLD to a frozen code."
                    )
                    throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
                }

                return PhaseResult(
                    harness: harnessID,
                    phase: "D",
                    ok: true,
                    run_id: bundle.runID,
                    device_udid: bundle.deviceUDID,
                    scope_id_hex: ns.scopeIDHex,
                    seed_digest_sha256: seedDigest,
                    record_key_digest_sha256: digestHex(recordKey),
                    seq1_digest_sha256: d1,
                    seq2_digest_sha256: d2,
                    chain_digest_sha256: chain,
                    outcome: "PLATFORM_HOLD_DOCUMENTED",
                    detail: hold,
                    production_enabled: false,
                    release_hold: ATSAMFullBraidProtectedStoreV1.releaseHold,
                    platform_hold_code: hold
                )
            }
        } catch let error as ATSAMFullBraidProtectedStoreV1.StoreError
            where error == .lockedOrPromptRequired
        {
            // Locked only counts after Phase-C bundle + scope binding already verified above.
            return PhaseResult(
                harness: harnessID,
                phase: "D",
                ok: true,
                run_id: bundle.runID,
                device_udid: bundle.deviceUDID,
                scope_id_hex: ns.scopeIDHex,
                seed_digest_sha256: bundle.seedDigest,
                record_key_digest_sha256: nil,
                seq1_digest_sha256: bundle.seq1Digest,
                seq2_digest_sha256: bundle.seq2Digest,
                chain_digest_sha256: bundle.chainDigest,
                outcome: "BFU_LOCKED_OR_PROMPT_REQUIRED",
                detail: error.description,
                production_enabled: false,
                release_hold: ATSAMFullBraidProtectedStoreV1.releaseHold,
                platform_hold_code: holdRaw
            )
        }
    }

    static func runCleanup(expect: Expectation, phaseName: String) throws -> PhaseResult {
        let rd = try requireRunDevice(expect)
        let ns = try openNS()
        if let scope = expect.scopeHex {
            try requireEqual(ns.scopeIDHex, scope)
        }
        try ns.labDeleteAllScopedItems()

        // Mutation-identity delete may miss synchronizable=true leftovers — prove empty via Any.
        let counted = try countScopedItems(ns)
        try require(counted.seedRows == 0, "cleanup: seed still present under SynchronizableAny")
        try require(
            counted.anchorAccounts.isEmpty,
            "cleanup: anchor leftovers under SynchronizableAny: \(counted.anchorAccounts)"
        )

        return PhaseResult(
            harness: harnessID,
            phase: phaseName,
            ok: true,
            run_id: rd.runID,
            device_udid: rd.deviceUDID,
            scope_id_hex: ns.scopeIDHex,
            seed_digest_sha256: nil,
            record_key_digest_sha256: nil,
            seq1_digest_sha256: nil,
            seq2_digest_sha256: nil,
            chain_digest_sha256: nil,
            outcome: "SCOPED_ITEMS_EMPTY_SYNCHRONIZABLE_ANY",
            detail: nil,
            production_enabled: false,
            release_hold: ATSAMFullBraidProtectedStoreV1.releaseHold,
            platform_hold_code: nil
        )
    }
}

final class ATSAMFullBraidProtectedStorePhysicalGateTests: XCTestCase {
    func testPhysicalGatePhase() throws {
        let phase = ATSAMFullBraidProtectedStorePhysicalGateV1.env("RAVEN_FB_PHYSICAL_GATE_PHASE")
        guard let phase else {
            throw XCTSkip(
                "Set RAVEN_FB_PHYSICAL_GATE_PHASE via operator script"
            )
        }

        try ATSAMFullBraidProtectedStorePhysicalGateV1.requireDeviceOrLabAllow()
        try ATSAMFullBraidProtectedStorePhysicalGateV1.require(
            !ATSAMFullBraidProtectedStoreV1.productionEnabled,
            "production must stay off"
        )
        try ATSAMFullBraidProtectedStorePhysicalGateV1.requireEqual(
            ATSAMFullBraidProtectedStoreV1.releaseHold,
            "FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED"
        )

        let expect = ATSAMFullBraidProtectedStorePhysicalGateV1.loadExpectation()
        let result: ATSAMFullBraidProtectedStorePhysicalGateV1.PhaseResult
        switch phase {
        case "A":
            result = try ATSAMFullBraidProtectedStorePhysicalGateV1.runPhaseA(expect: expect)
        case "A_RESUME":
            result = try ATSAMFullBraidProtectedStorePhysicalGateV1.runPhaseAResume(expect: expect)
        case "B":
            result = try ATSAMFullBraidProtectedStorePhysicalGateV1.runPhaseB(expect: expect)
        case "C":
            result = try ATSAMFullBraidProtectedStorePhysicalGateV1.runPhaseC(expect: expect)
        case "D":
            result = try ATSAMFullBraidProtectedStorePhysicalGateV1.runPhaseD(expect: expect)
        case "cleanup":
            result = try ATSAMFullBraidProtectedStorePhysicalGateV1.runCleanup(
                expect: expect,
                phaseName: "cleanup"
            )
        case "recovery_cleanup":
            result = try ATSAMFullBraidProtectedStorePhysicalGateV1.runCleanup(
                expect: expect,
                phaseName: "recovery_cleanup"
            )
        default:
            XCTFail("unknown phase \(phase)")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.corruptAttributes
        }

        // Emit only after fail-fast phase body succeeds — never after a thrown check.
        try ATSAMFullBraidProtectedStorePhysicalGateV1.emit(result)
        try ATSAMFullBraidProtectedStorePhysicalGateV1.require(result.ok, result.detail ?? result.outcome)
    }

    /// Simulator-only: duplicate seq2 must throw before any success JSON emit.
    func testPhaseBDuplicateSeq2ThrowsWithoutSuccessEmit() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("duplicate-seq2 fail-fast negative is simulator-only (protects physical Keychain evidence)")
        #endif
        let ns = try ATSAMFullBraidProtectedStoreV1.openAppleNamespace()
        try ns.labDeleteAllScopedItems()
        defer { try? ns.labDeleteAllScopedItems() }

        var candidate = Data(count: 32)
        let status = candidate.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ATSAMFullBraidProtectedStoreV1.StoreError.ioOrPlatform(status)
        }
        let created = try ns.seedCreateIfAbsent(candidate32: &candidate)
        guard case .created(let seed) = created else {
            XCTFail("expected Created seed")
            throw ATSAMFullBraidProtectedStoreV1.StoreError.duplicate
        }
        let seedDigest = ATSAMFullBraidProtectedStorePhysicalGateV1.digestHex(seed)

        let seq1Digest: String
        let seq2Digest: String
        do {
            var keys = try ATSAMFullBraidProtectedAnchorV1.deriveStoreKeys(seed32: seed)
            defer { keys.zeroize() }
            let recordKey = try ATSAMFullBraidProtectedAnchorV1.recordKey(
                kIndex: keys.kIndex,
                sessionID: ATSAMFullBraidProtectedStorePhysicalGateV1.sessionID
            )
            let seq1 = try ATSAMFullBraidProtectedStorePhysicalGateV1.encodeHead(
                recordKey: recordKey,
                anchorSeq: 1,
                generation: 1,
                clearedDigestLabel: "seq1",
                clearedStoreRevision: 7,
                transitionLabel: nil,
                kAnchor: keys.kAnchor
            )
            try ATSAMFullBraidProtectedStorePhysicalGateV1.requireAppended(
                try ns.anchorAppend(exactRVFA1: seq1, kIndex: keys.kIndex, kAnchor: keys.kAnchor)
            )
            let seq2 = try ATSAMFullBraidProtectedStorePhysicalGateV1.encodeHead(
                recordKey: recordKey,
                anchorSeq: 2,
                generation: 2,
                clearedDigestLabel: "seq2",
                clearedStoreRevision: 8,
                transitionLabel: "seq1-to-seq2",
                kAnchor: keys.kAnchor
            )
            try ATSAMFullBraidProtectedStorePhysicalGateV1.requireAppended(
                try ns.anchorAppend(exactRVFA1: seq2, kIndex: keys.kIndex, kAnchor: keys.kAnchor)
            )
            seq1Digest = ATSAMFullBraidProtectedStorePhysicalGateV1.digestHex(seq1)
            seq2Digest = ATSAMFullBraidProtectedStorePhysicalGateV1.digestHex(seq2)
            _ = seq2Digest
        }

        let expect = ATSAMFullBraidProtectedStorePhysicalGateV1.Expectation(
            runID: "lab-dup-seq2",
            deviceUDID: "simulator-lab",
            seedDigest: seedDigest,
            seq1Digest: seq1Digest,
            seq2Digest: nil,
            chainDigest: nil,
            scopeHex: ns.scopeIDHex,
            platformHold: nil
        )

        // require() XCTFails before throw (device harness diagnostics). Absorb that
        // expected failure so this negative can prove throw + no success emit.
        var emittedOk = false
        XCTExpectFailure("duplicate seq2 must fail-fast before success emit") {
            do {
                let result = try ATSAMFullBraidProtectedStorePhysicalGateV1.runPhaseB(expect: expect)
                // Must not reach: a returned PhaseResult would allow emit(ok:true).
                try ATSAMFullBraidProtectedStorePhysicalGateV1.emit(result)
                emittedOk = true
            } catch {
                // Expected: count!=1 throws before PhaseResult / emit.
            }
        }
        XCTAssertFalse(emittedOk, "duplicate seq2 must not emit RAVEN_FB_PHYSICAL_GATE_JSON ok=true")
    }
}

#endif
