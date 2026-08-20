//
//  ATSAMEndpointTransactionV1.swift
//  RAVEN
//
//  Recoverable endpoint acceptance boundary for ATSAM/indexed-session/v1.
//
//  This file is deliberately disconnected from RavenEnvelopeChatWire and all
//  live database/network services. Its protocols make the protected-state,
//  transactional-database, and immutable-queue durability boundaries explicit
//  and fault injectable. Production integration remains security-review gated.
//

import CryptoKit
import Foundation
import Security

enum ATSAMEndpointTransactionV1 {

    /// Tripwire: hard `false` in Release. DEBUG lab unlocks via `ATSAMLabGate`.
    static var productionEnabled: Bool {
        #if DEBUG
        ATSAMLabGate.isEnabled
        #else
        false
        #endif
    }
    static let maximumIndexJump: UInt32 = 256
    static let maximumSkippedKeys = 256
    static let maximumTextBytes = 262_144
    static let maximumLifetimeMs: UInt64 = 7 * 24 * 60 * 60 * 1_000
    static let maximumFutureSkewMs: UInt64 = 5 * 60 * 1_000
    /// G3: immutable ACK queue file retention ceiling (§4.7 / plan G3).
    static let ackQueueFileTTLMs: UInt64 = 7 * 24 * 60 * 60 * 1_000

    private static let localInboxKeyDomain = Data("ATSAM/v1/local-inbox-key".utf8)
    private static let localInboxAADDomain = Data("ATSAM/v1/local-inbox-aad".utf8)

    enum TransactionError: Error, Equatable {
        case productionDisabled
        case malformedEnvelope
        case wrongEnvelopeType
        case invalidTimeWindow
        case unexpectedRatchetHeader
        case invalidSealedHeader
        case wrongSession
        case wrongDirection
        case wrongRouteTag
        case wrongDeviceHint
        case unacceptedDevice
        case revokedDevice
        case invalidDeviceCertificate
        case deviceBindingMismatch
        case invalidDeviceKey
        case invalidOuterSignature
        case invalidProtectedState
        case publicGenerationMismatch
        case indexJumpTooLarge
        case replay
        case authenticationFailed
        case invalidTextPayload
        case invalidLocalSeal
        case logicalMessageCollision
        case receiptCollision
        case stagedAckCollision
        case malformedAckEnvelope
        case noPendingAck
        case ackTimestampMismatch
        case ackInnerSignatureInvalid
        case ackOutstandingMismatch
        case ackNonceConflict
        case sessionNotConfirmed
        case contactBlocked
        case mutationInProgress
        case outboundPending
        case stageCapacityExceeded
        case orphanStageDeleted
        case simulatedCrash(CrashPoint)
    }

    enum CrashPoint: String, CaseIterable {
        case beforeProtectedStateReplacement
        case afterProtectedStateReplacement
        case beforeDatabaseCommit
        case afterDatabaseCommit
        case beforeJournalClear
        case afterJournalClear
        case beforeImmutableAckEnqueue
        case afterImmutableAckEnqueue
        case beforeAckQueuedMark
        case afterAckQueuedMark
        case beforeOutboundStage
        case afterOutboundStage
        case beforeOutboundProtectedReplacement
        case afterOutboundProtectedReplacement
        case beforeOutboundDatabaseCommit
        case afterOutboundDatabaseCommit
        case beforeOutboundJournalClear
        case afterOutboundJournalClear
    }

    enum AckStatus: UInt8, Equatable {
        case delivered = 1
        case read = 2
    }

    enum DeliveryState: UInt8, Equatable, Comparable {
        case sent = 0
        case delivered = 1
        case read = 2

        static func < (lhs: DeliveryState, rhs: DeliveryState) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct BoundSession: Equatable {
        let sessionID: Data
        let initiatorAddress: String
        let responderAddress: String
        let inboundDirection: ATSAMIndexedSessionProfile.Direction
        let expectedLocalDeviceHint: UInt64
        /// PairInit-bound remote device Ed25519 key. The frozen V1 Rust profile
        /// uses this key as the exact remote-device row key.
        let remoteDeviceEd25519PublicKey: Data
        let senderCertificate: ATSAMPairInitV1.SignedDeviceCertificate
        let pairInitSenderCertificateHash: Data
        let sessionCreatedAtMs: UInt64
        let sessionExpiresAtMs: UInt64
        let senderDeviceAccepted: Bool
        let senderDeviceRevoked: Bool
        let publicGeneration: UInt64
        /// When set, §4.8 step 1 uses this contact gate instead of device accept/revoke.
        let senderContactAllowed: Bool?
        /// Provisional sessions must remain false until PairResponse confirmation.
        let sessionConfirmed: Bool

        init(
            sessionID: Data,
            initiatorAddress: String,
            responderAddress: String,
            inboundDirection: ATSAMIndexedSessionProfile.Direction,
            expectedLocalDeviceHint: UInt64,
            remoteDeviceEd25519PublicKey: Data,
            senderCertificate: ATSAMPairInitV1.SignedDeviceCertificate,
            pairInitSenderCertificateHash: Data,
            sessionCreatedAtMs: UInt64,
            sessionExpiresAtMs: UInt64,
            senderDeviceAccepted: Bool,
            senderDeviceRevoked: Bool,
            publicGeneration: UInt64,
            senderContactAllowed: Bool? = nil,
            sessionConfirmed: Bool = true
        ) {
            self.sessionID = sessionID
            self.initiatorAddress = initiatorAddress
            self.responderAddress = responderAddress
            self.inboundDirection = inboundDirection
            self.expectedLocalDeviceHint = expectedLocalDeviceHint
            self.remoteDeviceEd25519PublicKey = remoteDeviceEd25519PublicKey
            self.senderCertificate = senderCertificate
            self.pairInitSenderCertificateHash = pairInitSenderCertificateHash
            self.sessionCreatedAtMs = sessionCreatedAtMs
            self.sessionExpiresAtMs = sessionExpiresAtMs
            self.senderDeviceAccepted = senderDeviceAccepted
            self.senderDeviceRevoked = senderDeviceRevoked
            self.publicGeneration = publicGeneration
            self.senderContactAllowed = senderContactAllowed
            self.sessionConfirmed = sessionConfirmed
        }
    }

    struct SealedMessageHeader: Equatable {
        let index: UInt32
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    struct ReceiptKey: Hashable {
        let sessionID: Data
        let objectDigest: Data
    }

    struct LogicalMessageKey: Hashable {
        let sessionID: Data
        let senderDeviceID: Data
        let messageID: Data
    }

    struct OutstandingMessageKey: Hashable {
        let sessionID: Data
        let messageID: Data
        let recipientDeviceID: Data
    }

    struct AckIntent: Equatable {
        /// `source_message_digest` — digest of the accepted inbound message (§4.7).
        let receiptKey: ReceiptKey
        let ackedMessageID: Data
        let expectedRemoteDeviceID: Data
        let status: AckStatus
        let sessionGeneration: UInt64
        /// Durable `immutable_ack_bytes` after materialization.
        var stagedEnvelope: Data?
        /// `ack_object_digest` — queue/outbox key for the outbound ACK envelope.
        var queueObjectID: Data?
        var isQueued: Bool
        var isAbandoned: Bool
    }

    struct PendingAcceptance: Equatable {
        let receiptKey: ReceiptKey
        let logicalKey: LogicalMessageKey
        let messageIndex: UInt32
        let sealedLocalInboxRow: Data
        let ackIntent: AckIntent
        let sessionGeneration: UInt64
    }

    struct AckReceipt: Equatable {
        let receiptKey: ReceiptKey
        let outerMessageID: Data
        let remoteDeviceID: Data
        let ackedMessageID: Data
        let status: AckStatus
        let ackNonce: Data
        let createdAtMs: UInt64
        let sessionGeneration: UInt64
    }

    struct PendingAckAcceptance: Equatable {
        let receiptKey: ReceiptKey
        let outerMessageID: Data
        let remoteDeviceID: Data
        let ackedMessageID: Data
        let status: AckStatus
        let ackNonce: Data
        let createdAtMs: UInt64
        let sessionGeneration: UInt64
    }

    enum AckAcceptOutcome: Equatable {
        case committed(receipt: AckReceipt, deliveryState: DeliveryState)
        case exactDuplicate(receipt: AckReceipt, deliveryState: DeliveryState)
    }

    enum AckInsertOutcome: Equatable {
        case inserted(receipt: AckReceipt, deliveryState: DeliveryState)
        case exactDuplicate(receipt: AckReceipt, deliveryState: DeliveryState)
    }

    struct PendingOutbound: Equatable {
        let sessionID: Data
        /// For ACK outbox rows this is `ack_object_digest`, not `source_message_digest`.
        let objectDigest: Data
        let messageID: Data
        let recipientDevice: Data
        let ratchetIndex: UInt32
        let immutableEnvelopeBytes: Data
        let sessionGeneration: UInt64
        /// When set, this outbound row is an ACK for the given `source_message_digest`.
        let sourceAckIntent: Data?
    }

