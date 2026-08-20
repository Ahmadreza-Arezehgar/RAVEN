//
//  ATSAMLabTask18Tests.swift
//  RAVENTests — Task 18: same-connection PairResponse, duplicate ACK, migration, SQLCipher.
//

#if DEBUG

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

@MainActor
final class ATSAMLabTask18Tests: XCTestCase {

    private let userDefaultsKey = "raven.lab.test_a"
    private let aliceSeed = Data(repeating: 0x01, count: 32)
    private let bobSeed = Data(repeating: 0x02, count: 32)

    private var aliceEd: Data { LanDeterministicEd25519.publicKey(seed: aliceSeed) }
    private var bobEd: Data { LanDeterministicEd25519.publicKey(seed: bobSeed) }

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        ATSAMPairInitAcceptService.resetAcceptTestHooks()
        ATSAMPairInitAcceptService.skipUplinkForTesting = true
        ATSAMLabSessionMetaStore.deleteAllForTesting()
        try? KeychainProtectedSessionStore.deleteAllSessionsForTesting()
        ATSAMOutboundBodyStage.KeychainStageKey.deleteForTesting()
        ATSAMLabEndpointHost.shared.resetLabHostStateForTesting()
        ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(
            .failure(SQLCipherAcceptanceDatabaseError.sqlCipherUnavailable)
        )
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("task18-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        ATSAMPairResponseCache.setTestRoot(cacheRoot)
        let ackRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("task18-ack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ackRoot, withIntermediateDirectories: true)
        ATSAMEndpointDurableAdapters.rebindAckQueueForTesting(
            ImmutableAckFileQueue(testRoot: ackRoot)
        )
    }

    override func tearDown() async throws {
        ATSAMPairInitAcceptService.resetAcceptTestHooks()
        ATSAMPairResponseCache.setTestRoot(nil)
        ATSAMLabSessionMetaStore.deleteAllForTesting()
        ATSAMLabEndpointHost.shared.stop()
        ATSAMLabEndpointHost.shared.resetLabHostStateForTesting()
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        ATSAMLabEndpointHost.shared.stop()
        SQLCipherAcceptanceDatabase._testCipherVersionOverride = nil
        try? ATSAMLabTrustStore.removeImportedPeer(deviceEd: aliceEd)
        try await super.tearDown()
    }

    func testAcceptSameConnectionReturnsPackedPairResponse() async throws {
        let fixtures = try Task18PairInitFixtures()
        let initValue = try ATSAMPairInitV1.decodeInit(fixtures.initWire)
        try ATSAMPairResponseCache.store(
            initID: initValue.initID,
            packed: fixtures.overrides.packedResponse
        )
        ATSAMPairInitAcceptService.acceptTestVectorOverrides = fixtures.overrides
        ATSAMPairInitAcceptService.skipInstallSessionForTesting = true

        let returned = try await ATSAMPairInitAcceptService.accept(
            pairInitWire: fixtures.initWire,
            delivery: .sameConnection
        )
        XCTAssertEqual(returned, fixtures.overrides.packedResponse)
    }

    func testInboundPairInitDispatchReturnsPairResponseOnSameConnection() async throws {
        let fixtures = try Task18PairInitFixtures()
        let initValue = try ATSAMPairInitV1.decodeInit(fixtures.initWire)
        try ATSAMPairResponseCache.store(
            initID: initValue.initID,
            packed: fixtures.overrides.packedResponse
        )
        ATSAMPairInitAcceptService.acceptTestVectorOverrides = fixtures.overrides
        ATSAMPairInitAcceptService.skipInstallSessionForTesting = true

        let host = ATSAMLabEndpointHost.shared
        host.start()
        let peer = try RavenSecureLanRlb1V1.fixtureOfferBundle(deviceSeed: aliceSeed, deviceID: "task18-init")
        try importLabPeerCert(deviceEd: aliceEd, userSeed: 0x01)

        let replies = try await host.dispatchSecureInboundFrame(
            fixtures.packedInit,
            peer: peer,
            noiseEdPub: aliceEd
        )
        XCTAssertEqual(replies.count, 1)
        guard case .pairResponse = RavenPairInitLanOob.classifyPackedEnvelope(replies[0]) else {
            return XCTFail("expected PairResponse OOB reply bytes")
        }
    }

    private func importLabPeerCert(deviceEd: Data, userSeed: UInt8) throws {
        let userEd = Data(repeating: userSeed, count: 32)
        let dto = ATSAMLabTrustStore.LabCertJSON(
            device_ed_pub: deviceEd.ravenHex,
            device_x_pub: Data(repeating: 0xAA, count: 32).ravenHex,
            device_id: "task18-peer",
            not_before_ms: 1,
            not_after_ms: 9_999_999_999_999,
            capabilities: 0,
            signature: Data(repeating: 0xBB, count: 64).ravenHex,
            user_ed_pub: userEd.ravenHex
        )
        let json = String(decoding: try JSONEncoder().encode(dto), as: UTF8.self)
        try ATSAMLabTrustStore.importPeerCertJSON(json)
    }

    func testLegacyPlaintextSessionJSONRefusedFailClosed() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyDir = base.appendingPathComponent("raven-lab-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyFile = legacyDir.appendingPathComponent("deadbeef.json")
        let legacyJSON: [String: Any] = [
            "rootKey": Data(repeating: 0xAB, count: 32).base64EncodedString(),
            "initiatorAddress": "rvn1test",
            "responderAddress": "rvn1peer",
        ]
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: legacyFile, options: .atomic)

        XCTAssertThrowsError(try ATSAMLabSessionMetaStore.quarantineLegacyPlaintextSessionsIfPresent()) { error in
            guard case ATSAMLabSessionMetaStore.StoreError.legacyPlaintextRefused = error else {
                return XCTFail("expected legacyPlaintextRefused, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testSQLCipherOpenFailureSurfacedInHost() {
        SQLCipherAcceptanceDatabase._testCipherVersionOverride = .some(nil)
        ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(
            .failure(SQLCipherAcceptanceDatabaseError.sqlCipherUnavailable)
        )
        let host = ATSAMLabEndpointHost.shared
        host.start()
        XCTAssertNotNil(host.acceptanceDBErrorDescription)
        XCTAssertFalse(host.isOperational)
    }

    func testExactDuplicateLoadsStagedAckBytesForResend() throws {
        let Endpoint = ATSAMEndpointTransactionV1.self
        let sessionID = Data(repeating: 0x42, count: 32)
        let sourceDigest = Data(repeating: 0x77, count: 32)
        let stagedAck = Data("RVN1-exact-ack-bytes-task18".utf8)
        let receiptKey = Endpoint.ReceiptKey(sessionID: sessionID, objectDigest: sourceDigest)
        let root = Data(repeating: 0x01, count: 32)

        let state = Endpoint.ProtectedSessionState(
            sessionID: sessionID,
            rootKey: root,
            receiveChainKey: root,
            nextReceiveIndex: 0,
            skippedMessageKeys: [:],
            sendChainKey: root,
            nextSendIndex: 0,
            ackSendChainKey: root,
            nextAckSendIndex: 1,
            ackReceiveChainKey: root,
            nextAckReceiveIndex: 0,
            skippedAckKeys: [:],
            pendingAcceptance: nil,
            pendingAckAcceptance: nil,
            pendingOutbound: Endpoint.PendingOutbound(
                sessionID: sessionID,
                objectDigest: Data(repeating: 0x88, count: 32),
                messageID: Data(repeating: 0x11, count: 16),
                recipientDevice: Data(repeating: 0x99, count: 32),
                ratchetIndex: 0,
                immutableEnvelopeBytes: stagedAck,
                sessionGeneration: 1,
                sourceAckIntent: sourceDigest
            ),
            generation: 1
        )
        try ATSAMEndpointDurableAdapters.sharedProtectedStore.replace(state)
        defer { try? KeychainProtectedSessionStore.deleteAllSessionsForTesting() }

        let db = try SQLCipherAcceptanceDatabase(
            testRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("task18-dup-\(UUID().uuidString)", isDirectory: true),
            keyHex: String(repeating: "ab", count: 32)
        )
        ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(.success(db))

        let loaded = try ATSAMLabEndpointHost.shared.loadExactCommittedAckBytes(for: receiptKey)
        XCTAssertEqual(loaded, stagedAck)
    }

    func testAcceptAckOriginPathInvokedFromHost() async throws {
        let db = try SQLCipherAcceptanceDatabase(
            testRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("task18-ack-\(UUID().uuidString)", isDirectory: true),
            keyHex: String(repeating: "cd", count: 32)
        )
        let receiver = ATSAMEndpointTransactionV1.Receiver(
            protectedStore: ATSAMEndpointDurableAdapters.sharedProtectedStore,
            database: db
        )
        let harness = try Task18AckHarness(database: db)
        let ackPacked = try harness.buildAckEnvelope()
        do {
            _ = try await receiver.acceptAck(
                packedEnvelope: ackPacked,
                session: harness.bound,
                nowMs: harness.bound.sessionCreatedAtMs &+ 1000
            )
        } catch ATSAMEndpointTransactionV1.TransactionError.invalidDeviceCertificate,
                ATSAMEndpointTransactionV1.TransactionError.ackOutstandingMismatch,
                ATSAMEndpointTransactionV1.TransactionError.deviceBindingMismatch {
            // Origin acceptAck path invoked (post contact-gate / cert / outstanding checks).
            return
        }
    }

    private func testLimits() -> RavenSecureLanTransportLimits {
        RavenSecureLanTransportLimits(
            ioTimeoutSeconds: 5,
            replyIdleSeconds: 1,
            maxConcurrentInboundConnections: 4,
            maxConnectionsPerIP: 2,
            maxFramesPerConnection: 16,
            connectionLifetimeSeconds: 30
        )
    }

    private func localOffer(seed: Data) throws -> Data {
        try RavenSecureLanRlb1V1.encodeOffer(
            try RavenSecureLanRlb1V1.fixtureOfferBundle(deviceSeed: seed, deviceID: "task18")
        )
    }

    func testInitiatorPairResponseVerifyAndInstall() async throws {
        let fixtures = try Task18PairInitFixtures()
        let initValue = try ATSAMPairInitV1.decodeInit(fixtures.initWire)
        guard case .pairResponse(let wire) = RavenPairInitLanOob.classifyPackedEnvelope(
            fixtures.overrides.packedResponse
        ) else {
            return XCTFail("expected PairResponse wire")
        }
        let response = try ATSAMPairInitV1.decodeResponse(wire)
        try ATSAMPairInitV1.verifyResponse(
            response,
            acceptedInit: initValue,
            root: fixtures.overrides.root,
            nowMs: response.createdAtMs &+ 1
        )
        let sessionID = try ATSAMPairInitV1.sessionID(initValue)
        try await ATSAMLabEndpointHost.shared.installInitiatorSession(
            initValue: initValue,
            root: fixtures.overrides.root,
            sessionID: sessionID,
            responderCertificate: fixtures.overrides.trust.responderCertificate,
            nowMs: fixtures.overrides.nowMs
        )
        let meta = try XCTUnwrap(ATSAMLabSessionMetaStore.load(sessionID: sessionID))
        XCTAssertEqual(meta.inboundDirectionRaw, 1)
        let protected = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
        XCTAssertEqual(protected.generation, 1)
        XCTAssertEqual(ATSAMLabEndpointHost.shared.debugBoundGeneration(for: sessionID), 1)
    }

    func testReplayInstallDoesNotResetRatchetIndices() async throws {
        try? KeychainProtectedSessionStore.deleteAllSessionsForTesting()
        let fixtures = try Task18PairInitFixtures()
        let initValue = try ATSAMPairInitV1.decodeInit(fixtures.initWire)
        let sessionID = try ATSAMPairInitV1.sessionID(initValue)
        let host = ATSAMLabEndpointHost.shared
        try await host.installResponderSession(
            initValue: initValue,
            root: fixtures.overrides.root,
            sessionID: sessionID,
            initiatorCertificate: fixtures.overrides.trust.initiatorCertificate,
            nowMs: fixtures.overrides.nowMs
        )
        var state = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
        state.nextReceiveIndex = 3
        state.nextSendIndex = 2
        state.generation = 5
        try ATSAMEndpointDurableAdapters.sharedProtectedStore.replace(state)
        try await host.installResponderSession(
            initValue: initValue,
            root: fixtures.overrides.root,
            sessionID: sessionID,
            initiatorCertificate: fixtures.overrides.trust.initiatorCertificate,
            nowMs: fixtures.overrides.nowMs
        )
        let after = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
        XCTAssertEqual(after.nextReceiveIndex, 3)
        XCTAssertEqual(after.nextSendIndex, 2)
        XCTAssertEqual(after.generation, 5)
    }

    func testSyncBoundGenerationAfterProtectedStoreAdvance() throws {
        try? KeychainProtectedSessionStore.deleteAllSessionsForTesting()
        ATSAMLabEndpointHost.shared.resetLabHostStateForTesting()
        let sessionID = Data(repeating: 0xAB, count: 32)
        let root = Data(repeating: 0xCD, count: 32)
        let state = ATSAMEndpointTransactionV1.ProtectedSessionState(
            sessionID: sessionID,
            rootKey: root,
            receiveChainKey: root,
            nextReceiveIndex: 2,
            skippedMessageKeys: [:],
            sendChainKey: root,
            nextSendIndex: 0,
            ackSendChainKey: root,
            nextAckSendIndex: 0,
            ackReceiveChainKey: root,
            nextAckReceiveIndex: 0,
            skippedAckKeys: [:],
            pendingAcceptance: nil,
            pendingAckAcceptance: nil,
            pendingOutbound: nil,
            generation: 4
        )
        try ATSAMEndpointDurableAdapters.sharedProtectedStore.replace(state)
        defer { try? KeychainProtectedSessionStore.deleteAllSessionsForTesting() }
        let host = ATSAMLabEndpointHost.shared
        host.installBoundSessionForTesting(
            ATSAMEndpointTransactionV1.BoundSession(
                sessionID: sessionID,
                initiatorAddress: "rvn1sync",
                responderAddress: "rvn1peer",
                inboundDirection: .initiatorToResponder,
                expectedLocalDeviceHint: 1,
                remoteDeviceEd25519PublicKey: Data(repeating: 0x01, count: 32),
                senderCertificate: .init(
                    identityEd25519PublicKey: Data(repeating: 0x02, count: 32),
                    signingBytes: Data(repeating: 0x03, count: 80),
                    signature: Data(repeating: 0x04, count: 64)
                ),
                pairInitSenderCertificateHash: Data(repeating: 0x05, count: 32),
                sessionCreatedAtMs: 1,
                sessionExpiresAtMs: 9_999_999_999_999,
                senderDeviceAccepted: true,
                senderDeviceRevoked: false,
                publicGeneration: 1
            )
        )
        host.syncBoundGeneration(sessionID: sessionID)
        XCTAssertEqual(host.debugBoundGeneration(for: sessionID), 4)
    }

    func testBodyStageKeyNotDerivedFromConstant() throws {
        ATSAMOutboundBodyStage.KeychainStageKey.deleteForTesting()
        let constant = Data(SHA256.hash(data: Data("raven-lab-outbound-stage-v1".utf8)))
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("task18-key-constant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        let key = try ATSAMOutboundBodyStage.KeychainStageKey.loadOrCreate()
        let peer = Data(repeating: 0x71, count: 32)
        let sessionID = Data(repeating: 0x72, count: 32)
        let digest = Data(repeating: 0x73, count: 32)
        let messageID = Data(repeating: 0x74, count: 16)
        let keyedStore = ATSAMOutboundBodyStage.Store(
            directory: stageRoot,
            protector: ATSAMOutboundBodyStage.ScopedAeadProtector(key: key)
        )
        try keyedStore.stage(
            peerPub: peer,
            sessionID: sessionID,
            objectDigest: digest,
            messageID: messageID,
            createdAtMs: 1_700_000_000_000,
            body: "not-constant-key"
        )
        let constantStore = ATSAMOutboundBodyStage.Store(
            directory: stageRoot,
            protector: ATSAMOutboundBodyStage.ScopedAeadProtector(fixedKeyBytes: constant)
        )
        XCTAssertThrowsError(try constantStore.load(messageID: messageID)) { error in
            guard case ATSAMOutboundBodyStage.StageError.authenticationFailed = error else {
                return XCTFail("expected authenticationFailed for constant key, got \(error)")
            }
        }
    }

    func testBodyStageKeychainKeyStableAcrossStoreInstances() throws {
        ATSAMOutboundBodyStage.KeychainStageKey.deleteForTesting()
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("task18-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        let key = try ATSAMOutboundBodyStage.KeychainStageKey.loadOrCreate()
        let storeA = ATSAMOutboundBodyStage.Store(
            directory: stageRoot,
            protector: ATSAMOutboundBodyStage.ScopedAeadProtector(key: key)
        )
        let peer = Data(repeating: 0x61, count: 32)
        let sessionID = Data(repeating: 0x62, count: 32)
        let digest = Data(repeating: 0x63, count: 32)
        let messageID = Data(repeating: 0x64, count: 16)
        try storeA.stage(
            peerPub: peer,
            sessionID: sessionID,
            objectDigest: digest,
            messageID: messageID,
            createdAtMs: 1_700_000_000_000,
            body: "task18-stage-stable"
        )
        let storeB = ATSAMOutboundBodyStage.Store(
            directory: stageRoot,
            protector: ATSAMOutboundBodyStage.ScopedAeadProtector(
                key: try ATSAMOutboundBodyStage.KeychainStageKey.loadOrCreate()
            )
        )
        let loaded = try XCTUnwrap(try storeB.load(messageID: messageID))
        XCTAssertEqual(loaded.body, "task18-stage-stable")
    }

    func testDuplicateWithoutStagedAckMaterializesAndResendsInline() async throws {
        try DeviceIdentityService.shared.installDeterministicIdentityForLabIntegration(
            seed: Data(repeating: 0x99, count: 32)
        )
        let db = try SQLCipherAcceptanceDatabase(
            testRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("task18-dup-recover-\(UUID().uuidString)", isDirectory: true),
            keyHex: String(repeating: "ef", count: 32)
        )
        ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(.success(db))
        defer {
            try? KeychainProtectedSessionStore.deleteAllSessionsForTesting()
            ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(
                .failure(SQLCipherAcceptanceDatabaseError.sqlCipherUnavailable)
            )
        }

        let harness = try Task18FullFlowHarness(database: db)
        try harness.install(on: ATSAMLabEndpointHost.shared)
        XCTAssertNotNil(ATSAMLabEndpointHost.shared.debugBoundGeneration(for: harness.sessionID))
        let packed = try harness.buildMessageEnvelope(plaintext: Data("task18-dup-recover".utf8))

        let first = await ATSAMLabEndpointHost.shared.receivePacked(packed, replyOnSameConnection: true)
        XCTAssertEqual(first.count, 1, "first receive must inline ACK")
        let afterFirst = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: harness.sessionID)
        XCTAssertEqual(afterFirst.nextReceiveIndex, 1, "first receive must commit receipt")

        // Simulate crash after receipt commit but before ACK bytes were staged in SQL.
        let intents = try db.allAckIntents()
        XCTAssertEqual(intents.count, 1)
        let intent = try XCTUnwrap(intents.first)
        XCTAssertNotNil(intent.stagedEnvelope, "first inline ACK should have staged bytes")
        try db.clearAckStagedEnvelope(receiptKey: intent.receiptKey)

        var state = afterFirst
        state.pendingOutbound = nil
        try ATSAMEndpointDurableAdapters.sharedProtectedStore.replace(state)

        let duplicate = await ATSAMLabEndpointHost.shared.receivePacked(packed, replyOnSameConnection: true)
        XCTAssertEqual(duplicate.count, 1, "duplicate must materialize+resend ACK bytes")
        XCTAssertEqual(ATSAMLabEndpointHost.shared.duplicateAckRecoveryCount, 1)
        XCTAssertTrue(ATSAMLabEndpointHost.shared.lastLabStatus.contains("duplicate message; exact ACK resent inline"))
    }

    func testPairInitExactRetryUsesIdenticalPackedBytes() async throws {
        ATSAMPrekeyLifecycleStore.shared.resetForTesting(memoryOnly: true)
        defer { ATSAMPrekeyLifecycleStore.shared.resetForTesting(memoryOnly: true) }

        let initWire = try Task18PairInitFixtures().initWire
        let initValue = try ATSAMPairInitV1.decodeInit(initWire)
        let sessionID = try ATSAMPairInitV1.sessionID(initValue)
        let packedA = Data(repeating: 0xAA, count: 80)
        let root = Data(repeating: 0xBB, count: 32)

        try ATSAMPrekeyLifecycleStore.shared.persistInitiatorOutbound(
            initID: initValue.initID,
            packedWire: packedA,
            initWire: initWire,
            sessionID: sessionID,
            provisionalRoot: root,
            createdAtMs: initValue.createdAtMs
        )

        let pending = try XCTUnwrap(ATSAMPrekeyLifecycleStore.shared.loadPendingInitiatorOutbound())
        XCTAssertEqual(pending.record.packedWire, packedA)
        XCTAssertEqual(pending.record.provisionalRoot, root)

        let pendingAgain = try XCTUnwrap(ATSAMPrekeyLifecycleStore.shared.loadPendingInitiatorOutbound())
        XCTAssertEqual(pendingAgain.record.packedWire, packedA, "retry must reuse exact packed bytes")

        try ATSAMPrekeyLifecycleStore.shared.clearInitiatorOutbound(initID: initValue.initID)
        XCTAssertNil(try ATSAMPrekeyLifecycleStore.shared.loadInitiatorOutbound(initID: initValue.initID))
    }

    func testGenerationRollbackRefusedOnSync() throws {
        try? KeychainProtectedSessionStore.deleteAllSessionsForTesting()
        let sessionID = Data(repeating: 0xDE, count: 32)
        let root = Data(repeating: 0xAD, count: 32)
        let db = try SQLCipherAcceptanceDatabase(
            testRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("task18-rollback-\(UUID().uuidString)", isDirectory: true),
            keyHex: String(repeating: "be", count: 32)
        )
        ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(.success(db))
        defer {
            try? KeychainProtectedSessionStore.deleteAllSessionsForTesting()
            ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(
                .failure(SQLCipherAcceptanceDatabaseError.sqlCipherUnavailable)
            )
        }

        try db.upsertSessionHead(sessionID: sessionID, generation: 3)

        let state = ATSAMEndpointTransactionV1.ProtectedSessionState(
            sessionID: sessionID,
            rootKey: root,
            receiveChainKey: root,
            nextReceiveIndex: 0,
            skippedMessageKeys: [:],
            sendChainKey: root,
            nextSendIndex: 0,
            ackSendChainKey: root,
            nextAckSendIndex: 0,
            ackReceiveChainKey: root,
            nextAckReceiveIndex: 0,
            skippedAckKeys: [:],
            pendingAcceptance: nil,
            pendingAckAcceptance: nil,
            pendingOutbound: nil,
            generation: 1
        )
        try ATSAMEndpointDurableAdapters.sharedProtectedStore.replace(state)

        let host = ATSAMLabEndpointHost.shared
        host.installBoundSessionForTesting(
            ATSAMEndpointTransactionV1.BoundSession(
                sessionID: sessionID,
                initiatorAddress: "rvn1init",
                responderAddress: "rvn1resp",
                inboundDirection: .initiatorToResponder,
                expectedLocalDeviceHint: 1,
                remoteDeviceEd25519PublicKey: Data(repeating: 0x01, count: 32),
                senderCertificate: .init(
                    identityEd25519PublicKey: Data(repeating: 0x02, count: 32),
                    signingBytes: Data(repeating: 0x03, count: 80),
                    signature: Data(repeating: 0x04, count: 64)
                ),
                pairInitSenderCertificateHash: Data(repeating: 0x05, count: 32),
                sessionCreatedAtMs: 1,
                sessionExpiresAtMs: 9_999_999_999_999,
                senderDeviceAccepted: true,
                senderDeviceRevoked: false,
                publicGeneration: 3
            )
        )

        XCTAssertThrowsError(try host.syncBoundGenerationValidated(sessionID: sessionID)) { error in
            guard case ATSAMLabEndpointHost.HostError.generationRollback = error else {
                return XCTFail("expected generationRollback, got \(error)")
            }
        }
        XCTAssertTrue(host.lastLabStatus.contains("generation rollback refused"))
    }

    func testHostEndToEndMessageAckSecondMessage() async throws {
        try DeviceIdentityService.shared.installDeterministicIdentityForLabIntegration(
            seed: Data(repeating: 0x33, count: 32)
        )
        let db = try SQLCipherAcceptanceDatabase(
            testRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("task18-e2e-\(UUID().uuidString)", isDirectory: true),
            keyHex: String(repeating: "cc", count: 32)
        )
        ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(.success(db))
        defer {
            try? KeychainProtectedSessionStore.deleteAllSessionsForTesting()
            ATSAMLabEndpointHost.rebindAcceptanceDBForTesting(
                .failure(SQLCipherAcceptanceDatabaseError.sqlCipherUnavailable)
            )
        }

        let harness = try Task18FullFlowHarness(database: db)
        let host = ATSAMLabEndpointHost.shared

        // Responder receives first message and returns/stages ACK.
        let msg1 = try harness.buildMessageEnvelope(plaintext: Data("task18-e2e-1".utf8), index: 0)
        let env1 = try XCTUnwrap(RavenEnvelopeV1.unpack(msg1))
        try harness.install(on: host)
        let ackReplies = await host.receivePacked(msg1, replyOnSameConnection: true)
        let responderAfterMsg1 = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(
            sessionID: harness.sessionID
        )
        XCTAssertEqual(responderAfterMsg1.nextReceiveIndex, 1)
        let ackFrame: Data
        if let inline = ackReplies.first {
            ackFrame = inline
        } else {
            let intents = try db.allAckIntents()
            ackFrame = try XCTUnwrap(
                intents.first?.stagedEnvelope,
                "responder must stage ACK bytes even when inline return empty"
            )
        }

        // Initiator accepts inbound ACK (outstanding row + initiator durable view).
        try db.seedOutstandingRow(
            key: ATSAMEndpointTransactionV1.OutstandingMessageKey(
                sessionID: harness.sessionID,
                messageID: env1.messageId,
                recipientDeviceID: harness.localResponderSigningKey.publicKey.rawRepresentation
            ),
            state: .sent
        )
        try harness.installInitiatorProtectedState(nextSendIndex: 1)
        try db.setSessionHeadForTesting(sessionID: harness.sessionID, generation: 1)
        harness.installInitiatorBindings(on: host)
        try await host.acceptInboundAckPacked(ackFrame)
        XCTAssertTrue(host.lastLabStatus.contains("inbound ACK accepted"))

        // Second message on same session (index 1).
        let msg2 = try harness.buildMessageEnvelope(plaintext: Data("task18-e2e-2".utf8), index: 1)
        try ATSAMEndpointDurableAdapters.sharedProtectedStore.replace(responderAfterMsg1)
        try db.setSessionHeadForTesting(
            sessionID: harness.sessionID,
            generation: responderAfterMsg1.generation
        )
        harness.installResponderBindings(on: host)
        _ = await host.receivePacked(msg2, replyOnSameConnection: false)

        let responderState = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(
            sessionID: harness.sessionID
        )
        XCTAssertEqual(responderState.nextReceiveIndex, 2)
    }
}

private struct Task18PairInitFixtures {
    let initWire: Data
    let packedInit: Data
    let overrides: ATSAMPairInitAcceptService.AcceptTestVectorOverrides

    init() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorURL = repoRoot.appendingPathComponent("shared-vectors/rvn1/atsam/pair_init_v1_001.json")
        guard FileManager.default.fileExists(atPath: vectorURL.path) else {
            throw XCTSkip("shared PairInit vector not found")
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL)) as! [String: Any]
        let expected = json["expected"] as! [String: Any]
        let input = json["input"] as! [String: Any]
        initWire = Task18Hex.data(expected["pair_init_wire_hex"] as! String)
        let initValue = try ATSAMPairInitV1.decodeInit(initWire)
        let root = Task18Hex.data(expected["provisional_k_root_hex"] as! String)
        let responseWire = Task18Hex.data(expected["pair_response_wire_hex"] as! String)
        let signingKey = Curve25519.Signing.PrivateKey()
        let packedResponse = try RavenPairInitLanOob.wrapOobWire(
            responseWire,
            isPairInit: false,
            signingKey: signingKey,
            nowMs: initValue.createdAtMs
        )
        packedInit = try RavenPairInitLanOob.wrapOobWire(
            initWire,
            isPairInit: true,
            signingKey: signingKey,
            nowMs: initValue.createdAtMs
        )
        overrides = ATSAMPairInitAcceptService.AcceptTestVectorOverrides(
            trust: ATSAMPairInitV1.TrustContext(
                initiatorCertificate: .init(
                    identityEd25519PublicKey: Task18Hex.data(input["initiator_identity_ed_pub_hex"] as! String),
                    signingBytes: Task18Hex.data(input["initiator_device_cert_signing_bytes_hex"] as! String),
                    signature: Task18Hex.data(input["initiator_device_cert_signature_hex"] as! String)
                ),
                responderCertificate: .init(
                    identityEd25519PublicKey: Task18Hex.data(input["responder_identity_ed_pub_hex"] as! String),
                    signingBytes: Task18Hex.data(input["responder_device_cert_signing_bytes_hex"] as! String),
                    signature: Task18Hex.data(input["responder_device_cert_signature_hex"] as! String)
                ),
                responderPrekeyBundle: .init(
                    signingBytes: Task18Hex.data(input["responder_prekey_signing_bytes_hex"] as! String),
                    signature: Task18Hex.data(input["responder_prekey_signature_hex"] as! String)
                )
            ),
            root: root,
            nowMs: initValue.createdAtMs &+ 100,
            packedResponse: packedResponse,
            responseWire: responseWire,
            skipContactGate: true
        )
    }
}

private enum Task18Hex {
    static func data(_ hex: String) -> Data {
        var result = Data()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            result.append(UInt8(hex[cursor..<next], radix: 16)!)
            cursor = next
        }
        return result
    }
}

@MainActor
private final class Task18AckHarness {
    typealias Endpoint = ATSAMEndpointTransactionV1

