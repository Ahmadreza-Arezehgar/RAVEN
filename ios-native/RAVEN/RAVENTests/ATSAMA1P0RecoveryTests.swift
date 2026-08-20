//
//  ATSAMA1P0RecoveryTests.swift
//  RAVENTests
//
//  Task 9B P0: crash recovery, gates, and durable reopen per journal type.
//

#if DEBUG

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

private typealias Endpoint = ATSAMEndpointTransactionV1
private typealias TxError = Endpoint.TransactionError

@MainActor
final class ATSAMA1P0RecoveryTests: XCTestCase {

    private let labDefaultsKey = "raven.lab.test_a"
    private var priorLabGate: Bool?

    override func setUpWithError() throws {
        priorLabGate = UserDefaults.standard.object(forKey: labDefaultsKey) as? Bool
        UserDefaults.standard.set(true, forKey: labDefaultsKey)
    }

    override func tearDownWithError() throws {
        ATSAMPairInitAcceptService.resetAcceptTestHooks()
        ATSAMPrekeyLifecycleStore.shared.resetForTesting(memoryOnly: false)
        ATSAMPrekeyLifecycleStore.shared.resetForTesting(memoryOnly: true)
        try? ATSAMLabTrustStore.removeImportedPeerCertsForTesting()
        try? KeychainProtectedSessionStore.deleteAllSessionsForTesting()
        if let priorLabGate {
            UserDefaults.standard.set(priorLabGate, forKey: labDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: labDefaultsKey)
        }
    }

    // MARK: - §5.1 / §5.4 Send two-phase crash recovery

    func testSendProtectedHeadTwoPhaseCrashRecoveryMatrix() async throws {
        let outboundPoints: [Endpoint.CrashPoint] = [
            .beforeOutboundProtectedReplacement,
            .afterOutboundProtectedReplacement,
            .beforeOutboundDatabaseCommit,
            .afterOutboundDatabaseCommit,
            .beforeOutboundJournalClear,
            .afterOutboundJournalClear,
        ]

        for point in outboundPoints {
            P0StubOutboundMaterializer.lastPackedEnvelope = nil
            P0StubOutboundMaterializer.lastObjectDigest = nil
            let harness = try P0SendHarness()
            do {
                _ = try await harness.sender(faults: P0OneShotFaults(point)).send(
                    text: Data("p0-send-body".utf8),
                    session: harness.boundSession(),
                    createdAtMs: harness.nowMs,
                    expiresAtMs: harness.nowMs + 60_000
                )
                XCTFail("expected crash at \(point.rawValue)")
            } catch let error as TxError {
                XCTAssertEqual(error, .simulatedCrash(point))
            }

            let pending = try harness.loadState().pendingOutbound
            let hasOutbox = try harness.database.hasOutboxRow(
                sessionID: harness.sessionID,
                objectDigest: pending?.objectDigest
                    ?? P0StubOutboundMaterializer.lastObjectDigest
                    ?? harness.expectedObjectDigest
            )

            switch point {
            case .beforeOutboundProtectedReplacement:
                XCTAssertFalse(hasOutbox, point.rawValue)
                XCTAssertNil(pending, point.rawValue)
            case .afterOutboundProtectedReplacement, .beforeOutboundDatabaseCommit:
                XCTAssertFalse(hasOutbox, point.rawValue)
                XCTAssertNotNil(pending, point.rawValue)
            case .afterOutboundDatabaseCommit, .beforeOutboundJournalClear:
                XCTAssertTrue(hasOutbox, point.rawValue)
                XCTAssertNotNil(pending, point.rawValue)
            case .afterOutboundJournalClear:
                XCTAssertTrue(hasOutbox, point.rawValue)
                XCTAssertNil(pending, point.rawValue)
            default:
                XCTFail("unexpected point \(point.rawValue)")
            }
            XCTAssertEqual(harness.dialer.callCount, 0, point.rawValue)

            try await P0SendRecovery.finishAfterCrash(
                harness: harness,
                crashPoint: point,
                text: Data("p0-send-body".utf8)
            )
            XCTAssertEqual(harness.dialer.callCount, 1, point.rawValue)
        }
    }

    func testSendBeforeBodyStageCrashDoesNotDialOrAdvance() async throws {
        let harness = try P0SendHarness()
        do {
            _ = try await harness.sender(faults: P0OneShotFaults(.beforeOutboundStage)).send(
                text: Data("stage crash".utf8),
                session: harness.boundSession(),
                createdAtMs: harness.nowMs,
                expiresAtMs: harness.nowMs + 60_000
            )
            XCTFail("expected beforeOutboundStage crash")
        } catch let error as TxError {
            XCTAssertEqual(error, .simulatedCrash(.beforeOutboundStage))
        }
        XCTAssertNil(try harness.bodyStage.load(messageID: harness.messageID))
        XCTAssertEqual(harness.dialer.callCount, 0)
    }

    // MARK: - §5.2 ACK materialize two-phase

    func testAckMaterializeTwoPhaseCrashRecoveryDoesNotReAdvanceAckSend() async throws {
        let materializePoints: [Endpoint.CrashPoint] = [
            .beforeProtectedStateReplacement,
            .afterProtectedStateReplacement,
            .beforeDatabaseCommit,
            .afterDatabaseCommit,
            .beforeJournalClear,
            .afterJournalClear,
        ]

        for point in materializePoints {
            let harness = try P0AckHarness()
            let materializer = P0CountingAckMaterializer(harness: harness)
            let queue = P0MemoryQueue()
            let worker = harness.ackWorker(
                queue: queue,
                materializer: materializer,
                faults: P0OneShotFaults(point)
            )
            let ackSendBefore = try harness.loadState().nextAckSendIndex

            do {
                _ = try await worker.enqueueOneCommittedAck(
                    session: harness.boundSession(),
                    nowMs: harness.nowMs
                )
                XCTFail("expected materialize crash at \(point.rawValue)")
            } catch let error as TxError {
                XCTAssertEqual(error, .simulatedCrash(point))
            }

            XCTAssertEqual(materializer.calls, 1, point.rawValue)
            let ackSendAfterCrash = try harness.loadState().nextAckSendIndex
            if point == .beforeProtectedStateReplacement {
                XCTAssertEqual(ackSendAfterCrash, ackSendBefore, point.rawValue)
            } else {
                XCTAssertEqual(ackSendAfterCrash, ackSendBefore + 1, point.rawValue)
            }

            let retryWorker = harness.ackWorker(queue: queue, materializer: materializer)
            _ = try await retryWorker.enqueueOneCommittedAck(
                session: harness.boundSession(),
                nowMs: harness.nowMs
            )
            _ = try await harness.receiver().recoverPendingAcceptances()
            let expectedMaterializerCalls = point == .beforeProtectedStateReplacement ? 2 : 1
            XCTAssertEqual(materializer.calls, expectedMaterializerCalls, "resume must not re-advance ack_send")
            XCTAssertEqual(try harness.loadState().nextAckSendIndex, ackSendBefore + 1)
            XCTAssertNil(try harness.loadState().pendingOutbound)
        }
    }

    // MARK: - §5.5 PairInit windows

    func testPairInitClaimJournalRollForwardBeforeDurableWrite() throws {
        let fixtures = try P0PairInitFixtures()
        let store = ATSAMPrekeyLifecycleStore.shared
        store.resetForTesting(memoryOnly: true)

        store.injectFault(.beforeClaimJournal)
        XCTAssertThrowsError(
            try store.claimPairInit(
                pairInitWire: fixtures.initWire,
                initValue: fixtures.initValue,
                trust: fixtures.trust,
                root: fixtures.root,
                nowMs: fixtures.nowMs
            )
        ) { error in
            guard case ATSAMPrekeyLifecycleStore.StoreError.injectedCrash(let label) = error else {
                return XCTFail("expected injected crash, got \(error)")
            }
            XCTAssertEqual(label, "before claim journal")
        }
        XCTAssertEqual(try store.acceptedClaimCount(), 0)

        let recovered = try store.claimPairInit(
            pairInitWire: fixtures.initWire,
            initValue: fixtures.initValue,
            trust: fixtures.trust,
            root: fixtures.root,
            nowMs: fixtures.nowMs &+ 1
        )
        guard case .accepted = recovered else {
            return XCTFail("expected accepted claim after roll-forward")
        }
    }

