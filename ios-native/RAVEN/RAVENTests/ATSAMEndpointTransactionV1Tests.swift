//
//  ATSAMEndpointTransactionV1Tests.swift
//  RAVENTests
//
//  Failure-matrix tests for the production-disabled recoverable endpoint.
//

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

final class ATSAMEndpointTransactionV1Tests: XCTestCase {

    private typealias Endpoint = ATSAMEndpointTransactionV1
    private typealias TxError = ATSAMEndpointTransactionV1.TransactionError

    private enum HarnessFailure: Error {
        case injected
    }

    private final class MemoryProtectedStore: Endpoint.ProtectedStateStore {
        var states: [Data: Endpoint.ProtectedSessionState]
        var failLoad = false
        var failReplace = false
        var failClear = false
        private(set) var replacementCount = 0
        private(set) var clearCount = 0

        init(state: Endpoint.ProtectedSessionState) {
            states = [state.sessionID: state]
        }

        func pendingSessionIDs() throws -> [Data] {
            if failLoad { throw HarnessFailure.injected }
            return states.values
                .filter {
                    $0.pendingAcceptance != nil
                        || $0.pendingAckAcceptance != nil
                        || $0.pendingOutbound != nil
                }
                .map(\.sessionID)
        }

        func load(sessionID: Data) throws -> Endpoint.ProtectedSessionState {
            if failLoad { throw HarnessFailure.injected }
            guard let state = states[sessionID] else { throw HarnessFailure.injected }
            return state
        }

        func replace(_ state: Endpoint.ProtectedSessionState) throws {
            if failReplace { throw HarnessFailure.injected }
            replacementCount += 1
            states[state.sessionID] = state
        }

        func clearPending(sessionID: Data, objectDigest: Data) throws {
            if failClear { throw HarnessFailure.injected }
            guard var state = states[sessionID] else {
                throw HarnessFailure.injected
            }
            if state.pendingAcceptance?.receiptKey.objectDigest == objectDigest {
                state.pendingAcceptance = nil
            } else if state.pendingAckAcceptance?.receiptKey.objectDigest == objectDigest {
                state.pendingAckAcceptance = nil
            } else if state.pendingOutbound?.objectDigest == objectDigest {
                state.pendingOutbound = nil
            } else {
                throw HarnessFailure.injected
            }
            states[sessionID] = state
            clearCount += 1
        }
    }

    private final class MemoryDatabase: Endpoint.OutboundDatabase {
        var receipts: [Endpoint.ReceiptKey: Endpoint.CommittedReceipt] = [:]
        var logicalObjects: [Endpoint.LogicalMessageKey: Data] = [:]
        var ackIntents: [Endpoint.ReceiptKey: Endpoint.AckIntent] = [:]
        var ackReceipts: [Endpoint.ReceiptKey: Endpoint.AckReceipt] = [:]
        var ackNonceObjects: [Data: Data] = [:]
        var outstanding: [Endpoint.OutstandingMessageKey: Endpoint.DeliveryState] = [:]
        var outbox: Set<Data> = []
        var failBegin = false
        var failCommit = false
        var failStage = false
        var failMark = false
        private(set) var rollbackCount = 0
        private(set) var commitCount = 0

        func hasOutboxRow(sessionID: Data, objectDigest: Data) throws -> Bool {
            var key = Data()
            key.append(sessionID)
            key.append(objectDigest)
            return outbox.contains(key)
        }

        func beginImmediate() throws -> any Endpoint.AcceptanceDatabaseTransaction {
            if failBegin { throw HarnessFailure.injected }
            return Transaction(database: self)
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
            if failStage { throw HarnessFailure.injected }
            guard var intent = ackIntents[receiptKey], !intent.isQueued else {
                throw TxError.noPendingAck
            }
            if let existingEnvelope = intent.stagedEnvelope {
                guard existingEnvelope == packedEnvelope,
                      intent.queueObjectID == queueObjectID else {
                    throw TxError.stagedAckCollision
                }
                return intent
            }
            intent.stagedEnvelope = packedEnvelope
            intent.queueObjectID = queueObjectID
            ackIntents[receiptKey] = intent
            return intent
        }

        func markAckQueued(
            receiptKey: Endpoint.ReceiptKey,
            queueObjectID: Data
        ) throws {
            if failMark { throw HarnessFailure.injected }
            guard var intent = ackIntents[receiptKey],
                  intent.stagedEnvelope != nil,
                  intent.queueObjectID == queueObjectID else {
                throw TxError.stagedAckCollision
            }
            intent.isQueued = true
            ackIntents[receiptKey] = intent
        }

        private final class Transaction: Endpoint.OutboundDatabaseTransaction {
            private unowned let database: MemoryDatabase
            private var pending: Endpoint.PendingAcceptance?
            private var pendingAck: Endpoint.PendingAckAcceptance?
            private var pendingOutbound: Endpoint.PendingOutbound?
            private var pendingAckMaterialization: (
                receiptKey: Endpoint.ReceiptKey,
                packedEnvelope: Data,
                ackObjectDigest: Data
            )?
            private var active = true

            init(database: MemoryDatabase) {
                self.database = database
            }

            func existingReceipt(
                receiptKey: Endpoint.ReceiptKey,
                logicalKey: Endpoint.LogicalMessageKey
            ) throws -> Endpoint.CommittedReceipt? {
                guard active else { throw HarnessFailure.injected }
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
                guard active else { throw HarnessFailure.injected }
                guard let receipt = database.ackReceipts[receiptKey] else { return nil }
                guard receipt.outerMessageID == outerMessageID,
                      receipt.remoteDeviceID == remoteDeviceID else {
                    throw TxError.receiptCollision
                }
                return receipt
            }

            func outstandingDeliveryState(
                _ key: Endpoint.OutstandingMessageKey
            ) throws -> Endpoint.DeliveryState? {
                guard active else { throw HarnessFailure.injected }
                return database.outstanding[key]
            }

            func ackNonceObjectDigest(
                sessionID: Data,
                remoteDeviceID: Data,
                ackNonce: Data
            ) throws -> Data? {
                guard active else { throw HarnessFailure.injected }
                return database.ackNonceObjects[Self.ackNonceKey(
                    sessionID: sessionID,
                    remoteDeviceID: remoteDeviceID,
                    ackNonce: ackNonce
                )]
            }

            func insertAcceptance(
                _ value: Endpoint.PendingAcceptance
            ) throws -> Endpoint.InsertOutcome {
                if let existing = try existingReceipt(
                    receiptKey: value.receiptKey,
                    logicalKey: value.logicalKey
                ) {
                    guard existing.sealedLocalInboxRow == value.sealedLocalInboxRow,
                          database.ackIntents[value.receiptKey] == value.ackIntent else {
                        // Recovery may recreate a fresh local seal only if the
                        // protected journal itself changed, which is forbidden.
                        throw TxError.receiptCollision
                    }
                    return .exactDuplicate(existing)
                }
                guard pending == nil,
                      value.ackIntent.receiptKey == value.receiptKey,
                      value.ackIntent.ackedMessageID == value.logicalKey.messageID,
                      value.ackIntent.expectedRemoteDeviceID == value.logicalKey.senderDeviceID,
                      value.sessionGeneration == value.ackIntent.sessionGeneration else {
                    throw HarnessFailure.injected
                }
                pending = value
                return .inserted(Self.receipt(from: value))
            }

            func insertAckAcceptance(
                _ value: Endpoint.PendingAckAcceptance
            ) throws -> Endpoint.AckInsertOutcome {
                guard active,
                      value.receiptKey.sessionID.count == 32,
                      value.outerMessageID.count == 16,
                      value.remoteDeviceID.count == 32,
                      value.ackedMessageID.count == 16,
                      value.ackNonce.count == 12 else {
                    throw TxError.receiptCollision
                }
                let outstandingKey = Endpoint.OutstandingMessageKey(
                    sessionID: value.receiptKey.sessionID,
                    messageID: value.ackedMessageID,
                    recipientDeviceID: value.remoteDeviceID
                )
                guard let current = database.outstanding[outstandingKey] else {
                    throw TxError.ackOutstandingMismatch
                }
                let receipt = Self.ackReceipt(from: value)
                let target = Endpoint.DeliveryState(rawValue: value.status.rawValue)!
                let resulting = max(current, target)
                if let existing = database.ackReceipts[value.receiptKey] {
                    guard existing == receipt else { throw TxError.receiptCollision }
                    return .exactDuplicate(receipt: existing, deliveryState: current)
                }
                let nonceKey = Self.ackNonceKey(
                    sessionID: value.receiptKey.sessionID,
                    remoteDeviceID: value.remoteDeviceID,
                    ackNonce: value.ackNonce
                )
                if let digest = database.ackNonceObjects[nonceKey],
                   digest != value.receiptKey.objectDigest {
                    throw TxError.ackNonceConflict
                }
                guard pendingAck == nil else { throw TxError.receiptCollision }
                pendingAck = value
                return .inserted(receipt: receipt, deliveryState: resulting)
            }

            func insertPreparedOutbound(_ pending: Endpoint.PendingOutbound) throws {
                guard active else { throw HarnessFailure.injected }
                guard self.pendingOutbound == nil else {
                    throw TxError.receiptCollision
                }
                self.pendingOutbound = pending
            }

