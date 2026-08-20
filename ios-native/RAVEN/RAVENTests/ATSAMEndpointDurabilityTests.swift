//
//  ATSAMEndpointDurabilityTests.swift
//  RAVENTests
//
//  Session mutation lease (G1) and related durability guardrails.
//

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

private typealias Endpoint = ATSAMEndpointTransactionV1
private typealias TxError = ATSAMEndpointTransactionV1.TransactionError

final class ATSAMEndpointDurabilityTests: XCTestCase {

    // MARK: - Session mutation lease (G1)

    func testMutationLeaseReentryFailsClosed() throws {
        let lease = ATSAMSessionMutationLease()
        let sessionID = Data(repeating: 0xAB, count: 32)

        try lease.acquire(sessionID: sessionID)

        XCTAssertThrowsError(try lease.acquire(sessionID: sessionID)) { error in
            XCTAssertEqual(error as? TxError, .mutationInProgress)
        }

        lease.release(sessionID: sessionID)
        XCTAssertNoThrow(try lease.acquire(sessionID: sessionID))
        lease.release(sessionID: sessionID)
    }

    func testMutationLeaseWithLeaseReleasesOnThrow() {
        let lease = ATSAMSessionMutationLease()
        let sessionID = Data(repeating: 0xCD, count: 32)

        XCTAssertThrowsError(
            try lease.withLease(sessionID: sessionID) {
                throw TxError.mutationInProgress
            }
        )

        XCTAssertNoThrow(try lease.acquire(sessionID: sessionID))
        lease.release(sessionID: sessionID)
    }

