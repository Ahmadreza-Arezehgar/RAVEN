//
//  ATSAMFullBraidProtectedStoreV1Tests.swift
//  RAVENTests — Task 0B.2 Apple Keychain backend (lab-only).
//
//  Signed simulator: API/ordering/idempotency.
//  Physical device checklist:
//    node/scripts/ios_full_braid_protected_anchor_physical_device_checklist.md
//

import CryptoKit
import Foundation
import Security
import XCTest
@testable import RAVEN

#if !targetEnvironment(macCatalyst)

final class ATSAMFullBraidProtectedStoreV1Tests: XCTestCase {
    private var ns: ATSAMFullBraidProtectedStoreV1.Namespace!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ns = try ATSAMFullBraidProtectedStoreV1.openAppleNamespace()
        try ns.labDeleteAllScopedItems()
    }

    override func tearDownWithError() throws {
        try? ns?.labDeleteAllScopedItems()
        ns = nil
        try super.tearDownWithError()
    }

    func testProductionFlagStaysOff() {
        XCTAssertFalse(ATSAMFullBraidProtectedStoreV1.productionEnabled)
        XCTAssertEqual(
            ATSAMFullBraidProtectedStoreV1.releaseHold,
            "FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED"
        )
    }

    func testNamespaceProbeAttributes() throws {
        let probe = ns.namespaceProbe()
        XCTAssertEqual(probe.accessGroup, "group.app.raven.fullbraid")
        XCTAssertEqual(probe.seedService, "app.raven.atsam.full-braid.store.v1")
        XCTAssertEqual(probe.anchorService, "app.raven.atsam.full-braid.anchor.v1")
        XCTAssertEqual(probe.accessibility, "AfterFirstUnlockThisDeviceOnly")
        XCTAssertFalse(probe.synchronizable)
        XCTAssertTrue(probe.dataProtectionKeychain)
        XCTAssertEqual(probe.scopeIDHex.count, 64)
    }

    func testSeedCreateThenExactReload() throws {
        var candidate = Data((0..<32).map { UInt8($0) })
        let created = try ns.seedCreateIfAbsent(candidate32: &candidate)
        guard case .created(let seed) = created else {
            return XCTFail("expected Created")
        }
        XCTAssertEqual(seed.count, 32)
        XCTAssertTrue(candidate.isEmpty || candidate.allSatisfy { $0 == 0 } || candidate.count == 0)

        switch try ns.seedLoadExact() {
        case .exact(let loaded):
            XCTAssertEqual(loaded, seed)
        case .missing:
            XCTFail("seed missing after create")
        }

        var other = Data(repeating: 0xAB, count: 32)
        let second = try ns.seedCreateIfAbsent(candidate32: &other)
        guard case .existing(let existing) = second else {
            return XCTFail("expected Existing on second create")
        }
        XCTAssertEqual(existing, seed)
        XCTAssertNotEqual(existing, Data(repeating: 0xAB, count: 32))
    }

    func testSeedDuplicateRaceConvergesAndZeroizesLoser() throws {
        // Concurrent first-create: two tasks with different candidates must converge
        // on one seed (Created+Existing or Existing+Existing) and wipe losers.
        final class Box: @unchecked Sendable {
            var data: Data
            init(_ data: Data) { self.data = data }
        }
        let boxes = [
            Box(Data(repeating: 0x11, count: 32)),
            Box(Data(repeating: 0x22, count: 32)),
        ]
        let ready = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let done = expectation(description: "seed-race")
        done.expectedFulfillmentCount = 2
        let lock = NSLock()
        var outcomes: [ATSAMFullBraidProtectedStoreV1.SeedCreateResult] = []
        var errors: [Error] = []

        for i in 0..<2 {
            ready.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                ready.leave()
                start.wait()
                do {
                    let local = try ATSAMFullBraidProtectedStoreV1.openAppleNamespace()
                    var candidate = boxes[i].data
                    let result = try local.seedCreateIfAbsent(candidate32: &candidate)
                    boxes[i].data = candidate
                    lock.lock()
                    outcomes.append(result)
                    lock.unlock()
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
                done.fulfill()
            }
        }
        // Both workers parked at start; release together.
        ready.wait()
        start.signal()
        start.signal()
        wait(for: [done], timeout: 15)

        XCTAssertTrue(errors.isEmpty, "race errors: \(errors)")
        XCTAssertEqual(outcomes.count, 2)

        let seeds: [Data] = outcomes.map { outcome in
            switch outcome {
            case .created(let s), .existing(let s):
                return s
            }
        }
        XCTAssertEqual(seeds[0], seeds[1])
        XCTAssertEqual(seeds[0].count, 32)
        let createdCount = outcomes.reduce(0) { partial, outcome in
            if case .created = outcome { return partial + 1 }
            return partial
        }
        XCTAssertLessThanOrEqual(createdCount, 1)
        // Both API returns zeroize their candidate buffers.
        for box in boxes {
            XCTAssertTrue(box.data.isEmpty || box.data.allSatisfy { $0 == 0 })
        }
        switch try ns.seedLoadExact() {
        case .exact(let loaded):
            XCTAssertEqual(loaded, seeds[0])
        case .missing:
            XCTFail("seed missing after race")
        }
    }

    func testAnchorAccountMustBindRecordKeyAndSeq() throws {
        var seedBytes = Data(repeating: 0x11, count: 32)
        _ = try ns.seedCreateIfAbsent(candidate32: &seedBytes)
        guard case .exact(let seed) = try ns.seedLoadExact() else {
            return XCTFail("seed required")
        }
        var keys = try ATSAMFullBraidProtectedAnchorV1.deriveStoreKeys(seed32: seed)
        defer { keys.zeroize() }

        let sessionA = Data(repeating: 0x22, count: 32)
        let sessionB = Data(repeating: 0x23, count: 32)
        let rkA = try ATSAMFullBraidProtectedAnchorV1.recordKey(kIndex: keys.kIndex, sessionID: sessionA)
        let rkB = try ATSAMFullBraidProtectedAnchorV1.recordKey(kIndex: keys.kIndex, sessionID: sessionB)

        let rvfaB = try ATSAMFullBraidProtectedAnchorV1.encodeRVFA1(
            .init(
                status: .head,
                role: 0,
                recordKey: rkB,
                sessionID: sessionB,
                anchorSeq: 1,
                generation: 1,
                clearedStateDigest: Data(repeating: 0x33, count: 32),
                clearedStoreRevision: 7,
                transitionID: Data(count: 32),
                horizonMS: 0,
                hmac: Data(count: 32)
            ),
            kAnchor: keys.kAnchor
        )

        // Plant RVFA1(B) under account identity for A (binding mismatch).
        let scopeHex = ns.scopeIDHex
        let accountA = "anchor/\(scopeHex)/\(rkA.map { String(format: "%02x", $0) }.joined())/0000000000000001"
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ATSAMFullBraidProtectedStoreV1.anchorService,
            kSecAttrAccount as String: accountA,
            kSecAttrAccessGroup as String: ATSAMFullBraidProtectedStoreV1.accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrGeneric as String: Data(SHA256.hash(data: rvfaB)),
            kSecValueData as String: rvfaB,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: ATSAMFullBraidProtectedStoreV1.anchorService,
                kSecAttrAccount as String: accountA,
                kSecAttrAccessGroup as String: ATSAMFullBraidProtectedStoreV1.accessGroup,
            ] as CFDictionary)
        }

        XCTAssertThrowsError(
            try ns.anchorList(recordKey32: rkA, kIndex: keys.kIndex, kAnchor: keys.kAnchor)
        )
    }

    func testAnchorAppendReplayConflictAndGap() throws {
        var seedBytes = Data(repeating: 0x11, count: 32)
        _ = try ns.seedCreateIfAbsent(candidate32: &seedBytes)
        guard case .exact(let seed) = try ns.seedLoadExact() else {
            return XCTFail("seed required")
        }
        var keys = try ATSAMFullBraidProtectedAnchorV1.deriveStoreKeys(seed32: seed)
        defer { keys.zeroize() }

        let session = Data(repeating: 0x22, count: 32)
        let rk = try ATSAMFullBraidProtectedAnchorV1.recordKey(kIndex: keys.kIndex, sessionID: session)

        let seq1 = try ATSAMFullBraidProtectedAnchorV1.encodeRVFA1(
            .init(
                status: .head,
                role: 0,
                recordKey: rk,
                sessionID: session,
                anchorSeq: 1,
                generation: 1,
                clearedStateDigest: Data(repeating: 0x33, count: 32),
                clearedStoreRevision: 7,
                transitionID: Data(count: 32),
                horizonMS: 0,
                hmac: Data(count: 32)
            ),
            kAnchor: keys.kAnchor
        )
        let seq2 = try ATSAMFullBraidProtectedAnchorV1.encodeRVFA1(
            .init(
                status: .head,
                role: 0,
                recordKey: rk,
                sessionID: session,
                anchorSeq: 2,
                generation: 2,
                clearedStateDigest: Data(repeating: 0x44, count: 32),
                clearedStoreRevision: 8,
                transitionID: Data(repeating: 0x55, count: 32),
                horizonMS: 0,
                hmac: Data(count: 32)
            ),
            kAnchor: keys.kAnchor
        )
        let conflict = try ATSAMFullBraidProtectedAnchorV1.encodeRVFA1(
            .init(
                status: .head,
                role: 0,
                recordKey: rk,
                sessionID: session,
                anchorSeq: 2,
                generation: 2,
                clearedStateDigest: Data(repeating: 0xAA, count: 32),
                clearedStoreRevision: 8,
                transitionID: Data(repeating: 0x55, count: 32),
                horizonMS: 0,
                hmac: Data(count: 32)
            ),
            kAnchor: keys.kAnchor
        )
        let gap = try ATSAMFullBraidProtectedAnchorV1.encodeRVFA1(
            .init(
                status: .head,
                role: 0,
                recordKey: rk,
                sessionID: session,
                anchorSeq: 4,
                generation: 4,
                clearedStateDigest: Data(repeating: 0x66, count: 32),
                clearedStoreRevision: 9,
                transitionID: Data(repeating: 0x77, count: 32),
                horizonMS: 0,
                hmac: Data(count: 32)
            ),
            kAnchor: keys.kAnchor
        )

        XCTAssertEqual(
            try ns.anchorAppend(exactRVFA1: seq1, kIndex: keys.kIndex, kAnchor: keys.kAnchor),
            .appended
        )
        XCTAssertEqual(
            try ns.anchorAppend(exactRVFA1: seq1, kIndex: keys.kIndex, kAnchor: keys.kAnchor),
            .exactReplay
        )
        XCTAssertEqual(
            try ns.anchorAppend(exactRVFA1: seq2, kIndex: keys.kIndex, kAnchor: keys.kAnchor),
            .appended
        )
        XCTAssertThrowsError(
            try ns.anchorAppend(exactRVFA1: conflict, kIndex: keys.kIndex, kAnchor: keys.kAnchor)
        )
        XCTAssertThrowsError(
            try ns.anchorAppend(exactRVFA1: gap, kIndex: keys.kIndex, kAnchor: keys.kAnchor)
        )

        let listed = try ns.anchorList(recordKey32: rk, kIndex: keys.kIndex, kAnchor: keys.kAnchor)
        XCTAssertEqual(listed, [seq1, seq2])
    }

    func testSeedAndAnchorUseDedicatedAccessGroupOnly() throws {
        var candidate = Data(repeating: 0xCD, count: 32)
        _ = try ns.seedCreateIfAbsent(candidate32: &candidate)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ATSAMFullBraidProtectedStoreV1.seedService,
            kSecAttrAccessGroup as String: ATSAMFullBraidProtectedStoreV1.accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: kCFBooleanTrue,
            kSecReturnData as String: kCFBooleanTrue,
        ]
        query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue as Any
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let row = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(row[kSecAttrAccessGroup as String] as? String, "group.app.raven.fullbraid")
        XCTAssertTrue(CFEqual(
            row[kSecAttrAccessible as String] as CFTypeRef,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ))
    }
}

#endif