            func insertAckMaterialization(
                pending: Endpoint.PendingOutbound,
                intentReceiptKey: Endpoint.ReceiptKey,
                packedEnvelope: Data,
                ackObjectDigest: Data
            ) throws {
                guard active else { throw HarnessFailure.injected }
                guard pendingOutbound == nil, pendingAckMaterialization == nil else {
                    throw TxError.receiptCollision
                }
                guard pending.objectDigest == ackObjectDigest,
                      pending.immutableEnvelopeBytes == packedEnvelope,
                      pending.sourceAckIntent == intentReceiptKey.objectDigest else {
                    throw TxError.stagedAckCollision
                }
                pendingOutbound = pending
                pendingAckMaterialization = (intentReceiptKey, packedEnvelope, ackObjectDigest)
            }

            func commitAndFsync() throws {
                guard active else { throw HarnessFailure.injected }
                if database.failCommit { throw HarnessFailure.injected }
                if let value = pending {
                    if let logicalDigest = database.logicalObjects[value.logicalKey],
                       logicalDigest != value.receiptKey.objectDigest {
                        throw TxError.logicalMessageCollision
                    }
                    if let existing = database.receipts[value.receiptKey],
                       existing != Self.receipt(from: value) {
                        throw TxError.receiptCollision
                    }
                    database.receipts[value.receiptKey] = Self.receipt(from: value)
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
                    if let materialization = pendingAckMaterialization {
                        guard var intent = database.ackIntents[materialization.receiptKey],
                              !intent.isQueued,
                              !intent.isAbandoned else {
                            throw TxError.noPendingAck
                        }
                        intent.stagedEnvelope = materialization.packedEnvelope
                        intent.queueObjectID = materialization.ackObjectDigest
                        database.ackIntents[materialization.receiptKey] = intent
                    }
                }
                if let value = pendingAck {
                    let receipt = Self.ackReceipt(from: value)
                    let outstandingKey = Endpoint.OutstandingMessageKey(
                        sessionID: value.receiptKey.sessionID,
                        messageID: value.ackedMessageID,
                        recipientDeviceID: value.remoteDeviceID
                    )
                    guard let current = database.outstanding[outstandingKey] else {
                        throw TxError.ackOutstandingMismatch
                    }
                    let target = Endpoint.DeliveryState(rawValue: value.status.rawValue)!
                    let nonceKey = Self.ackNonceKey(
                        sessionID: value.receiptKey.sessionID,
                        remoteDeviceID: value.remoteDeviceID,
                        ackNonce: value.ackNonce
                    )
                    if let existing = database.ackReceipts[value.receiptKey],
                       existing != receipt {
                        throw TxError.receiptCollision
                    }
                    if let existingObject = database.ackNonceObjects[nonceKey],
                       existingObject != value.receiptKey.objectDigest {
                        throw TxError.ackNonceConflict
                    }
                    database.ackReceipts[value.receiptKey] = receipt
                    database.ackNonceObjects[nonceKey] = value.receiptKey.objectDigest
                    database.outstanding[outstandingKey] = max(current, target)
                }
                database.commitCount += 1
                active = false
            }

            func rollback() {
                guard active else { return }
                database.rollbackCount += 1
                active = false
                pending = nil
                pendingAck = nil
                pendingOutbound = nil
                pendingAckMaterialization = nil
            }

            private static func receipt(
                from value: Endpoint.PendingAcceptance
            ) -> Endpoint.CommittedReceipt {
                Endpoint.CommittedReceipt(
                    receiptKey: value.receiptKey,
                    logicalKey: value.logicalKey,
                    messageIndex: value.messageIndex,
                    sealedLocalInboxRow: value.sealedLocalInboxRow,
                    sessionGeneration: value.sessionGeneration
                )
            }

            private static func ackReceipt(
                from value: Endpoint.PendingAckAcceptance
            ) -> Endpoint.AckReceipt {
                Endpoint.AckReceipt(
                    receiptKey: value.receiptKey,
                    outerMessageID: value.outerMessageID,
                    remoteDeviceID: value.remoteDeviceID,
                    ackedMessageID: value.ackedMessageID,
                    status: value.status,
                    ackNonce: value.ackNonce,
                    createdAtMs: value.createdAtMs,
                    sessionGeneration: value.sessionGeneration
                )
            }

            private static func ackNonceKey(
                sessionID: Data,
                remoteDeviceID: Data,
                ackNonce: Data
            ) -> Data {
                var value = sessionID
                value.append(remoteDeviceID)
                value.append(ackNonce)
                return Data(SHA256.hash(data: value))
            }
        }
    }

    private final class IncrementingNonceSource: Endpoint.NonceSource {
        private var counter: UInt64 = 0

        func freshNonce12() throws -> Data {
            counter += 1
            var result = Data(repeating: 0xA7, count: 4)
            result.appendUInt64BE(counter)
            return result
        }
    }

    private final class FailingNonceSource: Endpoint.NonceSource {
        func freshNonce12() throws -> Data { throw HarnessFailure.injected }
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

    private final class MemoryQueue: Endpoint.ImmutableAckQueue {
        var objects: [Data: Data] = [:]
        var failEnqueue = false
        private(set) var calls = 0

        func enqueueImmutable(objectID: Data, packedEnvelope: Data) throws {
            calls += 1
            if failEnqueue { throw HarnessFailure.injected }
            if let existing = objects[objectID] {
                guard existing == packedEnvelope else {
                    throw TxError.stagedAckCollision
                }
                return
            }
            objects[objectID] = packedEnvelope
        }

        func contains(objectID: Data) throws -> Bool {
            objects[objectID] != nil
        }

        @discardableResult
        func deleteIfPresent(objectID: Data) throws -> Bool {
            objects.removeValue(forKey: objectID) != nil
        }
    }

    private final class CountingAckDialer: Endpoint.AckDialer {
        private(set) var callCount = 0

        func dial(packedEnvelope: Data, ackObjectDigest: Data) throws {
            callCount += 1
        }
    }

    private final class RealAckMaterializer: Endpoint.AckMaterializer {
        let fixture: Fixture
        private(set) var calls = 0

        init(fixture: Fixture) {
            self.fixture = fixture
        }

        func prepareCommittedAck(
            intent: Endpoint.AckIntent,
            session: Endpoint.BoundSession,
            state: Endpoint.ProtectedSessionState,
            createdAtMs: UInt64,
            expiresAtMs: UInt64
        ) throws -> Endpoint.PreparedAckOutbound {
            calls += 1
            let direction = ATSAMIndexedSessionProfile.Direction.responderToInitiator
            let pair = try ATSAMIndexedSessionProfile.endpoints(
                initiatorAddress: fixture.initiatorAddress,
                responderAddress: fixture.responderAddress,
                direction: direction
            )
            let index = state.nextAckSendIndex
            var chainKey = state.ackSendChainKey
            _ = try ATSAMIndexedSessionProfile.laneMessageKey(
                chainKey: chainKey,
                sender: pair.sender,
                recipient: pair.recipient
            )
            chainKey = try ATSAMIndexedSessionProfile.advanceChainKey(chainKey)
            let outerMessageID = Data(repeating: 0xD4, count: 16)
            let innerNonce = Data(repeating: 0x39, count: 12)
            var signedAck = ATSAMIndexedSessionProfile.SignedAck(
                ackedMessageId: intent.ackedMessageID,
                status: intent.status.rawValue,
                ackNonce: innerNonce,
                createdAtMs: createdAtMs,
                signature: Data(repeating: 0, count: 64)
            )
            let signature = try fixture.responderSigningKey.signature(
                for: ATSAMIndexedSessionProfile.ackSigningBytes(signedAck)
            )
            signedAck = ATSAMIndexedSessionProfile.SignedAck(
                ackedMessageId: intent.ackedMessageID,
                status: intent.status.rawValue,
                ackNonce: innerNonce,
                createdAtMs: createdAtMs,
                signature: Data(signature)
            )
            let plaintext = try ATSAMIndexedSessionProfile.encodeSignedAck(signedAck)
            let sealed = try ATSAMIndexedSessionProfile.sealAck(
                root: fixture.rootKey,
                initiatorAddress: fixture.initiatorAddress,
                responderAddress: fixture.responderAddress,
                direction: direction,
                index: index,
                outerMessageId: outerMessageID,
                plaintext: plaintext,
                nonce: Data(repeating: 0x71, count: 12)
            )
            let route = try ATSAMIndexedSessionProfile.deriveRouteTag(
                root: fixture.rootKey,
                createdAtMs: createdAtMs,
                index: index,
                envelopeType: RavenEnvelopeV1.EnvType.ack.rawValue,
                direction: direction
            )
            var envelope = RavenEnvelopeV1(
                envType: RavenEnvelopeV1.EnvType.ack.rawValue,
                flags: 0,
                messageId: outerMessageID,
                routingTag: route,
                destDeviceHint: 0,
                createdAtMs: createdAtMs,
                expiresAtMs: expiresAtMs,
                antiReplayNonce: Data(repeating: 0x53, count: 12),
                messageCiphertext: sealed,
                senderAuthentication: Data(repeating: 0, count: 64)
            )
            envelope.sign(with: fixture.responderSigningKey)
            let packed = envelope.pack()
            let ackObjectDigest = envelope.relayObjectDigest()
            let generation = state.generation + 1
            let pendingOutbound = Endpoint.PendingOutbound(
                sessionID: session.sessionID,
                objectDigest: ackObjectDigest,
                messageID: outerMessageID,
                recipientDevice: intent.expectedRemoteDeviceID,
                ratchetIndex: index,
                immutableEnvelopeBytes: packed,
                sessionGeneration: generation,
                sourceAckIntent: intent.receiptKey.objectDigest
            )
            return Endpoint.PreparedAckOutbound(
                sourceMessageDigest: intent.receiptKey.objectDigest,
                ackObjectDigest: ackObjectDigest,
                messageID: outerMessageID,
                packedEnvelope: packed,
                advancedAckSendChainKey: chainKey,
                advancedNextAckSendIndex: index + 1,
                committedGeneration: generation,
                pendingOutbound: pendingOutbound
            )
        }
    }