    func testReceiveFailsWhenSessionLeaseAlreadyHeld() async throws {
        let harness = try LeaseHarness()
        let lease = ATSAMSessionMutationLease()
        try lease.acquire(sessionID: harness.sessionID)

        let receiver = Endpoint.Receiver(
            protectedStore: harness.store,
            database: harness.database,
            mutationLease: lease
        )

        defer { lease.release(sessionID: harness.sessionID) }

        do {
            _ = try await receiver.receive(
                packedEnvelope: try harness.packedEnvelope(),
                session: harness.boundSession,
                nowMs: harness.nowMs
            )
            XCTFail("Expected mutationInProgress")
        } catch TxError.mutationInProgress {
            // Expected: fail-closed while lease is held externally.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAckEnqueueFailsWhenSessionLeaseAlreadyHeld() async throws {
        let harness = try LeaseHarness()
        harness.database.ackIntents[harness.receiptKey] = harness.pendingAckIntent

        let lease = ATSAMSessionMutationLease()
        try lease.acquire(sessionID: harness.sessionID)

        let worker = Endpoint.AckWorker(
            protectedStore: harness.store,
            database: harness.database,
            queue: harness.queue,
            materializer: harness.materializer,
            mutationLease: lease
        )

        defer { lease.release(sessionID: harness.sessionID) }

        do {
            _ = try await worker.enqueueOneCommittedAck(
                session: harness.boundSession,
                nowMs: harness.nowMs
            )
            XCTFail("Expected mutationInProgress")
        } catch TxError.mutationInProgress {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Receive path order (§4.5) + ACK intent in same SQL tx

    func testExactDuplicateAfterOuterAuthDoesNotDecryptOrAdvanceRatchet() async throws {
        let harness = try ReceiveOrderHarness()
        let packed = try harness.packedEnvelope()
        let receiver = harness.receiver()
        _ = try await receiver.receive(
            packedEnvelope: packed,
            session: harness.session(),
            nowMs: harness.nowMs
        )
        let authenticatorCalls = harness.authenticator.callCount
        let nextIndex = harness.store.states[harness.sessionID]?.nextReceiveIndex

        let duplicate = try await receiver.receive(
            packedEnvelope: packed,
            session: harness.session(),
            nowMs: harness.nowMs
        )

        guard case .exactDuplicate = duplicate else {
            return XCTFail("expected exact duplicate after outer authentication")
        }
        XCTAssertEqual(harness.authenticator.callCount, authenticatorCalls)
        XCTAssertEqual(harness.store.states[harness.sessionID]?.nextReceiveIndex, nextIndex)
        XCTAssertEqual(harness.database.receipts.count, 1)
        XCTAssertEqual(harness.database.ackIntents.count, 1)
    }

    func testAckIntentRowExistsAfterDatabaseCommitBeforeJournalClear() async throws {
        let harness = try ReceiveOrderHarness()
        let packed = try harness.packedEnvelope()
        do {
            _ = try await harness.receiver(
                faults: OneShotFaults(.afterDatabaseCommit)
            ).receive(
                packedEnvelope: packed,
                session: harness.session(),
                nowMs: harness.nowMs
            )
            XCTFail("expected simulated crash after database commit")
        } catch let error as TxError {
            XCTAssertEqual(error, .simulatedCrash(.afterDatabaseCommit))
        }

        XCTAssertEqual(harness.database.receipts.count, 1)
        XCTAssertEqual(harness.database.ackIntents.count, 1)
        let intent = try XCTUnwrap(harness.database.ackIntents.values.first)
        XCTAssertNil(intent.stagedEnvelope)
        XCTAssertFalse(intent.isQueued)
        XCTAssertNotNil(harness.store.states[harness.sessionID]?.pendingAcceptance)
    }

    func testAckIntentPersistsAfterJournalClear() async throws {
        let harness = try ReceiveOrderHarness()
        let packed = try harness.packedEnvelope()
        let outcome = try await harness.receiver().receive(
            packedEnvelope: packed,
            session: harness.session(),
            nowMs: harness.nowMs
        )
        guard case .committed = outcome else {
            return XCTFail("expected committed receive")
        }

        XCTAssertEqual(harness.database.receipts.count, 1)
        XCTAssertEqual(harness.database.ackIntents.count, 1)
        XCTAssertNil(harness.store.states[harness.sessionID]?.pendingAcceptance)
        let intent = try XCTUnwrap(harness.database.ackIntents.values.first)
        XCTAssertNil(intent.stagedEnvelope)
        XCTAssertFalse(intent.isQueued)
    }

    // MARK: - Outbound body stage (§4.6) + orphan policy (G2)

    func testOutboundStageRoundTripBindingsAndMagic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atsam-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ATSAMOutboundBodyStage.Store(
            directory: root,
            protector: ATSAMOutboundBodyStage.ScopedAeadProtector(
                fixedKeyBytes: Data(repeating: 0x5A, count: 32)
            )
        )
        let peer = Data(repeating: 0x11, count: 32)
        let sessionID = Data(repeating: 0x22, count: 32)
        let digest = Data(repeating: 0x33, count: 32)
        let messageID = Data(repeating: 0x44, count: 16)

        try store.stage(
            peerPub: peer,
            sessionID: sessionID,
            objectDigest: digest,
            messageID: messageID,
            createdAtMs: 1_786_579_200_000,
            body: "stage round trip"
        )

        let onDisk = root.appendingPathComponent(ATSAMOutboundBodyStage.fileName)
        let bytes = try Data(contentsOf: onDisk)
        XCTAssertTrue(bytes.starts(with: ATSAMOutboundBodyStage.magic))

        let loaded = try XCTUnwrap(try store.load(messageID: messageID))
        XCTAssertEqual(loaded.body, "stage round trip")
        XCTAssertEqual(
            loaded.peerPubHex,
            peer.map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(
            loaded.sessionIDHex,
            sessionID.map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(
            loaded.objectDigestHex,
            digest.map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(
            loaded.messageIDHex,
            messageID.map { String(format: "%02x", $0) }.joined()
        )
    }

    func testOrphanStageDeleteNeverDials() async throws {
        let harness = try SendOrderHarness()
        let orphanDigest = Data(repeating: 0x99, count: 32)
        try harness.bodyStage.stage(
            peerPub: harness.peerPub,
            sessionID: harness.sessionID,
            objectDigest: orphanDigest,
            messageID: harness.messageID,
            createdAtMs: harness.nowMs,
            body: "orphan body"
        )
        XCTAssertEqual(harness.dialer.callCount, 0)

        let sender = harness.sender()
        let reconciled = try await sender.reconcileOrphanStages()
        XCTAssertEqual(reconciled.count, 1)
        guard case let .deleted(messageID) = reconciled[0] else {
            return XCTFail("expected orphan deletion")
        }
        XCTAssertEqual(messageID, harness.messageID)
        XCTAssertNil(try harness.bodyStage.load(messageID: harness.messageID))
        XCTAssertEqual(harness.dialer.callCount, 0)
    }

    func testStageBeforeOutboxCrashWindow() async throws {
        let harness = try SendOrderHarness()
        do {
            _ = try await harness.sender(
                faults: OneShotFaults(.afterOutboundStage)
            ).send(
                text: Data("crash after stage".utf8),
                session: harness.boundSession(),
                createdAtMs: harness.nowMs,
                expiresAtMs: harness.nowMs + 60_000
            )
            XCTFail("expected simulated crash after stage")
        } catch let error as TxError {
            XCTAssertEqual(error, .simulatedCrash(.afterOutboundStage))
        }

        XCTAssertNotNil(try harness.bodyStage.load(messageID: harness.messageID))
        let staged = try XCTUnwrap(try harness.bodyStage.load(messageID: harness.messageID))
        let stagedDigest = try XCTUnwrap(ATSAMOutboundBodyStage.parseHex32(staged.objectDigestHex))
        XCTAssertFalse(try harness.database.hasOutboxRow(
            sessionID: harness.sessionID,
            objectDigest: stagedDigest
        ))
        XCTAssertNil(harness.store.states[harness.sessionID]?.pendingOutbound)
        XCTAssertEqual(harness.dialer.callCount, 0)

        let reconciled = try await harness.sender().reconcileOrphanStages()
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertNil(try harness.bodyStage.load(messageID: harness.messageID))
        XCTAssertEqual(harness.dialer.callCount, 0)
    }

    func testSendCommitsOutboxBeforeDialOutsideLease() async throws {
        let harness = try SendOrderHarness()
        let outcome = try await harness.sender().send(
            text: Data("queued send".utf8),
            session: harness.boundSession(),
            createdAtMs: harness.nowMs,
            expiresAtMs: harness.nowMs + 60_000
        )
        guard case let .queued(objectDigest, messageID) = outcome else {
            return XCTFail("expected queued outcome")
        }
        XCTAssertEqual(messageID, harness.messageID)
        XCTAssertTrue(try harness.database.hasOutboxRow(
            sessionID: harness.sessionID,
            objectDigest: objectDigest
        ))
        XCTAssertNil(harness.store.states[harness.sessionID]?.pendingOutbound)
        XCTAssertNotNil(try harness.bodyStage.load(messageID: messageID))
        XCTAssertEqual(harness.dialer.callCount, 1)
    }

    func testSendFailsWhenSessionLeaseAlreadyHeld() async throws {
        let harness = try SendOrderHarness()
        let lease = ATSAMSessionMutationLease()
        try lease.acquire(sessionID: harness.sessionID)
        defer { lease.release(sessionID: harness.sessionID) }

        do {
            _ = try await harness.sender(mutationLease: lease).send(
                text: Data("blocked send".utf8),
                session: harness.boundSession(),
                createdAtMs: harness.nowMs,
                expiresAtMs: harness.nowMs + 60_000
            )
            XCTFail("expected mutationInProgress")
        } catch TxError.mutationInProgress {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(harness.dialer.callCount, 0)
    }
}

// MARK: - Receive path order harness (§4.5)

private final class ReceiveOrderHarness {

    let sessionID: Data
    let nowMs: UInt64
    let boundSession: Endpoint.BoundSession
    let store: MemoryProtectedStore
    let database: MemoryDatabase
    let authenticator: CountingAuthenticator

    private let rootKey: Data
    private let senderSigningKey: Curve25519.Signing.PrivateKey
    private let initiatorAddress: String
    private let responderAddress: String

    init() throws {
        nowMs = 1_786_579_200_000
        rootKey = Data(0..<32)
        sessionID = Data(SHA256.hash(data: Data("receive-order-harness".utf8)))
        senderSigningKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((1...32).map(UInt8.init))
        )
        let initiatorIdentity = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((65...96).map(UInt8.init))
        )
        let responderIdentity = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((97...128).map(UInt8.init))
        )
        initiatorAddress = try XCTUnwrap(
            RavenAddressV1.encode(
                ed25519PublicKey: initiatorIdentity.publicKey.rawRepresentation
            )
        )
        responderAddress = try XCTUnwrap(
            RavenAddressV1.encode(
                ed25519PublicKey: responderIdentity.publicKey.rawRepresentation
            )
        )
        let certificate = try LeaseHarness.makeCertificate(
            identityKey: initiatorIdentity,
            deviceKey: senderSigningKey.publicKey.rawRepresentation,
            deviceID: "initiator-device",
            notBeforeMs: nowMs - 86_400_000,
            notAfterMs: nowMs + 8 * 86_400_000
        )
        let certificateHash = try ATSAMPairInitV1.deviceCertificateHash(certificate)
        let state = try LeaseHarness.initialState(
            sessionID: sessionID,
            rootKey: rootKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
        store = MemoryProtectedStore(state: state)
        database = MemoryDatabase()
        authenticator = CountingAuthenticator()
        boundSession = Endpoint.BoundSession(
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
            senderDeviceAccepted: true,
            senderDeviceRevoked: false,
            publicGeneration: 7
        )
    }

    func session() -> Endpoint.BoundSession {
        let generation = store.states[sessionID]?.generation ?? 7
        return Endpoint.BoundSession(
            sessionID: sessionID,
            initiatorAddress: boundSession.initiatorAddress,
            responderAddress: boundSession.responderAddress,
            inboundDirection: boundSession.inboundDirection,
            expectedLocalDeviceHint: boundSession.expectedLocalDeviceHint,
            remoteDeviceEd25519PublicKey: boundSession.remoteDeviceEd25519PublicKey,
            senderCertificate: boundSession.senderCertificate,
            pairInitSenderCertificateHash: boundSession.pairInitSenderCertificateHash,
            sessionCreatedAtMs: boundSession.sessionCreatedAtMs,
            sessionExpiresAtMs: boundSession.sessionExpiresAtMs,
            senderDeviceAccepted: boundSession.senderDeviceAccepted,
            senderDeviceRevoked: boundSession.senderDeviceRevoked,
            publicGeneration: generation
        )
    }

    func receiver(
        faults: any Endpoint.FaultInjector = Endpoint.NoFaults()
    ) -> Endpoint.Receiver {
        Endpoint.Receiver(
            protectedStore: store,
            database: database,
            authenticator: authenticator,
            faults: faults
        )
    }

    func packedEnvelope() throws -> Data {
        let index: UInt32 = 0
        let messageID = Data(repeating: 0x44, count: 16)
        let plaintext = Data("receive order harness plaintext".utf8)
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

private final class CountingAuthenticator: Endpoint.CandidateAuthenticator {
    private(set) var callCount = 0

    func authenticateAndAdvance(
        envelope: RavenEnvelopeV1,
        header: Endpoint.SealedMessageHeader,
        session: Endpoint.BoundSession,
        state: Endpoint.ProtectedSessionState
    ) throws -> Endpoint.AuthenticatedCandidate {
        callCount += 1
        return try Endpoint.IndexedSessionCandidateAuthenticator().authenticateAndAdvance(
            envelope: envelope,
            header: header,
            session: session,
            state: state
        )
    }
}

private final class OneShotFaults: Endpoint.FaultInjector {
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

// MARK: - Minimal harness for lease integration tests

private final class LeaseHarness {

    let sessionID: Data
    let nowMs: UInt64
    let boundSession: Endpoint.BoundSession
    let store: MemoryProtectedStore
    let database: MemoryDatabase
    let queue: MemoryQueue
    let materializer: StubAckMaterializer
    let receiptKey: Endpoint.ReceiptKey
    let pendingAckIntent: Endpoint.AckIntent

    private let rootKey: Data
    private let senderSigningKey: Curve25519.Signing.PrivateKey
    private let initiatorAddress: String
    private let responderAddress: String

    init() throws {
        nowMs = 1_786_579_200_000
        rootKey = Data(0..<32)
        sessionID = Data(SHA256.hash(data: Data("lease-harness-session".utf8)))
        senderSigningKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((1...32).map(UInt8.init))
        )
        let initiatorIdentity = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((65...96).map(UInt8.init))
        )
        let responderIdentity = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((97...128).map(UInt8.init))
        )
        initiatorAddress = try XCTUnwrap(
            RavenAddressV1.encode(
                ed25519PublicKey: initiatorIdentity.publicKey.rawRepresentation
            )
        )
        responderAddress = try XCTUnwrap(
            RavenAddressV1.encode(
                ed25519PublicKey: responderIdentity.publicKey.rawRepresentation
            )
        )
        let certificate = try Self.makeCertificate(
            identityKey: initiatorIdentity,
            deviceKey: senderSigningKey.publicKey.rawRepresentation,
            deviceID: "initiator-device",
            notBeforeMs: nowMs - 86_400_000,
            notAfterMs: nowMs + 8 * 86_400_000
        )
        let certificateHash = try ATSAMPairInitV1.deviceCertificateHash(certificate)
        let state = try Self.initialState(
            sessionID: sessionID,
            rootKey: rootKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
        store = MemoryProtectedStore(state: state)
        database = MemoryDatabase()
        queue = MemoryQueue()
        materializer = StubAckMaterializer()
        boundSession = Endpoint.BoundSession(
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
            senderDeviceAccepted: true,
            senderDeviceRevoked: false,
            publicGeneration: 7
        )
        let objectDigest = Data(repeating: 0xEE, count: 32)
        receiptKey = Endpoint.ReceiptKey(
            sessionID: sessionID,
            objectDigest: objectDigest
        )
        pendingAckIntent = Endpoint.AckIntent(
            receiptKey: receiptKey,
            ackedMessageID: Data(repeating: 0x11, count: 16),
            expectedRemoteDeviceID: senderSigningKey.publicKey.rawRepresentation,
            status: .delivered,
            sessionGeneration: state.generation,
            stagedEnvelope: nil,
            queueObjectID: nil,
            isQueued: false,
            isAbandoned: false
        )
    }

    func packedEnvelope() throws -> Data {
        let index: UInt32 = 0
        let messageID = Data(repeating: 0x44, count: 16)
        let plaintext = Data("hello from the lease harness".utf8)
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

    fileprivate static func initialState(
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

    fileprivate static func makeCertificate(
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

private final class MemoryProtectedStore: Endpoint.ProtectedStateStore {
    var states: [Data: Endpoint.ProtectedSessionState]

    init(state: Endpoint.ProtectedSessionState) {
        states = [state.sessionID: state]
    }

    func pendingSessionIDs() throws -> [Data] {
        states.values
            .filter {
                $0.pendingAcceptance != nil
                    || $0.pendingAckAcceptance != nil
                    || $0.pendingOutbound != nil
            }
            .map(\.sessionID)
    }

    func load(sessionID: Data) throws -> Endpoint.ProtectedSessionState {
        guard let state = states[sessionID] else {
            throw TxError.invalidProtectedState
        }
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

private final class MemoryDatabase: Endpoint.OutboundDatabase {
    var receipts: [Endpoint.ReceiptKey: Endpoint.CommittedReceipt] = [:]
    var logicalObjects: [Endpoint.LogicalMessageKey: Data] = [:]
    var ackIntents: [Endpoint.ReceiptKey: Endpoint.AckIntent] = [:]
    var outbox: Set<Data> = []

    func hasOutboxRow(sessionID: Data, objectDigest: Data) throws -> Bool {
        var key = Data()
        key.append(sessionID)
        key.append(objectDigest)
        return outbox.contains(key)
    }

    func beginImmediate() throws -> any Endpoint.AcceptanceDatabaseTransaction {
        LeaseTransaction(database: self)
    }

    func nextUnqueuedAckIntent() throws -> Endpoint.AckIntent? {
        ackIntents.values.first { !$0.isQueued && !$0.isAbandoned }
    }

    func allAckIntents() throws -> [Endpoint.AckIntent] {
        Array(ackIntents.values)
    }

    func markAckAbandoned(receiptKey: Endpoint.ReceiptKey) throws {
        guard var intent = ackIntents[receiptKey] else {
            throw TxError.noPendingAck
        }
        intent.isAbandoned = true
        intent.isQueued = false
        ackIntents[receiptKey] = intent
    }

    func stageAckEnvelope(
        receiptKey: Endpoint.ReceiptKey,
        packedEnvelope: Data,
        queueObjectID: Data
    ) throws -> Endpoint.AckIntent {
        guard var intent = ackIntents[receiptKey], !intent.isQueued else {
            throw TxError.noPendingAck
        }
        intent.stagedEnvelope = packedEnvelope
        intent.queueObjectID = queueObjectID
        ackIntents[receiptKey] = intent
        return intent
    }

    func markAckQueued(receiptKey: Endpoint.ReceiptKey, queueObjectID: Data) throws {
        guard var intent = ackIntents[receiptKey],
              intent.stagedEnvelope != nil,
              intent.queueObjectID == queueObjectID else {
            throw TxError.stagedAckCollision
        }
        intent.isQueued = true
        ackIntents[receiptKey] = intent
    }

    private final class LeaseTransaction: Endpoint.OutboundDatabaseTransaction {
        private unowned let database: MemoryDatabase
        private var pending: Endpoint.PendingAcceptance?
        private var pendingOutbound: Endpoint.PendingOutbound?
        private var active = true

        init(database: MemoryDatabase) {
            self.database = database
        }

        func existingReceipt(
            receiptKey: Endpoint.ReceiptKey,
            logicalKey: Endpoint.LogicalMessageKey
        ) throws -> Endpoint.CommittedReceipt? {
            guard active else { throw TxError.invalidProtectedState }
            if let receipt = database.receipts[receiptKey] {
                guard receipt.logicalKey == logicalKey else {
                    throw TxError.receiptCollision
                }
                return receipt
            }
            if let digest = database.logicalObjects[logicalKey] {
                guard digest == receiptKey.objectDigest else {
                    throw TxError.logicalMessageCollision
                }
                throw TxError.receiptCollision
            }
            return nil
        }

        func existingAckReceipt(
            receiptKey: Endpoint.ReceiptKey,
            outerMessageID: Data,
            remoteDeviceID: Data
        ) throws -> Endpoint.AckReceipt? {
            nil
        }

        func outstandingDeliveryState(
            _ key: Endpoint.OutstandingMessageKey
        ) throws -> Endpoint.DeliveryState? {
            nil
        }

        func ackNonceObjectDigest(
            sessionID: Data,
            remoteDeviceID: Data,
            ackNonce: Data
        ) throws -> Data? {
            nil
        }

        func insertAcceptance(
            _ pending: Endpoint.PendingAcceptance
        ) throws -> Endpoint.InsertOutcome {
            if let existing = try existingReceipt(
                receiptKey: pending.receiptKey,
                logicalKey: pending.logicalKey
            ) {
                guard existing.sealedLocalInboxRow == pending.sealedLocalInboxRow,
                      database.ackIntents[pending.receiptKey] == pending.ackIntent else {
                    throw TxError.receiptCollision
                }
                return .exactDuplicate(existing)
            }
            guard self.pending == nil,
                  pending.ackIntent.receiptKey == pending.receiptKey,
                  pending.ackIntent.ackedMessageID == pending.logicalKey.messageID,
                  pending.ackIntent.expectedRemoteDeviceID == pending.logicalKey.senderDeviceID,
                  pending.sessionGeneration == pending.ackIntent.sessionGeneration else {
                throw TxError.invalidProtectedState
            }
            self.pending = pending
            return .inserted(
                Endpoint.CommittedReceipt(
                    receiptKey: pending.receiptKey,
                    logicalKey: pending.logicalKey,
                    messageIndex: pending.messageIndex,
                    sealedLocalInboxRow: pending.sealedLocalInboxRow,
                    sessionGeneration: pending.sessionGeneration
                )
            )
        }

        func insertAckAcceptance(
            _ pending: Endpoint.PendingAckAcceptance
        ) throws -> Endpoint.AckInsertOutcome {
            throw TxError.invalidProtectedState
        }

        func insertPreparedOutbound(_ pending: Endpoint.PendingOutbound) throws {
            guard active else { throw TxError.invalidProtectedState }
            guard pendingOutbound == nil else {
                throw TxError.receiptCollision
            }
            pendingOutbound = pending
        }

        func insertAckMaterialization(
            pending: Endpoint.PendingOutbound,
            intentReceiptKey: Endpoint.ReceiptKey,
            packedEnvelope: Data,
            ackObjectDigest: Data
        ) throws {
            guard active else { throw TxError.invalidProtectedState }
            pendingOutbound = pending
        }

        func commitAndFsync() throws {
            guard active else { throw TxError.invalidProtectedState }
            if let value = pending {
                if let logicalDigest = database.logicalObjects[value.logicalKey],
                   logicalDigest != value.receiptKey.objectDigest {
                    throw TxError.logicalMessageCollision
                }
                let receipt = Endpoint.CommittedReceipt(
                    receiptKey: value.receiptKey,
                    logicalKey: value.logicalKey,
                    messageIndex: value.messageIndex,
                    sealedLocalInboxRow: value.sealedLocalInboxRow,
                    sessionGeneration: value.sessionGeneration
                )
                database.receipts[value.receiptKey] = receipt
                database.logicalObjects[value.logicalKey] = value.receiptKey.objectDigest
                if let existingIntent = database.ackIntents[value.receiptKey],
                   existingIntent != value.ackIntent {
                    throw TxError.receiptCollision
                }
                database.ackIntents[value.receiptKey] = value.ackIntent
            }
            if let outbound = pendingOutbound {
                var key = Data()
                key.append(outbound.sessionID)
                key.append(outbound.objectDigest)
                database.outbox.insert(key)
            }
            active = false
        }

        func rollback() {
            guard active else { return }
            active = false
            pending = nil
        }
    }
}

private final class MemoryQueue: Endpoint.ImmutableAckQueue {
    func enqueueImmutable(objectID: Data, packedEnvelope: Data) throws {}

    func contains(objectID: Data) throws -> Bool { false }

    @discardableResult
    func deleteIfPresent(objectID: Data) throws -> Bool { false }
}

private final class StubAckMaterializer: Endpoint.AckMaterializer {
    func prepareCommittedAck(
        intent: Endpoint.AckIntent,
        session: Endpoint.BoundSession,
        state: Endpoint.ProtectedSessionState,
        createdAtMs: UInt64,
        expiresAtMs: UInt64
    ) throws -> Endpoint.PreparedAckOutbound {
        let bytes = Data(repeating: 0xAC, count: 96)
        let ackDigest = Data(repeating: 0xBD, count: 32)
        let pending = Endpoint.PendingOutbound(
            sessionID: session.sessionID,
            objectDigest: ackDigest,
            messageID: Data(repeating: 0xCD, count: 16),
            recipientDevice: intent.expectedRemoteDeviceID,
            ratchetIndex: 0,
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

// MARK: - Send path harness (§4.6)

private final class SendOrderHarness {
    let sessionID: Data
    let nowMs: UInt64
    let peerPub: Data
    let messageID: Data
    let store: MemoryProtectedStore
    let database: MemoryDatabase
    let bodyStage: ATSAMOutboundBodyStage.Store
    let dialer: CountingDialer

    private let rootKey: Data
    fileprivate let localSigningKey: Curve25519.Signing.PrivateKey
    private let initiatorAddress: String
    private let responderAddress: String

    init() throws {
        nowMs = 1_786_579_200_000
        rootKey = Data((32..<64).map(UInt8.init))
        sessionID = Data(SHA256.hash(data: Data("send-order-harness".utf8)))
        messageID = Data(repeating: 0x55, count: 16)
        peerPub = Data((1...32).map(UInt8.init))
        localSigningKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((101...132).map(UInt8.init))
        )
        let initiatorIdentity = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((65...96).map(UInt8.init))
        )
        let responderIdentity = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((97...128).map(UInt8.init))
        )
        initiatorAddress = try XCTUnwrap(
            RavenAddressV1.encode(
                ed25519PublicKey: initiatorIdentity.publicKey.rawRepresentation
            )
        )
        responderAddress = try XCTUnwrap(
            RavenAddressV1.encode(
                ed25519PublicKey: responderIdentity.publicKey.rawRepresentation
            )
        )
        let state = try LeaseHarness.initialState(
            sessionID: sessionID,
            rootKey: rootKey,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress
        )
        store = MemoryProtectedStore(state: state)
        database = MemoryDatabase()
        dialer = CountingDialer()
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("atsam-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        bodyStage = ATSAMOutboundBodyStage.Store(
            directory: stageRoot,
            protector: ATSAMOutboundBodyStage.ScopedAeadProtector(
                fixedKeyBytes: Data(repeating: 0x7C, count: 32)
            )
        )
    }

    func boundSession() -> Endpoint.BoundSession {
        let generation = store.states[sessionID]?.generation ?? 7
        let certificate = try! LeaseHarness.makeCertificate(
            identityKey: try! Curve25519.Signing.PrivateKey(
                rawRepresentation: Data((65...96).map(UInt8.init))
            ),
            deviceKey: peerPub,
            deviceID: "remote-device",
            notBeforeMs: nowMs - 86_400_000,
            notAfterMs: nowMs + 8 * 86_400_000
        )
        let certificateHash = try! ATSAMPairInitV1.deviceCertificateHash(certificate)
        return Endpoint.BoundSession(
            sessionID: sessionID,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            inboundDirection: .initiatorToResponder,
            expectedLocalDeviceHint: 0x0102_0304_0506_0708,
            remoteDeviceEd25519PublicKey: peerPub,
            senderCertificate: certificate,
            pairInitSenderCertificateHash: certificateHash,
            sessionCreatedAtMs: nowMs - 86_400_000,
            sessionExpiresAtMs: nowMs + 8 * 86_400_000,
            senderDeviceAccepted: true,
            senderDeviceRevoked: false,
            publicGeneration: generation
        )
    }

    func sender(
        faults: any Endpoint.FaultInjector = Endpoint.NoFaults(),
        mutationLease: ATSAMSessionMutationLease = ATSAMSessionMutationLease()
    ) -> Endpoint.Sender {
        Endpoint.Sender(
            protectedStore: store,
            database: database,
            bodyStage: bodyStage,
            materializer: StubOutboundMaterializer(
                harness: self
            ),
            dialer: dialer,
            faults: faults,
            mutationLease: mutationLease
        )
    }
}

private final class CountingDialer: Endpoint.OutboundDialer {
    private(set) var callCount = 0

    func dial(packedEnvelope: Data, objectDigest: Data) throws {
        callCount += 1
    }
}

private final class StubOutboundMaterializer: Endpoint.OutboundMaterializer {
    private unowned let harness: SendOrderHarness

    init(harness: SendOrderHarness) {
        self.harness = harness
    }

    func prepareOutbound(
        text: Data,
        session: Endpoint.BoundSession,
        state: Endpoint.ProtectedSessionState,
        createdAtMs: UInt64,
        expiresAtMs: UInt64
    ) throws -> Endpoint.PreparedOutbound {
        let index = state.nextSendIndex
        let outboundPair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: session.initiatorAddress,
            responderAddress: session.responderAddress,
            direction: .responderToInitiator
        )
        var chainKey = state.sendChainKey
        let messageKey = try ATSAMIndexedSessionProfile.laneMessageKey(
            chainKey: chainKey,
            sender: outboundPair.sender,
            recipient: outboundPair.recipient
        )
        chainKey = try ATSAMIndexedSessionProfile.advanceChainKey(chainKey)
        let aad = try ATSAMIndexedSessionProfile.buildAAD(
            index: index,
            sender: outboundPair.sender,
            recipient: outboundPair.recipient,
            outerMessageId: harness.messageID
        )
        var nonce = Data(repeating: 0x30, count: 8)
        nonce.appendUInt32BE(index &+ 1)
        let box = try ChaChaPoly.seal(
            text,
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
            root: state.rootKey,
            createdAtMs: createdAtMs,
            index: index,
            envelopeType: RavenEnvelopeV1.EnvType.message.rawValue,
            direction: .responderToInitiator
        )
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            flags: 0,
            messageId: harness.messageID,
            routingTag: route,
            destDeviceHint: session.expectedLocalDeviceHint,
            createdAtMs: createdAtMs,
            expiresAtMs: expiresAtMs,
            antiReplayNonce: Data(repeating: 0x13, count: 12),
            messageCiphertext: wire,
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: harness.localSigningKey)
        let packed = envelope.pack()
        let digest = envelope.relayObjectDigest()
        let generation = state.generation + 1
        let pending = Endpoint.PendingOutbound(
            sessionID: session.sessionID,
            objectDigest: digest,
            messageID: harness.messageID,
            recipientDevice: session.remoteDeviceEd25519PublicKey,
            ratchetIndex: index,
            immutableEnvelopeBytes: packed,
            sessionGeneration: generation,
            sourceAckIntent: nil
        )
        return Endpoint.PreparedOutbound(
            peerPub: session.remoteDeviceEd25519PublicKey,
            sessionID: session.sessionID,
            objectDigest: digest,
            messageID: harness.messageID,
            createdAtMs: createdAtMs,
            body: String(data: text, encoding: .utf8) ?? "",
            packedEnvelope: packed,
            advancedSendChainKey: chainKey,
            advancedNextSendIndex: index + 1,
            committedGeneration: generation,
            pendingOutbound: pending
        )
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        appendUInt32BE(UInt32((value >> 32) & 0xFFFF_FFFF))
        appendUInt32BE(UInt32(value & 0xFFFF_FFFF))
    }
}