    func testPairInitAcceptWindowFaultInjectionNeverCompletesClaimBeforeConfirm() async throws {
        let fixtures = try P0PairInitFixtures()
        try fixtures.importPeerTrust()
        ATSAMPairInitAcceptService.acceptTestVectorOverrides = try fixtures.acceptTestOverrides()
        ATSAMPairInitAcceptService.skipUplinkForTesting = true
        ATSAMPairInitAcceptService.skipInstallSessionForTesting = true
        defer {
            ATSAMPairInitAcceptService.resetAcceptTestHooks()
        }

        let windows: [ATSAMPairInitAcceptService.AcceptFaultPoint] = [
            .afterClaimBeforeCache,
            .afterCacheBeforeConfirm,
            .afterConfirmBeforeCompleteClaim,
        ]

        for window in windows {
            ATSAMPrekeyLifecycleStore.shared.resetForTesting(memoryOnly: true)
            ATSAMPairResponseCache.setTestRoot(fixtures.cacheRoot)
            try? ATSAMPairResponseCache.removeStored(initID: fixtures.initValue.initID)
            defer { ATSAMPairResponseCache.setTestRoot(nil) }

            ATSAMPairInitAcceptService.injectFault(window)
            do {
                try await ATSAMPairInitAcceptService.accept(pairInitWire: fixtures.initWire)
                XCTFail("expected injected crash at \(window)")
            } catch ATSAMPairInitAcceptService.AcceptError.injectedCrash {
                // Expected.
            }

            let store = ATSAMPrekeyLifecycleStore.shared
            switch window {
            case .afterClaimBeforeCache:
                XCTAssertEqual(try store.acceptedClaimCount(), 1)
                XCTAssertThrowsError(
                    try ATSAMPairResponseCache.loadVerified(
                        initValue: fixtures.initValue,
                        localDeviceEd: fixtures.initValue.responderDeviceEd25519PublicKey
                    )
                ) { error in
                    guard case ATSAMPairResponseCache.CacheError.unavailable = error else {
                        return XCTFail("expected missing cache, got \(error)")
                    }
                }
            case .afterCacheBeforeConfirm, .afterConfirmBeforeCompleteClaim:
                let cached = try ATSAMPairResponseCache.loadVerified(
                    initValue: fixtures.initValue,
                    localDeviceEd: fixtures.initValue.responderDeviceEd25519PublicKey
                )
                XCTAssertNotNil(cached)
                let initHash = try ATSAMPairInitV1.initHash(fixtures.initValue)
                let claimState = try store.claimState(initHash: initHash)
                XCTAssertEqual(claimState, .pendingHandoff, "complete_claim must not run before confirm handoff finishes")
            }

            ATSAMPairInitAcceptService.resetAcceptTestHooks()
            ATSAMPairInitAcceptService.skipUplinkForTesting = true
            ATSAMPairInitAcceptService.skipInstallSessionForTesting = true
            ATSAMPairInitAcceptService.acceptTestVectorOverrides = try fixtures.acceptTestOverrides()
            let firstPacked = try? ATSAMPairResponseCache.loadVerified(
                initValue: fixtures.initValue,
                localDeviceEd: fixtures.initValue.responderDeviceEd25519PublicKey
            )
            try await ATSAMPairInitAcceptService.accept(pairInitWire: fixtures.initWire)
            let secondPacked = try? ATSAMPairResponseCache.loadVerified(
                initValue: fixtures.initValue,
                localDeviceEd: fixtures.initValue.responderDeviceEd25519PublicKey
            )
            if let firstPacked, let secondPacked {
                XCTAssertEqual(firstPacked, secondPacked, "roll-forward must reuse cached bytes")
            }
            let initHash = try ATSAMPairInitV1.initHash(fixtures.initValue)
            XCTAssertEqual(try store.claimState(initHash: initHash), .completed)
        }
    }

    // MARK: - §4 gates (receive, inbound ACK, PairInit accept)

    func testReceiveBlockRevokeGatesRefuseWithoutAdvance() async throws {
        let harness = try P0ReceiveHarness()
        let packed = try harness.packedEnvelope()

        for (label, session, expected) in [
            ("revoked", harness.session(revoked: true), TxError.revokedDevice),
            ("unaccepted", harness.session(accepted: false), TxError.unacceptedDevice),
        ] {
            do {
                _ = try await harness.receiver().receive(
                    packedEnvelope: packed,
                    session: session,
                    nowMs: harness.nowMs
                )
                XCTFail("\(label) must refuse")
            } catch let error as TxError {
                XCTAssertEqual(error, expected, label)
            }
            XCTAssertEqual(try harness.loadState().nextReceiveIndex, 0, label)
            if let mem = harness.database as? P0MemoryDatabase {
                XCTAssertEqual(mem.receipts.count, 0, label)
            }
        }
    }

    func testInboundAckContactBlockRevokeGatesRefuseWithoutDeliveryChange() async throws {
        let harness = try P0AckHarness(direction: .responderToInitiator)
        let messageID = Data(repeating: 0xE8, count: 16)
        harness.registerOutstanding(messageID: messageID)
        let packed = try harness.ackEnvelope(ackedMessageID: messageID)

        for (label, session, expected) in [
            ("contact gate", harness.session(contactAllowed: false), TxError.contactBlocked),
            ("revoked", harness.session(revoked: true), TxError.revokedDevice),
            ("unaccepted", harness.session(accepted: false), TxError.unacceptedDevice),
        ] {
            do {
                _ = try await harness.receiver().acceptAck(
                    packedEnvelope: packed,
                    session: session,
                    nowMs: harness.nowMs
                )
                XCTFail("\(label) must refuse")
            } catch let error as TxError {
                XCTAssertEqual(error, expected, label)
            }
            if let mem = harness.database as? P0MemoryDatabase {
                XCTAssertEqual(mem.ackReceipts.count, 0, label)
            }
            XCTAssertEqual(harness.outstandingState(messageID: messageID), .sent, label)
        }
    }

    func testPairInitAcceptContactGateRefusesUntrustedPeer() async throws {
        let fixtures = try P0PairInitFixtures()
        do {
            try await ATSAMPairInitAcceptService.accept(pairInitWire: fixtures.initWire)
            XCTFail("untrusted initiator must refuse at contact gate")
        } catch ATSAMPairInitAcceptService.AcceptError.contactGateClosed {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(try ATSAMPrekeyLifecycleStore.shared.acceptedClaimCount(), 0)
    }

    // MARK: - Durable reopen (one representative per journal)

    func testDurableReopenReceiveJournalRecoversPendingAcceptance() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0-receive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let keyHex = P0DurableFixtures.testKeyHex()
        let db = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let protected = KeychainProtectedSessionStore()
        let harness = try P0ReceiveHarness(store: protected, database: db)

        let packed = try harness.packedEnvelope()
        do {
            _ = try await harness.receiver(faults: P0OneShotFaults(.beforeJournalClear)).receive(
                packedEnvelope: packed,
                session: harness.boundSession(),
                nowMs: harness.nowMs
            )
            XCTFail("expected crash before journal clear")
        } catch let error as TxError {
            XCTAssertEqual(error, .simulatedCrash(.beforeJournalClear))
        }
        XCTAssertNotNil(try protected.load(sessionID: harness.sessionID).pendingAcceptance)

        protected.dropMemoryCacheForRelaunchSimulation()
        try db.dropMemoryCacheForRelaunchSimulation()
        let relaunchedDB = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let relaunchedStore = KeychainProtectedSessionStore()
        let relaunched = try P0ReceiveHarness(
            store: relaunchedStore,
            database: relaunchedDB,
            sessionID: harness.sessionID,
            boundSessionOverride: harness.boundSession(),
            nowMs: harness.nowMs
        )
        let recovered = try await relaunched.receiver().recoverPendingAcceptances()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertNil(try relaunchedStore.load(sessionID: harness.sessionID).pendingAcceptance)
        XCTAssertEqual(try relaunchedDB.allAckIntents().count, 1)
    }

    func testDurableReopenSendOutboxSurvivesRelaunchWithoutOrphanDial() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let keyHex = P0DurableFixtures.testKeyHex()
        let db = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let protected = KeychainProtectedSessionStore()
        let harness = try P0SendHarness(store: protected, database: db, tempRoot: tempRoot)

        do {
            _ = try await harness.sender(faults: P0OneShotFaults(.beforeOutboundJournalClear)).send(
                text: Data("durable send".utf8),
                session: harness.boundSession(),
                createdAtMs: harness.nowMs,
                expiresAtMs: harness.nowMs + 60_000
            )
            XCTFail("expected crash before journal clear")
        } catch let error as TxError {
            XCTAssertEqual(error, .simulatedCrash(.beforeOutboundJournalClear))
        }