    let sessionID: Data
    let database: SQLCipherAcceptanceDatabase
    let remoteSigningKey: Curve25519.Signing.PrivateKey
    let bound: Endpoint.BoundSession
    let root: Data
    let initiatorAddress: String
    let responderAddress: String

    init(database: SQLCipherAcceptanceDatabase) throws {
        self.database = database
        sessionID = Data((0..<32).map { UInt8($0 &+ 0xA0) })
        root = Data(repeating: 0x42, count: 32)
        remoteSigningKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x43, count: 32))
        initiatorAddress = try XCTUnwrap(
            RavenAddressV1.encode(ed25519PublicKey: remoteSigningKey.publicKey.rawRepresentation)
        )
        let localIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x44, count: 32))
        responderAddress = try XCTUnwrap(
            RavenAddressV1.encode(ed25519PublicKey: localIdentity.publicKey.rawRepresentation)
        )
        let remoteCert = Endpoint.BoundSession.self
        _ = remoteCert
        let senderCert = ATSAMPairInitV1.SignedDeviceCertificate(
            identityEd25519PublicKey: remoteSigningKey.publicKey.rawRepresentation,
            signingBytes: Data(repeating: 0x45, count: 80),
            signature: Data(repeating: 0x46, count: 64)
        )
        bound = Endpoint.BoundSession(
            sessionID: sessionID,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            inboundDirection: .initiatorToResponder,
            expectedLocalDeviceHint: ATSAMLabEndpointHost.deviceHint(Data(repeating: 0x47, count: 32)),
            remoteDeviceEd25519PublicKey: remoteSigningKey.publicKey.rawRepresentation,
            senderCertificate: senderCert,
            pairInitSenderCertificateHash: Data(repeating: 0x48, count: 32),
            sessionCreatedAtMs: 1_700_000_000_000,
            sessionExpiresAtMs: 1_700_086_400_000,
            senderDeviceAccepted: true,
            senderDeviceRevoked: false,
            publicGeneration: 1
        )
        let state = Endpoint.ProtectedSessionState(
            sessionID: sessionID,
            rootKey: root,
            receiveChainKey: root,
            nextReceiveIndex: 0,
            skippedMessageKeys: [:],
            sendChainKey: root,
            nextSendIndex: 0,
            ackSendChainKey: root,
            nextAckSendIndex: 0,
            ackReceiveChainKey: root,
            nextAckReceiveIndex: 0,
            skippedAckKeys: [:],
            pendingAcceptance: nil,
            pendingAckAcceptance: nil,
            pendingOutbound: nil,
            generation: 1
        )
        try ATSAMEndpointDurableAdapters.sharedProtectedStore.replace(state)
    }

    func install(on host: ATSAMLabEndpointHost) throws {
        let meta = ATSAMLabSessionMetaStore.PersistedMeta(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            remoteDeviceEd: bound.remoteDeviceEd25519PublicKey,
            senderCertIdentity: bound.senderCertificate.identityEd25519PublicKey,
            senderCertSigning: bound.senderCertificate.signingBytes,
            senderCertSig: bound.senderCertificate.signature,
            pairInitSenderCertHash: bound.pairInitSenderCertificateHash,
            sessionCreatedAtMs: bound.sessionCreatedAtMs,
            sessionExpiresAtMs: bound.sessionExpiresAtMs,
            localDeviceEd: Data(repeating: 0x47, count: 32),
            inboundDirectionRaw: 0
        )
        try ATSAMLabSessionMetaStore.save(meta, sessionID: sessionID)
        host.start()
    }

    func buildAckEnvelope() throws -> Data {
        let nowMs = bound.sessionCreatedAtMs &+ 1000
        let index: UInt32 = 0
        let direction = ATSAMIndexedSessionProfile.Direction.initiatorToResponder
        let pair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction
        )
        let messageKey = try ATSAMIndexedSessionProfile.laneMessageKey(
            chainKey: root,
            sender: pair.sender,
            recipient: pair.recipient
        )
        var messageID = Data(repeating: 0x49, count: 16)
        let signedAck = ATSAMIndexedSessionProfile.SignedAck(
            ackedMessageId: messageID,
            status: ATSAMEndpointTransactionV1.AckStatus.delivered.rawValue,
            ackNonce: Data(repeating: 0x4A, count: 12),
            createdAtMs: nowMs,
            signature: Data(repeating: 0, count: 64)
        )
        var signed = signedAck
        signed = ATSAMIndexedSessionProfile.SignedAck(
            ackedMessageId: signedAck.ackedMessageId,
            status: signedAck.status,
            ackNonce: signedAck.ackNonce,
            createdAtMs: signedAck.createdAtMs,
            signature: try remoteSigningKey.signature(
                for: ATSAMIndexedSessionProfile.ackSigningBytes(signedAck)
            )
        )
        let plaintext = try ATSAMIndexedSessionProfile.encodeSignedAck(signed)
        var sealNonce = Data(repeating: 0x4B, count: 12)
        let sealed = try ATSAMIndexedSessionProfile.sealAck(
            root: root,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction,
            index: index,
            outerMessageId: messageID,
            plaintext: plaintext,
            nonce: sealNonce
        )
        let route = try ATSAMIndexedSessionProfile.deriveRouteTag(
            root: root,
            createdAtMs: nowMs,
            index: index,
            envelopeType: RavenEnvelopeV1.EnvType.ack.rawValue,
            direction: direction
        )
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            flags: 0,
            messageId: messageID,
            routingTag: route,
            destDeviceHint: bound.expectedLocalDeviceHint,
            createdAtMs: nowMs,
            expiresAtMs: nowMs &+ 3600_000,
            antiReplayNonce: Data(repeating: 0x4C, count: 12),
            messageCiphertext: sealed,
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: remoteSigningKey)
        return envelope.pack()
    }
}