    struct PreparedAckOutbound: Equatable {
        let sourceMessageDigest: Data
        let ackObjectDigest: Data
        let messageID: Data
        let packedEnvelope: Data
        let advancedAckSendChainKey: Data
        let advancedNextAckSendIndex: UInt32
        let committedGeneration: UInt64
        let pendingOutbound: PendingOutbound
    }

    enum AckResumeAction: Equatable {
        case idle
        case expired(sourceMessageDigest: Data)
        case materialized(sourceMessageDigest: Data, ackObjectDigest: Data)
        case enqueued(ackObjectDigest: Data)
        case queuedMarked(ackObjectDigest: Data)
        case dialed(ackObjectDigest: Data)
    }

    struct PreparedOutbound: Equatable {
        let peerPub: Data
        let sessionID: Data
        let objectDigest: Data
        let messageID: Data
        let createdAtMs: UInt64
        let body: String
        let packedEnvelope: Data
        let advancedSendChainKey: Data
        let advancedNextSendIndex: UInt32
        let committedGeneration: UInt64
        let pendingOutbound: PendingOutbound
    }

    struct ProtectedSessionState: Equatable {
        let sessionID: Data
        let rootKey: Data
        var receiveChainKey: Data
        var nextReceiveIndex: UInt32
        var skippedMessageKeys: [UInt32: Data]
        var sendChainKey: Data
        var nextSendIndex: UInt32
        var ackSendChainKey: Data
        var nextAckSendIndex: UInt32
        var ackReceiveChainKey: Data
        var nextAckReceiveIndex: UInt32
        var skippedAckKeys: [UInt32: Data]
        var pendingAcceptance: PendingAcceptance?
        var pendingAckAcceptance: PendingAckAcceptance?
        var pendingOutbound: PendingOutbound?
        var generation: UInt64
    }

    struct AuthenticatedCandidate: Equatable {
        let plaintext: Data
        let advancedReceiveChainKey: Data
        let advancedNextReceiveIndex: UInt32
        let advancedSkippedMessageKeys: [UInt32: Data]
    }

    struct AuthenticatedAckCandidate: Equatable {
        let signedAck: ATSAMIndexedSessionProfile.SignedAck
        let advancedReceiveChainKey: Data
        let advancedNextReceiveIndex: UInt32
        let advancedSkippedKeys: [UInt32: Data]
    }

    struct CommittedReceipt: Equatable {
        let receiptKey: ReceiptKey
        let logicalKey: LogicalMessageKey
        let messageIndex: UInt32
        let sealedLocalInboxRow: Data
        let sessionGeneration: UInt64
    }

    enum ReceiveOutcome: Equatable {
        case committed(plaintext: Data, receipt: CommittedReceipt)
        case exactDuplicate(receipt: CommittedReceipt)
    }

    enum InsertOutcome: Equatable {
        case inserted(CommittedReceipt)
        case exactDuplicate(CommittedReceipt)
    }

    enum SendOutcome: Equatable {
        case queued(objectDigest: Data, messageID: Data)
    }

    enum OrphanReconcileResult: Equatable {
        case deleted(messageID: Data)
    }

    protocol ProtectedStateStore: AnyObject {
        /// Returns every session with a protected pending-acceptance journal.
        func pendingSessionIDs() throws -> [Data]
        func load(sessionID: Data) throws -> ProtectedSessionState

        /// Must atomically replace and durably synchronize the protected state.
        func replace(_ state: ProtectedSessionState) throws

        /// Must durably clear only the matching message, ACK, or outbound journal;
        /// it may not clear a different acceptance written by a newer operation.
        func clearPending(sessionID: Data, objectDigest: Data) throws
    }

    protocol AcceptanceDatabase: AnyObject {
        /// Begins an immediate, isolated transaction. The returned transaction
        /// owns all uniqueness checks and inserts until commit or rollback.
        func beginImmediate() throws -> any AcceptanceDatabaseTransaction

        func nextUnqueuedAckIntent() throws -> AckIntent?

        func allAckIntents() throws -> [AckIntent]

        /// Persists the first complete packed ACK envelope. A retry must return
        /// the identical staged bytes and must never replace them.
        func stageAckEnvelope(
            receiptKey: ReceiptKey,
            packedEnvelope: Data,
            queueObjectID: Data
        ) throws -> AckIntent

        func markAckQueued(receiptKey: ReceiptKey, queueObjectID: Data) throws

        func markAckAbandoned(receiptKey: ReceiptKey) throws
    }

    protocol OutboundDatabase: AcceptanceDatabase {
        func hasOutboxRow(sessionID: Data, objectDigest: Data) throws -> Bool
    }

    protocol OutboundDatabaseTransaction: AcceptanceDatabaseTransaction {
        func insertPreparedOutbound(_ pending: PendingOutbound) throws

        /// Atomically inserts the ACK outbox row and persists `immutable_ack_bytes`.
        func insertAckMaterialization(
            pending: PendingOutbound,
            intentReceiptKey: ReceiptKey,
            packedEnvelope: Data,
            ackObjectDigest: Data
        ) throws
    }

    protocol OutboundMaterializer {
        /// Builds a complete signed envelope and ratchet advance candidate in memory only.
        func prepareOutbound(
            text: Data,
            session: BoundSession,
            state: ProtectedSessionState,
            createdAtMs: UInt64,
            expiresAtMs: UInt64
        ) throws -> PreparedOutbound
    }

    protocol OutboundDialer: AnyObject {
        /// Must run outside the session mutation lease.
        func dial(packedEnvelope: Data, objectDigest: Data) throws
    }

    protocol AckDialer: AnyObject {
        /// Must run outside the session mutation lease.
        func dial(packedEnvelope: Data, ackObjectDigest: Data) throws
    }

    protocol AcceptanceDatabaseTransaction: AnyObject {
        /// Read-only authenticated duplicate check inside the same immediate
        /// transaction used for the eventual insert. An exact receipt returns
        /// its committed row; a reused logical public ID with a different
        /// object digest throws `logicalMessageCollision`.
        func existingReceipt(
            receiptKey: ReceiptKey,
            logicalKey: LogicalMessageKey
        ) throws -> CommittedReceipt?

        /// Returns an exact authenticated ACK receipt by immutable object.
        /// Any conflict in outer ID or remote device fails closed.
        func existingAckReceipt(
            receiptKey: ReceiptKey,
            outerMessageID: Data,
            remoteDeviceID: Data
        ) throws -> AckReceipt?

        func outstandingDeliveryState(
            _ key: OutstandingMessageKey
        ) throws -> DeliveryState?

        /// A nonce is unique per `(session, remote_device)`. Returning an
        /// object digest supports exact duplicate recovery while rejecting a
        /// different authenticated ACK that reuses the nonce.
        func ackNonceObjectDigest(
            sessionID: Data,
            remoteDeviceID: Data,
            ackNonce: Data
        ) throws -> Data?

        /// Enforces both `(session, object_digest)` receipt uniqueness and the
        /// `(session, sender_device, message_id) -> object_digest` mapping. It
        /// must also require that the public session head exactly matches
        /// `pending.sessionGeneration` in this same database transaction.
        func insertAcceptance(_ pending: PendingAcceptance) throws -> InsertOutcome

        /// Atomically inserts the ACK receipt and nonce mapping and advances
        /// only the exact outstanding row with `max(current, status)`. It must
        /// also match `pending.sessionGeneration` to the public session head.
        func insertAckAcceptance(_ pending: PendingAckAcceptance) throws -> AckInsertOutcome

        /// Commits and synchronizes the database before returning success.
        func commitAndFsync() throws
        func rollback()
    }

    protocol CandidateAuthenticator {
        func authenticateAndAdvance(
            envelope: RavenEnvelopeV1,
            header: SealedMessageHeader,
            session: BoundSession,
            state: ProtectedSessionState
        ) throws -> AuthenticatedCandidate
    }

    protocol NonceSource {
        func freshNonce12() throws -> Data
    }

    protocol FaultInjector {
        func checkpoint(_ point: CrashPoint) throws
    }

    protocol AckMaterializer {
        /// Builds a complete signed ACK envelope and `ack_send` ratchet advance
        /// candidate in memory only. Durability is via §4.4 `pending_outbound`.
        func prepareCommittedAck(
            intent: AckIntent,
            session: BoundSession,
            state: ProtectedSessionState,
            createdAtMs: UInt64,
            expiresAtMs: UInt64
        ) throws -> PreparedAckOutbound
    }

    protocol ImmutableAckQueue: AnyObject {
        /// Enqueue is idempotent only when `objectID` (`ack_object_digest`) maps to these bytes.
        func enqueueImmutable(objectID: Data, packedEnvelope: Data) throws

        func contains(objectID: Data) throws -> Bool

        /// Idempotent delete; returns whether a file was removed.
        @discardableResult
        func deleteIfPresent(objectID: Data) throws -> Bool
    }

    struct NoFaults: FaultInjector {
        func checkpoint(_ point: CrashPoint) throws {}
    }