        protected.dropMemoryCacheForRelaunchSimulation()
        try db.dropMemoryCacheForRelaunchSimulation()
        let pendingDigest = try XCTUnwrap(
            try protected.load(sessionID: harness.sessionID).pendingOutbound?.objectDigest
                ?? harness.expectedObjectDigest
        )
        let relaunchedDB = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let relaunchedStore = KeychainProtectedSessionStore()
        let relaunched = try P0SendHarness(
            store: relaunchedStore,
            database: relaunchedDB,
            tempRoot: tempRoot,
            sessionID: harness.sessionID,
            boundSessionOverride: harness.boundSession(),
            nowMs: harness.nowMs
        )
        _ = try await relaunched.receiver().recoverPendingAcceptances()
        XCTAssertNil(try relaunchedStore.load(sessionID: harness.sessionID).pendingOutbound)
        XCTAssertTrue(try relaunchedDB.hasOutboxRow(
            sessionID: harness.sessionID,
            objectDigest: pendingDigest
        ))
        XCTAssertEqual(relaunched.dialer.callCount, 0)
    }

    func testDurableReopenAckSendMaterializeResumesAfterRelaunch() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0-acksend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let keyHex = P0DurableFixtures.testKeyHex()
        let db = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let protected = KeychainProtectedSessionStore()
        let harness = try P0AckHarness(store: protected, database: db)
        let materializer = P0CountingAckMaterializer(harness: harness)
        let queue = P0MemoryQueue()

        do {
            _ = try await harness.ackWorker(
                queue: queue,
                materializer: materializer,
                faults: P0OneShotFaults(.beforeJournalClear)
            ).enqueueOneCommittedAck(
                session: harness.boundSession(),
                nowMs: harness.nowMs
            )
            XCTFail("expected materialize crash")
        } catch let error as TxError {
            XCTAssertEqual(error, .simulatedCrash(.beforeJournalClear))
        }

        protected.dropMemoryCacheForRelaunchSimulation()
        try db.dropMemoryCacheForRelaunchSimulation()
        let relaunchedDB = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let relaunchedStore = KeychainProtectedSessionStore()
        let relaunched = try P0AckHarness(
            store: relaunchedStore,
            database: relaunchedDB,
            sessionID: harness.sessionID,
            boundSessionOverride: harness.boundSession(),
            nowMs: harness.nowMs,
            seedReceive: false
        )
        let retryMaterializer = P0CountingAckMaterializer(harness: relaunched)
        _ = try await relaunched.ackWorker(queue: queue, materializer: retryMaterializer)
            .enqueueOneCommittedAck(
                session: relaunched.boundSession(),
                nowMs: relaunched.nowMs
            )
        _ = try await relaunched.receiver().recoverPendingAcceptances()
        XCTAssertEqual(retryMaterializer.calls, 0, "relaunch must resume staged ack without rematerialize")
        XCTAssertNil(try relaunchedStore.load(sessionID: harness.sessionID).pendingOutbound)
    }

    func testDurableReopenAckAcceptJournalRecoversAfterRelaunch() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0-ackaccept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let keyHex = P0DurableFixtures.testKeyHex()
        let db = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let protected = KeychainProtectedSessionStore()
        let harness = try P0AckHarness(
            store: protected,
            database: db
        )
        let messageID = Data(repeating: 0xAB, count: 16)
        harness.registerOutstanding(messageID: messageID)
        let packed = try harness.ackEnvelope(ackedMessageID: messageID)

        do {
            _ = try await harness.receiver(faults: P0OneShotFaults(.beforeJournalClear)).acceptAck(
                packedEnvelope: packed,
                session: harness.boundSession(),
                nowMs: harness.nowMs
            )
            XCTFail("expected crash before journal clear")
        } catch let error as TxError {
            XCTAssertEqual(error, .simulatedCrash(.beforeJournalClear))
        }
        XCTAssertNotNil(try protected.load(sessionID: harness.sessionID).pendingAckAcceptance)

        protected.dropMemoryCacheForRelaunchSimulation()
        try db.dropMemoryCacheForRelaunchSimulation()
        let relaunchedDB = try SQLCipherAcceptanceDatabase(testRoot: tempRoot, keyHex: keyHex)
        let relaunchedStore = KeychainProtectedSessionStore()
        let relaunched = try P0AckHarness(
            store: relaunchedStore,
            database: relaunchedDB,
            sessionID: harness.sessionID,
            boundSessionOverride: harness.boundSession(),
            nowMs: harness.nowMs,
            seedReceive: false
        )
        relaunched.registerOutstanding(messageID: messageID, state: Endpoint.DeliveryState.sent)
        _ = try await relaunched.receiver().recoverPendingAcceptances()
        XCTAssertNil(try relaunchedStore.load(sessionID: harness.sessionID).pendingAckAcceptance)
        XCTAssertEqual(try relaunchedDB.ackReceiptCount(), 1)
        XCTAssertEqual(relaunched.outstandingState(messageID: messageID), Endpoint.DeliveryState.delivered)
    }

    func testDurableReopenPairInitClaimJournalRollsForwardAfterRelaunch() throws {
        let fixtures = try P0PairInitFixtures()
        let store = ATSAMPrekeyLifecycleStore.shared
        store.resetForTesting(memoryOnly: false)
        defer { store.resetForTesting(memoryOnly: true) }

        store.injectFault(.claimJournal)
        XCTAssertThrowsError(
            try store.claimPairInit(
                pairInitWire: fixtures.initWire,
                initValue: fixtures.initValue,
                trust: fixtures.trust,
                root: fixtures.root,
                nowMs: fixtures.nowMs
            )
        )

        store.clearInjectedFault()
        store.dropMemoryCacheForRelaunchSimulation()
        let recovered = try store.claimPairInit(
            pairInitWire: fixtures.initWire,
            initValue: fixtures.initValue,
            trust: fixtures.trust,
            root: fixtures.root,
            nowMs: fixtures.nowMs &+ 1
        )
        guard case .duplicatePending = recovered else {
            return XCTFail("expected duplicate pending after durable reopen")
        }
        XCTAssertEqual(try store.acceptedClaimCount(), 1)
    }
}

// MARK: - PairInit test helpers

@MainActor
private struct P0PairInitFixtures {
    let initWire: Data
    let initValue: ATSAMPairInitV1.PairInit
    let trust: ATSAMPairInitV1.TrustContext
    let root: Data
    let nowMs: UInt64
    let cacheRoot: URL

    init() throws {
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0-pairinit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "shared-vectors/rvn1/atsam/pair_init_v1_001.json"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("shared PairInit vector not found in this checkout")
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let expected = json["expected"] as! [String: Any]
        let input = json["input"] as! [String: Any]
        initWire = P0Hex.data(expected["pair_init_wire_hex"] as! String)
        initValue = try ATSAMPairInitV1.decodeInit(initWire)
        root = P0Hex.data(expected["provisional_k_root_hex"] as! String)
        nowMs = initValue.createdAtMs &+ 100
        trust = ATSAMPairInitV1.TrustContext(
            initiatorCertificate: .init(
                identityEd25519PublicKey: P0Hex.data(input["initiator_identity_ed_pub_hex"] as! String),
                signingBytes: P0Hex.data(input["initiator_device_cert_signing_bytes_hex"] as! String),
                signature: P0Hex.data(input["initiator_device_cert_signature_hex"] as! String)
            ),
            responderCertificate: .init(
                identityEd25519PublicKey: P0Hex.data(input["responder_identity_ed_pub_hex"] as! String),
                signingBytes: P0Hex.data(input["responder_device_cert_signing_bytes_hex"] as! String),
                signature: P0Hex.data(input["responder_device_cert_signature_hex"] as! String)
            ),
            responderPrekeyBundle: .init(
                signingBytes: P0Hex.data(input["responder_prekey_signing_bytes_hex"] as! String),
                signature: P0Hex.data(input["responder_prekey_signature_hex"] as! String)
            )
        )
    }