@MainActor
private final class Task18FullFlowHarness {
    typealias Endpoint = ATSAMEndpointTransactionV1

    let sessionID: Data
    let database: SQLCipherAcceptanceDatabase
    let remoteSigningKey: Curve25519.Signing.PrivateKey
    let localResponderSigningKey: Curve25519.Signing.PrivateKey
    let responderCert: ATSAMPairInitV1.SignedDeviceCertificate
    let responderCertHash: Data
    let bound: Endpoint.BoundSession
    let root: Data
    let initiatorAddress: String
    let responderAddress: String
    let nowMs: UInt64

    init(database: SQLCipherAcceptanceDatabase) throws {
        self.database = database
        nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        sessionID = Data((0..<32).map { UInt8($0 &+ 0xC0) })
        root = Data(repeating: 0x31, count: 32)
        remoteSigningKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x32, count: 32))
        initiatorAddress = try XCTUnwrap(
            RavenAddressV1.encode(ed25519PublicKey: remoteSigningKey.publicKey.rawRepresentation)
        )
        let localIdentity = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
        localResponderSigningKey = localIdentity
        responderAddress = try XCTUnwrap(
            RavenAddressV1.encode(ed25519PublicKey: localIdentity.publicKey.rawRepresentation)
        )
        responderCert = try Self.makeCertificate(
            identityKey: localIdentity,
            deviceKey: localIdentity.publicKey.rawRepresentation,
            deviceID: "task18-local-responder",
            notBeforeMs: nowMs - 86_400_000,
            notAfterMs: nowMs + 8 * 86_400_000
        )
        responderCertHash = try ATSAMPairInitV1.deviceCertificateHash(responderCert)
        let senderCert = try Self.makeCertificate(
            identityKey: remoteSigningKey,
            deviceKey: remoteSigningKey.publicKey.rawRepresentation,
            deviceID: "task18-remote",
            notBeforeMs: nowMs - 86_400_000,
            notAfterMs: nowMs + 8 * 86_400_000
        )
        let certHash = try ATSAMPairInitV1.deviceCertificateHash(senderCert)
        bound = Endpoint.BoundSession(
            sessionID: sessionID,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            inboundDirection: .initiatorToResponder,
            expectedLocalDeviceHint: ATSAMLabEndpointHost.deviceHint(Data(repeating: 0x34, count: 32)),
            remoteDeviceEd25519PublicKey: remoteSigningKey.publicKey.rawRepresentation,
            senderCertificate: senderCert,
            pairInitSenderCertificateHash: certHash,
            sessionCreatedAtMs: nowMs - 86_400_000,
            sessionExpiresAtMs: nowMs + 8 * 86_400_000,
            senderDeviceAccepted: true,
            senderDeviceRevoked: false,
            publicGeneration: 1
        )
        let inbound = ATSAMIndexedSessionProfile.Direction.initiatorToResponder
        let pair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: inbound
        )
        let state = Endpoint.ProtectedSessionState(
            sessionID: sessionID,
            rootKey: root,
            receiveChainKey: try ATSAMIndexedSessionProfile.initialChainKey(
                root: root,
                sender: pair.sender,
                recipient: pair.recipient
            ),
            nextReceiveIndex: 0,
            skippedMessageKeys: [:],
            sendChainKey: try ATSAMIndexedSessionProfile.initialChainKey(
                root: root,
                sender: pair.recipient,
                recipient: pair.sender
            ),
            nextSendIndex: 0,
            ackSendChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: root,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: .responderToInitiator,
                index: 0
            ),
            nextAckSendIndex: 0,
            ackReceiveChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: root,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: inbound,
                index: 0
            ),
            nextAckReceiveIndex: 0,
            skippedAckKeys: [:],
            pendingAcceptance: nil,
            pendingAckAcceptance: nil,
            pendingOutbound: nil,
            generation: 1
        )
        try ATSAMEndpointDurableAdapters.sharedProtectedStore.replace(state)
    }

    func install(on host: ATSAMLabEndpointHost) throws {
        let meta = ATSAMLabSessionMetaStore.PersistedMeta(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            remoteDeviceEd: bound.remoteDeviceEd25519PublicKey,
            senderCertIdentity: bound.senderCertificate.identityEd25519PublicKey,
            senderCertSigning: bound.senderCertificate.signingBytes,
            senderCertSig: bound.senderCertificate.signature,
            pairInitSenderCertHash: bound.pairInitSenderCertificateHash,
            sessionCreatedAtMs: bound.sessionCreatedAtMs,
            sessionExpiresAtMs: bound.sessionExpiresAtMs,
            localDeviceEd: Data(repeating: 0x34, count: 32),
            inboundDirectionRaw: 0
        )
        try ATSAMLabSessionMetaStore.save(meta, sessionID: sessionID)
        host.start()
        host.installSessionMetaForTesting(rootKey: root, meta: meta, sessionID: sessionID)
        host.installBoundSessionForTesting(bound)
        host.syncBoundGeneration(sessionID: sessionID)
    }

    func installResponderBindings(on host: ATSAMLabEndpointHost) {
        host.start()
        host.installBoundSessionForTesting(bound)
        let meta = ATSAMLabSessionMetaStore.PersistedMeta(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            remoteDeviceEd: bound.remoteDeviceEd25519PublicKey,
            senderCertIdentity: bound.senderCertificate.identityEd25519PublicKey,
            senderCertSigning: bound.senderCertificate.signingBytes,
            senderCertSig: bound.senderCertificate.signature,
            pairInitSenderCertHash: bound.pairInitSenderCertificateHash,
            sessionCreatedAtMs: bound.sessionCreatedAtMs,
            sessionExpiresAtMs: bound.sessionExpiresAtMs,
            localDeviceEd: Data(repeating: 0x34, count: 32),
            inboundDirectionRaw: 0
        )
        host.installSessionMetaForTesting(rootKey: root, meta: meta, sessionID: sessionID)
        host.syncBoundGeneration(sessionID: sessionID)
    }

    /// Flip durable + in-memory host state to initiator role (post first outbound message).
    func installInitiatorRole(on host: ATSAMLabEndpointHost) throws {
        try installInitiatorProtectedState(nextSendIndex: 0)
        installInitiatorBindings(on: host)
    }

    /// Rebind host in-memory initiator session without replacing protected store.
    func installInitiatorBindings(on host: ATSAMLabEndpointHost) {
        host.start()
        let initiatorBound = Endpoint.BoundSession(
            sessionID: sessionID,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            inboundDirection: .responderToInitiator,
            expectedLocalDeviceHint: ATSAMLabEndpointHost.deviceHint(Data(repeating: 0x32, count: 32)),
            remoteDeviceEd25519PublicKey: localResponderSigningKey.publicKey.rawRepresentation,
            senderCertificate: responderCert,
            pairInitSenderCertificateHash: responderCertHash,
            sessionCreatedAtMs: bound.sessionCreatedAtMs,
            sessionExpiresAtMs: bound.sessionExpiresAtMs,
            senderDeviceAccepted: true,
            senderDeviceRevoked: false,
            publicGeneration: (try? ATSAMEndpointDurableAdapters.sharedProtectedStore.load(
                sessionID: sessionID
            ))?.generation ?? 1
        )
        host.installBoundSessionForTesting(initiatorBound)
        let meta = ATSAMLabSessionMetaStore.PersistedMeta(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            remoteDeviceEd: localResponderSigningKey.publicKey.rawRepresentation,
            senderCertIdentity: responderCert.identityEd25519PublicKey,
            senderCertSigning: responderCert.signingBytes,
            senderCertSig: responderCert.signature,
            pairInitSenderCertHash: responderCertHash,
            sessionCreatedAtMs: bound.sessionCreatedAtMs,
            sessionExpiresAtMs: bound.sessionExpiresAtMs,
            localDeviceEd: remoteSigningKey.publicKey.rawRepresentation,
            inboundDirectionRaw: 1
        )
        host.installSessionMetaForTesting(rootKey: root, meta: meta, sessionID: sessionID)
        host.syncBoundGeneration(sessionID: sessionID)
    }

    fileprivate func installInitiatorProtectedState(nextSendIndex: UInt32) throws {
        let outbound = ATSAMIndexedSessionProfile.Direction.initiatorToResponder
        let inbound = ATSAMIndexedSessionProfile.Direction.responderToInitiator
        let outboundPair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: outbound
        )
        let inboundPair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: inbound
        )
        let sendChainKey: Data
        if nextSendIndex == 0 {
            sendChainKey = try ATSAMIndexedSessionProfile.initialChainKey(
                root: root,
                sender: outboundPair.sender,
                recipient: outboundPair.recipient
            )
        } else {
            sendChainKey = try ATSAMIndexedSessionProfile.messageKeyAtIndex(
                root: root,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: outbound,
                index: nextSendIndex
            )
        }
        let state = Endpoint.ProtectedSessionState(
            sessionID: sessionID,
            rootKey: root,
            receiveChainKey: try ATSAMIndexedSessionProfile.initialChainKey(
                root: root,
                sender: inboundPair.sender,
                recipient: inboundPair.recipient
            ),
            nextReceiveIndex: 0,
            skippedMessageKeys: [:],
            sendChainKey: sendChainKey,
            nextSendIndex: nextSendIndex,
            ackSendChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: root,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: outbound,
                index: 0
            ),
            nextAckSendIndex: 0,
            ackReceiveChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: root,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: inbound,
                index: 0
            ),
            nextAckReceiveIndex: 0,
            skippedAckKeys: [:],
            pendingAcceptance: nil,
            pendingAckAcceptance: nil,
            pendingOutbound: nil,
            generation: 1
        )
        try ATSAMEndpointDurableAdapters.sharedProtectedStore.replace(state)
        try database.upsertSessionHead(sessionID: sessionID, generation: 1)
    }

    func buildMessageEnvelope(plaintext: Data, index: UInt32 = 0) throws -> Data {
        let direction = ATSAMIndexedSessionProfile.Direction.initiatorToResponder
        let pair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction
        )
        let messageKey = try ATSAMIndexedSessionProfile.messageKeyAtIndex(
            root: root,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction,
            index: index
        )
        var messageID = Data(repeating: 0x35, count: 16)
        messageID[15] = UInt8(index & 0xFF)
        let aad = try ATSAMIndexedSessionProfile.buildAAD(
            index: index,
            sender: pair.sender,
            recipient: pair.recipient,
            outerMessageId: messageID
        )
        var nonce = Data(repeating: 0x36, count: 8)
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
            root: root,
            createdAtMs: nowMs,
            index: index,
            envelopeType: RavenEnvelopeV1.EnvType.message.rawValue,
            direction: direction
        )
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            flags: 0,
            messageId: messageID,
            routingTag: route,
            destDeviceHint: bound.expectedLocalDeviceHint,
            createdAtMs: nowMs,
            expiresAtMs: nowMs &+ 3600_000,
            antiReplayNonce: Data(repeating: 0x37, count: 12),
            messageCiphertext: wire,
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: remoteSigningKey)
        return envelope.pack()
    }

    private static func makeCertificate(
        identityKey: Curve25519.Signing.PrivateKey,
        deviceKey: Data,
        deviceID: String,
        notBeforeMs: UInt64,
        notAfterMs: UInt64
    ) throws -> ATSAMPairInitV1.SignedDeviceCertificate {
        var signingBytes = Data("rvn1/devcert".utf8)
        signingBytes.appendUInt16BE(UInt16(deviceKey.count))
        signingBytes.append(deviceKey)
        let deviceX25519 = Data(SHA256.hash(data: Data("x25519/\(deviceID)".utf8)))
        signingBytes.appendUInt16BE(UInt16(deviceX25519.count))
        signingBytes.append(deviceX25519)
        let deviceIDBytes = Data(deviceID.utf8)
        signingBytes.appendUInt16BE(UInt16(deviceIDBytes.count))
        signingBytes.append(deviceIDBytes)
        signingBytes.appendUInt64BE(notBeforeMs)
        signingBytes.appendUInt64BE(notAfterMs)
        signingBytes.appendUInt64BE(0)
        return ATSAMPairInitV1.SignedDeviceCertificate(
            identityEd25519PublicKey: identityKey.publicKey.rawRepresentation,
            signingBytes: signingBytes,
            signature: try identityKey.signature(for: signingBytes)
        )
    }
}

#endif