    struct SystemNonceSource: NonceSource {
        func freshNonce12() throws -> Data {
            var bytes = Data(count: 12)
            let status = bytes.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return errSecAllocate
                }
                return SecRandomCopyBytes(kSecRandomDefault, 12, baseAddress)
            }
            guard status == errSecSuccess else {
                throw TransactionError.invalidLocalSeal
            }
            return bytes
        }
    }

    /// Real indexed-chain and ChaCha20-Poly1305 candidate authenticator. It
    /// mutates only a returned candidate; the protected store is untouched.
    struct IndexedSessionCandidateAuthenticator: CandidateAuthenticator {
        func authenticateAndAdvance(
            envelope: RavenEnvelopeV1,
            header: SealedMessageHeader,
            session: BoundSession,
            state: ProtectedSessionState
        ) throws -> AuthenticatedCandidate {
            let endpoints = try ATSAMIndexedSessionProfile.endpoints(
                initiatorAddress: session.initiatorAddress,
                responderAddress: session.responderAddress,
                direction: session.inboundDirection
            )

            var advancedChain = state.receiveChainKey
            var advancedNext = state.nextReceiveIndex
            var advancedSkipped = state.skippedMessageKeys
            var selectedMessageKey: Data?

            if header.index < state.nextReceiveIndex {
                guard let skippedKey = advancedSkipped.removeValue(forKey: header.index) else {
                    throw TransactionError.replay
                }
                selectedMessageKey = skippedKey
            } else {
                let jump = header.index - state.nextReceiveIndex
                guard jump <= maximumIndexJump else {
                    throw TransactionError.indexJumpTooLarge
                }
                guard header.index != UInt32.max else {
                    throw TransactionError.indexJumpTooLarge
                }

                var cursor = state.nextReceiveIndex
                while cursor <= header.index {
                    let candidateKey = try ATSAMIndexedSessionProfile.laneMessageKey(
                        chainKey: advancedChain,
                        sender: endpoints.sender,
                        recipient: endpoints.recipient
                    )
                    advancedChain = try ATSAMIndexedSessionProfile.advanceChainKey(advancedChain)
                    if cursor == header.index {
                        selectedMessageKey = candidateKey
                        break
                    }
                    guard advancedSkipped.count < maximumSkippedKeys else {
                        throw TransactionError.indexJumpTooLarge
                    }
                    advancedSkipped[cursor] = candidateKey
                    cursor += 1
                }
                advancedNext = header.index + 1
            }

            guard let messageKey = selectedMessageKey else {
                throw TransactionError.invalidProtectedState
            }

            let aad = try ATSAMIndexedSessionProfile.buildAAD(
                index: header.index,
                sender: endpoints.sender,
                recipient: endpoints.recipient,
                outerMessageId: envelope.messageId
            )
            let plaintext: Data
            do {
                let box = try ChaChaPoly.SealedBox(
                    nonce: ChaChaPoly.Nonce(data: header.nonce),
                    ciphertext: header.ciphertext,
                    tag: header.tag
                )
                plaintext = try ChaChaPoly.open(
                    box,
                    using: SymmetricKey(data: messageKey),
                    authenticating: aad
                )
            } catch {
                throw TransactionError.authenticationFailed
            }

            return AuthenticatedCandidate(
                plaintext: plaintext,
                advancedReceiveChainKey: advancedChain,
                advancedNextReceiveIndex: advancedNext,
                advancedSkippedMessageKeys: advancedSkipped
            )
        }
    }