    func importPeerTrust() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "shared-vectors/rvn1/atsam/pair_init_v1_001.json"
        )
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let input = json["input"] as! [String: Any]
        let dto = ATSAMLabTrustStore.LabCertJSON(
            device_ed_pub: P0Hex.string(input["initiator_device_ed_pub_hex"] as! String),
            device_x_pub: "07a1a4e709bf085ac494aba0469b9b1eda0ab1f78b16aabb79ffeda90623e852",
            device_id: "vector-initiator",
            not_before_ms: initValue.createdAtMs &- 60_000,
            not_after_ms: initValue.expiresAtMs,
            capabilities: 0,
            signature: P0Hex.string(input["initiator_device_cert_signature_hex"] as! String),
            user_ed_pub: P0Hex.string(input["initiator_identity_ed_pub_hex"] as! String)
        )
        let encoded = try JSONEncoder().encode(dto)
        guard let jsonString = String(data: encoded, encoding: .utf8) else {
            throw XCTSkip("could not encode peer cert JSON")
        }
        try ATSAMLabTrustStore.importPeerCertJSON(jsonString)
    }

    func acceptTestOverrides() throws -> ATSAMPairInitAcceptService.AcceptTestVectorOverrides {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent(
            "shared-vectors/rvn1/atsam/pair_init_v1_001.json"
        )
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let expected = json["expected"] as! [String: Any]
        let responseWire = P0Hex.data(expected["pair_response_wire_hex"] as! String)
        let signingKey = Curve25519.Signing.PrivateKey()
        let packed = try RavenPairInitLanOob.wrapOobWire(
            responseWire,
            isPairInit: false,
            signingKey: signingKey,
            nowMs: initValue.createdAtMs
        )
        return ATSAMPairInitAcceptService.AcceptTestVectorOverrides(
            trust: trust,
            root: root,
            nowMs: nowMs,
            packedResponse: packed,
            responseWire: responseWire
        )
    }
}

private enum P0SendRecovery {
    static func finishAfterCrash(
        harness: P0SendHarness,
        crashPoint: Endpoint.CrashPoint,
        text: Data
    ) async throws {
        switch crashPoint {
        case .beforeOutboundProtectedReplacement:
            _ = try await harness.sender().reconcileOrphanStages()
            let outcome = try await harness.sender().send(
                text: text,
                session: harness.boundSession(),
                createdAtMs: harness.nowMs,
                expiresAtMs: harness.nowMs + 60_000
            )
            guard case .queued = outcome else {
                return XCTFail("expected queued send after orphan reconcile")
            }
        case .afterOutboundProtectedReplacement,
             .beforeOutboundDatabaseCommit,
             .afterOutboundDatabaseCommit,
             .beforeOutboundJournalClear:
            let pending = try XCTUnwrap(harness.loadState().pendingOutbound)
            _ = try await harness.receiver().recoverPendingAcceptances()
            try harness.dialer.dial(
                packedEnvelope: pending.immutableEnvelopeBytes,
                objectDigest: pending.objectDigest
            )
        case .afterOutboundJournalClear:
            let packed = try XCTUnwrap(P0StubOutboundMaterializer.lastPackedEnvelope)
            try harness.dialer.dial(
                packedEnvelope: packed,
                objectDigest: harness.expectedObjectDigest
            )
        default:
            XCTFail("unexpected send crash point \(crashPoint.rawValue)")
        }
    }
}

// MARK: - Shared harness utilities

private enum P0Hex {
    static func data(_ value: String) -> Data {
        var result = Data()
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let next = value.index(cursor, offsetBy: 2)
            result.append(UInt8(value[cursor..<next], radix: 16)!)
            cursor = next
        }
        return result
    }

    static func string(_ value: String) -> String { value }
}

private enum P0DurableFixtures {
    static func testKeyHex() -> String {
        Data((0..<32).map { UInt8($0) }).map { String(format: "%02x", $0) }.joined()
    }
}

private final class P0OneShotFaults: Endpoint.FaultInjector {
    private var crashPoint: Endpoint.CrashPoint?

    init(_ crashPoint: Endpoint.CrashPoint?) {
        self.crashPoint = crashPoint
    }

    func checkpoint(_ point: Endpoint.CrashPoint) throws {
        guard crashPoint == point else { return }
        crashPoint = nil
        throw TxError.simulatedCrash(point)
    }
}

private final class P0MemoryQueue: Endpoint.ImmutableAckQueue {
    var objects: [Data: Data] = [:]

    func enqueueImmutable(objectID: Data, packedEnvelope: Data) throws {
        if let existing = objects[objectID] {
            guard existing == packedEnvelope else { throw TxError.stagedAckCollision }
            return
        }
        objects[objectID] = packedEnvelope
    }

    func contains(objectID: Data) throws -> Bool { objects[objectID] != nil }

    @discardableResult
    func deleteIfPresent(objectID: Data) throws -> Bool {
        objects.removeValue(forKey: objectID) != nil
    }
}

private final class P0CountingDialer: Endpoint.OutboundDialer {
    private(set) var callCount = 0
    func dial(packedEnvelope: Data, objectDigest: Data) throws { callCount += 1 }
}

private final class P0ProtectedStore: Endpoint.ProtectedStateStore {
    var states: [Data: Endpoint.ProtectedSessionState]

    init(state: Endpoint.ProtectedSessionState) {
        states = [state.sessionID: state]
    }

    func pendingSessionIDs() throws -> [Data] {
        states.values.filter {
            $0.pendingAcceptance != nil || $0.pendingAckAcceptance != nil || $0.pendingOutbound != nil
        }.map(\.sessionID)
    }

    func load(sessionID: Data) throws -> Endpoint.ProtectedSessionState {
        guard let state = states[sessionID] else { throw TxError.invalidProtectedState }
        return state
    }

    func replace(_ state: Endpoint.ProtectedSessionState) throws {
        states[state.sessionID] = state
    }

    func clearPending(sessionID: Data, objectDigest: Data) throws {
        guard var state = states[sessionID] else { return }
        if state.pendingAcceptance?.receiptKey.objectDigest == objectDigest {
            state.pendingAcceptance = nil
        } else if state.pendingAckAcceptance?.receiptKey.objectDigest == objectDigest {
            state.pendingAckAcceptance = nil
        } else if state.pendingOutbound?.objectDigest == objectDigest {
            state.pendingOutbound = nil
        }
        states[sessionID] = state
    }
}

private final class P0MemoryDatabase: Endpoint.OutboundDatabase {
    var receipts: [Endpoint.ReceiptKey: Endpoint.CommittedReceipt] = [:]
    var logicalObjects: [Endpoint.LogicalMessageKey: Data] = [:]
    var ackIntents: [Endpoint.ReceiptKey: Endpoint.AckIntent] = [:]
    var ackReceipts: [Endpoint.ReceiptKey: Endpoint.AckReceipt] = [:]
    var ackNonceObjects: [Data: Data] = [:]
    var outstanding: [Endpoint.OutstandingMessageKey: Endpoint.DeliveryState] = [:]
    var outbox: Set<Data> = []

    func hasOutboxRow(sessionID: Data, objectDigest: Data) throws -> Bool {
        var key = Data()
        key.append(sessionID)
        key.append(objectDigest)
        return outbox.contains(key)
    }

    func beginImmediate() throws -> any Endpoint.AcceptanceDatabaseTransaction {
        P0LeaseTransaction(database: self)
    }

    func nextUnqueuedAckIntent() throws -> Endpoint.AckIntent? {
        ackIntents.values.first { !$0.isQueued && !$0.isAbandoned }
    }

    func allAckIntents() throws -> [Endpoint.AckIntent] { Array(ackIntents.values) }

    func markAckAbandoned(receiptKey: Endpoint.ReceiptKey) throws {
        guard var intent = ackIntents[receiptKey] else { throw TxError.noPendingAck }
        intent.isAbandoned = true
        ackIntents[receiptKey] = intent
    }

    func stageAckEnvelope(
        receiptKey: Endpoint.ReceiptKey,
        packedEnvelope: Data,
        queueObjectID: Data
    ) throws -> Endpoint.AckIntent {
        guard var intent = ackIntents[receiptKey] else { throw TxError.noPendingAck }
        intent.stagedEnvelope = packedEnvelope
        intent.queueObjectID = queueObjectID
        ackIntents[receiptKey] = intent
        return intent
    }

    func markAckQueued(receiptKey: Endpoint.ReceiptKey, queueObjectID: Data) throws {
        guard var intent = ackIntents[receiptKey] else { throw TxError.stagedAckCollision }
        intent.isQueued = true
        ackIntents[receiptKey] = intent
    }
}

private final class P0LeaseTransaction: Endpoint.AcceptanceDatabaseTransaction, Endpoint.OutboundDatabaseTransaction {
    private unowned let database: P0MemoryDatabase
    private var active = true
    private var pending: Endpoint.PendingAcceptance?
    private var pendingAck: Endpoint.PendingAckAcceptance?
    private var pendingOutbound: Endpoint.PendingOutbound?