    private struct Fixture {
        let rootKey: Data
        let sessionID: Data
        let senderSigningKey: Curve25519.Signing.PrivateKey
        let responderSigningKey: Curve25519.Signing.PrivateKey
        let initiatorIdentityKey: Curve25519.Signing.PrivateKey
        let responderIdentityKey: Curve25519.Signing.PrivateKey
        let initiatorCertificate: ATSAMPairInitV1.SignedDeviceCertificate
        let responderCertificate: ATSAMPairInitV1.SignedDeviceCertificate
        let initiatorCertificateHash: Data
        let responderCertificateHash: Data
        let initiatorAddress: String
        let responderAddress: String
        let nowMs: UInt64
        let localDeviceHint: UInt64

        init() throws {
            let fixtureNowMs: UInt64 = 1_786_579_200_000
            let initiatorDevice = try Curve25519.Signing.PrivateKey(
                rawRepresentation: Data((1...32).map(UInt8.init))
            )
            let responderDevice = try Curve25519.Signing.PrivateKey(
                rawRepresentation: Data((33...64).map(UInt8.init))
            )
            let initiatorIdentity = try Curve25519.Signing.PrivateKey(
                rawRepresentation: Data((65...96).map(UInt8.init))
            )
            let responderIdentity = try Curve25519.Signing.PrivateKey(
                rawRepresentation: Data((97...128).map(UInt8.init))
            )
            rootKey = Data(0..<32)
            sessionID = Data(SHA256.hash(data: Data("endpoint-session-1".utf8)))
            senderSigningKey = initiatorDevice
            responderSigningKey = responderDevice
            initiatorIdentityKey = initiatorIdentity
            responderIdentityKey = responderIdentity
            let initiatorCert = try Self.makeCertificate(
                identityKey: initiatorIdentity,
                deviceKey: initiatorDevice.publicKey.rawRepresentation,
                deviceID: "initiator-device",
                notBeforeMs: fixtureNowMs - 86_400_000,
                notAfterMs: fixtureNowMs + 8 * 86_400_000
            )
            let responderCert = try Self.makeCertificate(
                identityKey: responderIdentity,
                deviceKey: responderDevice.publicKey.rawRepresentation,
                deviceID: "responder-device",
                notBeforeMs: fixtureNowMs - 86_400_000,
                notAfterMs: fixtureNowMs + 8 * 86_400_000
            )
            initiatorCertificate = initiatorCert
            responderCertificate = responderCert
            initiatorCertificateHash = try ATSAMPairInitV1.deviceCertificateHash(
                initiatorCert
            )
            responderCertificateHash = try ATSAMPairInitV1.deviceCertificateHash(
                responderCert
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
            nowMs = fixtureNowMs
            localDeviceHint = 0x0102_0304_0506_0708
        }

        func session(
            direction: ATSAMIndexedSessionProfile.Direction = .initiatorToResponder,
            hint: UInt64? = nil,
            accepted: Bool = true,
            revoked: Bool = false,
            contactAllowed: Bool? = nil,
            sessionConfirmed: Bool = true,
            signingPublicKey: Data? = nil,
            certificate: ATSAMPairInitV1.SignedDeviceCertificate? = nil,
            certificateHash: Data? = nil,
            generation: UInt64 = 7
        ) -> Endpoint.BoundSession {
            let defaultPublicKey = direction == .initiatorToResponder
                ? senderSigningKey.publicKey.rawRepresentation
                : responderSigningKey.publicKey.rawRepresentation
            let publicKey = signingPublicKey ?? defaultPublicKey
            let defaultCertificate = direction == .initiatorToResponder
                ? initiatorCertificate
                : responderCertificate
            let selectedCertificate = certificate ?? defaultCertificate
            let selectedHash = certificateHash ?? (direction == .initiatorToResponder
                ? initiatorCertificateHash
                : responderCertificateHash)
            return Endpoint.BoundSession(
                sessionID: sessionID,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                inboundDirection: direction,
                expectedLocalDeviceHint: hint ?? localDeviceHint,
                remoteDeviceEd25519PublicKey: publicKey,
                senderCertificate: selectedCertificate,
                pairInitSenderCertificateHash: selectedHash,
                sessionCreatedAtMs: nowMs - 86_400_000,
                sessionExpiresAtMs: nowMs + 8 * 86_400_000,
                senderDeviceAccepted: accepted,
                senderDeviceRevoked: revoked,
                publicGeneration: generation,
                senderContactAllowed: contactAllowed,
                sessionConfirmed: sessionConfirmed
            )
        }

        static func makeCertificate(
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

        func initialState(
            direction: ATSAMIndexedSessionProfile.Direction = .initiatorToResponder,
            generation: UInt64 = 7
        ) throws -> Endpoint.ProtectedSessionState {
            let pair = try ATSAMIndexedSessionProfile.endpoints(
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: direction
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
                    direction: direction,
                    index: 0
                ),
                nextAckReceiveIndex: 0,
                skippedAckKeys: [:],
                pendingAcceptance: nil,
                pendingAckAcceptance: nil,
                pendingOutbound: nil,
                generation: generation
            )
        }

        func envelope(
            index: UInt32 = 0,
            plaintext: Data = Data("hello from the authenticated endpoint".utf8),
            messageID: Data = Data(repeating: 0x44, count: 16),
            aadMessageID: Data? = nil,
            createdAt: UInt64? = nil,
            expiresAt: UInt64? = nil,
            flags: UInt16 = 0,
            envType: UInt8 = RavenEnvelopeV1.EnvType.message.rawValue,
            hint: UInt64? = nil,
            direction: ATSAMIndexedSessionProfile.Direction = .initiatorToResponder,
            signer: Curve25519.Signing.PrivateKey? = nil,
            ratchetHeader: Data = Data()
        ) throws -> Data {
            let createdAt = createdAt ?? nowMs
            let expiresAt = expiresAt ?? (createdAt + 60_000)
            let pair = try ATSAMIndexedSessionProfile.endpoints(
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: direction
            )
            let messageKey = try ATSAMIndexedSessionProfile.messageKeyAtIndex(
                root: rootKey,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: direction,
                index: index
            )
            let aad = try ATSAMIndexedSessionProfile.buildAAD(
                index: index,
                sender: pair.sender,
                recipient: pair.recipient,
                outerMessageId: aadMessageID ?? messageID
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
                createdAtMs: createdAt,
                index: index,
                envelopeType: envType,
                direction: direction
            )
            var envelope = RavenEnvelopeV1(
                envType: envType,
                flags: flags,
                messageId: messageID,
                routingTag: route,
                destDeviceHint: hint ?? localDeviceHint,
                createdAtMs: createdAt,
                expiresAtMs: expiresAt,
                antiReplayNonce: Data(repeating: UInt8(truncatingIfNeeded: index), count: 12),
                ratchetHeaderCiphertext: ratchetHeader,
                messageCiphertext: wire,
                senderAuthentication: Data(repeating: 0, count: 64)
            )
            envelope.sign(with: signer ?? senderSigningKey)
            return envelope.pack()
        }

        func ackEnvelope(
            index: UInt32 = 0,
            status: Endpoint.AckStatus = .delivered,
            ackedMessageID: Data,
            outerMessageID: Data = Data(repeating: 0xD4, count: 16),
            ackNonce: Data = Data(repeating: 0x39, count: 12),
            createdAt: UInt64? = nil,
            innerCreatedAt: UInt64? = nil,
            innerSigner: Curve25519.Signing.PrivateKey? = nil,
            outerSigner: Curve25519.Signing.PrivateKey? = nil,
            aadMessageID: Data? = nil,
            hint: UInt64 = 0,
            direction: ATSAMIndexedSessionProfile.Direction = .responderToInitiator
        ) throws -> Data {
            let createdAt = createdAt ?? nowMs
            var signedAck = ATSAMIndexedSessionProfile.SignedAck(
                ackedMessageId: ackedMessageID,
                status: status.rawValue,
                ackNonce: ackNonce,
                createdAtMs: innerCreatedAt ?? createdAt,
                signature: Data(repeating: 0, count: 64)
            )
            let innerSignature = try (innerSigner ?? responderSigningKey).signature(
                for: ATSAMIndexedSessionProfile.ackSigningBytes(signedAck)
            )
            signedAck = ATSAMIndexedSessionProfile.SignedAck(
                ackedMessageId: ackedMessageID,
                status: status.rawValue,
                ackNonce: ackNonce,
                createdAtMs: innerCreatedAt ?? createdAt,
                signature: Data(innerSignature)
            )
            let sealed = try ATSAMIndexedSessionProfile.sealAck(
                root: rootKey,
                initiatorAddress: initiatorAddress,
                responderAddress: responderAddress,
                direction: direction,
                index: index,
                outerMessageId: aadMessageID ?? outerMessageID,
                plaintext: ATSAMIndexedSessionProfile.encodeSignedAck(signedAck),
                nonce: Data(repeating: UInt8(truncatingIfNeeded: index &+ 0x51), count: 12)
            )
            let route = try ATSAMIndexedSessionProfile.deriveRouteTag(
                root: rootKey,
                createdAtMs: createdAt,
                index: index,
                envelopeType: RavenEnvelopeV1.EnvType.ack.rawValue,
                direction: direction
            )
            var envelope = RavenEnvelopeV1(
                envType: RavenEnvelopeV1.EnvType.ack.rawValue,
                flags: 0,
                messageId: outerMessageID,
                routingTag: route,
                destDeviceHint: hint,
                createdAtMs: createdAt,
                expiresAtMs: createdAt + 60_000,
                antiReplayNonce: Data(repeating: UInt8(truncatingIfNeeded: index), count: 12),
                messageCiphertext: sealed,
                senderAuthentication: Data(repeating: 0, count: 64)
            )
            envelope.sign(with: outerSigner ?? responderSigningKey)
            return envelope.pack()
        }
    }