    actor Receiver {
        private let protectedStore: any ProtectedStateStore
        private let database: any AcceptanceDatabase
        private let authenticator: any CandidateAuthenticator
        private let nonceSource: any NonceSource
        private let faults: any FaultInjector
        private let mutationLease: ATSAMSessionMutationLease

        init(
            protectedStore: any ProtectedStateStore,
            database: any AcceptanceDatabase,
            authenticator: any CandidateAuthenticator = IndexedSessionCandidateAuthenticator(),
            nonceSource: any NonceSource = SystemNonceSource(),
            faults: any FaultInjector = NoFaults(),
            mutationLease: ATSAMSessionMutationLease = .shared
        ) {
            self.protectedStore = protectedStore
            self.database = database
            self.authenticator = authenticator
            self.nonceSource = nonceSource
            self.faults = faults
            self.mutationLease = mutationLease
        }

        /// Recovers every protected pending journal before allowing a new
        /// ratchet mutation. Replayed inserts are constrained to exact bytes.
        @discardableResult
        func recoverPendingAcceptances() throws -> [CommittedReceipt] {
            var recovered: [CommittedReceipt] = []
            for sessionID in try protectedStore.pendingSessionIDs() {
                let state = try protectedStore.load(sessionID: sessionID)
                try ATSAMEndpointTransactionV1.validateProtectedState(state)
                let pendingKinds = [
                    state.pendingAcceptance != nil,
                    state.pendingAckAcceptance != nil,
                    state.pendingOutbound != nil,
                ].filter { $0 }.count
                guard pendingKinds <= 1 else {
                    throw TransactionError.invalidProtectedState
                }
                if pendingKinds == 0 {
                    continue
                }
                if let pendingOutbound = state.pendingOutbound {
                    guard pendingOutbound.sessionID == state.sessionID,
                          pendingOutbound.objectDigest.count == 32,
                          pendingOutbound.messageID.count == 16,
                          pendingOutbound.recipientDevice.count == 32,
                          pendingOutbound.immutableEnvelopeBytes.count <= RavenEnvelopeV1.maximumWireLength else {
                        throw TransactionError.invalidProtectedState
                    }
                    try mutationLease.withLease(sessionID: state.sessionID) {
                        let transaction = try database.beginImmediate()
                        guard let outboundTx = transaction as? any OutboundDatabaseTransaction else {
                            throw TransactionError.invalidProtectedState
                        }
                        var finished = false
                        defer {
                            if !finished { transaction.rollback() }
                        }
                        if let sourceIntent = pendingOutbound.sourceAckIntent {
                            let intentReceiptKey = ReceiptKey(
                                sessionID: state.sessionID,
                                objectDigest: sourceIntent
                            )
                            if let existingIntent = try database.allAckIntents().first(where: {
                                $0.receiptKey == intentReceiptKey
                            }),
                               existingIntent.stagedEnvelope == pendingOutbound.immutableEnvelopeBytes,
                               existingIntent.queueObjectID == pendingOutbound.objectDigest,
                               !existingIntent.isAbandoned {
                                // Idempotent journal clear after crash-after-SQL materialize.
                            } else {
                                try outboundTx.insertAckMaterialization(
                                    pending: pendingOutbound,
                                    intentReceiptKey: intentReceiptKey,
                                    packedEnvelope: pendingOutbound.immutableEnvelopeBytes,
                                    ackObjectDigest: pendingOutbound.objectDigest
                                )
                            }
                        } else {
                            try outboundTx.insertPreparedOutbound(pendingOutbound)
                        }
                        try transaction.commitAndFsync()
                        finished = true
                        try protectedStore.clearPending(
                            sessionID: state.sessionID,
                            objectDigest: pendingOutbound.objectDigest
                        )
                    }
                    continue
                }
                if let pendingAck = state.pendingAckAcceptance {
                    guard pendingAck.receiptKey.sessionID == state.sessionID,
                          pendingAck.outerMessageID.count == 16,
                          pendingAck.remoteDeviceID.count == 32,
                          pendingAck.ackedMessageID.count == 16,
                          pendingAck.ackNonce.count == 12,
                          pendingAck.sessionGeneration == state.generation else {
                        throw TransactionError.invalidProtectedState
                    }
                    try mutationLease.withLease(sessionID: state.sessionID) {
                        let transaction = try database.beginImmediate()
                        var finished = false
                        defer {
                            if !finished { transaction.rollback() }
                        }
                        _ = try transaction.insertAckAcceptance(pendingAck)
                        try transaction.commitAndFsync()
                        finished = true
                        try protectedStore.clearPending(
                            sessionID: state.sessionID,
                            objectDigest: pendingAck.receiptKey.objectDigest
                        )
                    }
                    continue
                }
                guard let pending = state.pendingAcceptance else { continue }
                guard pending.receiptKey.sessionID == state.sessionID,
                      pending.logicalKey.sessionID == state.sessionID,
                      pending.sessionGeneration == state.generation,
                      pending.ackIntent.receiptKey == pending.receiptKey,
                      pending.ackIntent.sessionGeneration == state.generation else {
                    throw TransactionError.invalidProtectedState
                }

                try mutationLease.withLease(sessionID: state.sessionID) {
                    let transaction = try database.beginImmediate()
                    var finished = false
                    defer {
                        if !finished { transaction.rollback() }
                    }
                    let result = try transaction.insertAcceptance(pending)
                    try transaction.commitAndFsync()
                    finished = true
                    try protectedStore.clearPending(
                        sessionID: state.sessionID,
                        objectDigest: pending.receiptKey.objectDigest
                    )
                    switch result {
                    case let .inserted(receipt), let .exactDuplicate(receipt):
                        recovered.append(receipt)
                    }
                }
            }
            return recovered
        }

        func receive(
            packedEnvelope: Data,
            session: BoundSession,
            nowMs: UInt64
        ) throws -> ReceiveOutcome {
            _ = try recoverPendingAcceptances()

            guard packedEnvelope.count <= RavenEnvelopeV1.maximumWireLength,
                  let envelope = RavenEnvelopeV1.unpack(packedEnvelope) else {
                throw TransactionError.malformedEnvelope
            }
            guard envelope.envType == RavenEnvelopeV1.EnvType.message.rawValue else {
                throw TransactionError.wrongEnvelopeType
            }
            try ATSAMEndpointTransactionV1.validateTime(envelope: envelope, nowMs: nowMs)
            guard envelope.ratchetHeaderCiphertext.isEmpty else {
                throw TransactionError.unexpectedRatchetHeader
            }
            let header = try ATSAMEndpointTransactionV1.parseSealedMessageHeader(
                envelope.messageCiphertext
            )
            try ATSAMEndpointTransactionV1.validateBoundSession(session)

            let state = try protectedStore.load(sessionID: session.sessionID)
            try ATSAMEndpointTransactionV1.validateProtectedState(state)
            guard state.sessionID == session.sessionID else {
                throw TransactionError.wrongSession
            }
            guard state.generation == session.publicGeneration else {
                throw TransactionError.publicGenerationMismatch
            }

            let expectedTag = try ATSAMIndexedSessionProfile.deriveRouteTag(
                root: state.rootKey,
                createdAtMs: envelope.createdAtMs,
                index: header.index,
                envelopeType: RavenEnvelopeV1.EnvType.message.rawValue,
                direction: session.inboundDirection
            )
            guard RavenRoutingTagV1.matches(expectedTag, envelope.routingTag) else {
                throw TransactionError.wrongRouteTag
            }
            // The destination hint is deliberately mutable and excluded from
            // the signature. Zero means a relay cleared it; any nonzero value
            // must still select this exact local device candidate.
            guard envelope.destDeviceHint == 0
                    || envelope.destDeviceHint == session.expectedLocalDeviceHint else {
                throw TransactionError.wrongDeviceHint
            }
            guard session.senderDeviceAccepted else {
                throw TransactionError.unacceptedDevice
            }
            guard !session.senderDeviceRevoked else {
                throw TransactionError.revokedDevice
            }
            try ATSAMEndpointTransactionV1.validateDeviceCertificate(
                session,
                nowMs: nowMs
            )
            try ATSAMEndpointTransactionV1.validateSessionWindow(
                session,
                envelope: envelope,
                nowMs: nowMs
            )

            let senderPublicKey: Curve25519.Signing.PublicKey
            do {
                senderPublicKey = try Curve25519.Signing.PublicKey(
                    rawRepresentation: session.remoteDeviceEd25519PublicKey
                )
            } catch {
                throw TransactionError.invalidDeviceKey
            }
            guard envelope.verify(publicKey: senderPublicKey) else {
                throw TransactionError.invalidOuterSignature
            }

            let objectDigest = envelope.relayObjectDigest()
            let receiptKey = ReceiptKey(
                sessionID: session.sessionID,
                objectDigest: objectDigest
            )
            let logicalKey = LogicalMessageKey(
                sessionID: session.sessionID,
                senderDeviceID: session.remoteDeviceEd25519PublicKey,
                messageID: envelope.messageId
            )

            let transaction = try database.beginImmediate()
            var finished = false
            defer {
                if !finished { transaction.rollback() }
            }

            if let receipt = try transaction.existingReceipt(
                receiptKey: receiptKey,
                logicalKey: logicalKey
            ) {
                return .exactDuplicate(receipt: receipt)
            }

            return try mutationLease.withLease(sessionID: session.sessionID) {
                let candidate = try authenticator.authenticateAndAdvance(
                    envelope: envelope,
                    header: header,
                    session: session,
                    state: state
                )
                try ATSAMEndpointTransactionV1.validateCandidate(
                    candidate,
                    originalState: state,
                    index: header.index
                )
                try ATSAMEndpointTransactionV1.validateText(candidate.plaintext)

                let sealedLocalRow = try ATSAMEndpointTransactionV1.sealForLocalInbox(
                    plaintext: candidate.plaintext,
                    rootKey: state.rootKey,
                    sessionID: session.sessionID,
                    objectDigest: objectDigest,
                    messageID: envelope.messageId,
                    senderDeviceID: session.remoteDeviceEd25519PublicKey,
                    nonce: try nonceSource.freshNonce12()
                )
                var advancedState = state
                advancedState.receiveChainKey = candidate.advancedReceiveChainKey
                advancedState.nextReceiveIndex = candidate.advancedNextReceiveIndex
                advancedState.skippedMessageKeys = candidate.advancedSkippedMessageKeys
                guard advancedState.generation < UInt64.max else {
                    throw TransactionError.invalidProtectedState
                }
                advancedState.generation += 1
                let committedGeneration = advancedState.generation
                let committedAckIntent = AckIntent(
                    receiptKey: receiptKey,
                    ackedMessageID: envelope.messageId,
                    expectedRemoteDeviceID: session.remoteDeviceEd25519PublicKey,
                    status: .delivered,
                    sessionGeneration: committedGeneration,
                    stagedEnvelope: nil,
                    queueObjectID: nil,
                    isQueued: false,
                    isAbandoned: false
                )
                let committedPending = PendingAcceptance(
                    receiptKey: receiptKey,
                    logicalKey: logicalKey,
                    messageIndex: header.index,
                    sealedLocalInboxRow: sealedLocalRow,
                    ackIntent: committedAckIntent,
                    sessionGeneration: committedGeneration
                )
                advancedState.pendingAcceptance = committedPending

                try faults.checkpoint(.beforeProtectedStateReplacement)
                try protectedStore.replace(advancedState)
                try faults.checkpoint(.afterProtectedStateReplacement)

                let insertResult = try transaction.insertAcceptance(committedPending)
                try faults.checkpoint(.beforeDatabaseCommit)
                try transaction.commitAndFsync()
                finished = true
                try faults.checkpoint(.afterDatabaseCommit)

                try faults.checkpoint(.beforeJournalClear)
                try protectedStore.clearPending(
                    sessionID: session.sessionID,
                    objectDigest: objectDigest
                )
                try faults.checkpoint(.afterJournalClear)

                switch insertResult {
                case let .inserted(receipt):
                    return .committed(plaintext: candidate.plaintext, receipt: receipt)
                case let .exactDuplicate(receipt):
                    // The database is authoritative. A correct protected state can
                    // reach this only after recovery/racing durable work; never
                    // surface a second plaintext event.
                    return .exactDuplicate(receipt: receipt)
                }
            }
        }

        /// Origin-side ACK acceptance. This uses the independent ACK receive
        /// lane and the same protected-journal/database recovery boundary as
        /// message acceptance. It never trusts an ID-only acknowledgement.
        ///
        /// Processing order is frozen to §4.8:
        /// contact gate → session/type/time/route/hint → revocation/cert/binding →
        /// outer signature → exact-duplicate lookup → decrypt → inner auth →
        /// outstanding match → nonce uniqueness → pending journal → SQL commit →
        /// journal clear → delivery reconcile.
        func acceptAck(
            packedEnvelope: Data,
            session: BoundSession,
            nowMs: UInt64
        ) throws -> AckAcceptOutcome {
            _ = try recoverPendingAcceptances()

            guard packedEnvelope.count <= RavenEnvelopeV1.maximumWireLength,
                  let envelope = RavenEnvelopeV1.unpack(packedEnvelope) else {
                throw TransactionError.malformedEnvelope
            }

            // §4.8 step 1 — contact gate when bound; else device accept/revoke.
            try ATSAMEndpointTransactionV1.validateAckContactGate(session)

            // §4.8 step 2 — session confirmed; type ACK; time; route; hint.
            guard session.sessionConfirmed else {
                throw TransactionError.sessionNotConfirmed
            }
            guard envelope.envType == RavenEnvelopeV1.EnvType.ack.rawValue else {
                throw TransactionError.wrongEnvelopeType
            }
            try ATSAMEndpointTransactionV1.validateTime(envelope: envelope, nowMs: nowMs)
            guard envelope.ratchetHeaderCiphertext.isEmpty else {
                throw TransactionError.unexpectedRatchetHeader
            }
            guard envelope.messageCiphertext.count
                    == ATSAMIndexedSessionProfile.sealedAckLength else {
                throw TransactionError.invalidSealedHeader
            }
            let header = try ATSAMEndpointTransactionV1.parseSealedMessageHeader(
                envelope.messageCiphertext
            )
            try ATSAMEndpointTransactionV1.validateBoundSession(session)

            let state = try protectedStore.load(sessionID: session.sessionID)
            try ATSAMEndpointTransactionV1.validateProtectedState(state)
            guard state.sessionID == session.sessionID else {
                throw TransactionError.wrongSession
            }
            guard state.generation == session.publicGeneration else {
                throw TransactionError.publicGenerationMismatch
            }
            guard state.pendingAcceptance == nil,
                  state.pendingAckAcceptance == nil,
                  state.pendingOutbound == nil else {
                throw TransactionError.mutationInProgress
            }

            let expectedTag = try ATSAMIndexedSessionProfile.deriveRouteTag(
                root: state.rootKey,
                createdAtMs: envelope.createdAtMs,
                index: header.index,
                envelopeType: RavenEnvelopeV1.EnvType.ack.rawValue,
                direction: session.inboundDirection
            )
            guard RavenRoutingTagV1.matches(expectedTag, envelope.routingTag) else {
                throw TransactionError.wrongRouteTag
            }
            guard envelope.destDeviceHint == 0
                    || envelope.destDeviceHint == session.expectedLocalDeviceHint else {
                throw TransactionError.wrongDeviceHint
            }

            // §4.8 step 3 — revocation + cert verify + device binding.
            guard !session.senderDeviceRevoked else {
                throw TransactionError.revokedDevice
            }
            try ATSAMEndpointTransactionV1.validateDeviceCertificate(session, nowMs: nowMs)
            try ATSAMEndpointTransactionV1.validateSessionWindow(
                session,
                envelope: envelope,
                nowMs: nowMs
            )

            // §4.8 step 4 — outer signature.
            let senderPublicKey: Curve25519.Signing.PublicKey
            do {
                senderPublicKey = try Curve25519.Signing.PublicKey(
                    rawRepresentation: session.remoteDeviceEd25519PublicKey
                )
            } catch {
                throw TransactionError.invalidDeviceKey
            }
            guard envelope.verify(publicKey: senderPublicKey) else {
                throw TransactionError.invalidOuterSignature
            }

            // §4.8 step 5 — `ack_object_digest`; exact duplicate before decrypt.
            let objectDigest = envelope.relayObjectDigest()
            let receiptKey = ReceiptKey(
                sessionID: session.sessionID,
                objectDigest: objectDigest
            )
            let transaction = try database.beginImmediate()
            var finished = false
            defer {
                if !finished { transaction.rollback() }
            }

            if let receipt = try transaction.existingAckReceipt(
                receiptKey: receiptKey,
                outerMessageID: envelope.messageId,
                remoteDeviceID: session.remoteDeviceEd25519PublicKey
            ) {
                let outstandingKey = OutstandingMessageKey(
                    sessionID: session.sessionID,
                    messageID: receipt.ackedMessageID,
                    recipientDeviceID: session.remoteDeviceEd25519PublicKey
                )
                guard let deliveryState = try transaction.outstandingDeliveryState(
                    outstandingKey
                ) else {
                    throw TransactionError.ackOutstandingMismatch
                }
                finished = true
                return .exactDuplicate(receipt: receipt, deliveryState: deliveryState)
            }

            return try mutationLease.withLease(sessionID: session.sessionID) {
                // §4.8 step 6 — decrypt ack_receive lane.
                let candidate = try ATSAMEndpointTransactionV1.authenticateAckAndAdvance(
                    envelope: envelope,
                    header: header,
                    session: session,
                    state: state
                )

                // §4.8 step 7 — inner signature, status, time, nonce.
                guard candidate.signedAck.createdAtMs == envelope.createdAtMs else {
                    throw TransactionError.ackTimestampMismatch
                }
                let innerSigningBytes: Data
                do {
                    innerSigningBytes = try ATSAMIndexedSessionProfile.ackSigningBytes(
                        candidate.signedAck
                    )
                } catch {
                    throw TransactionError.malformedAckEnvelope
                }
                guard senderPublicKey.isValidSignature(
                    candidate.signedAck.signature,
                    for: innerSigningBytes
                ) else {
                    throw TransactionError.ackInnerSignatureInvalid
                }
                guard let status = AckStatus(rawValue: candidate.signedAck.status) else {
                    throw TransactionError.malformedAckEnvelope
                }

                // §4.8 step 8 — outstanding exact match; refuse without delivery change.
                let outstandingKey = OutstandingMessageKey(
                    sessionID: session.sessionID,
                    messageID: candidate.signedAck.ackedMessageId,
                    recipientDeviceID: session.remoteDeviceEd25519PublicKey
                )
                guard try transaction.outstandingDeliveryState(outstandingKey) != nil else {
                    throw TransactionError.ackOutstandingMismatch
                }

                // §4.8 step 9 — nonce replay UNIQUE per (session, remote_device).
                if let existingObject = try transaction.ackNonceObjectDigest(
                    sessionID: session.sessionID,
                    remoteDeviceID: session.remoteDeviceEd25519PublicKey,
                    ackNonce: candidate.signedAck.ackNonce
                ), existingObject != objectDigest {
                    throw TransactionError.ackNonceConflict
                }

                // §4.8 steps 10–11 — monotonic delivery target + pending_ack_acceptance journal.
                var advancedState = state
                advancedState.ackReceiveChainKey = candidate.advancedReceiveChainKey
                advancedState.nextAckReceiveIndex = candidate.advancedNextReceiveIndex
                advancedState.skippedAckKeys = candidate.advancedSkippedKeys
                guard advancedState.generation < UInt64.max else {
                    throw TransactionError.invalidProtectedState
                }
                advancedState.generation += 1
                let pending = PendingAckAcceptance(
                    receiptKey: receiptKey,
                    outerMessageID: envelope.messageId,
                    remoteDeviceID: session.remoteDeviceEd25519PublicKey,
                    ackedMessageID: candidate.signedAck.ackedMessageId,
                    status: status,
                    ackNonce: candidate.signedAck.ackNonce,
                    createdAtMs: candidate.signedAck.createdAtMs,
                    sessionGeneration: advancedState.generation
                )
                advancedState.pendingAckAcceptance = pending

                try faults.checkpoint(.beforeProtectedStateReplacement)
                try protectedStore.replace(advancedState)
                try faults.checkpoint(.afterProtectedStateReplacement)

                // §4.8 step 12 — one SQL tx: ACK receipt + CAS outstanding.
                let insertResult = try transaction.insertAckAcceptance(pending)
                try faults.checkpoint(.beforeDatabaseCommit)
                try transaction.commitAndFsync()
                finished = true
                try faults.checkpoint(.afterDatabaseCommit)

                // §4.8 step 13 — journal clear.
                try faults.checkpoint(.beforeJournalClear)
                try protectedStore.clearPending(
                    sessionID: session.sessionID,
                    objectDigest: objectDigest
                )
                try faults.checkpoint(.afterJournalClear)

                // §4.8 step 14 — history/stage reconcile (stub until UI wiring).
                ATSAMEndpointTransactionV1.reconcileAckDeliveryHistory(
                    receiptKey: receiptKey,
                    ackedMessageID: pending.ackedMessageID,
                    remoteDeviceID: pending.remoteDeviceID
                )

                switch insertResult {
                case let .inserted(receipt, deliveryState):
                    return .committed(receipt: receipt, deliveryState: deliveryState)
                case let .exactDuplicate(receipt, deliveryState):
                    return .exactDuplicate(receipt: receipt, deliveryState: deliveryState)
                }
            }
        }
    }