    init(database: P0MemoryDatabase) { self.database = database }

    func existingReceipt(
        receiptKey: Endpoint.ReceiptKey,
        logicalKey: Endpoint.LogicalMessageKey
    ) throws -> Endpoint.CommittedReceipt? {
        database.receipts[receiptKey]
    }

    func existingAckReceipt(
        receiptKey: Endpoint.ReceiptKey,
        outerMessageID: Data,
        remoteDeviceID: Data
    ) throws -> Endpoint.AckReceipt? {
        database.ackReceipts[receiptKey]
    }

    func outstandingDeliveryState(_ key: Endpoint.OutstandingMessageKey) throws -> Endpoint.DeliveryState? {
        database.outstanding[key]
    }

    func ackNonceObjectDigest(sessionID: Data, remoteDeviceID: Data, ackNonce: Data) throws -> Data? {
        nil
    }

    func insertAcceptance(_ pending: Endpoint.PendingAcceptance) throws -> Endpoint.InsertOutcome {
        self.pending = pending
        return .inserted(Endpoint.CommittedReceipt(
            receiptKey: pending.receiptKey,
            logicalKey: pending.logicalKey,
            messageIndex: pending.messageIndex,
            sealedLocalInboxRow: pending.sealedLocalInboxRow,
            sessionGeneration: pending.sessionGeneration
        ))
    }

    func insertAckAcceptance(_ pending: Endpoint.PendingAckAcceptance) throws -> Endpoint.AckInsertOutcome {
        self.pendingAck = pending
        return .inserted(
            receipt: Endpoint.AckReceipt(
                receiptKey: pending.receiptKey,
                outerMessageID: pending.outerMessageID,
                remoteDeviceID: pending.remoteDeviceID,
                ackedMessageID: pending.ackedMessageID,
                status: pending.status,
                ackNonce: pending.ackNonce,
                createdAtMs: pending.createdAtMs,
                sessionGeneration: pending.sessionGeneration
            ),
            deliveryState: .delivered
        )
    }

    func insertPreparedOutbound(_ pending: Endpoint.PendingOutbound) throws {
        pendingOutbound = pending
    }

    func insertAckMaterialization(
        pending: Endpoint.PendingOutbound,
        intentReceiptKey: Endpoint.ReceiptKey,
        packedEnvelope: Data,
        ackObjectDigest: Data
    ) throws {
        pendingOutbound = pending
        if var intent = database.ackIntents[intentReceiptKey] {
            intent.stagedEnvelope = packedEnvelope
            intent.queueObjectID = ackObjectDigest
            database.ackIntents[intentReceiptKey] = intent
        }
    }

    func commitAndFsync() throws {
        if let value = pending {
            database.receipts[value.receiptKey] = Endpoint.CommittedReceipt(
                receiptKey: value.receiptKey,
                logicalKey: value.logicalKey,
                messageIndex: value.messageIndex,
                sealedLocalInboxRow: value.sealedLocalInboxRow,
                sessionGeneration: value.sessionGeneration
            )
            database.ackIntents[value.receiptKey] = value.ackIntent
        }
        if let ack = pendingAck {
            database.ackReceipts[ack.receiptKey] = Endpoint.AckReceipt(
                receiptKey: ack.receiptKey,
                outerMessageID: ack.outerMessageID,
                remoteDeviceID: ack.remoteDeviceID,
                ackedMessageID: ack.ackedMessageID,
                status: ack.status,
                ackNonce: ack.ackNonce,
                createdAtMs: ack.createdAtMs,
                sessionGeneration: ack.sessionGeneration
            )
            database.outstanding[Endpoint.OutstandingMessageKey(
                sessionID: ack.receiptKey.sessionID,
                messageID: ack.ackedMessageID,
                recipientDeviceID: ack.remoteDeviceID
            )] = .delivered
        }
        if let outbound = pendingOutbound {
            var key = Data()
            key.append(outbound.sessionID)
            key.append(outbound.objectDigest)
            database.outbox.insert(key)
        }
        active = false
    }

    func rollback() { active = false }
}

private enum P0SessionFactory {
    static func initialState(
        sessionID: Data,
        rootKey: Data,
        initiatorAddress: String,
        responderAddress: String
    ) throws -> Endpoint.ProtectedSessionState {
        let pair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: .initiatorToResponder
        )
        return Endpoint.ProtectedSessionState(
            sessionID: sessionID,
            rootKey: rootKey,
            receiveChainKey: try ATSAMIndexedSessionProfile.initialChainKey(
                root: rootKey,
                sender: pair.sender,
                recipient: pair.recipient
            ),
            nextReceiveIndex: 0,
            skippedMessageKeys: [:],
            sendChainKey: try ATSAMIndexedSessionProfile.initialChainKey(
                root: rootKey,
                sender: pair.recipient,
                recipient: pair.sender
            ),
            nextSendIndex: 0,
            ackSendChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: rootKey,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: .responderToInitiator,
                index: 0
            ),
            nextAckSendIndex: 0,
            ackReceiveChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: rootKey,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: .initiatorToResponder,
                index: 0
            ),
            nextAckReceiveIndex: 0,
            skippedAckKeys: [:],
            pendingAcceptance: nil,
            pendingAckAcceptance: nil,
            pendingOutbound: nil,
            generation: 7
        )
    }
}

private final class P0SendHarness {
    let sessionID: Data
    let nowMs: UInt64
    let messageID: Data
    let expectedObjectDigest: Data
    let store: Endpoint.ProtectedStateStore
    let database: Endpoint.OutboundDatabase
    let bodyStage: ATSAMOutboundBodyStage.Store
    let dialer: P0CountingDialer
    private let initiatorAddress: String
    private let responderAddress: String

    init(
        store: Endpoint.ProtectedStateStore? = nil,
        database: Endpoint.OutboundDatabase? = nil,
        tempRoot: URL? = nil,
        sessionID: Data? = nil,
        boundSessionOverride: Endpoint.BoundSession? = nil,
        nowMs: UInt64? = nil
    ) throws {
        let resolvedNow = nowMs ?? 1_786_579_200_000
        self.nowMs = resolvedNow
        let rootKey = Data((32..<64).map(UInt8.init))
        self.sessionID = sessionID ?? Data(SHA256.hash(data: Data("p0-send".utf8)))
        messageID = Data(repeating: 0x55, count: 16)
        let peerPub = Data((1...32).map(UInt8.init))
        let initiatorIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((65...96).map(UInt8.init)))
        let responderIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((97...128).map(UInt8.init)))
        self.initiatorAddress = try XCTUnwrap(
            RavenAddressV1.encode(ed25519PublicKey: initiatorIdentity.publicKey.rawRepresentation)
        )
        self.responderAddress = try XCTUnwrap(
            RavenAddressV1.encode(ed25519PublicKey: responderIdentity.publicKey.rawRepresentation)
        )
        let state = try P0SessionFactory.initialState(
            sessionID: self.sessionID,
            rootKey: rootKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
        if let store {
            self.store = store
            if (try? store.load(sessionID: self.sessionID)) == nil {
                try store.replace(state)
            }
        } else {
            self.store = P0ProtectedStore(state: state)
        }
        self.database = database ?? P0MemoryDatabase()
        dialer = P0CountingDialer()
        let stageRoot = tempRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("p0-send-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        bodyStage = ATSAMOutboundBodyStage.Store(
            directory: stageRoot,
            protector: ATSAMOutboundBodyStage.ScopedAeadProtector(fixedKeyBytes: Data(repeating: 0x7C, count: 32))
        )
        let previewSession = Self.makeBoundSession(
            store: self.store,
            sessionID: self.sessionID,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            nowMs: self.nowMs
        )
        let materializer = P0StubOutboundMaterializer(
            messageID: messageID,
            nowMs: self.nowMs,
            peerPub: peerPub,
            rootKey: rootKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
        expectedObjectDigest = try materializer.previewDigest(
            text: Data("p0-send-body".utf8),
            session: previewSession,
            state: state
        )
    }

    func boundSession() -> Endpoint.BoundSession {
        Self.makeBoundSession(
            store: store,
            sessionID: sessionID,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            nowMs: nowMs
        )
    }

    private static func makeBoundSession(
        store: any Endpoint.ProtectedStateStore,
        sessionID: Data,
        initiatorAddress: String,
        responderAddress: String,
        nowMs: UInt64
    ) -> Endpoint.BoundSession {
        let initiatorIdentity = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data((65...96).map(UInt8.init)))
        let deviceKey = Data((1...32).map(UInt8.init))
        var signingBytes = Data("rvn1/devcert".utf8)
        signingBytes.appendUInt16BE(UInt16(deviceKey.count))
        signingBytes.append(deviceKey)
        let deviceX25519 = Data(SHA256.hash(data: Data("x25519/remote".utf8)))
        signingBytes.appendUInt16BE(UInt16(deviceX25519.count))
        signingBytes.append(deviceX25519)
        let deviceIDBytes = Data("remote-device".utf8)
        signingBytes.appendUInt16BE(UInt16(deviceIDBytes.count))
        signingBytes.append(deviceIDBytes)
        signingBytes.appendUInt64BE(nowMs - 86_400_000)
        signingBytes.appendUInt64BE(nowMs + 8 * 86_400_000)
        signingBytes.appendUInt64BE(0)
        let certificate = ATSAMPairInitV1.SignedDeviceCertificate(
            identityEd25519PublicKey: initiatorIdentity.publicKey.rawRepresentation,
            signingBytes: signingBytes,
            signature: try! initiatorIdentity.signature(for: signingBytes)
        )
        let certificateHash = try! ATSAMPairInitV1.deviceCertificateHash(certificate)
        let generation = (try? store.load(sessionID: sessionID).generation) ?? 7
        return Endpoint.BoundSession(
            sessionID: sessionID,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            inboundDirection: .initiatorToResponder,
            expectedLocalDeviceHint: 0x0102_0304_0506_0708,
            remoteDeviceEd25519PublicKey: Data((1...32).map(UInt8.init)),
            senderCertificate: certificate,
            pairInitSenderCertificateHash: certificateHash,
            sessionCreatedAtMs: nowMs - 86_400_000,
            sessionExpiresAtMs: nowMs + 8 * 86_400_000,
            senderDeviceAccepted: true,
            senderDeviceRevoked: false,
            publicGeneration: generation
        )
    }

    func sender(faults: any Endpoint.FaultInjector = Endpoint.NoFaults()) -> Endpoint.Sender {
        Endpoint.Sender(
            protectedStore: store,
            database: database,
            bodyStage: bodyStage,
            materializer: P0StubOutboundMaterializer(
                messageID: messageID,
                nowMs: nowMs,
                peerPub: Data((1...32).map(UInt8.init)),
                rootKey: Data((32..<64).map(UInt8.init)),
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress
            ),
            dialer: dialer,
            faults: faults
        )
    }

    func receiver(faults: any Endpoint.FaultInjector = Endpoint.NoFaults()) -> Endpoint.Receiver {
        Endpoint.Receiver(protectedStore: store, database: database, faults: faults)
    }

    func loadState() throws -> Endpoint.ProtectedSessionState {
        try store.load(sessionID: sessionID)
    }
}