    private struct Harness {
        let fixture: Fixture
        let protectedStore: MemoryProtectedStore
        let database: MemoryDatabase
        let nonceSource: IncrementingNonceSource

        let direction: ATSAMIndexedSessionProfile.Direction

        init(
            direction: ATSAMIndexedSessionProfile.Direction = .initiatorToResponder
        ) throws {
            fixture = try Fixture()
            self.direction = direction
            protectedStore = MemoryProtectedStore(
                state: try fixture.initialState(direction: direction)
            )
            database = MemoryDatabase()
            nonceSource = IncrementingNonceSource()
        }

        func session(
            contactAllowed: Bool? = nil,
            sessionConfirmed: Bool = true,
            accepted: Bool = true,
            revoked: Bool = false
        ) -> Endpoint.BoundSession {
            let generation = protectedStore.states[fixture.sessionID]?.generation ?? 7
            return fixture.session(
                direction: direction,
                accepted: accepted,
                revoked: revoked,
                contactAllowed: contactAllowed,
                sessionConfirmed: sessionConfirmed,
                generation: generation
            )
        }

        func registerOutstanding(
            messageID: Data,
            state: Endpoint.DeliveryState = .sent
        ) {
            let key = Endpoint.OutstandingMessageKey(
                sessionID: fixture.sessionID,
                messageID: messageID,
                recipientDeviceID: session().remoteDeviceEd25519PublicKey
            )
            database.outstanding[key] = state
        }

        func outstandingState(messageID: Data) -> Endpoint.DeliveryState? {
            database.outstanding[Endpoint.OutstandingMessageKey(
                sessionID: fixture.sessionID,
                messageID: messageID,
                recipientDeviceID: session().remoteDeviceEd25519PublicKey
            )]
        }

        func receiver(
            faults: any Endpoint.FaultInjector = Endpoint.NoFaults(),
            nonceSource overrideNonce: (any Endpoint.NonceSource)? = nil
        ) -> Endpoint.Receiver {
            Endpoint.Receiver(
                protectedStore: protectedStore,
                database: database,
                nonceSource: overrideNonce ?? nonceSource,
                faults: faults
            )
        }

        func ackWorker(
            queue: MemoryQueue,
            materializer: RealAckMaterializer,
            dialer: CountingAckDialer = CountingAckDialer(),
            faults: any Endpoint.FaultInjector = Endpoint.NoFaults()
        ) -> (Endpoint.AckWorker, CountingAckDialer) {
            let worker = Endpoint.AckWorker(
                protectedStore: protectedStore,
                database: database,
                queue: queue,
                materializer: materializer,
                dialer: dialer,
                faults: faults
            )
            return (worker, dialer)
        }
    }

    func testSuccessfulAcceptanceCommitsEverythingBeforeReturningPlaintext() async throws {
        let harness = try Harness()
        let plaintext = Data("durable before visible; never plaintext at rest".utf8)
        let packed = try harness.fixture.envelope(plaintext: plaintext)
        let outcome = try await harness.receiver().receive(
            packedEnvelope: packed,
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )

        guard case let .committed(returned, receipt) = outcome else {
            return XCTFail("expected a first durable commit")
        }
        XCTAssertEqual(returned, plaintext)
        XCTAssertEqual(harness.database.receipts.count, 1)
        XCTAssertEqual(harness.database.ackIntents.count, 1)
        XCTAssertEqual(harness.database.commitCount, 1)
        XCTAssertEqual(harness.protectedStore.clearCount, 1)
        XCTAssertNil(harness.protectedStore.states[harness.fixture.sessionID]?.pendingAcceptance)
        XCTAssertEqual(
            harness.protectedStore.states[harness.fixture.sessionID]?.nextReceiveIndex,
            1
        )
        XCTAssertNotEqual(receipt.sealedLocalInboxRow, plaintext)
        XCTAssertNil(receipt.sealedLocalInboxRow.range(of: plaintext))
        XCTAssertEqual(receipt.sealedLocalInboxRow.first, 1)
        XCTAssertEqual(receipt.sealedLocalInboxRow.count, plaintext.count + 29)
        XCTAssertFalse(Endpoint.productionEnabled)
    }