    actor AckWorker {
        private let protectedStore: any ProtectedStateStore
        private let database: any OutboundDatabase
        private let queue: any ImmutableAckQueue
        private let materializer: any AckMaterializer
        private let dialer: any AckDialer
        private let faults: any FaultInjector
        private let mutationLease: ATSAMSessionMutationLease

        init(
            protectedStore: any ProtectedStateStore,
            database: any OutboundDatabase,
            queue: any ImmutableAckQueue,
            materializer: any AckMaterializer,
            dialer: any AckDialer = NoAckDialer(),
            faults: any FaultInjector = NoFaults(),
            mutationLease: ATSAMSessionMutationLease = .shared
        ) {
            self.protectedStore = protectedStore
            self.database = database
            self.queue = queue
            self.materializer = materializer
            self.dialer = dialer
            self.faults = faults
            self.mutationLease = mutationLease
        }

        /// G3: expire stale queue files and abandon matching intents before any dial.
        @discardableResult
        func expireSweep(
            session: BoundSession,
            nowMs: UInt64
        ) throws -> Int {
            var abandoned = 0
            for intent in try database.allAckIntents().filter({ !$0.isAbandoned }) {
                guard let packed = intent.stagedEnvelope,
                      let ackDigest = intent.queueObjectID,
                      let envelope = RavenEnvelopeV1.unpack(packed) else {
                    continue
                }
                let expiresAtMs = Self.ackQueueExpiresAtMs(
                    sessionExpiresAtMs: session.sessionExpiresAtMs,
                    envelopeExpiresAtMs: envelope.expiresAtMs,
                    createdAtMs: envelope.createdAtMs
                )
                guard nowMs >= expiresAtMs else { continue }
                _ = try queue.deleteIfPresent(objectID: ackDigest)
                try database.markAckAbandoned(receiptKey: intent.receiptKey)
                abandoned += 1
            }
            return abandoned
        }

        /// §4.7 resume inspection — never jump straight to dial.
        @discardableResult
        func resumeOneCommittedAck(
            session: BoundSession,
            nowMs: UInt64,
            allowDial: Bool = true
        ) throws -> AckResumeAction {
            _ = try expireSweep(session: session, nowMs: nowMs)

            let unqueued = try database.nextUnqueuedAckIntent()
            let queued = try database.allAckIntents().first(where: { $0.isQueued && !$0.isAbandoned })
            guard let intent = unqueued ?? queued else {
                return .idle
            }
            if intent.isAbandoned {
                return .idle
            }

            let sourceDigest = intent.receiptKey.objectDigest

            // Crash-after-SQL may leave staged bytes in SQL while Keychain still holds pending_outbound.
            let protectedState = try protectedStore.load(sessionID: session.sessionID)
            if let pendingOutbound = protectedState.pendingOutbound,
               pendingOutbound.sourceAckIntent == sourceDigest {
                return try resumeAckMaterializationFromJournal(
                    intent: intent,
                    session: session,
                    pending: pendingOutbound
                )
            }

            if intent.stagedEnvelope == nil {
                return try materializeAck(intent: intent, session: session, nowMs: nowMs)
            }

            guard let packed = intent.stagedEnvelope,
                  let ackDigest = intent.queueObjectID,
                  ackDigest.count == 32 else {
                throw TransactionError.stagedAckCollision
            }

            if intent.isQueued {
                guard allowDial else { return .idle }
                guard try queue.contains(objectID: ackDigest) else {
                    return try enqueueAck(intent: intent, packed: packed, ackDigest: ackDigest)
                }
                try dialer.dial(packedEnvelope: packed, ackObjectDigest: ackDigest)
                if try database.nextUnqueuedAckIntent() == nil {
                    _ = try queue.deleteIfPresent(objectID: ackDigest)
                }
                return .dialed(ackObjectDigest: ackDigest)
            }

            if try !queue.contains(objectID: ackDigest) {
                return try enqueueAck(intent: intent, packed: packed, ackDigest: ackDigest)
            }
            return try markAckQueued(intent: intent, packed: packed, ackDigest: ackDigest)
        }

        /// Enqueues through queued-mark without dialing (legacy lab hook).
        @discardableResult
        func enqueueOneCommittedAck(
            session: BoundSession,
            nowMs: UInt64
        ) throws -> Bool {
            var progressed = false
            while true {
                switch try resumeOneCommittedAck(
                    session: session,
                    nowMs: nowMs,
                    allowDial: false
                ) {
                case .idle, .expired:
                    return progressed
                case .materialized, .enqueued:
                    progressed = true
                case .queuedMarked, .dialed:
                    return true
                }
            }
        }

        private func materializeAck(
            intent: AckIntent,
            session: BoundSession,
            nowMs: UInt64
        ) throws -> AckResumeAction {
            let state = try protectedStore.load(sessionID: intent.receiptKey.sessionID)
            if let pending = state.pendingOutbound,
               pending.sourceAckIntent == intent.receiptKey.objectDigest {
                return try resumeAckMaterializationFromJournal(
                    intent: intent,
                    session: session,
                    pending: pending
                )
            }
            guard state.pendingOutbound == nil else {
                throw TransactionError.outboundPending
            }
            let expiresAtMs = min(
                session.sessionExpiresAtMs,
                nowMs.addingReportingOverflow(ATSAMEndpointTransactionV1.maximumLifetimeMs).partialValue
            )
            return try mutationLease.withLease(sessionID: session.sessionID) {
                let prepared = try materializer.prepareCommittedAck(
                    intent: intent,
                    session: session,
                    state: state,
                    createdAtMs: nowMs &+ 1,
                    expiresAtMs: expiresAtMs
                )
                guard prepared.sourceMessageDigest == intent.receiptKey.objectDigest,
                      prepared.pendingOutbound.sourceAckIntent == intent.receiptKey.objectDigest,
                      prepared.pendingOutbound.objectDigest == prepared.ackObjectDigest,
                      prepared.sourceMessageDigest != prepared.ackObjectDigest else {
                    throw TransactionError.stagedAckCollision
                }

                var advancedState = state
                advancedState.ackSendChainKey = prepared.advancedAckSendChainKey
                advancedState.nextAckSendIndex = prepared.advancedNextAckSendIndex
                advancedState.generation = prepared.committedGeneration
                advancedState.pendingOutbound = prepared.pendingOutbound

                try faults.checkpoint(.beforeProtectedStateReplacement)
                try protectedStore.replace(advancedState)
                try faults.checkpoint(.afterProtectedStateReplacement)

                let transaction = try database.beginImmediate()
                guard let outboundTx = transaction as? any OutboundDatabaseTransaction else {
                    throw TransactionError.invalidProtectedState
                }
                var finished = false
                defer {
                    if !finished { transaction.rollback() }
                }
                try outboundTx.insertAckMaterialization(
                    pending: prepared.pendingOutbound,
                    intentReceiptKey: intent.receiptKey,
                    packedEnvelope: prepared.packedEnvelope,
                    ackObjectDigest: prepared.ackObjectDigest
                )
                try faults.checkpoint(.beforeDatabaseCommit)
                try transaction.commitAndFsync()
                finished = true
                try faults.checkpoint(.afterDatabaseCommit)

                try faults.checkpoint(.beforeJournalClear)
                try protectedStore.clearPending(
                    sessionID: session.sessionID,
                    objectDigest: prepared.ackObjectDigest
                )
                try faults.checkpoint(.afterJournalClear)

                return .materialized(
                    sourceMessageDigest: prepared.sourceMessageDigest,
                    ackObjectDigest: prepared.ackObjectDigest
                )
            }
        }

        private func resumeAckMaterializationFromJournal(
            intent: AckIntent,
            session: BoundSession,
            pending: PendingOutbound
        ) throws -> AckResumeAction {
            guard pending.sessionID == session.sessionID,
                  pending.objectDigest.count == 32,
                  pending.immutableEnvelopeBytes.count <= RavenEnvelopeV1.maximumWireLength else {
                throw TransactionError.invalidProtectedState
            }
            let ackDigest = pending.objectDigest
            let packed = pending.immutableEnvelopeBytes
            return try mutationLease.withLease(sessionID: session.sessionID) {
                if intent.stagedEnvelope == nil {
                    let transaction = try database.beginImmediate()
                    guard let outboundTx = transaction as? any OutboundDatabaseTransaction else {
                        throw TransactionError.invalidProtectedState
                    }
                    var finished = false
                    defer {
                        if !finished { transaction.rollback() }
                    }
                    try outboundTx.insertAckMaterialization(
                        pending: pending,
                        intentReceiptKey: intent.receiptKey,
                        packedEnvelope: packed,
                        ackObjectDigest: ackDigest
                    )
                    try faults.checkpoint(.beforeDatabaseCommit)
                    try transaction.commitAndFsync()
                    finished = true
                    try faults.checkpoint(.afterDatabaseCommit)
                } else {
                    guard intent.stagedEnvelope == packed,
                          intent.queueObjectID == ackDigest else {
                        throw TransactionError.stagedAckCollision
                    }
                }

                try faults.checkpoint(.beforeJournalClear)
                try protectedStore.clearPending(
                    sessionID: session.sessionID,
                    objectDigest: ackDigest
                )
                try faults.checkpoint(.afterJournalClear)

                return .materialized(
                    sourceMessageDigest: intent.receiptKey.objectDigest,
                    ackObjectDigest: ackDigest
                )
            }
        }

        private func enqueueAck(
            intent: AckIntent,
            packed: Data,
            ackDigest: Data
        ) throws -> AckResumeAction {
            guard ackDigest == Self.ackObjectDigest(for: packed) else {
                throw TransactionError.stagedAckCollision
            }
            try faults.checkpoint(.beforeImmutableAckEnqueue)
            try queue.enqueueImmutable(objectID: ackDigest, packedEnvelope: packed)
            try faults.checkpoint(.afterImmutableAckEnqueue)
            return try markAckQueued(intent: intent, packed: packed, ackDigest: ackDigest)
        }

        private func markAckQueued(
            intent: AckIntent,
            packed: Data,
            ackDigest: Data
        ) throws -> AckResumeAction {
            if intent.isQueued {
                return .queuedMarked(ackObjectDigest: ackDigest)
            }
            return try mutationLease.withLease(sessionID: intent.receiptKey.sessionID) {
                try faults.checkpoint(.beforeAckQueuedMark)
                try database.markAckQueued(
                    receiptKey: intent.receiptKey,
                    queueObjectID: ackDigest
                )
                try faults.checkpoint(.afterAckQueuedMark)
                return .queuedMarked(ackObjectDigest: ackDigest)
            }
        }

        static func ackObjectDigest(for packedEnvelope: Data) -> Data {
            guard let envelope = RavenEnvelopeV1.unpack(packedEnvelope) else {
                return Data(repeating: 0, count: 32)
            }
            return envelope.relayObjectDigest()
        }

        static func ackQueueExpiresAtMs(
            sessionExpiresAtMs: UInt64,
            envelopeExpiresAtMs: UInt64,
            createdAtMs: UInt64
        ) -> UInt64 {
            let ttlDeadline = createdAtMs.addingReportingOverflow(ackQueueFileTTLMs)
            let candidates = [
                sessionExpiresAtMs,
                envelopeExpiresAtMs,
                ttlDeadline.overflow ? UInt64.max : ttlDeadline.partialValue,
            ]
            return candidates.min() ?? sessionExpiresAtMs
        }
    }