private final class P0StubOutboundMaterializer: Endpoint.OutboundMaterializer {
    static var lastPackedEnvelope: Data?
    static var lastObjectDigest: Data?
    private let messageID: Data
    private let nowMs: UInt64
    private let peerPub: Data
    private let rootKey: Data
    private let initiatorAddress: String
    private let responderAddress: String
    private let localSigningKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data((101...132).map(UInt8.init)))

    init(
        messageID: Data,
        nowMs: UInt64,
        peerPub: Data,
        rootKey: Data,
        initiatorAddress: String,
        responderAddress: String
    ) {
        self.messageID = messageID
        self.nowMs = nowMs
        self.peerPub = peerPub
        self.rootKey = rootKey
        self.initiatorAddress = initiatorAddress
        self.responderAddress = responderAddress
    }

    func previewDigest(text: Data, session: Endpoint.BoundSession, state: Endpoint.ProtectedSessionState) throws -> Data {
        try prepareOutbound(text: text, session: session, state: state, createdAtMs: nowMs, expiresAtMs: nowMs + 60_000).objectDigest
    }

    func prepareOutbound(
        text: Data,
        session: Endpoint.BoundSession,
        state: Endpoint.ProtectedSessionState,
        createdAtMs: UInt64,
        expiresAtMs: UInt64
    ) throws -> Endpoint.PreparedOutbound {
        let index = state.nextSendIndex
        let route = try ATSAMIndexedSessionProfile.deriveRouteTag(
            root: state.rootKey,
            createdAtMs: createdAtMs,
            index: index,
            envelopeType: RavenEnvelopeV1.EnvType.message.rawValue,
            direction: .responderToInitiator
        )
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            flags: 0,
            messageId: messageID,
            routingTag: route,
            destDeviceHint: session.expectedLocalDeviceHint,
            createdAtMs: createdAtMs,
            expiresAtMs: expiresAtMs,
            antiReplayNonce: Data(repeating: 0x13, count: 12),
            messageCiphertext: text,
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: localSigningKey)
        let packed = envelope.pack()
        Self.lastPackedEnvelope = packed
        let digest = envelope.relayObjectDigest()
        Self.lastObjectDigest = digest
        let generation = state.generation + 1
        let pending = Endpoint.PendingOutbound(
            sessionID: session.sessionID,
            objectDigest: digest,
            messageID: messageID,
            recipientDevice: session.remoteDeviceEd25519PublicKey,
            ratchetIndex: index,
            immutableEnvelopeBytes: packed,
            sessionGeneration: generation,
            sourceAckIntent: nil
        )
        return Endpoint.PreparedOutbound(
            peerPub: peerPub,
            sessionID: session.sessionID,
            objectDigest: digest,
            messageID: messageID,
            createdAtMs: createdAtMs,
            body: String(data: text, encoding: .utf8) ?? "",
            packedEnvelope: packed,
            advancedSendChainKey: state.sendChainKey,
            advancedNextSendIndex: index + 1,
            committedGeneration: generation,
            pendingOutbound: pending
        )
    }
}

private final class P0ReceiveHarness {
    let sessionID: Data
    let nowMs: UInt64
    let store: Endpoint.ProtectedStateStore
    let database: Endpoint.OutboundDatabase
    private let rootKey: Data
    private let senderSigningKey: Curve25519.Signing.PrivateKey
    private let initiatorAddress: String
    private let responderAddress: String
    private let bound: Endpoint.BoundSession