    func testExactCommittedDuplicateDoesNotAdvanceOrSurfacePlaintextTwice() async throws {
        let harness = try Harness()
        let packed = try harness.fixture.envelope()
        _ = try await harness.receiver().receive(
            packedEnvelope: packed,
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        let replacements = harness.protectedStore.replacementCount
        let duplicate = try await harness.receiver().receive(
            packedEnvelope: packed,
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )

        guard case .exactDuplicate = duplicate else {
            return XCTFail("expected exact durable duplicate")
        }
        XCTAssertEqual(harness.database.receipts.count, 1)
        XCTAssertEqual(harness.database.ackIntents.count, 1)
        XCTAssertEqual(harness.protectedStore.replacementCount, replacements)
        XCTAssertEqual(
            harness.protectedStore.states[harness.fixture.sessionID]?.nextReceiveIndex,
            1
        )
    }

    func testOutOfOrderWindowConsumesSkippedKeysOnceAndRejectsReplay() async throws {
        let harness = try Harness()
        let receiver = harness.receiver()
        _ = try await receiver.receive(
            packedEnvelope: try harness.fixture.envelope(
                index: 2,
                messageID: Data(repeating: 0x22, count: 16)
            ),
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        XCTAssertEqual(
            harness.protectedStore.states[harness.fixture.sessionID]?.skippedMessageKeys.count,
            2
        )
        _ = try await receiver.receive(
            packedEnvelope: try harness.fixture.envelope(
                index: 0,
                messageID: Data(repeating: 0x20, count: 16)
            ),
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        _ = try await receiver.receive(
            packedEnvelope: try harness.fixture.envelope(
                index: 1,
                messageID: Data(repeating: 0x21, count: 16)
            ),
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        XCTAssertEqual(
            harness.protectedStore.states[harness.fixture.sessionID]?.nextReceiveIndex,
            3
        )
        XCTAssertEqual(
            harness.protectedStore.states[harness.fixture.sessionID]?.skippedMessageKeys.count,
            0
        )

        await assertRejected(
            try harness.fixture.envelope(
                index: 0,
                messageID: Data(repeating: 0x23, count: 16)
            ),
            session: harness.session(),
            expected: .replay,
            harness: harness
        )
        XCTAssertEqual(harness.database.receipts.count, 3)
        XCTAssertEqual(harness.database.ackIntents.count, 3)
    }

    func testAuthenticatedPublicMessageIDCollisionNeverOverwrites() async throws {
        let harness = try Harness()
        let messageID = Data(repeating: 0x91, count: 16)
        _ = try await harness.receiver().receive(
            packedEnvelope: try harness.fixture.envelope(index: 0, messageID: messageID),
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        await assertRejected(
            try harness.fixture.envelope(
                index: 1,
                plaintext: Data("different authenticated object".utf8),
                messageID: messageID
            ),
            session: harness.session(),
            expected: .logicalMessageCollision,
            harness: harness
        )
        XCTAssertEqual(harness.database.receipts.count, 1)
        XCTAssertEqual(
            harness.protectedStore.states[harness.fixture.sessionID]?.nextReceiveIndex,
            1
        )
    }

    func testPreCommitNegativeMatrixCreatesNoDeliveryOrAck() async throws {
        let base = try Fixture()
        let otherKey = Curve25519.Signing.PrivateKey()
        var tamperedOuter = try XCTUnwrap(
            RavenEnvelopeV1.unpack(try base.envelope())
        )
        tamperedOuter.messageCiphertext[tamperedOuter.messageCiphertext.count - 1] ^= 0x01

        var tamperedAEAD = tamperedOuter
        tamperedAEAD.sign(with: base.senderSigningKey)

        var wrongRoute = try XCTUnwrap(RavenEnvelopeV1.unpack(try base.envelope()))
        wrongRoute.routingTag = Data(repeating: 0xF0, count: 16)
        wrongRoute.sign(with: base.senderSigningKey)

        var invalidMagic = try XCTUnwrap(RavenEnvelopeV1.unpack(try base.envelope()))
        invalidMagic.messageCiphertext[0] ^= 0x01
        invalidMagic.sign(with: base.senderSigningKey)

        var tamperedCertificateSignature = base.initiatorCertificate.signature
        tamperedCertificateSignature[0] ^= 0x01
        let tamperedCertificate = ATSAMPairInitV1.SignedDeviceCertificate(
            identityEd25519PublicKey: base.initiatorCertificate.identityEd25519PublicKey,
            signingBytes: base.initiatorCertificate.signingBytes,
            signature: tamperedCertificateSignature
        )
        let wrongIdentityCertificate = try Fixture.makeCertificate(
            identityKey: otherKey,
            deviceKey: base.senderSigningKey.publicKey.rawRepresentation,
            deviceID: "initiator-device",
            notBeforeMs: base.nowMs - 86_400_000,
            notAfterMs: base.nowMs + 86_400_000
        )
        let expiredCertificate = try Fixture.makeCertificate(
            identityKey: base.initiatorIdentityKey,
            deviceKey: base.senderSigningKey.publicKey.rawRepresentation,
            deviceID: "initiator-device",
            notBeforeMs: base.nowMs - 86_400_000,
            notAfterMs: base.nowMs - 1
        )

        let oversizedText = Data(repeating: 0x41, count: Endpoint.maximumTextBytes + 1)
        let invalidUTF8 = Data([0xF8, 0x80, 0x80, 0x80])
        let deleteControl = Data([0x61, 0x7F, 0x62])
        let cases: [(String, Data, Endpoint.BoundSession, TxError)] = [
            ("wrong route", wrongRoute.pack(), base.session(), .wrongRouteTag),
            ("wrong device hint", try base.envelope(hint: 9), base.session(), .wrongDeviceHint),
            ("unaccepted device", try base.envelope(), base.session(accepted: false), .unacceptedDevice),
            ("revoked device", try base.envelope(), base.session(revoked: true), .revokedDevice),
            ("wrong device key", try base.envelope(), base.session(
                signingPublicKey: otherKey.publicKey.rawRepresentation
            ), .deviceBindingMismatch),
            ("tampered certificate", try base.envelope(), base.session(
                certificate: tamperedCertificate
            ), .invalidDeviceCertificate),
            ("wrong certificate identity", try base.envelope(), base.session(
                certificate: wrongIdentityCertificate,
                certificateHash: try ATSAMPairInitV1.deviceCertificateHash(
                    wrongIdentityCertificate
                )
            ), .deviceBindingMismatch),
            ("expired certificate", try base.envelope(), base.session(
                certificate: expiredCertificate,
                certificateHash: try ATSAMPairInitV1.deviceCertificateHash(expiredCertificate)
            ), .invalidDeviceCertificate),
            ("wrong PairInit certificate hash", try base.envelope(), base.session(
                certificateHash: Data(repeating: 0xE1, count: 32)
            ), .deviceBindingMismatch),
            ("bad outer signature", tamperedOuter.pack(), base.session(), .invalidOuterSignature),
            ("tampered AEAD", tamperedAEAD.pack(), base.session(), .authenticationFailed),
            ("wrong AAD message id", try base.envelope(
                messageID: Data(repeating: 0x70, count: 16),
                aadMessageID: Data(repeating: 0x71, count: 16)
            ), base.session(), .authenticationFailed),
            ("jump 257", try base.envelope(
                index: 257,
                messageID: Data(repeating: 0x72, count: 16)
            ), base.session(), .indexJumpTooLarge),
            ("invalid RVNA header", invalidMagic.pack(), base.session(), .invalidSealedHeader),
            ("oversized text", try base.envelope(
                plaintext: oversizedText,
                messageID: Data(repeating: 0x73, count: 16)
            ), base.session(), .invalidSealedHeader),
            ("invalid UTF-8", try base.envelope(
                plaintext: invalidUTF8,
                messageID: Data(repeating: 0x74, count: 16)
            ), base.session(), .invalidTextPayload),
            ("DEL control", try base.envelope(
                plaintext: deleteControl,
                messageID: Data(repeating: 0x75, count: 16)
            ), base.session(), .invalidTextPayload),
            ("expired", try base.envelope(
                createdAt: base.nowMs - 60_000,
                expiresAt: base.nowMs
            ), base.session(), .invalidTimeWindow),
            ("future", try base.envelope(
                createdAt: base.nowMs + Endpoint.maximumFutureSkewMs + 1
            ), base.session(), .invalidTimeWindow),
            ("wrong envelope type", try base.envelope(
                envType: RavenEnvelopeV1.EnvType.ack.rawValue
            ), base.session(), .wrongEnvelopeType),
            ("unexpected ratchet header", try base.envelope(
                ratchetHeader: Data([1])
            ), base.session(), .unexpectedRatchetHeader),
            ("wrong direction", try base.envelope(), base.session(
                direction: .responderToInitiator
            ), .wrongRouteTag),
            ("public generation mismatch", try base.envelope(), base.session(
                generation: 8
            ), .publicGenerationMismatch)
        ]

        for (name, packed, session, expected) in cases {
            let harness = try Harness()
            await assertRejected(
                packed,
                session: session,
                expected: expected,
                harness: harness,
                label: name
            )
            XCTAssertEqual(harness.database.receipts.count, 0, name)
            XCTAssertEqual(harness.database.ackIntents.count, 0, name)
            XCTAssertEqual(
                harness.protectedStore.states[harness.fixture.sessionID]?.nextReceiveIndex,
                0,
                name
            )
            XCTAssertNil(
                harness.protectedStore.states[harness.fixture.sessionID]?.pendingAcceptance,
                name
            )
        }
    }

    func testCrashMatrixRecoversWithoutKeyReuseOrFalseSecondUIEvent() async throws {
        let points: [Endpoint.CrashPoint] = [
            .beforeProtectedStateReplacement,
            .afterProtectedStateReplacement,
            .beforeDatabaseCommit,
            .afterDatabaseCommit,
            .beforeJournalClear,
            .afterJournalClear
        ]

        for point in points {
            let harness = try Harness()
            let plaintext = Data("crash-safe plaintext \(point.rawValue)".utf8)
            let packed = try harness.fixture.envelope(plaintext: plaintext)
            do {
                _ = try await harness.receiver(faults: OneShotFaults(point)).receive(
                    packedEnvelope: packed,
                    session: harness.session(),
                    nowMs: harness.fixture.nowMs
                )
                XCTFail("expected injected crash at \(point.rawValue)")
            } catch let error as TxError {
                XCTAssertEqual(error, .simulatedCrash(point))
            }

            if point == .beforeProtectedStateReplacement {
                XCTAssertEqual(harness.database.receipts.count, 0)
                XCTAssertEqual(harness.database.ackIntents.count, 0)
                XCTAssertNil(
                    harness.protectedStore.states[harness.fixture.sessionID]?.pendingAcceptance
                )
            } else if point == .afterProtectedStateReplacement
                        || point == .beforeDatabaseCommit {
                XCTAssertEqual(harness.database.receipts.count, 0)
                XCTAssertEqual(harness.database.ackIntents.count, 0)
                let pending = try XCTUnwrap(
                    harness.protectedStore.states[harness.fixture.sessionID]?.pendingAcceptance
                )
                XCTAssertNotEqual(pending.sealedLocalInboxRow, plaintext)
                XCTAssertNil(pending.sealedLocalInboxRow.range(of: plaintext))
            } else {
                XCTAssertEqual(harness.database.receipts.count, 1)
                XCTAssertEqual(harness.database.ackIntents.count, 1)
            }

            let restarted = harness.receiver()
            let retry = try await restarted.receive(
                packedEnvelope: packed,
                session: harness.session(),
                nowMs: harness.fixture.nowMs
            )
            if point == .beforeProtectedStateReplacement {
                guard case .committed = retry else {
                    XCTFail("pre-write crash must allow one first commit")
                    continue
                }
            } else {
                guard case .exactDuplicate = retry else {
                    XCTFail("recovery must not surface plaintext twice")
                    continue
                }
            }
            XCTAssertEqual(harness.database.receipts.count, 1)
            XCTAssertEqual(harness.database.ackIntents.count, 1)
            XCTAssertNil(
                harness.protectedStore.states[harness.fixture.sessionID]?.pendingAcceptance
            )
            XCTAssertEqual(
                harness.protectedStore.states[harness.fixture.sessionID]?.nextReceiveIndex,
                1
            )
        }
    }

    func testDurabilityFailuresFailClosedAndRecoverFromProtectedJournal() async throws {
        do {
            let harness = try Harness()
            harness.protectedStore.failReplace = true
            await assertInjectedFailure(
                receiver: harness.receiver(),
                packed: try harness.fixture.envelope(),
                harness: harness
            )
            XCTAssertEqual(harness.database.receipts.count, 0)
            XCTAssertEqual(harness.database.ackIntents.count, 0)
            XCTAssertEqual(
                harness.protectedStore.states[harness.fixture.sessionID]?.nextReceiveIndex,
                0
            )
        }

        do {
            let harness = try Harness()
            harness.database.failCommit = true
            await assertInjectedFailure(
                receiver: harness.receiver(),
                packed: try harness.fixture.envelope(),
                harness: harness
            )
            XCTAssertEqual(harness.database.receipts.count, 0)
            XCTAssertEqual(harness.database.ackIntents.count, 0)
            XCTAssertNotNil(
                harness.protectedStore.states[harness.fixture.sessionID]?.pendingAcceptance
            )
            harness.database.failCommit = false
            let recovered = try await harness.receiver().recoverPendingAcceptances()
            XCTAssertEqual(recovered.count, 1)
            XCTAssertEqual(harness.database.receipts.count, 1)
            XCTAssertEqual(harness.database.ackIntents.count, 1)
            XCTAssertNil(
                harness.protectedStore.states[harness.fixture.sessionID]?.pendingAcceptance
            )
        }

        do {
            let harness = try Harness()
            harness.protectedStore.failClear = true
            await assertInjectedFailure(
                receiver: harness.receiver(),
                packed: try harness.fixture.envelope(),
                harness: harness
            )
            XCTAssertEqual(harness.database.receipts.count, 1)
            XCTAssertEqual(harness.database.ackIntents.count, 1)
            XCTAssertNotNil(
                harness.protectedStore.states[harness.fixture.sessionID]?.pendingAcceptance
            )
            harness.protectedStore.failClear = false
            let recovered = try await harness.receiver().recoverPendingAcceptances()
            XCTAssertEqual(recovered.count, 1)
            XCTAssertNil(
                harness.protectedStore.states[harness.fixture.sessionID]?.pendingAcceptance
            )
        }

        do {
            let harness = try Harness()
            await assertInjectedFailure(
                receiver: harness.receiver(nonceSource: FailingNonceSource()),
                packed: try harness.fixture.envelope(),
                harness: harness
            )
            XCTAssertEqual(harness.database.receipts.count, 0)
            XCTAssertEqual(harness.protectedStore.replacementCount, 0)
        }
    }

    func testOriginAckAcceptanceIsExactIndependentAndMonotonic() async throws {
        let harness = try Harness(direction: .responderToInitiator)
        let messageID = Data(repeating: 0xA1, count: 16)
        harness.registerOutstanding(messageID: messageID)
        let receiver = harness.receiver()

        let delivered = try harness.fixture.ackEnvelope(
            index: 0,
            status: .delivered,
            ackedMessageID: messageID
        )
        let first = try await receiver.acceptAck(
            packedEnvelope: delivered,
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        guard case let .committed(receipt, deliveryState) = first else {
            return XCTFail("expected authenticated ACK commit")
        }
        XCTAssertEqual(receipt.ackedMessageID, messageID)
        XCTAssertEqual(receipt.remoteDeviceID, harness.fixture.responderSigningKey.publicKey.rawRepresentation)
        XCTAssertEqual(deliveryState, .delivered)
        XCTAssertEqual(harness.outstandingState(messageID: messageID), .delivered)
        XCTAssertEqual(harness.database.ackReceipts.count, 1)
        XCTAssertEqual(harness.database.ackNonceObjects.count, 1)
        XCTAssertEqual(
            harness.protectedStore.states[harness.fixture.sessionID]?.nextAckReceiveIndex,
            1
        )
        XCTAssertEqual(
            harness.protectedStore.states[harness.fixture.sessionID]?.nextReceiveIndex,
            0,
            "ACK lane must not consume the message lane"
        )

        let replacements = harness.protectedStore.replacementCount
        let duplicate = try await receiver.acceptAck(
            packedEnvelope: delivered,
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        guard case .exactDuplicate = duplicate else {
            return XCTFail("expected exact ACK duplicate")
        }
        XCTAssertEqual(harness.protectedStore.replacementCount, replacements)

        let read = try harness.fixture.ackEnvelope(
            index: 1,
            status: .read,
            ackedMessageID: messageID,
            outerMessageID: Data(repeating: 0xD5, count: 16),
            ackNonce: Data(repeating: 0x3A, count: 12)
        )
        _ = try await receiver.acceptAck(
            packedEnvelope: read,
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        XCTAssertEqual(harness.outstandingState(messageID: messageID), .read)

        let lateDelivered = try harness.fixture.ackEnvelope(
            index: 2,
            status: .delivered,
            ackedMessageID: messageID,
            outerMessageID: Data(repeating: 0xD6, count: 16),
            ackNonce: Data(repeating: 0x3B, count: 12)
        )
        let late = try await receiver.acceptAck(
            packedEnvelope: lateDelivered,
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        guard case let .committed(_, finalState) = late else {
            return XCTFail("expected later authenticated ACK")
        }
        XCTAssertEqual(finalState, .read)
        XCTAssertEqual(harness.outstandingState(messageID: messageID), .read)
    }

    func testOriginAckNegativeMatrixNeverAdvancesOutstandingOrRatchet() async throws {
        let fixture = try Fixture()
        let messageID = Data(repeating: 0xB1, count: 16)
        let wrongKey = Curve25519.Signing.PrivateKey()

        var wrongRoute = try XCTUnwrap(RavenEnvelopeV1.unpack(
            try fixture.ackEnvelope(ackedMessageID: messageID)
        ))
        wrongRoute.routingTag = Data(repeating: 0xEE, count: 16)
        wrongRoute.sign(with: fixture.responderSigningKey)

        var tamperedAEAD = try XCTUnwrap(RavenEnvelopeV1.unpack(
            try fixture.ackEnvelope(ackedMessageID: messageID)
        ))
        tamperedAEAD.messageCiphertext[50] ^= 0x01
        tamperedAEAD.sign(with: fixture.responderSigningKey)

        var wrongType = try XCTUnwrap(RavenEnvelopeV1.unpack(
            try fixture.ackEnvelope(ackedMessageID: messageID)
        ))
        wrongType.envType = RavenEnvelopeV1.EnvType.message.rawValue
        wrongType.sign(with: fixture.responderSigningKey)

        let cases: [(String, Data, TxError, Bool, Endpoint.BoundSession?)] = [
            ("wrong route", wrongRoute.pack(), .wrongRouteTag, true, nil),
            ("wrong hint", try fixture.ackEnvelope(
                ackedMessageID: messageID,
                hint: 9
            ), .wrongDeviceHint, true, nil),
            ("bad outer signature", try fixture.ackEnvelope(
                ackedMessageID: messageID,
                outerSigner: wrongKey
            ), .invalidOuterSignature, true, nil),
            ("tampered AEAD", tamperedAEAD.pack(), .authenticationFailed, true, nil),
            ("wrong AAD", try fixture.ackEnvelope(
                ackedMessageID: messageID,
                aadMessageID: Data(repeating: 0xC1, count: 16)
            ), .authenticationFailed, true, nil),
            ("bad inner signature", try fixture.ackEnvelope(
                ackedMessageID: messageID,
                innerSigner: wrongKey
            ), .ackInnerSignatureInvalid, true, nil),
            ("inner timestamp mismatch", try fixture.ackEnvelope(
                ackedMessageID: messageID,
                innerCreatedAt: fixture.nowMs - 1
            ), .ackTimestampMismatch, true, nil),
            ("not outstanding", try fixture.ackEnvelope(
                ackedMessageID: Data(repeating: 0xB2, count: 16)
            ), .ackOutstandingMismatch, false, nil),
            ("jump 257", try fixture.ackEnvelope(
                index: 257,
                ackedMessageID: messageID
            ), .indexJumpTooLarge, true, nil),
            ("wrong envelope type", wrongType.pack(), .wrongEnvelopeType, true, nil),
            ("revoked device", try fixture.ackEnvelope(
                ackedMessageID: messageID
            ), .revokedDevice, true, nil),
            ("unaccepted device", try fixture.ackEnvelope(
                ackedMessageID: messageID
            ), .unacceptedDevice, true, nil)
        ]

        for (label, packed, expected, register, boundOverride) in cases {
            let harness = try Harness(direction: .responderToInitiator)
            if register { harness.registerOutstanding(messageID: messageID) }
            let bound: Endpoint.BoundSession
            if label == "revoked device" {
                bound = harness.session(revoked: true)
            } else if label == "unaccepted device" {
                bound = harness.session(accepted: false)
            } else {
                bound = boundOverride ?? harness.session()
            }
            await assertAckRejected(
                packed,
                expected: expected,
                harness: harness,
                session: bound,
                label: label
            )
            XCTAssertEqual(harness.database.ackReceipts.count, 0, label)
            XCTAssertEqual(harness.database.ackNonceObjects.count, 0, label)
            XCTAssertEqual(
                harness.protectedStore.states[harness.fixture.sessionID]?.nextAckReceiveIndex,
                0,
                label
            )
            if register {
                XCTAssertEqual(harness.outstandingState(messageID: messageID), .sent, label)
            }
        }
    }

    func testOriginAckContactGateAndSessionConfirmedRefuseWithoutDeliveryChange() async throws {
        let messageID = Data(repeating: 0xE1, count: 16)
        let packed = try Fixture().ackEnvelope(ackedMessageID: messageID)

        do {
            let harness = try Harness(direction: .responderToInitiator)
            harness.registerOutstanding(messageID: messageID)
            await assertAckRejected(
                packed,
                expected: .contactBlocked,
                harness: harness,
                session: harness.session(contactAllowed: false),
                label: "contact gate blocked"
            )
        }

        do {
            let harness = try Harness(direction: .responderToInitiator)
            harness.registerOutstanding(messageID: messageID)
            await assertAckRejected(
                packed,
                expected: .sessionNotConfirmed,
                harness: harness,
                session: harness.session(sessionConfirmed: false),
                label: "provisional session"
            )
        }

        do {
            let harness = try Harness(direction: .responderToInitiator)
            harness.registerOutstanding(messageID: messageID)
            var state = try XCTUnwrap(harness.protectedStore.states[harness.fixture.sessionID])
            state.pendingAckAcceptance = Endpoint.PendingAckAcceptance(
                receiptKey: Endpoint.ReceiptKey(
                    sessionID: harness.fixture.sessionID,
                    objectDigest: Data(repeating: 0xF0, count: 32)
                ),
                outerMessageID: Data(repeating: 0xF1, count: 16),
                remoteDeviceID: harness.session().remoteDeviceEd25519PublicKey,
                ackedMessageID: messageID,
                status: .delivered,
                ackNonce: Data(repeating: 0xF2, count: 12),
                createdAtMs: harness.fixture.nowMs,
                sessionGeneration: state.generation
            )
            state.pendingOutbound = Endpoint.PendingOutbound(
                sessionID: harness.fixture.sessionID,
                objectDigest: Data(repeating: 0xF3, count: 32),
                messageID: Data(repeating: 0xF4, count: 16),
                recipientDevice: harness.session().remoteDeviceEd25519PublicKey,
                ratchetIndex: 0,
                immutableEnvelopeBytes: Data(repeating: 0xF5, count: 96),
                sessionGeneration: state.generation,
                sourceAckIntent: nil
            )
            harness.protectedStore.states[harness.fixture.sessionID] = state
            await assertAckRejected(
                packed,
                expected: .invalidProtectedState,
                harness: harness,
                label: "corrupt dual pending journals"
            )
        }
    }

    func testOriginAckDuplicateObjectDigestConflictFailsClosed() async throws {
        let harness = try Harness(direction: .responderToInitiator)
        let messageID = Data(repeating: 0xE2, count: 16)
        harness.registerOutstanding(messageID: messageID)
        let packed = try harness.fixture.ackEnvelope(ackedMessageID: messageID)
        guard let envelope = RavenEnvelopeV1.unpack(packed) else {
            return XCTFail("expected valid ACK envelope")
        }
        let objectDigest = envelope.relayObjectDigest()
        let receiptKey = Endpoint.ReceiptKey(
            sessionID: harness.fixture.sessionID,
            objectDigest: objectDigest
        )
        harness.database.ackReceipts[receiptKey] = Endpoint.AckReceipt(
            receiptKey: receiptKey,
            outerMessageID: Data(repeating: 0xE3, count: 16),
            remoteDeviceID: harness.session().remoteDeviceEd25519PublicKey,
            ackedMessageID: messageID,
            status: .delivered,
            ackNonce: Data(repeating: 0x39, count: 12),
            createdAtMs: harness.fixture.nowMs,
            sessionGeneration: 8
        )

        await assertAckRejected(
            packed,
            expected: .receiptCollision,
            harness: harness,
            label: "digest identity conflict"
        )
        XCTAssertEqual(harness.database.ackReceipts.count, 1)
        XCTAssertEqual(harness.outstandingState(messageID: messageID), .sent)
    }

    func testOriginAckNonceConflictAndConsumedIndexReplayFailClosed() async throws {
        let harness = try Harness(direction: .responderToInitiator)
        let messageID = Data(repeating: 0xC2, count: 16)
        let nonce = Data(repeating: 0x62, count: 12)
        harness.registerOutstanding(messageID: messageID)
        let receiver = harness.receiver()
        _ = try await receiver.acceptAck(
            packedEnvelope: try harness.fixture.ackEnvelope(
                index: 0,
                ackedMessageID: messageID,
                ackNonce: nonce
            ),
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )

        await assertAckRejected(
            try harness.fixture.ackEnvelope(
                index: 1,
                status: .read,
                ackedMessageID: messageID,
                outerMessageID: Data(repeating: 0xC3, count: 16),
                ackNonce: nonce
            ),
            expected: .ackNonceConflict,
            harness: harness
        )
        XCTAssertEqual(harness.outstandingState(messageID: messageID), .delivered)
        XCTAssertEqual(
            harness.protectedStore.states[harness.fixture.sessionID]?.nextAckReceiveIndex,
            1
        )

        await assertAckRejected(
            try harness.fixture.ackEnvelope(
                index: 0,
                status: .read,
                ackedMessageID: messageID,
                outerMessageID: Data(repeating: 0xC4, count: 16),
                ackNonce: Data(repeating: 0x63, count: 12)
            ),
            expected: .replay,
            harness: harness
        )
        XCTAssertEqual(harness.database.ackReceipts.count, 1)
        XCTAssertEqual(harness.database.ackNonceObjects.count, 1)
        XCTAssertEqual(harness.outstandingState(messageID: messageID), .delivered)
    }

    func testOriginAckCrashAndDatabaseFailureRecoveryIsIdempotent() async throws {
        let crashPoints: [Endpoint.CrashPoint] = [
            .beforeProtectedStateReplacement,
            .afterProtectedStateReplacement,
            .beforeDatabaseCommit,
            .afterDatabaseCommit,
            .beforeJournalClear,
            .afterJournalClear
        ]
        for point in crashPoints {
            let harness = try Harness(direction: .responderToInitiator)
            let messageID = Data(repeating: 0xD1, count: 16)
            harness.registerOutstanding(messageID: messageID)
            let packed = try harness.fixture.ackEnvelope(ackedMessageID: messageID)
            do {
                _ = try await harness.receiver(faults: OneShotFaults(point)).acceptAck(
                    packedEnvelope: packed,
                    session: harness.session(),
                    nowMs: harness.fixture.nowMs
                )
                XCTFail("expected ACK crash at \(point.rawValue)")
            } catch let error as TxError {
                XCTAssertEqual(error, .simulatedCrash(point))
            }

            if point == .beforeProtectedStateReplacement {
                XCTAssertNil(
                    harness.protectedStore.states[harness.fixture.sessionID]?.pendingAckAcceptance
                )
                XCTAssertEqual(harness.database.ackReceipts.count, 0)
                XCTAssertEqual(harness.outstandingState(messageID: messageID), .sent)
            } else if point == .afterProtectedStateReplacement
                        || point == .beforeDatabaseCommit {
                XCTAssertNotNil(
                    harness.protectedStore.states[harness.fixture.sessionID]?.pendingAckAcceptance
                )
                XCTAssertEqual(harness.database.ackReceipts.count, 0)
                XCTAssertEqual(harness.outstandingState(messageID: messageID), .sent)
            } else {
                XCTAssertEqual(harness.database.ackReceipts.count, 1)
                XCTAssertEqual(harness.outstandingState(messageID: messageID), .delivered)
            }

            let retry = try await harness.receiver().acceptAck(
                packedEnvelope: packed,
                session: harness.session(),
                nowMs: harness.fixture.nowMs
            )
            if point == .beforeProtectedStateReplacement {
                guard case .committed = retry else {
                    XCTFail("pre-write ACK crash must allow first commit")
                    continue
                }
            } else {
                guard case .exactDuplicate = retry else {
                    XCTFail("recovered ACK must be an exact duplicate")
                    continue
                }
            }
            XCTAssertEqual(harness.database.ackReceipts.count, 1)
            XCTAssertEqual(harness.database.ackNonceObjects.count, 1)
            XCTAssertEqual(harness.outstandingState(messageID: messageID), .delivered)
            XCTAssertNil(
                harness.protectedStore.states[harness.fixture.sessionID]?.pendingAckAcceptance
            )
            XCTAssertEqual(
                harness.protectedStore.states[harness.fixture.sessionID]?.nextAckReceiveIndex,
                1
            )
        }

        let failing = try Harness(direction: .responderToInitiator)
        let messageID = Data(repeating: 0xD2, count: 16)
        failing.registerOutstanding(messageID: messageID)
        failing.database.failCommit = true
        do {
            _ = try await failing.receiver().acceptAck(
                packedEnvelope: try failing.fixture.ackEnvelope(ackedMessageID: messageID),
                session: failing.session(),
                nowMs: failing.fixture.nowMs
            )
            XCTFail("expected ACK database failure")
        } catch is HarnessFailure {}
        XCTAssertEqual(failing.database.ackReceipts.count, 0)
        XCTAssertEqual(failing.outstandingState(messageID: messageID), .sent)
        XCTAssertNotNil(
            failing.protectedStore.states[failing.fixture.sessionID]?.pendingAckAcceptance
        )
        failing.database.failCommit = false
        let recovered = try await failing.receiver().recoverPendingAcceptances()
        XCTAssertTrue(recovered.isEmpty, "ACK recovery must not masquerade as inbox delivery")
        XCTAssertEqual(failing.database.ackReceipts.count, 1)
        XCTAssertEqual(failing.outstandingState(messageID: messageID), .delivered)
        XCTAssertNil(
            failing.protectedStore.states[failing.fixture.sessionID]?.pendingAckAcceptance
        )
    }

    func testAckWorkerStagesFullEnvelopeAndRetriesIdenticalBytesAfterCrashes() async throws {
        let crashPoints: [Endpoint.CrashPoint] = [
            .beforeImmutableAckEnqueue,
            .afterImmutableAckEnqueue,
            .beforeAckQueuedMark,
            .afterAckQueuedMark
        ]

        for point in crashPoints {
            let harness = try Harness()
            _ = try await harness.receiver().receive(
                packedEnvelope: try harness.fixture.envelope(),
                session: harness.session(),
                nowMs: harness.fixture.nowMs
            )
            let queue = MemoryQueue()
            let materializer = RealAckMaterializer(fixture: harness.fixture)
            let (worker, _) = harness.ackWorker(
                queue: queue,
                materializer: materializer,
                faults: OneShotFaults(point)
            )
            do {
                _ = try await worker.enqueueOneCommittedAck(
                    session: harness.session(),
                    nowMs: harness.fixture.nowMs
                )
                XCTFail("expected ACK worker crash at \(point.rawValue)")
            } catch let error as TxError {
                XCTAssertEqual(error, .simulatedCrash(point))
            }

            let staged = try XCTUnwrap(harness.database.ackIntents.values.first)
            let stagedBytes = try XCTUnwrap(staged.stagedEnvelope)
            let decoded = try XCTUnwrap(RavenEnvelopeV1.unpack(stagedBytes))
            XCTAssertEqual(decoded.envType, RavenEnvelopeV1.EnvType.ack.rawValue)
            XCTAssertEqual(decoded.messageCiphertext.count, ATSAMIndexedSessionProfile.sealedAckLength)
            XCTAssertEqual(decoded.senderAuthentication.count, 64)
            XCTAssertGreaterThan(stagedBytes.count, 16)
            XCTAssertEqual(materializer.calls, 1)

            if point == .beforeImmutableAckEnqueue {
                XCTAssertEqual(queue.objects.count, 0)
            } else {
                XCTAssertEqual(queue.objects.count, 1)
            }

            let retryWorker = harness.ackWorker(
                queue: queue,
                materializer: materializer
            ).0
            let retried = try await retryWorker.enqueueOneCommittedAck(
                session: harness.session(),
                nowMs: harness.fixture.nowMs
            )
            if point == .afterAckQueuedMark {
                XCTAssertFalse(retried)
            } else {
                XCTAssertTrue(retried)
            }
            XCTAssertEqual(queue.objects.count, 1)
            XCTAssertEqual(queue.objects.values.first, stagedBytes)
            XCTAssertEqual(materializer.calls, 1)
            XCTAssertTrue(try XCTUnwrap(harness.database.ackIntents.values.first).isQueued)
        }
    }

    func testQueueAndDatabaseAckFailuresNeverMarkIntentQueued() async throws {
        let harness = try Harness()
        _ = try await harness.receiver().receive(
            packedEnvelope: try harness.fixture.envelope(),
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        let queue = MemoryQueue()
        queue.failEnqueue = true
        let materializer = RealAckMaterializer(fixture: harness.fixture)
        let (worker, _) = harness.ackWorker(queue: queue, materializer: materializer)
        do {
            _ = try await worker.enqueueOneCommittedAck(
                session: harness.session(),
                nowMs: harness.fixture.nowMs
            )
            XCTFail("expected queue failure")
        } catch is HarnessFailure {}
        XCTAssertFalse(try XCTUnwrap(harness.database.ackIntents.values.first).isQueued)
        XCTAssertEqual(queue.objects.count, 0)

        queue.failEnqueue = false
        harness.database.failMark = true
        do {
            _ = try await worker.enqueueOneCommittedAck(
                session: harness.session(),
                nowMs: harness.fixture.nowMs
            )
            XCTFail("expected queued-mark failure")
        } catch is HarnessFailure {}
        XCTAssertFalse(try XCTUnwrap(harness.database.ackIntents.values.first).isQueued)
        XCTAssertEqual(queue.objects.count, 1)

        harness.database.failMark = false
        let queued = try await worker.enqueueOneCommittedAck(
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        XCTAssertTrue(queued)
        XCTAssertTrue(try XCTUnwrap(harness.database.ackIntents.values.first).isQueued)
        XCTAssertEqual(queue.objects.count, 1)
        XCTAssertEqual(materializer.calls, 1)
    }

    func testAckResumeStopsAtEnqueueNotDial() async throws {
        let harness = try Harness()
        _ = try await harness.receiver().receive(
            packedEnvelope: try harness.fixture.envelope(),
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        let intent = try XCTUnwrap(harness.database.ackIntents.values.first)
        let materializer = RealAckMaterializer(fixture: harness.fixture)
        let prepared = try materializer.prepareCommittedAck(
            intent: intent,
            session: harness.session(),
            state: try XCTUnwrap(harness.protectedStore.states[harness.fixture.sessionID]),
            createdAtMs: harness.fixture.nowMs + 1,
            expiresAtMs: harness.fixture.nowMs + 60_000
        )
        var staged = intent
        staged.stagedEnvelope = prepared.packedEnvelope
        staged.queueObjectID = prepared.ackObjectDigest
        harness.database.ackIntents[intent.receiptKey] = staged
        var outboxKey = Data()
        outboxKey.append(harness.fixture.sessionID)
        outboxKey.append(prepared.ackObjectDigest)
        harness.database.outbox.insert(outboxKey)
        XCTAssertTrue(
            try harness.database.hasOutboxRow(
                sessionID: harness.fixture.sessionID,
                objectDigest: prepared.ackObjectDigest
            )
        )

        let queue = MemoryQueue()
        let dialer = CountingAckDialer()
        let (worker, trackedDialer) = harness.ackWorker(
            queue: queue,
            materializer: materializer,
            dialer: dialer
        )
        let action = try await worker.resumeOneCommittedAck(
            session: harness.session(),
            nowMs: harness.fixture.nowMs,
            allowDial: true
        )
        switch action {
        case .enqueued, .queuedMarked:
            break
        default:
            XCTFail("expected enqueue or queued-mark, got \(action)")
        }
        XCTAssertEqual(trackedDialer.callCount, 0)
        XCTAssertEqual(queue.objects.count, 1)
    }

    func testAckQueueDeletedAfterExpiry() async throws {
        let harness = try Harness()
        _ = try await harness.receiver().receive(
            packedEnvelope: try harness.fixture.envelope(),
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        let intent = try XCTUnwrap(harness.database.ackIntents.values.first)
        let materializer = RealAckMaterializer(fixture: harness.fixture)
        let prepared = try materializer.prepareCommittedAck(
            intent: intent,
            session: harness.session(),
            state: try XCTUnwrap(harness.protectedStore.states[harness.fixture.sessionID]),
            createdAtMs: harness.fixture.nowMs + 1,
            expiresAtMs: harness.fixture.nowMs + 1_000
        )
        var staged = intent
        staged.stagedEnvelope = prepared.packedEnvelope
        staged.queueObjectID = prepared.ackObjectDigest
        harness.database.ackIntents[intent.receiptKey] = staged

        let queue = MemoryQueue()
        try queue.enqueueImmutable(objectID: prepared.ackObjectDigest, packedEnvelope: prepared.packedEnvelope)
        let (worker, _) = harness.ackWorker(queue: queue, materializer: materializer)
        let abandoned = try await worker.expireSweep(
            session: harness.session(),
            nowMs: harness.fixture.nowMs + 2_000
        )
        XCTAssertEqual(abandoned, 1)
        XCTAssertTrue(try !queue.contains(objectID: prepared.ackObjectDigest))
        XCTAssertTrue(try XCTUnwrap(harness.database.ackIntents[intent.receiptKey]).isAbandoned)
    }

    func testSourceMessageDigestDistinctFromAckObjectDigest() async throws {
        let harness = try Harness()
        _ = try await harness.receiver().receive(
            packedEnvelope: try harness.fixture.envelope(),
            session: harness.session(),
            nowMs: harness.fixture.nowMs
        )
        let intent = try XCTUnwrap(harness.database.ackIntents.values.first)
        let queue = MemoryQueue()
        let materializer = RealAckMaterializer(fixture: harness.fixture)
        let (worker, _) = harness.ackWorker(queue: queue, materializer: materializer)
        let action = try await worker.resumeOneCommittedAck(
            session: harness.session(),
            nowMs: harness.fixture.nowMs,
            allowDial: false
        )
        guard case let .materialized(source, ack) = action else {
            return XCTFail("expected materialized action, got \(action)")
        }
        XCTAssertEqual(source, intent.receiptKey.objectDigest)
        XCTAssertNotEqual(source, ack)
        XCTAssertEqual(
            ack,
            Endpoint.AckWorker.ackObjectDigest(
                for: try XCTUnwrap(harness.database.ackIntents[intent.receiptKey]?.stagedEnvelope)
            )
        )
    }

    // MARK: - Assertions

    private func assertRejected(
        _ packed: Data,
        session: Endpoint.BoundSession,
        expected: TxError,
        harness: Harness,
        label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await harness.receiver().receive(
                packedEnvelope: packed,
                session: session,
                nowMs: harness.fixture.nowMs
            )
            XCTFail("expected rejection \(label)", file: file, line: line)
        } catch let error as TxError {
            XCTAssertEqual(error, expected, label, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error) \(label)", file: file, line: line)
        }
    }

    private func assertInjectedFailure(
        receiver: Endpoint.Receiver,
        packed: Data,
        harness: Harness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await receiver.receive(
                packedEnvelope: packed,
                session: harness.session(),
                nowMs: harness.fixture.nowMs
            )
            XCTFail("expected injected durability failure", file: file, line: line)
        } catch is HarnessFailure {
            // Expected fail-closed injection.
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func assertAckRejected(
        _ packed: Data,
        expected: TxError,
        harness: Harness,
        session: Endpoint.BoundSession? = nil,
        label: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await harness.receiver().acceptAck(
                packedEnvelope: packed,
                session: session ?? harness.session(),
                nowMs: harness.fixture.nowMs
            )
            XCTFail("expected ACK rejection \(label)", file: file, line: line)
        } catch let error as TxError {
            XCTAssertEqual(error, expected, label, file: file, line: line)
        } catch {
            XCTFail("unexpected ACK error \(error) \(label)", file: file, line: line)
        }
    }
}