    final class NoAckDialer: AckDialer {
        func dial(packedEnvelope: Data, ackObjectDigest: Data) throws {}
    }

    /// Origin-side send path (§4.6). Order is frozen:
    /// 1 capacity preflight → 2 envelope in memory → 3 durable body stage →
    /// 4 protected replacement + SQL outbox under G1 lease → 5 journal clear →
    /// 6 release lease then queued + dial (dial outside lease).
    /// Orphans (stage without outbox/pending journal) are deleted and never dialed.
    actor Sender {
        private let protectedStore: any ProtectedStateStore
        private let database: any OutboundDatabase
        private let bodyStage: ATSAMOutboundBodyStage.Store
        private let materializer: any OutboundMaterializer
        private let dialer: any OutboundDialer
        private let faults: any FaultInjector
        private let mutationLease: ATSAMSessionMutationLease

        init(
            protectedStore: any ProtectedStateStore,
            database: any OutboundDatabase,
            bodyStage: ATSAMOutboundBodyStage.Store,
            materializer: any OutboundMaterializer,
            dialer: any OutboundDialer,
            faults: any FaultInjector = NoFaults(),
            mutationLease: ATSAMSessionMutationLease = .shared
        ) {
            self.protectedStore = protectedStore
            self.database = database
            self.bodyStage = bodyStage
            self.materializer = materializer
            self.dialer = dialer
            self.faults = faults
            self.mutationLease = mutationLease
        }

        /// G2 orphan policy: securely delete staged bodies with no outbox/pending journal.
        @discardableResult
        func reconcileOrphanStages() throws -> [OrphanReconcileResult] {
            let orphans = try bodyStage.reconcileOrphans(
                hasOutbox: { sessionID, objectDigest in
                    try self.database.hasOutboxRow(
                        sessionID: sessionID,
                        objectDigest: objectDigest
                    )
                },
                hasPendingOutbound: { sessionID, objectDigest, messageID in
                    let state = try self.protectedStore.load(sessionID: sessionID)
                    guard let pending = state.pendingOutbound else { return false }
                    return pending.sessionID == sessionID
                        && pending.objectDigest == objectDigest
                        && pending.messageID == messageID
                }
            )
            return orphans.compactMap { error in
                if case let .orphanDeleted(messageID) = error {
                    return .deleted(messageID: messageID)
                }
                return nil
            }
        }

        func send(
            text: Data,
            session: BoundSession,
            createdAtMs: UInt64,
            expiresAtMs: UInt64
        ) throws -> SendOutcome {
            _ = try reconcileOrphanStages()
            try ATSAMEndpointTransactionV1.validateText(text)
            try ATSAMEndpointTransactionV1.validateBoundSession(session)

            let state = try protectedStore.load(sessionID: session.sessionID)
            try ATSAMEndpointTransactionV1.validateProtectedState(state)
            guard state.sessionID == session.sessionID else {
                throw TransactionError.wrongSession
            }
            guard state.generation == session.publicGeneration else {
                throw TransactionError.publicGenerationMismatch
            }
            guard state.pendingOutbound == nil else {
                throw TransactionError.outboundPending
            }

            guard let body = String(data: text, encoding: .utf8) else {
                throw TransactionError.invalidTextPayload
            }

            // 1. Capacity preflight
            do {
                try bodyStage.preflightCapacity(body: body, createdAtMs: createdAtMs)
            } catch ATSAMOutboundBodyStage.StageError.tooLarge {
                throw TransactionError.stageCapacityExceeded
            } catch let error as ATSAMOutboundBodyStage.StageError {
                switch error {
                case .fsyncFailed, .ioFailed, .authenticationFailed, .corrupt, .bindingMismatch:
                    throw TransactionError.invalidProtectedState
                case .tooLarge:
                    throw TransactionError.stageCapacityExceeded
                case .orphanDeleted:
                    throw TransactionError.invalidProtectedState
                }
            }

            // 2. Build envelope + bindings in memory (ratchet only in memory)
            let prepared = try materializer.prepareOutbound(
                text: text,
                session: session,
                state: state,
                createdAtMs: createdAtMs,
                expiresAtMs: expiresAtMs
            )
            guard prepared.sessionID == session.sessionID,
                  prepared.pendingOutbound.sessionID == session.sessionID,
                  prepared.pendingOutbound.objectDigest == prepared.objectDigest,
                  prepared.pendingOutbound.messageID == prepared.messageID else {
                throw TransactionError.invalidProtectedState
            }

            // 3. Durable body stage (outside G1 lease; stage store has its own lock)
            try faults.checkpoint(.beforeOutboundStage)
            do {
                try bodyStage.stage(
                    peerPub: prepared.peerPub,
                    sessionID: prepared.sessionID,
                    objectDigest: prepared.objectDigest,
                    messageID: prepared.messageID,
                    createdAtMs: prepared.createdAtMs,
                    body: prepared.body
                )
            } catch ATSAMOutboundBodyStage.StageError.tooLarge {
                throw TransactionError.stageCapacityExceeded
            } catch let error as ATSAMOutboundBodyStage.StageError {
                switch error {
                case .fsyncFailed, .ioFailed:
                    throw TransactionError.invalidProtectedState
                case .authenticationFailed, .corrupt, .bindingMismatch:
                    throw TransactionError.invalidProtectedState
                default:
                    throw TransactionError.invalidProtectedState
                }
            } catch {
                throw TransactionError.invalidProtectedState
            }
            try faults.checkpoint(.afterOutboundStage)

            // 4–5. Protected replacement + SQL outbox under G1 lease, then journal clear.
            try mutationLease.withLease(sessionID: session.sessionID) {
                let transaction = try database.beginImmediate()
                var finished = false
                defer {
                    if !finished { transaction.rollback() }
                }
                guard let outboundTx = transaction as? any OutboundDatabaseTransaction else {
                    throw TransactionError.invalidProtectedState
                }

                var advancedState = state
                advancedState.sendChainKey = prepared.advancedSendChainKey
                advancedState.nextSendIndex = prepared.advancedNextSendIndex
                advancedState.generation = prepared.committedGeneration
                advancedState.pendingOutbound = prepared.pendingOutbound

                try faults.checkpoint(.beforeOutboundProtectedReplacement)
                try protectedStore.replace(advancedState)
                try faults.checkpoint(.afterOutboundProtectedReplacement)

                try outboundTx.insertPreparedOutbound(prepared.pendingOutbound)
                try faults.checkpoint(.beforeOutboundDatabaseCommit)
                try transaction.commitAndFsync()
                finished = true
                try faults.checkpoint(.afterOutboundDatabaseCommit)

                try faults.checkpoint(.beforeOutboundJournalClear)
                try protectedStore.clearPending(
                    sessionID: session.sessionID,
                    objectDigest: prepared.objectDigest
                )
                try faults.checkpoint(.afterOutboundJournalClear)
            }

            // 6. Release lease (defer in withLease) → queued + dial outside lease.
            try dialer.dial(
                packedEnvelope: prepared.packedEnvelope,
                objectDigest: prepared.objectDigest
            )
            return .queued(
                objectDigest: prepared.objectDigest,
                messageID: prepared.messageID
            )
        }
    }