    init(
        store: Endpoint.ProtectedStateStore? = nil,
        database: Endpoint.OutboundDatabase? = nil,
        sessionID: Data? = nil,
        boundSessionOverride: Endpoint.BoundSession? = nil,
        nowMs: UInt64? = nil
    ) throws {
        let resolvedNow = nowMs ?? 1_786_579_200_000
        self.nowMs = resolvedNow
        rootKey = Data(0..<32)
        self.sessionID = sessionID ?? Data(SHA256.hash(data: Data("p0-receive".utf8)))
        senderSigningKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))
        let initiatorIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((65...96).map(UInt8.init)))
        let responderIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((97...128).map(UInt8.init)))
        initiatorAddress = try XCTUnwrap(RavenAddressV1.encode(ed25519PublicKey: initiatorIdentity.publicKey.rawRepresentation))
        responderAddress = try XCTUnwrap(RavenAddressV1.encode(ed25519PublicKey: responderIdentity.publicKey.rawRepresentation))
        let state = try P0SessionFactory.initialState(
            sessionID: self.sessionID,
            rootKey: rootKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
        if let store {
            self.store = store
            if (try? store.load(sessionID: self.sessionID)) == nil {
                try store.replace(state)
            }
        } else {
            self.store = P0ProtectedStore(state: state)
        }
        self.database = database ?? P0MemoryDatabase()
        bound = boundSessionOverride ?? Self.makeBoundSession(
            sessionID: self.sessionID,
            nowMs: resolvedNow,
            senderSigningKey: senderSigningKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
    }

    private static func makeBoundSession(
        sessionID: Data,
        nowMs: UInt64,
        senderSigningKey: Curve25519.Signing.PrivateKey,
        initiatorAddress: String,
        responderAddress: String,
        accepted: Bool = true,
        revoked: Bool = false,
        contactAllowed: Bool? = nil
    ) -> Endpoint.BoundSession {
        let initiatorIdentity = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data((65...96).map(UInt8.init)))
        var signingBytes = Data("rvn1/devcert".utf8)
        signingBytes.appendUInt16BE(32)
        signingBytes.append(senderSigningKey.publicKey.rawRepresentation)
        signingBytes.appendUInt16BE(32)
        signingBytes.append(Data(SHA256.hash(data: Data("x/init".utf8))))
        signingBytes.appendUInt16BE(UInt16(Data("initiator-device".utf8).count))
        signingBytes.append(Data("initiator-device".utf8))
        signingBytes.appendUInt64BE(nowMs - 86_400_000)
        signingBytes.appendUInt64BE(nowMs + 8 * 86_400_000)
        signingBytes.appendUInt64BE(0)
        let certificate = ATSAMPairInitV1.SignedDeviceCertificate(
            identityEd25519PublicKey: initiatorIdentity.publicKey.rawRepresentation,
            signingBytes: signingBytes,
            signature: try! initiatorIdentity.signature(for: signingBytes)
        )
        let certificateHash = try! ATSAMPairInitV1.deviceCertificateHash(certificate)
        return Endpoint.BoundSession(
            sessionID: sessionID,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            inboundDirection: .initiatorToResponder,
            expectedLocalDeviceHint: 0x0102_0304_0506_0708,
            remoteDeviceEd25519PublicKey: senderSigningKey.publicKey.rawRepresentation,
            senderCertificate: certificate,
            pairInitSenderCertificateHash: certificateHash,
            sessionCreatedAtMs: nowMs - 86_400_000,
            sessionExpiresAtMs: nowMs + 8 * 86_400_000,
            senderDeviceAccepted: accepted,
            senderDeviceRevoked: revoked,
            publicGeneration: 7,
            senderContactAllowed: contactAllowed
        )
    }

    func boundSession() -> Endpoint.BoundSession { bound }

    func session(
        accepted: Bool = true,
        revoked: Bool = false,
        contactAllowed: Bool? = nil
    ) -> Endpoint.BoundSession {
        Self.makeBoundSession(
            sessionID: sessionID,
            nowMs: nowMs,
            senderSigningKey: senderSigningKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            accepted: accepted,
            revoked: revoked,
            contactAllowed: contactAllowed
        )
    }

    func receiver(faults: any Endpoint.FaultInjector = Endpoint.NoFaults()) -> Endpoint.Receiver {
        Endpoint.Receiver(protectedStore: store, database: database, faults: faults)
    }

    func loadState() throws -> Endpoint.ProtectedSessionState {
        try store.load(sessionID: sessionID)
    }

    func packedEnvelope() throws -> Data {
        let index: UInt32 = 0
        let messageID = Data(repeating: 0x44, count: 16)
        let plaintext = Data("p0 receive plaintext".utf8)
        let pair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: .initiatorToResponder
        )
        let messageKey = try ATSAMIndexedSessionProfile.messageKeyAtIndex(
            root: rootKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: .initiatorToResponder,
            index: index
        )
        let aad = try ATSAMIndexedSessionProfile.buildAAD(
            index: index,
            sender: pair.sender,
            recipient: pair.recipient,
            outerMessageId: messageID
        )
        var nonce = Data(repeating: 0x20, count: 8)
        nonce.appendUInt32BE(index &+ 1)
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: messageKey),
            nonce: try ChaChaPoly.Nonce(data: nonce),
            authenticating: aad
        )
        var wire = ATSAMIndexedSessionProfile.rvna1Magic
        wire.append(ATSAMIndexedSessionProfile.protocolByte)
        wire.append(ATSAMIndexedSessionProfile.suiteByte)
        wire.appendUInt32BE(index)
        wire.append(nonce)
        wire.append(box.ciphertext)
        wire.append(box.tag)
        let route = try ATSAMIndexedSessionProfile.deriveRouteTag(
            root: rootKey,
            createdAtMs: nowMs,
            index: index,
            envelopeType: RavenEnvelopeV1.EnvType.message.rawValue,
            direction: .initiatorToResponder
        )
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            flags: 0,
            messageId: messageID,
            routingTag: route,
            destDeviceHint: 0x0102_0304_0506_0708,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + 60_000,
            antiReplayNonce: Data(repeating: 0x12, count: 12),
            messageCiphertext: wire,
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: senderSigningKey)
        return envelope.pack()
    }
}

private final class P0AckHarness {
    let sessionID: Data
    let nowMs: UInt64
    let store: Endpoint.ProtectedStateStore
    let database: Endpoint.OutboundDatabase
    private let rootKey: Data
    private let responderSigningKey: Curve25519.Signing.PrivateKey
    private let initiatorAddress: String
    private let responderAddress: String
    private let direction: ATSAMIndexedSessionProfile.Direction
    private let bound: Endpoint.BoundSession