    // MARK: - Validation and local sealing

    private static func validateTime(envelope: RavenEnvelopeV1, nowMs: UInt64) throws {
        guard envelope.createdAtMs < envelope.expiresAtMs,
              nowMs < envelope.expiresAtMs,
              envelope.expiresAtMs - envelope.createdAtMs <= maximumLifetimeMs else {
            throw TransactionError.invalidTimeWindow
        }
        let latestCreated = nowMs.addingReportingOverflow(maximumFutureSkewMs)
        guard latestCreated.overflow || envelope.createdAtMs <= latestCreated.partialValue else {
            throw TransactionError.invalidTimeWindow
        }
    }

    private static func validateBoundSession(_ session: BoundSession) throws {
        guard session.sessionID.count == 32,
              session.remoteDeviceEd25519PublicKey.count == 32 else {
            throw TransactionError.wrongSession
        }
        guard session.remoteDeviceEd25519PublicKey.count == 32 else {
            throw TransactionError.invalidDeviceKey
        }
        do {
            _ = try ATSAMIndexedSessionProfile.endpoints(
                initiatorAddress: session.initiatorAddress,
                responderAddress: session.responderAddress,
                direction: session.inboundDirection
            )
        } catch {
            throw TransactionError.wrongDirection
        }
    }

    /// §4.8 step 1 — optional contact gate; otherwise legacy device accept/revoke.
    private static func validateAckContactGate(_ session: BoundSession) throws {
        if let contactAllowed = session.senderContactAllowed {
            guard contactAllowed else {
                throw TransactionError.contactBlocked
            }
        } else {
            guard session.senderDeviceAccepted else {
                throw TransactionError.unacceptedDevice
            }
            guard !session.senderDeviceRevoked else {
                throw TransactionError.revokedDevice
            }
        }
    }

    /// §4.8 step 14 — post-commit delivery/history reconcile hook (stub).
    private static func reconcileAckDeliveryHistory(
        receiptKey: ReceiptKey,
        ackedMessageID: Data,
        remoteDeviceID: Data
    ) {
        _ = receiptKey
        _ = ackedMessageID
        _ = remoteDeviceID
    }

    private static func validateDeviceCertificate(
        _ session: BoundSession,
        nowMs: UInt64
    ) throws {
        let expectedIdentityAddress: String
        do {
            expectedIdentityAddress = try ATSAMIndexedSessionProfile.endpoints(
                initiatorAddress: session.initiatorAddress,
                responderAddress: session.responderAddress,
                direction: session.inboundDirection
            ).sender
            _ = try ATSAMPairInitV1.verifyBoundDeviceCertificate(
                session.senderCertificate,
                expectedCertificateHash: session.pairInitSenderCertificateHash,
                expectedDeviceEd25519PublicKey: session.remoteDeviceEd25519PublicKey,
                expectedIdentityAddress: expectedIdentityAddress,
                nowMs: nowMs
            )
        } catch ATSAMPairInitV1.PairInitError.identityMismatch {
            throw TransactionError.deviceBindingMismatch
        } catch ATSAMPairInitV1.PairInitError.certificateMismatch {
            throw TransactionError.deviceBindingMismatch
        } catch {
            throw TransactionError.invalidDeviceCertificate
        }
    }

    private static func validateSessionWindow(
        _ session: BoundSession,
        envelope: RavenEnvelopeV1,
        nowMs: UInt64
    ) throws {
        guard session.sessionCreatedAtMs < session.sessionExpiresAtMs,
              nowMs >= session.sessionCreatedAtMs,
              nowMs < session.sessionExpiresAtMs,
              envelope.createdAtMs >= session.sessionCreatedAtMs,
              envelope.expiresAtMs <= session.sessionExpiresAtMs else {
            throw TransactionError.invalidTimeWindow
        }
    }

    private static func authenticateAckAndAdvance(
        envelope: RavenEnvelopeV1,
        header: SealedMessageHeader,
        session: BoundSession,
        state: ProtectedSessionState
    ) throws -> AuthenticatedAckCandidate {
        let endpoints = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: session.initiatorAddress,
            responderAddress: session.responderAddress,
            direction: session.inboundDirection
        )
        var advancedChain = state.ackReceiveChainKey
        var advancedNext = state.nextAckReceiveIndex
        var advancedSkipped = state.skippedAckKeys
        var selectedKey: Data?

        if header.index < state.nextAckReceiveIndex {
            guard let skippedKey = advancedSkipped.removeValue(forKey: header.index) else {
                throw TransactionError.replay
            }
            selectedKey = skippedKey
        } else {
            let jump = header.index - state.nextAckReceiveIndex
            guard jump <= maximumIndexJump, header.index != UInt32.max else {
                throw TransactionError.indexJumpTooLarge
            }
            var cursor = state.nextAckReceiveIndex
            while cursor <= header.index {
                let candidateKey = try ATSAMIndexedSessionProfile.laneMessageKey(
                    chainKey: advancedChain,
                    sender: endpoints.sender,
                    recipient: endpoints.recipient
                )
                advancedChain = try ATSAMIndexedSessionProfile.advanceChainKey(advancedChain)
                if cursor == header.index {
                    selectedKey = candidateKey
                    break
                }
                guard advancedSkipped.count < maximumSkippedKeys else {
                    throw TransactionError.indexJumpTooLarge
                }
                advancedSkipped[cursor] = candidateKey
                cursor += 1
            }
            advancedNext = header.index + 1
        }
        guard let messageKey = selectedKey else {
            throw TransactionError.invalidProtectedState
        }

        let aad = try ATSAMIndexedSessionProfile.buildAAD(
            index: header.index,
            sender: endpoints.sender,
            recipient: endpoints.recipient,
            outerMessageId: envelope.messageId
        )
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: header.nonce),
                ciphertext: header.ciphertext,
                tag: header.tag
            )
            plaintext = try ChaChaPoly.open(
                box,
                using: SymmetricKey(data: messageKey),
                authenticating: aad
            )
        } catch {
            throw TransactionError.authenticationFailed
        }
        let signedAck: ATSAMIndexedSessionProfile.SignedAck
        do {
            signedAck = try ATSAMIndexedSessionProfile.decodeSignedAck(plaintext)
        } catch {
            throw TransactionError.malformedAckEnvelope
        }
        return AuthenticatedAckCandidate(
            signedAck: signedAck,
            advancedReceiveChainKey: advancedChain,
            advancedNextReceiveIndex: advancedNext,
            advancedSkippedKeys: advancedSkipped
        )
    }

    private static func validateProtectedState(_ state: ProtectedSessionState) throws {
        guard state.sessionID.count == 32,
              state.rootKey.count == 32,
              state.receiveChainKey.count == 32,
              state.sendChainKey.count == 32,
              state.ackSendChainKey.count == 32,
              state.ackReceiveChainKey.count == 32,
              state.skippedMessageKeys.count <= maximumSkippedKeys,
              state.skippedMessageKeys.values.allSatisfy({ $0.count == 32 }),
              state.skippedAckKeys.count <= maximumSkippedKeys,
              state.skippedAckKeys.values.allSatisfy({ $0.count == 32 }) else {
            throw TransactionError.invalidProtectedState
        }
    }

    private static func validateCandidate(
        _ candidate: AuthenticatedCandidate,
        originalState: ProtectedSessionState,
        index: UInt32
    ) throws {
        guard candidate.advancedReceiveChainKey.count == 32,
              candidate.advancedSkippedMessageKeys.count <= maximumSkippedKeys,
              candidate.advancedSkippedMessageKeys.values.allSatisfy({ $0.count == 32 }) else {
            throw TransactionError.invalidProtectedState
        }
        if index < originalState.nextReceiveIndex {
            guard candidate.advancedNextReceiveIndex == originalState.nextReceiveIndex,
                  candidate.advancedReceiveChainKey == originalState.receiveChainKey,
                  candidate.advancedSkippedMessageKeys[index] == nil else {
                throw TransactionError.invalidProtectedState
            }
        } else {
            guard index != UInt32.max,
                  candidate.advancedNextReceiveIndex == index + 1 else {
                throw TransactionError.invalidProtectedState
            }
        }
    }

    private static func validateText(_ plaintext: Data) throws {
        guard !plaintext.isEmpty,
              plaintext.count <= maximumTextBytes,
              let text = String(data: plaintext, encoding: .utf8),
              !text.unicodeScalars.contains(where: { scalar in
                  scalar.value == 0x7F || scalar.value == 0 || (scalar.value < 0x20
                      && scalar.value != 0x09
                      && scalar.value != 0x0A
                      && scalar.value != 0x0D)
              }) else {
            throw TransactionError.invalidTextPayload
        }
    }

    private static func parseSealedMessageHeader(_ wire: Data) throws -> SealedMessageHeader {
        let fixedPrefixLength = 26
        let tagLength = 16
        guard wire.count >= fixedPrefixLength + tagLength,
              wire.count <= maximumTextBytes + fixedPrefixLength + tagLength,
              wire.prefix(8) == ATSAMIndexedSessionProfile.rvna1Magic,
              wire[8] == ATSAMIndexedSessionProfile.protocolByte,
              wire[9] == ATSAMIndexedSessionProfile.suiteByte else {
            throw TransactionError.invalidSealedHeader
        }
        let index = (UInt32(wire[10]) << 24)
            | (UInt32(wire[11]) << 16)
            | (UInt32(wire[12]) << 8)
            | UInt32(wire[13])
        let tagStart = wire.count - tagLength
        return SealedMessageHeader(
            index: index,
            nonce: wire.subdata(in: 14..<26),
            ciphertext: wire.subdata(in: 26..<tagStart),
            tag: wire.subdata(in: tagStart..<wire.count)
        )
    }

    private static func sealForLocalInbox(
        plaintext: Data,
        rootKey: Data,
        sessionID: Data,
        objectDigest: Data,
        messageID: Data,
        senderDeviceID: Data,
        nonce: Data
    ) throws -> Data {
        guard rootKey.count == 32,
              sessionID.count == 32,
              objectDigest.count == 32,
              messageID.count == 16,
              senderDeviceID.count == 32,
              nonce.count == 12 else {
            throw TransactionError.invalidLocalSeal
        }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rootKey),
            salt: sessionID,
            info: localInboxKeyDomain,
            outputByteCount: 32
        )
        var aad = localInboxAADDomain
        aad.append(sessionID)
        aad.append(objectDigest)
        aad.append(messageID)
        aad.append(senderDeviceID)
        do {
            let box = try ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: ChaChaPoly.Nonce(data: nonce),
                authenticating: aad
            )
            var result = Data([0x01])
            result.append(nonce)
            result.append(box.ciphertext)
            result.append(box.tag)
            guard result.count == 1 + 12 + plaintext.count + 16 else {
                throw TransactionError.invalidLocalSeal
            }
            return result
        } catch let error as TransactionError {
            throw error
        } catch {
            throw TransactionError.invalidLocalSeal
        }
    }
}