    init(
        store: Endpoint.ProtectedStateStore? = nil,
        database: Endpoint.OutboundDatabase? = nil,
        direction: ATSAMIndexedSessionProfile.Direction = .initiatorToResponder,
        sessionID: Data? = nil,
        boundSessionOverride: Endpoint.BoundSession? = nil,
        nowMs: UInt64? = nil,
        seedReceive: Bool = true
    ) throws {
        self.direction = direction
        let resolvedNow = nowMs ?? 1_786_579_200_000
        self.nowMs = resolvedNow
        rootKey = Data(0..<32)
        self.sessionID = sessionID ?? Data(SHA256.hash(data: Data("p0-ack".utf8)))
        responderSigningKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((33...64).map(UInt8.init)))
        let initiatorIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((65...96).map(UInt8.init)))
        let responderIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((97...128).map(UInt8.init)))
        initiatorAddress = try XCTUnwrap(RavenAddressV1.encode(ed25519PublicKey: initiatorIdentity.publicKey.rawRepresentation))
        responderAddress = try XCTUnwrap(RavenAddressV1.encode(ed25519PublicKey: responderIdentity.publicKey.rawRepresentation))
        let state = try P0SessionFactory.initialState(
            sessionID: self.sessionID,
            rootKey: rootKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
        if let store {
            self.store = store
            if (try? store.load(sessionID: self.sessionID)) == nil {
                try store.replace(state)
            }
        } else {
            self.store = P0ProtectedStore(state: state)
        }
        let memDB = database ?? P0MemoryDatabase()
        self.database = memDB
        let resolvedBound = boundSessionOverride ?? Self.makeBoundSession(
            store: self.store,
            sessionID: self.sessionID,
            nowMs: resolvedNow,
            direction: direction,
            responderSigningKey: responderSigningKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
        bound = resolvedBound
        if seedReceive, direction == .initiatorToResponder {
            let receiveHarness = try P0ReceiveHarness(
                store: self.store,
                database: memDB,
                sessionID: self.sessionID,
                boundSessionOverride: resolvedBound,
                nowMs: self.nowMs
            )
            _ = try awaitSync {
                try await receiveHarness.receiver().receive(
                    packedEnvelope: try receiveHarness.packedEnvelope(),
                    session: resolvedBound,
                    nowMs: self.nowMs
                )
            }
        }
    }

    private static func makeBoundSession(
        store: (any Endpoint.ProtectedStateStore)? = nil,
        sessionID: Data,
        nowMs: UInt64,
        direction: ATSAMIndexedSessionProfile.Direction,
        responderSigningKey: Curve25519.Signing.PrivateKey,
        initiatorAddress: String,
        responderAddress: String,
        accepted: Bool = true,
        revoked: Bool = false,
        contactAllowed: Bool? = nil,
        sessionConfirmed: Bool = true
    ) -> Endpoint.BoundSession {
        let signingKey = direction == .initiatorToResponder
            ? try! Curve25519.Signing.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))
            : responderSigningKey
        let identity = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data((65...96).map(UInt8.init)))
        var signingBytes = Data("rvn1/devcert".utf8)
        signingBytes.appendUInt16BE(32)
        signingBytes.append(signingKey.publicKey.rawRepresentation)
        signingBytes.appendUInt16BE(32)
        signingBytes.append(Data(SHA256.hash(data: Data("x/ack".utf8))))
        signingBytes.appendUInt16BE(UInt16(Data("device".utf8).count))
        signingBytes.append(Data("device".utf8))
        signingBytes.appendUInt64BE(nowMs - 86_400_000)
        signingBytes.appendUInt64BE(nowMs + 8 * 86_400_000)
        signingBytes.appendUInt64BE(0)
        let certificate = ATSAMPairInitV1.SignedDeviceCertificate(
            identityEd25519PublicKey: identity.publicKey.rawRepresentation,
            signingBytes: signingBytes,
            signature: try! identity.signature(for: signingBytes)
        )
        let certificateHash = try! ATSAMPairInitV1.deviceCertificateHash(certificate)
        let generation = (try? store?.load(sessionID: sessionID).generation) ?? 7
        return Endpoint.BoundSession(
            sessionID: sessionID,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            inboundDirection: direction,
            expectedLocalDeviceHint: 0x0102_0304_0506_0708,
            remoteDeviceEd25519PublicKey: signingKey.publicKey.rawRepresentation,
            senderCertificate: certificate,
            pairInitSenderCertificateHash: certificateHash,
            sessionCreatedAtMs: nowMs - 86_400_000,
            sessionExpiresAtMs: nowMs + 8 * 86_400_000,
            senderDeviceAccepted: accepted,
            senderDeviceRevoked: revoked,
            publicGeneration: generation,
            senderContactAllowed: contactAllowed,
            sessionConfirmed: sessionConfirmed
        )
    }

    func responderSigningKeyForTests() -> Curve25519.Signing.PrivateKey { responderSigningKey }

    func boundSession() -> Endpoint.BoundSession {
        let generation = (try? store.load(sessionID: sessionID).generation) ?? bound.publicGeneration
        return Endpoint.BoundSession(
            sessionID: bound.sessionID,
            initiatorAddress: bound.initiatorAddress,
            responderAddress: bound.responderAddress,
            inboundDirection: bound.inboundDirection,
            expectedLocalDeviceHint: bound.expectedLocalDeviceHint,
            remoteDeviceEd25519PublicKey: bound.remoteDeviceEd25519PublicKey,
            senderCertificate: bound.senderCertificate,
            pairInitSenderCertificateHash: bound.pairInitSenderCertificateHash,
            sessionCreatedAtMs: bound.sessionCreatedAtMs,
            sessionExpiresAtMs: bound.sessionExpiresAtMs,
            senderDeviceAccepted: bound.senderDeviceAccepted,
            senderDeviceRevoked: bound.senderDeviceRevoked,
            publicGeneration: generation,
            senderContactAllowed: bound.senderContactAllowed,
            sessionConfirmed: bound.sessionConfirmed
        )
    }

    func session(
        accepted: Bool = true,
        revoked: Bool = false,
        contactAllowed: Bool? = nil,
        sessionConfirmed: Bool = true
    ) -> Endpoint.BoundSession {
        Self.makeBoundSession(
            store: store,
            sessionID: sessionID,
            nowMs: nowMs,
            direction: direction,
            responderSigningKey: responderSigningKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            accepted: accepted,
            revoked: revoked,
            contactAllowed: contactAllowed,
            sessionConfirmed: sessionConfirmed
        )
    }

    func registerOutstanding(messageID: Data, state: Endpoint.DeliveryState = .sent) {
        let key = Endpoint.OutstandingMessageKey(
            sessionID: sessionID,
            messageID: messageID,
            recipientDeviceID: self.bound.remoteDeviceEd25519PublicKey
        )
        if let mem = database as? P0MemoryDatabase {
            mem.outstanding[key] = state
        } else if let sql = database as? SQLCipherAcceptanceDatabase {
            try? sql.seedOutstandingRow(key: key, state: state)
        }
    }

    func outstandingState(messageID: Data) -> Endpoint.DeliveryState? {
        let key = Endpoint.OutstandingMessageKey(
            sessionID: sessionID,
            messageID: messageID,
            recipientDeviceID: self.bound.remoteDeviceEd25519PublicKey
        )
        if let mem = database as? P0MemoryDatabase {
            return mem.outstanding[key]
        }
        if let sql = database as? SQLCipherAcceptanceDatabase {
            let tx = try? sql.beginImmediate()
            defer { tx?.rollback() }
            return try? tx?.outstandingDeliveryState(key)
        }
        return nil
    }

    func receiver(faults: any Endpoint.FaultInjector = Endpoint.NoFaults()) -> Endpoint.Receiver {
        Endpoint.Receiver(protectedStore: store, database: database, faults: faults)
    }

    func ackWorker(
        queue: P0MemoryQueue,
        materializer: P0CountingAckMaterializer,
        faults: any Endpoint.FaultInjector = Endpoint.NoFaults()
    ) -> Endpoint.AckWorker {
        Endpoint.AckWorker(
            protectedStore: store,
            database: database,
            queue: queue,
            materializer: materializer,
            faults: faults
        )
    }

    func loadState() throws -> Endpoint.ProtectedSessionState {
        try store.load(sessionID: sessionID)
    }

    func ackEnvelope(ackedMessageID: Data) throws -> Data {
        let index: UInt32 = 0
        let outerMessageID = Data(repeating: 0xD4, count: 16)
        let innerNonce = Data(repeating: 0x39, count: 12)
        let createdAt = nowMs + 1
        let ackDirection = direction
        let outerSigner = ackDirection == .initiatorToResponder
            ? try Curve25519.Signing.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init)))
            : responderSigningKey
        var signedAck = ATSAMIndexedSessionProfile.SignedAck(
            ackedMessageId: ackedMessageID,
            status: Endpoint.AckStatus.delivered.rawValue,
            ackNonce: innerNonce,
            createdAtMs: createdAt,
            signature: Data(repeating: 0, count: 64)
        )
        signedAck = ATSAMIndexedSessionProfile.SignedAck(
            ackedMessageId: ackedMessageID,
            status: Endpoint.AckStatus.delivered.rawValue,
            ackNonce: innerNonce,
            createdAtMs: createdAt,
            signature: Data(try outerSigner.signature(for: ATSAMIndexedSessionProfile.ackSigningBytes(signedAck)))
        )
        let plaintext = try ATSAMIndexedSessionProfile.encodeSignedAck(signedAck)
        let sealed = try ATSAMIndexedSessionProfile.sealAck(
            root: rootKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: ackDirection,
            index: index,
            outerMessageId: outerMessageID,
            plaintext: plaintext,
            nonce: Data(repeating: UInt8(truncatingIfNeeded: index &+ 0x51), count: 12)
        )
        let route = try ATSAMIndexedSessionProfile.deriveRouteTag(
            root: rootKey,
            createdAtMs: createdAt,
            index: index,
            envelopeType: RavenEnvelopeV1.EnvType.ack.rawValue,
            direction: ackDirection
        )
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            flags: 0,
            messageId: outerMessageID,
            routingTag: route,
            destDeviceHint: 0,
            createdAtMs: createdAt,
            expiresAtMs: createdAt + 60_000,
            antiReplayNonce: Data(repeating: UInt8(truncatingIfNeeded: index), count: 12),
            messageCiphertext: sealed,
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: outerSigner)
        return envelope.pack()
    }
}

private final class P0CountingAckMaterializer: Endpoint.AckMaterializer {
    private unowned let harness: P0AckHarness
    private(set) var calls = 0

    init(harness: P0AckHarness) { self.harness = harness }

    func prepareCommittedAck(
        intent: Endpoint.AckIntent,
        session: Endpoint.BoundSession,
        state: Endpoint.ProtectedSessionState,
        createdAtMs: UInt64,
        expiresAtMs: UInt64
    ) throws -> Endpoint.PreparedAckOutbound {
        calls += 1
        let route = try ATSAMIndexedSessionProfile.deriveRouteTag(
            root: state.rootKey,
            createdAtMs: createdAtMs,
            index: state.nextAckSendIndex,
            envelopeType: RavenEnvelopeV1.EnvType.ack.rawValue,
            direction: .responderToInitiator
        )
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            flags: 0,
            messageId: Data(repeating: 0xCD, count: 16),
            routingTag: route,
            destDeviceHint: 0,
            createdAtMs: createdAtMs,
            expiresAtMs: expiresAtMs,
            antiReplayNonce: Data(repeating: 0x53, count: 12),
            messageCiphertext: Data(repeating: 0xAC, count: 32),
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: harness.responderSigningKeyForTests())
        let bytes = envelope.pack()
        let ackDigest = envelope.relayObjectDigest()
        let pending = Endpoint.PendingOutbound(
            sessionID: session.sessionID,
            objectDigest: ackDigest,
            messageID: Data(repeating: 0xCD, count: 16),
            recipientDevice: intent.expectedRemoteDeviceID,
            ratchetIndex: state.nextAckSendIndex,
            immutableEnvelopeBytes: bytes,
            sessionGeneration: state.generation + 1,
            sourceAckIntent: intent.receiptKey.objectDigest
        )
        return Endpoint.PreparedAckOutbound(
            sourceMessageDigest: intent.receiptKey.objectDigest,
            ackObjectDigest: ackDigest,
            messageID: pending.messageID,
            packedEnvelope: bytes,
            advancedAckSendChainKey: state.ackSendChainKey,
            advancedNextAckSendIndex: state.nextAckSendIndex + 1,
            committedGeneration: state.generation + 1,
            pendingOutbound: pending
        )
    }
}

private func awaitSync<T>(_ work: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task {
        do {
            result = .success(try await work())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

#endif
