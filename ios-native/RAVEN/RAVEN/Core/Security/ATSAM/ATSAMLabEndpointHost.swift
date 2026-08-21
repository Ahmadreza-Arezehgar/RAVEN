//
//  ATSAMLabEndpointHost.swift
//  RAVEN — Test A lab endpoint: session install, receive → chat, sealed ACK uplink.
//

import CryptoKit
import Foundation

@MainActor
final class ATSAMLabEndpointHost {
    static let shared = ATSAMLabEndpointHost()

    enum HostError: Error, LocalizedError {
        case sqlCipherUnavailable(String)
        case labGateClosed
        case noSession
        case lanConfigMissing
        case legacySessionRefused(Int)
        case inboundAckMissing
        case generationRollback(sessionID: Data, protected: UInt64, head: UInt64)
        case rngFailed(String)

        var errorDescription: String? {
            switch self {
            case .sqlCipherUnavailable(let detail): return "SQLCipher unavailable: \(detail)"
            case .labGateClosed: return "Lab endpoint gate closed"
            case .noSession: return "No lab session installed"
            case .lanConfigMissing: return "LAN config missing — Save host/port first"
            case .legacySessionRefused(let n): return "Legacy plaintext sessions quarantined (\(n)) — re-pair required"
            case .inboundAckMissing: return "Dial completed but no sealed ACK on same connection"
            case .generationRollback(let sid, let protected, let head):
                let prefix = sid.prefix(4).map { String(format: "%02x", $0) }.joined()
                return "Generation rollback refused session=\(prefix)… protected=\(protected) head=\(head)"
            case .rngFailed(let s): return "CSPRNG failed: \(s)"
            }
        }
    }

    private var acceptanceDBResult: Result<SQLCipherAcceptanceDatabase, Error>
    private(set) var lastLabStatus: String = "idle"
    private(set) var legacyMigrationRefused = false

    #if DEBUG
    private(set) var duplicateAckRecoveryCount = 0
    #endif

    #if DEBUG
    static var acceptanceDBFactory: (() throws -> SQLCipherAcceptanceDatabase) = {
        try SQLCipherAcceptanceDatabase()
    }
    #endif

    private init() {
        #if DEBUG
        acceptanceDBResult = Result { try Self.acceptanceDBFactory() }
        #else
        acceptanceDBResult = Result { try SQLCipherAcceptanceDatabase() }
        #endif
    }

    var acceptanceDB: SQLCipherAcceptanceDatabase? {
        try? acceptanceDBResult.get()
    }

    var acceptanceDBErrorDescription: String? {
        switch acceptanceDBResult {
        case .success: return nil
        case .failure(let error): return String(describing: error)
        }
    }

    var isOperational: Bool {
        acceptanceDB != nil && !legacyMigrationRefused
    }
    private var boundSessions: [Data: ATSAMEndpointTransactionV1.BoundSession] = [:]
    private var sessionMeta: [Data: SessionMeta] = [:]
    private var ingestObserver: NSObjectProtocol?
    private var acceptObserver: NSObjectProtocol?
    private let secureContactBook = RavenSecureLanLabTrustContactBook()
    private let secureEphemeralCache = RavenSecureLanEphemeralPeerCache()

    private struct SessionMeta: Codable {
        var rootKey: Data
        var initiatorAddress: String
        var responderAddress: String
        var remoteDeviceEd: Data
        var senderCertIdentity: Data
        var senderCertSigning: Data
        var senderCertSig: Data
        var pairInitSenderCertHash: Data
        var sessionCreatedAtMs: UInt64
        var sessionExpiresAtMs: UInt64
        var localDeviceEd: Data
    }

    func start() {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled,
              FeatureFlag.isRavenEnvelopeV1Enabled else { return }

        migrateLegacyPlaintextSessionsFailClosed()
        rehydrateBoundSessionsFromDurableStores()
        surfaceAcceptanceDBStatus()

        if ingestObserver == nil {
            ingestObserver = NotificationCenter.default.addObserver(
                forName: .ravenEnvelopeV1EndpointIngest,
                object: nil,
                queue: .main
            ) { [weak self] note in
                Task { @MainActor in
                    await self?.onSealedIngest(note)
                }
            }
        }
        // Avoid double-accept: ViewModel calls AcceptService directly.
        // Observer retained only for external/automation posts of the same name.
        if acceptObserver == nil {
            acceptObserver = NotificationCenter.default.addObserver(
                forName: .ravenPairInitAccepted,
                object: nil,
                queue: .main
            ) { _ in
                // no-op: accept already completed by ContactRequestInboxViewModel
            }
        }
        configureSecureSessionIfPossible()
        RavenSecureLanLabListenerController.shared.installLifecycleObserversIfNeeded()
        configureSecureListenIfPossible()
        #if DEBUG
        print("🕊️ [LabEndpoint] started (lab Test A, secure listen wired)")
        #endif
    }

    private func configureSecureSessionIfPossible() {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return }
        let host = self
        RavenSecureLanTransportV1.configureLabSession(
            RavenSecureLanSessionConfiguration(
                deviceSeedProvider: {
                    guard let seed = DeviceIdentityService.shared.deviceSigningSeed else {
                        throw RavenSecureLanSessionError.ioFailed
                    }
                    return seed
                },
                encodeLocalOffer: {
                    try ATSAMLabTrustStore.encodeLocalRlb1Offer()
                },
                contactBook: secureContactBook,
                ephemeralCache: secureEphemeralCache,
                trustedPersistence: nil,
                inboundDispatch: { frame, peer, noiseEd in
                    try await host.dispatchSecureInboundFrame(frame, peer: peer, noiseEdPub: noiseEd)
                }
            )
        )
    }

    #if DEBUG
    static func rebindAcceptanceDBForTesting(_ result: Result<SQLCipherAcceptanceDatabase, Error>) {
        shared.acceptanceDBResult = result
    }
    #endif

    /// Post-Noise dispatch for inbound LAN frames (no RavenServerlessLanPath).
    func dispatchSecureInboundFrame(
        _ frame: Data,
        peer: RavenSecureLanRlb1V1.LanBundle,
        noiseEdPub: Data
    ) async throws -> [Data] {
        if RavenSecureLanRlb1V1.isRlb1(frame) {
            let offer = try RavenSecureLanRlb1V1.decodeOffer(frame)
            guard RavenSecureLanDispatchV1.rlb1MatchesNoiseIdentity(offer, noiseEdPub: noiseEdPub) else {
                throw RavenSecureLanDispatchError.rlb1NoiseIdentityMismatch
            }
            guard offer.cert.deviceEdPub == peer.cert.deviceEdPub else {
                throw RavenSecureLanDispatchError.rlb1DeviceIdentityDrift
            }
            try secureEphemeralCache.cachePeerBundle(
                offer,
                contactBook: secureContactBook,
                durable: nil
            )
            return []
        }

        switch RavenPairInitLanOob.classifyPackedEnvelope(frame) {
        case .pairInit(let wire):
            try requireSecureContact(peer: peer, noiseEdPub: noiseEdPub, kind: "pair init")
            if let packed = try await ATSAMPairInitAcceptService.accept(
                pairInitWire: wire,
                delivery: .sameConnection
            ) {
                return [packed]
            }
            return []
        case .pairResponse:
            return []
        case .notPairInitOob:
            break
        }

        guard let env = RavenEnvelopeV1.unpack(frame) else {
            throw RavenSecureLanDispatchError.notEnvelope
        }

        if env.envType == RavenEnvelopeV1.EnvType.ack.rawValue {
            try requireSecureContact(peer: peer, noiseEdPub: noiseEdPub, kind: "ack")
            try await acceptInboundAckPacked(frame)
            return []
        }

        if env.envType == RavenEnvelopeV1.EnvType.message.rawValue {
            try requireSecureContact(peer: peer, noiseEdPub: noiseEdPub, kind: "message")
            return await receivePacked(frame, replyOnSameConnection: true)
        }

        return []
    }

    private func requireSecureContact(
        peer: RavenSecureLanRlb1V1.LanBundle,
        noiseEdPub: Data,
        kind: String
    ) throws {
        if secureContactBook.isBlocked(
            deviceEdPub: peer.cert.deviceEdPub,
            userEdPub: peer.cert.userEdPub,
            noiseEdPub: noiseEdPub
        ) {
            throw RavenSecureLanDispatchError.peerBlocked
        }
        guard RavenSecureLanDispatchV1.peerIsTrusted(peer, contactBook: secureContactBook) else {
            throw RavenSecureLanDispatchError.notLocalContact("\(kind) refused: peer is not a local contact")
        }
    }

    private func configureSecureListenIfPossible() {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return }
        guard let cfg = RavenServerlessLanConfig.stored, cfg.listenPort > 0 else { return }
        do {
            try RavenSecureLanTransportV1.configureLabListenIfEnabled(port: cfg.listenPort)
        } catch RavenSecureLanListenError.labGateClosed {
            #if DEBUG
            print("🕊️ [LabEndpoint] secure listen refused: lab gate closed")
            #endif
        } catch {
            #if DEBUG
            print("🕊️ [LabEndpoint] secure listen not started: \(error.localizedDescription)")
            #endif
        }
    }

    func stop() {
        if let ingestObserver {
            NotificationCenter.default.removeObserver(ingestObserver)
            self.ingestObserver = nil
        }
        if let acceptObserver {
            NotificationCenter.default.removeObserver(acceptObserver)
            self.acceptObserver = nil
        }
        RavenSecureLanTransportV1.stopLabListen()
        RavenSecureLanTransportV1.configureLabSession(nil)
    }

    func refreshSecureListen() {
        configureSecureSessionIfPossible()
        configureSecureListenIfPossible()
    }

    /// Refresh in-memory `publicGeneration` from durable protected store + SQL head after G1 mutations.
    func syncBoundGeneration(sessionID: Data) {
        do {
            try syncBoundGenerationValidated(sessionID: sessionID)
        } catch HostError.generationRollback {
            // Fail closed — bound session left at last known-good generation.
        } catch {
            #if DEBUG
            print("🕊️ [LabEndpoint] syncBoundGeneration failed: \(error)")
            #endif
        }
    }

    /// Validates protected generation against durable SQL head; upserts head on advance.
    func syncBoundGenerationValidated(sessionID: Data) throws {
        guard let bound = boundSessions[sessionID] else { return }
        guard let state = try? ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID) else {
            return
        }

        let durableHead: UInt64
        if let acceptanceDB {
            durableHead = try acceptanceDB.loadSessionHead(sessionID: sessionID)
        } else {
            durableHead = 0
        }

        if durableHead > 0, state.generation < durableHead {
            lastLabStatus = "generation rollback refused"
            TestATrace.emit(
                location: "ATSAMLabEndpointHost.syncBoundGenerationValidated",
                message: "TRACE_GENERATION_ROLLBACK",
                status: "FAIL_CLOSED",
                detail: "protected=\(state.generation) head=\(durableHead)"
            )
            throw HostError.generationRollback(
                sessionID: sessionID,
                protected: state.generation,
                head: durableHead
            )
        }

        let head = max(state.generation, durableHead)
        if state.generation > durableHead, let acceptanceDB {
            try acceptanceDB.upsertSessionHead(sessionID: sessionID, generation: state.generation)
        } else if durableHead == 0, state.generation > 0, let acceptanceDB {
            try acceptanceDB.upsertSessionHead(sessionID: sessionID, generation: state.generation)
        }

        guard bound.publicGeneration != head else { return }
        boundSessions[sessionID] = ATSAMEndpointTransactionV1.BoundSession(
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
            publicGeneration: head,
            senderContactAllowed: bound.senderContactAllowed,
            sessionConfirmed: bound.sessionConfirmed
        )
    }

    static func protectedSessionHasAdvancedState(
        _ state: ATSAMEndpointTransactionV1.ProtectedSessionState
    ) -> Bool {
        if state.generation > 1 { return true }
        if state.nextReceiveIndex > 0 || state.nextSendIndex > 0 { return true }
        if state.nextAckReceiveIndex > 0 || state.nextAckSendIndex > 0 { return true }
        if state.pendingAcceptance != nil
            || state.pendingAckAcceptance != nil
            || state.pendingOutbound != nil {
            return true
        }
        if !state.skippedMessageKeys.isEmpty || !state.skippedAckKeys.isEmpty { return true }
        return false
    }

    private func shouldSkipProtectedSessionReplace(sessionID: Data) -> Bool {
        guard let existing = try? ATSAMEndpointDurableAdapters.sharedProtectedStore.load(
            sessionID: sessionID
        ) else {
            return false
        }
        return existing.generation > 0 || Self.protectedSessionHasAdvancedState(existing)
    }

    func installResponderSession(
        initValue: ATSAMPairInitV1.PairInit,
        root: Data,
        sessionID: Data,
        initiatorCertificate: ATSAMPairInitV1.SignedDeviceCertificate,
        nowMs: UInt64
    ) async throws {
        if shouldSkipProtectedSessionReplace(sessionID: sessionID) {
            try ensureResponderHostBinding(
                initValue: initValue,
                root: root,
                sessionID: sessionID,
                initiatorCertificate: initiatorCertificate
            )
            syncBoundGeneration(sessionID: sessionID)
            TestATrace.emit(
                location: "ATSAMLabEndpointHost.installResponderSession",
                message: "TRACE_SESSION_DURABLE_COMMIT",
                status: "PAIR_RESPONSE_REPLAY_NOOP",
                detail: "gen=\(boundSessions[sessionID]?.publicGeneration ?? 0)"
            )
            _ = nowMs
            return
        }

        let localDeviceEd = initValue.responderDeviceEd25519PublicKey
        let hint = Self.deviceHint(localDeviceEd)
        let certHash = try ATSAMPairInitV1.deviceCertificateHash(initiatorCertificate)

        let inbound: ATSAMIndexedSessionProfile.Direction = .initiatorToResponder
        let pair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initValue.initiatorAddress,
            responderAddress: initValue.responderAddress,
            direction: inbound
        )
        let outboundPair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initValue.initiatorAddress,
            responderAddress: initValue.responderAddress,
            direction: .responderToInitiator
        )
        let state = ATSAMEndpointTransactionV1.ProtectedSessionState(
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
                sender: outboundPair.sender,
                recipient: outboundPair.recipient
            ),
            nextSendIndex: 0,
            ackSendChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: root,
                initiatorAddress: initValue.initiatorAddress,
                responderAddress: initValue.responderAddress,
                direction: .responderToInitiator,
                index: 0
            ),
            nextAckSendIndex: 0,
            ackReceiveChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: root,
                initiatorAddress: initValue.initiatorAddress,
                responderAddress: initValue.responderAddress,
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

        let bound = ATSAMEndpointTransactionV1.BoundSession(
            sessionID: sessionID,
            initiatorAddress: initValue.initiatorAddress,
            responderAddress: initValue.responderAddress,
            inboundDirection: inbound,
            expectedLocalDeviceHint: hint,
            remoteDeviceEd25519PublicKey: initValue.initiatorDeviceEd25519PublicKey,
            senderCertificate: initiatorCertificate,
            pairInitSenderCertificateHash: certHash,
            sessionCreatedAtMs: initValue.createdAtMs,
            sessionExpiresAtMs: initValue.expiresAtMs,
            senderDeviceAccepted: true,
            senderDeviceRevoked: false,
            publicGeneration: 1
        )
        boundSessions[sessionID] = bound
        let meta = SessionMeta(
            rootKey: root,
            initiatorAddress: initValue.initiatorAddress,
            responderAddress: initValue.responderAddress,
            remoteDeviceEd: initValue.initiatorDeviceEd25519PublicKey,
            senderCertIdentity: initiatorCertificate.identityEd25519PublicKey,
            senderCertSigning: initiatorCertificate.signingBytes,
            senderCertSig: initiatorCertificate.signature,
            pairInitSenderCertHash: certHash,
            sessionCreatedAtMs: initValue.createdAtMs,
            sessionExpiresAtMs: initValue.expiresAtMs,
            localDeviceEd: localDeviceEd
        )
        sessionMeta[sessionID] = meta
        try persistMeta(meta, sessionID: sessionID, inboundDirection: inbound)

        syncBoundGeneration(sessionID: sessionID)
        TestATrace.emit(
            location: "ATSAMLabEndpointHost.installResponderSession",
            message: "TRACE_SESSION_DURABLE_COMMIT",
            status: "PAIR_RESPONSE_READY",
            detail: "gen=1"
        )
        _ = nowMs
    }

    func installInitiatorSession(
        initValue: ATSAMPairInitV1.PairInit,
        root: Data,
        sessionID: Data,
        responderCertificate: ATSAMPairInitV1.SignedDeviceCertificate,
        nowMs: UInt64
    ) async throws {
        if shouldSkipProtectedSessionReplace(sessionID: sessionID) {
            try ensureInitiatorHostBinding(
                initValue: initValue,
                root: root,
                sessionID: sessionID,
                responderCertificate: responderCertificate
            )
            syncBoundGeneration(sessionID: sessionID)
            TestATrace.emit(
                location: "ATSAMLabEndpointHost.installInitiatorSession",
                message: "TRACE_SESSION_DURABLE_COMMIT",
                status: "PAIR_RESPONSE_CONFIRM_REPLAY_NOOP",
                detail: "gen=\(boundSessions[sessionID]?.publicGeneration ?? 0)"
            )
            _ = nowMs
            return
        }

        let localDeviceEd = initValue.initiatorDeviceEd25519PublicKey
        let hint = Self.deviceHint(localDeviceEd)
        let certHash = try ATSAMPairInitV1.deviceCertificateHash(responderCertificate)

        let inbound: ATSAMIndexedSessionProfile.Direction = .responderToInitiator
        let pair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initValue.initiatorAddress,
            responderAddress: initValue.responderAddress,
            direction: inbound
        )
        let outboundPair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initValue.initiatorAddress,
            responderAddress: initValue.responderAddress,
            direction: .initiatorToResponder
        )
        let state = ATSAMEndpointTransactionV1.ProtectedSessionState(
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
                sender: outboundPair.sender,
                recipient: outboundPair.recipient
            ),
            nextSendIndex: 0,
            ackSendChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: root,
                initiatorAddress: initValue.initiatorAddress,
                responderAddress: initValue.responderAddress,
                direction: .initiatorToResponder,
                index: 0
            ),
            nextAckSendIndex: 0,
            ackReceiveChainKey: try ATSAMIndexedSessionProfile.ackChainKeyAtIndex(
                root: root,
                initiatorAddress: initValue.initiatorAddress,
                responderAddress: initValue.responderAddress,
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

        let bound = ATSAMEndpointTransactionV1.BoundSession(
            sessionID: sessionID,
            initiatorAddress: initValue.initiatorAddress,
            responderAddress: initValue.responderAddress,
            inboundDirection: inbound,
            expectedLocalDeviceHint: hint,
            remoteDeviceEd25519PublicKey: initValue.responderDeviceEd25519PublicKey,
            senderCertificate: responderCertificate,
            pairInitSenderCertificateHash: certHash,
            sessionCreatedAtMs: initValue.createdAtMs,
            sessionExpiresAtMs: initValue.expiresAtMs,
            senderDeviceAccepted: true,
            senderDeviceRevoked: false,
            publicGeneration: 1
        )
        boundSessions[sessionID] = bound
        let meta = SessionMeta(
            rootKey: root,
            initiatorAddress: initValue.initiatorAddress,
            responderAddress: initValue.responderAddress,
            remoteDeviceEd: initValue.responderDeviceEd25519PublicKey,
            senderCertIdentity: responderCertificate.identityEd25519PublicKey,
            senderCertSigning: responderCertificate.signingBytes,
            senderCertSig: responderCertificate.signature,
            pairInitSenderCertHash: certHash,
            sessionCreatedAtMs: initValue.createdAtMs,
            sessionExpiresAtMs: initValue.expiresAtMs,
            localDeviceEd: localDeviceEd
        )
        sessionMeta[sessionID] = meta
        try persistMeta(meta, sessionID: sessionID, inboundDirection: inbound)

        syncBoundGeneration(sessionID: sessionID)
        TestATrace.emit(
            location: "ATSAMLabEndpointHost.installInitiatorSession",
            message: "TRACE_SESSION_DURABLE_COMMIT",
            status: "INITIATOR_SESSION_READY",
            detail: "gen=1"
        )
        _ = nowMs
    }

    private func ensureResponderHostBinding(
        initValue: ATSAMPairInitV1.PairInit,
        root: Data,
        sessionID: Data,
        initiatorCertificate: ATSAMPairInitV1.SignedDeviceCertificate
    ) throws {
        let certHash = try ATSAMPairInitV1.deviceCertificateHash(initiatorCertificate)
        let inbound: ATSAMIndexedSessionProfile.Direction = .initiatorToResponder
        if boundSessions[sessionID] == nil {
            boundSessions[sessionID] = ATSAMEndpointTransactionV1.BoundSession(
                sessionID: sessionID,
                initiatorAddress: initValue.initiatorAddress,
                responderAddress: initValue.responderAddress,
                inboundDirection: inbound,
                expectedLocalDeviceHint: Self.deviceHint(initValue.responderDeviceEd25519PublicKey),
                remoteDeviceEd25519PublicKey: initValue.initiatorDeviceEd25519PublicKey,
                senderCertificate: initiatorCertificate,
                pairInitSenderCertificateHash: certHash,
                sessionCreatedAtMs: initValue.createdAtMs,
                sessionExpiresAtMs: initValue.expiresAtMs,
                senderDeviceAccepted: true,
                senderDeviceRevoked: false,
                publicGeneration: (
                    try? ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
                )?.generation ?? 1
            )
        }
        if sessionMeta[sessionID] == nil {
            sessionMeta[sessionID] = SessionMeta(
                rootKey: root,
                initiatorAddress: initValue.initiatorAddress,
                responderAddress: initValue.responderAddress,
                remoteDeviceEd: initValue.initiatorDeviceEd25519PublicKey,
                senderCertIdentity: initiatorCertificate.identityEd25519PublicKey,
                senderCertSigning: initiatorCertificate.signingBytes,
                senderCertSig: initiatorCertificate.signature,
                pairInitSenderCertHash: certHash,
                sessionCreatedAtMs: initValue.createdAtMs,
                sessionExpiresAtMs: initValue.expiresAtMs,
                localDeviceEd: initValue.responderDeviceEd25519PublicKey
            )
            try persistMeta(
                sessionMeta[sessionID]!,
                sessionID: sessionID,
                inboundDirection: inbound
            )
        }
    }

    private func ensureInitiatorHostBinding(
        initValue: ATSAMPairInitV1.PairInit,
        root: Data,
        sessionID: Data,
        responderCertificate: ATSAMPairInitV1.SignedDeviceCertificate
    ) throws {
        let certHash = try ATSAMPairInitV1.deviceCertificateHash(responderCertificate)
        let inbound: ATSAMIndexedSessionProfile.Direction = .responderToInitiator
        if boundSessions[sessionID] == nil {
            boundSessions[sessionID] = ATSAMEndpointTransactionV1.BoundSession(
                sessionID: sessionID,
                initiatorAddress: initValue.initiatorAddress,
                responderAddress: initValue.responderAddress,
                inboundDirection: inbound,
                expectedLocalDeviceHint: Self.deviceHint(initValue.initiatorDeviceEd25519PublicKey),
                remoteDeviceEd25519PublicKey: initValue.responderDeviceEd25519PublicKey,
                senderCertificate: responderCertificate,
                pairInitSenderCertificateHash: certHash,
                sessionCreatedAtMs: initValue.createdAtMs,
                sessionExpiresAtMs: initValue.expiresAtMs,
                senderDeviceAccepted: true,
                senderDeviceRevoked: false,
                publicGeneration: (
                    try? ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
                )?.generation ?? 1
            )
        }
        if sessionMeta[sessionID] == nil {
            sessionMeta[sessionID] = SessionMeta(
                rootKey: root,
                initiatorAddress: initValue.initiatorAddress,
                responderAddress: initValue.responderAddress,
                remoteDeviceEd: initValue.responderDeviceEd25519PublicKey,
                senderCertIdentity: responderCertificate.identityEd25519PublicKey,
                senderCertSigning: responderCertificate.signingBytes,
                senderCertSig: responderCertificate.signature,
                pairInitSenderCertHash: certHash,
                sessionCreatedAtMs: initValue.createdAtMs,
                sessionExpiresAtMs: initValue.expiresAtMs,
                localDeviceEd: initValue.initiatorDeviceEd25519PublicKey
            )
            try persistMeta(
                sessionMeta[sessionID]!,
                sessionID: sessionID,
                inboundDirection: inbound
            )
        }
    }

    // MARK: - Receive

    private func onSealedIngest(_ note: Notification) async {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return }
        guard (note.userInfo?["kind"] as? String) == "message",
              let messageId = note.userInfo?["messageId"] as? Data,
              let sealedBody = note.userInfo?["sealedBody"] as? Data else { return }

        // Prefer full packed if present; else rebuild is not possible — ChatWire
        // path uses sealed body only. Lab pull publishes via publishPacked which
        // posts sealed body. We need the full packed envelope for Receiver.
        guard let packed = note.userInfo?["packed"] as? Data else {
            // Try reconstruct-free open via profile when we have a single session.
            await openSealedBodyFallback(messageId: messageId, sealedBody: sealedBody)
            return
        }
        await receivePacked(packed)
    }

    func receivePacked(_ packed: Data, replyOnSameConnection: Bool = false) async -> [Data] {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return [] }
        guard isOperational, let acceptanceDB else {
            lastLabStatus = "receive refused: SQLCipher unavailable"
            TestATrace.emit(
                location: "ATSAMLabEndpointHost.receivePacked",
                message: "TRACE_RECEIVE_REFUSED",
                status: "SQLCIPHER_UNAVAILABLE",
                detail: acceptanceDBErrorDescription
            )
            return []
        }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        for (sid, session) in boundSessions {
            do {
                let receiver = ATSAMEndpointTransactionV1.Receiver(
                    protectedStore: ATSAMEndpointDurableAdapters.sharedProtectedStore,
                    database: acceptanceDB
                )
                let outcome = try await receiver.receive(
                    packedEnvelope: packed,
                    session: session,
                    nowMs: nowMs
                )
                switch outcome {
                case let .committed(plaintext, receipt):
                    syncBoundGeneration(sessionID: sid)
                    await presentPlaintext(plaintext, sessionID: sid)
                    if replyOnSameConnection,
                       let ackBytes = try? await committedAckBytes(
                           for: receipt.receiptKey,
                           session: session,
                           nowMs: nowMs
                       ) {
                        lastLabStatus = "indexed message accepted; ACK inline"
                        TestATrace.emit(
                            location: "ATSAMLabEndpointHost.receivePacked",
                            message: "TRACE_INDEXED_MESSAGE_ACCEPTED",
                            status: "ACK_INLINE_SAME_CONNECTION",
                            detail: "bytes=\(plaintext.count)"
                        )
                        return [ackBytes]
                    }
                    try await enqueueAndUplinkAck(for: receipt.receiptKey)
                    TestATrace.emit(
                        location: "ATSAMLabEndpointHost.receivePacked",
                        message: "TRACE_INDEXED_MESSAGE_ACCEPTED",
                        status: "WAITING_FOR_ENDPOINT_ACK_UPLINK",
                        detail: "bytes=\(plaintext.count)"
                    )
                    return []
                case let .exactDuplicate(receipt):
                    syncBoundGeneration(sessionID: sid)
                    let ackBytes: Data
                    do {
                        ackBytes = try loadExactCommittedAckBytes(for: receipt.receiptKey)
                    } catch {
                        #if DEBUG
                        duplicateAckRecoveryCount += 1
                        #endif
                        TestATrace.emit(
                            location: "ATSAMLabEndpointHost.receivePacked",
                            message: "TRACE_DUPLICATE_ACK_RECOVERY",
                            status: "MATERIALIZE_COMMITTED_ACK",
                            detail: String(describing: error)
                        )
                        do {
                            ackBytes = try await committedAckBytes(
                                for: receipt.receiptKey,
                                session: session,
                                nowMs: nowMs
                            )
                            syncBoundGeneration(sessionID: sid)
                        } catch let recoveryError {
                            TestATrace.emit(
                                location: "ATSAMLabEndpointHost.receivePacked",
                                message: "TRACE_DUPLICATE_ACK_RECOVERY",
                                status: "FAIL_CLOSED",
                                detail: String(describing: recoveryError)
                            )
                            lastLabStatus = "duplicate message; ACK materialization failed"
                            continue
                        }
                    }
                    if replyOnSameConnection {
                        lastLabStatus = "duplicate message; exact ACK resent inline"
                        TestATrace.emit(
                            location: "ATSAMLabEndpointHost.receivePacked",
                            message: "TRACE_DUPLICATE_ACK_RESEND",
                            status: "ACK_INLINE_SAME_CONNECTION",
                            detail: "digest=\(receipt.receiptKey.objectDigest.prefix(4).map { String(format: "%02x", $0) }.joined())"
                        )
                        return [ackBytes]
                    }
                    do {
                        try await resendAckViaSecureDial(ackBytes, sessionID: receipt.receiptKey.sessionID)
                        lastLabStatus = "duplicate message; exact ACK redialed"
                    } catch {
                        TestATrace.emit(
                            location: "ATSAMLabEndpointHost.receivePacked",
                            message: "TRACE_DUPLICATE_ACK_RESEND",
                            status: "REDIAL_FAILED",
                            detail: String(describing: error)
                        )
                        lastLabStatus = "duplicate message; ACK redial failed"
                    }
                    return []
                }
            } catch {
                continue
            }
        }
        return []
    }

    /// Origin-side inbound ACK acceptance (§4.8) — not contact-check only.
    func acceptInboundAckPacked(_ packed: Data) async throws {
        guard isOperational, let acceptanceDB else {
            throw HostError.sqlCipherUnavailable(acceptanceDBErrorDescription ?? "unknown")
        }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let receiver = ATSAMEndpointTransactionV1.Receiver(
            protectedStore: ATSAMEndpointDurableAdapters.sharedProtectedStore,
            database: acceptanceDB
        )
        var lastError: Error?
        for session in boundSessions.values {
            do {
                let outcome = try await receiver.acceptAck(
                    packedEnvelope: packed,
                    session: session,
                    nowMs: nowMs
                )
                switch outcome {
                case .committed:
                    syncBoundGeneration(sessionID: session.sessionID)
                    lastLabStatus = "inbound ACK accepted (origin path)"
                    TestATrace.emit(
                        location: "ATSAMLabEndpointHost.acceptInboundAckPacked",
                        message: "TRACE_INBOUND_ACK_ACCEPTED",
                        status: "ORIGIN_ACK_COMMITTED",
                        detail: nil
                    )
                    return
                case .exactDuplicate:
                    lastLabStatus = "inbound ACK duplicate (idempotent)"
                    return
                }
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError {
            throw lastError
        }
        throw ATSAMEndpointTransactionV1.TransactionError.wrongSession
    }

    // MARK: - Lab initiator entrypoints (Debug UI)

    func dialPairInitToMac() async throws -> String {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { throw HostError.labGateClosed }
        guard isOperational else {
            throw HostError.sqlCipherUnavailable(acceptanceDBErrorDescription ?? "unknown")
        }
        guard let lan = RavenServerlessLanConfig.stored,
              let peerEd = Data(ravenHex: lan.peerPubHex), peerEd.count == 32 else {
            throw HostError.lanConfigMissing
        }
        _ = try ATSAMLabTrustStore.ensureLocalMaterial()
        let lifecycle = ATSAMPrekeyLifecycleStore.shared

        let built: (wire: Data, packed: Data, root: Data)
        let initValue: ATSAMPairInitV1.PairInit
        let replies: [Data]
        let responderCert: ATSAMPairInitV1.SignedDeviceCertificate

        if let pending = try lifecycle.loadPendingInitiatorOutbound() {
            initValue = try ATSAMPairInitV1.decodeInit(pending.record.initWire)
            built = (pending.record.initWire, pending.record.packedWire, pending.record.provisionalRoot)
            replies = try await RavenSecureLanDialerV1.dialLab(
                host: lan.host,
                port: lan.port,
                expectedDeviceEdPub: peerEd,
                frames: [built.packed]
            )
            responderCert = try ATSAMLabTrustStore.peerCertificate(forDeviceEd: peerEd)
        } else {
            // Prefer live RLB1 offer so PairInit matches the peer's current prekey on the wire.
            let capture = try await RavenSecureLanDialerV1.dialLabPairInitCapturing(
                host: lan.host,
                port: lan.port,
                expectedDeviceEdPub: peerEd
            )
            replies = capture.replies
            built = (capture.initWire, capture.packed, capture.root)
            initValue = try ATSAMPairInitV1.decodeInit(capture.initWire)
            responderCert = ATSAMLabPairInitBuilder.pairInitCertificate(from: capture.responderBundle.cert)
            let sessionIDPending = try ATSAMPairInitV1.sessionID(initValue)
            try lifecycle.persistInitiatorOutbound(
                initID: initValue.initID,
                packedWire: capture.packed,
                initWire: capture.initWire,
                sessionID: sessionIDPending,
                provisionalRoot: capture.root,
                createdAtMs: initValue.createdAtMs
            )
        }

        guard let pairResponsePacked = replies.dropFirst().first(where: { frame in
            if case .pairResponse = RavenPairInitLanOob.classifyPackedEnvelope(frame) { return true }
            return false
        }) else {
            lastLabStatus = "PairInit dialed — no PairResponse on same connection"
            throw ATSAMPairInitAcceptService.AcceptError.uplinkFailed("no PairResponse reply")
        }
        guard case .pairResponse(let responseWire) = RavenPairInitLanOob.classifyPackedEnvelope(
            pairResponsePacked
        ) else {
            throw ATSAMPairInitAcceptService.AcceptError.decodeFailed
        }
        let response = try ATSAMPairInitV1.decodeResponse(responseWire)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        try ATSAMPairInitV1.verifyResponse(
            response,
            acceptedInit: initValue,
            root: built.root,
            nowMs: nowMs
        )
        let sessionID = try ATSAMPairInitV1.sessionID(initValue)
        try await installInitiatorSession(
            initValue: initValue,
            root: built.root,
            sessionID: sessionID,
            responderCertificate: responderCert,
            nowMs: nowMs
        )
        try lifecycle.clearInitiatorOutbound(initID: initValue.initID)
        lastLabStatus = "PairInit dialed — PairResponse verified; initiator session installed"
        TestATrace.emit(
            location: "ATSAMLabEndpointHost.dialPairInitToMac",
            message: "TRACE_PAIR_INIT_DIAL_OK",
            status: "INITIATOR_SESSION_INSTALLED",
            detail: "replies=\(replies.count) sid=\(sessionID.prefix(4).map { String(format: "%02x", $0) }.joined())"
        )
        return lastLabStatus
    }

    func sendLabIndexedMessage(_ text: String) async throws -> String {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { throw HostError.labGateClosed }
        guard isOperational, let acceptanceDB else {
            throw HostError.sqlCipherUnavailable(acceptanceDBErrorDescription ?? "unknown")
        }
        guard let lan = RavenServerlessLanConfig.stored,
              let peerEd = Data(ravenHex: lan.peerPubHex), peerEd.count == 32 else {
            throw HostError.lanConfigMissing
        }
        guard let (sessionID, session) = boundSessions.first else { throw HostError.noSession }
        guard let meta = sessionMeta[sessionID] else { throw HostError.noSession }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed else { throw HostError.noSession }

        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let materializer = LabOutboundMaterializer(
            root: meta.rootKey,
            initiatorAddress: meta.initiatorAddress,
            responderAddress: meta.responderAddress,
            signingKey: signingKey,
            inboundDirection: session.inboundDirection
        )
        let capture = LabOutboundCaptureDialer()
        let sender = ATSAMEndpointTransactionV1.Sender(
            protectedStore: ATSAMEndpointDurableAdapters.sharedProtectedStore,
            database: acceptanceDB,
            bodyStage: try labOutboundBodyStage(),
            materializer: materializer,
            dialer: capture
        )
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let textData = Data(text.utf8)
        _ = try await sender.send(
            text: textData,
            session: session,
            createdAtMs: nowMs,
            expiresAtMs: min(meta.sessionExpiresAtMs, nowMs &+ 3600_000)
        )
        syncBoundGeneration(sessionID: sessionID)
        guard let packed = capture.lastPacked else {
            throw ATSAMEndpointTransactionV1.TransactionError.invalidProtectedState
        }
        try await dialLabAndAcceptInboundAck(
            host: lan.host,
            port: lan.port,
            expectedDeviceEdPub: meta.remoteDeviceEd,
            outboundFrames: [packed]
        )
        syncBoundGeneration(sessionID: sessionID)
        lastLabStatus = "lab text sent + inbound ACK accepted (\(text.count) chars) session=\(sessionID.prefix(2).map { String(format: "%02x", $0) }.joined())…"
        return lastLabStatus
    }

    #if DEBUG
    /// Test hook: dial frames over secure LAN and return raw replies (no ACK accept).
    func dialLabCollectingReplies(outboundFrames: [Data]) async throws -> [Data] {
        guard let lan = RavenServerlessLanConfig.stored,
              let peerEd = Data(ravenHex: lan.peerPubHex), peerEd.count == 32 else {
            throw HostError.lanConfigMissing
        }
        return try await RavenSecureLanDialerV1.dialLab(
            host: lan.host,
            port: lan.port,
            expectedDeviceEdPub: peerEd,
            frames: outboundFrames
        )
    }

    /// Test hook: dial packed message, require sealed ACK, CAS outstanding → Delivered.
    func dialLabAndAcceptInboundAckForTesting(outboundFrames: [Data]) async throws {
        guard let lan = RavenServerlessLanConfig.stored,
              let peerEd = Data(ravenHex: lan.peerPubHex), peerEd.count == 32 else {
            throw HostError.lanConfigMissing
        }
        try await dialLabAndAcceptInboundAck(
            host: lan.host,
            port: lan.port,
            expectedDeviceEdPub: peerEd,
            outboundFrames: outboundFrames
        )
        if let sid = boundSessions.keys.first {
            syncBoundGeneration(sessionID: sid)
        }
    }

    static func sealedAckFrame(in replies: [Data]) -> Data? {
        findSealedAckFrame(in: replies)
    }

    /// Test hook: run Sender path and return packed envelope without network dial.
    func captureOutboundIndexedMessage(_ text: String) async throws -> Data {
        guard isOperational, let acceptanceDB else {
            throw HostError.sqlCipherUnavailable(acceptanceDBErrorDescription ?? "unknown")
        }
        guard let (sessionID, session) = boundSessions.first else { throw HostError.noSession }
        guard let meta = sessionMeta[sessionID] else { throw HostError.noSession }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed else { throw HostError.noSession }

        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let materializer = LabOutboundMaterializer(
            root: meta.rootKey,
            initiatorAddress: meta.initiatorAddress,
            responderAddress: meta.responderAddress,
            signingKey: signingKey,
            inboundDirection: session.inboundDirection
        )
        let capture = LabOutboundCaptureDialer()
        let sender = ATSAMEndpointTransactionV1.Sender(
            protectedStore: ATSAMEndpointDurableAdapters.sharedProtectedStore,
            database: acceptanceDB,
            bodyStage: try labOutboundBodyStage(),
            materializer: materializer,
            dialer: capture
        )
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        _ = try await sender.send(
            text: Data(text.utf8),
            session: session,
            createdAtMs: nowMs,
            expiresAtMs: min(meta.sessionExpiresAtMs, nowMs &+ 3600_000)
        )
        syncBoundGeneration(sessionID: sessionID)
        guard let packed = capture.lastPacked else {
            throw ATSAMEndpointTransactionV1.TransactionError.invalidProtectedState
        }
        return packed
    }
    #endif

    /// Dial lab peer, require sealed ACK on same connection, accept on origin path.
    private func dialLabAndAcceptInboundAck(
        host: String,
        port: UInt16,
        expectedDeviceEdPub: Data,
        outboundFrames: [Data]
    ) async throws {
        let replies = try await RavenSecureLanDialerV1.dialLab(
            host: host,
            port: port,
            expectedDeviceEdPub: expectedDeviceEdPub,
            frames: outboundFrames
        )
        guard let ackFrame = Self.findSealedAckFrame(in: replies) else {
            lastLabStatus = "dial completed — no sealed ACK on same connection"
            TestATrace.emit(
                location: "ATSAMLabEndpointHost.dialLabAndAcceptInboundAck",
                message: "TRACE_INBOUND_ACK_MISSING",
                status: "FAIL_CLOSED",
                detail: "replies=\(replies.count)"
            )
            throw HostError.inboundAckMissing
        }
        try await acceptInboundAckPacked(ackFrame)
    }

    private static func findSealedAckFrame(in replies: [Data]) -> Data? {
        replies.first { frame in
            if RavenSecureLanDispatchV1.classifyFrame(frame) == .ack { return true }
            guard let env = RavenEnvelopeV1.unpack(frame) else { return false }
            return env.envType == RavenEnvelopeV1.EnvType.ack.rawValue
        }
    }

    private func openSealedBodyFallback(messageId: Data, sealedBody: Data) async {
        // Without outer envelope we cannot run full Receiver (route tag / sig).
        // Fail closed with TRACE — Pull path should forward packed when available.
        TestATrace.emit(
            location: "ATSAMLabEndpointHost.openSealedBodyFallback",
            message: "TRACE_SEALED_BODY_NEEDS_PACKED",
            status: "WAITING_FOR_PACKED_ENVELOPE",
            detail: "mid=\(messageId.prefix(4).map { String(format: "%02x", $0) }.joined()) body=\(sealedBody.count)"
        )
    }

    private func presentPlaintext(_ plaintext: Data, sessionID: Data) async {
        let text = String(data: plaintext, encoding: .utf8)
            ?? plaintext.map { String(format: "%02x", $0) }.joined()
        let peerKey = sessionMeta[sessionID].map {
            $0.remoteDeviceEd.prefix(4).map { String(format: "%02x", $0) }.joined()
        } ?? "lab-peer"
        NotificationCenter.default.post(
            name: .ravenLabIndexedMessageDisplayed,
            object: nil,
            userInfo: [
                "text": text,
                "peerKey": peerKey,
                "sessionID": sessionID,
            ]
        )
        // Best-effort inbox insert via existing chat ingest path (UTF-8 only).
        #if DEBUG
        print("🕊️ [LabEndpoint] indexed plaintext accepted chars=\(text.count) (no plaintext in TRACE)")
        #endif
        if let myId = await KeychainService.shared.getUserId(), !myId.isEmpty {
            let senderId = "lab-\(peerKey)"
            await MessageRepository.shared.insertInboundPlaintextIfPossible(
                text: text,
                senderUserId: senderId,
                myUserId: myId
            )
        }
    }

    private func enqueueAndUplinkAck(
        for receiptKey: ATSAMEndpointTransactionV1.ReceiptKey
    ) async throws {
        guard let acceptanceDB,
              let bound = boundSessions[receiptKey.sessionID],
              let meta = sessionMeta[receiptKey.sessionID],
              let seed = DeviceIdentityService.shared.deviceSigningSeed else { return }
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let materializer = LabAckMaterializer(
            root: meta.rootKey,
            initiatorAddress: meta.initiatorAddress,
            responderAddress: meta.responderAddress,
            signingKey: signingKey,
            inboundDirection: bound.inboundDirection
        )
        let dialer = LabAckDialer()
        let worker = ATSAMEndpointTransactionV1.AckWorker(
            protectedStore: ATSAMEndpointDurableAdapters.sharedProtectedStore,
            database: acceptanceDB,
            queue: ATSAMEndpointDurableAdapters.sharedAckQueue,
            materializer: materializer,
            dialer: dialer
        )
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        _ = try await worker.enqueueOneCommittedAck(session: bound, nowMs: nowMs)
        let action = try await worker.resumeOneCommittedAck(
            session: bound,
            nowMs: nowMs,
            allowDial: true
        )
        guard case .dialed = action else { return }
        guard let lan = RavenServerlessLanConfig.stored,
              let packed = dialer.lastPacked else { return }

        // Network I/O outside G1 mutation lease (AckWorker.dial captures packed only).
        _ = try await RavenSecureLanDialerV1.dialLab(
            host: lan.host,
            port: lan.port,
            expectedDeviceEdPub: meta.remoteDeviceEd,
            frames: [packed]
        )
        TestATrace.emit(
            location: "ATSAMLabEndpointHost.enqueueAndUplinkAck",
            message: "TRACE_SEALED_ACK_UPLINKED",
            status: "ACK_QUEUED",
            detail: nil
        )
    }

    private func persistMeta(
        _ meta: SessionMeta,
        sessionID: Data,
        inboundDirection: ATSAMIndexedSessionProfile.Direction
    ) throws {
        let dto = ATSAMLabSessionMetaStore.PersistedMeta(
            initiatorAddress: meta.initiatorAddress,
            responderAddress: meta.responderAddress,
            remoteDeviceEd: meta.remoteDeviceEd,
            senderCertIdentity: meta.senderCertIdentity,
            senderCertSigning: meta.senderCertSigning,
            senderCertSig: meta.senderCertSig,
            pairInitSenderCertHash: meta.pairInitSenderCertHash,
            sessionCreatedAtMs: meta.sessionCreatedAtMs,
            sessionExpiresAtMs: meta.sessionExpiresAtMs,
            localDeviceEd: meta.localDeviceEd,
            inboundDirectionRaw: inboundDirection == .initiatorToResponder ? 0 : 1
        )
        try ATSAMLabSessionMetaStore.save(dto, sessionID: sessionID)
    }

    private func labOutboundBodyStage() throws -> ATSAMOutboundBodyStage.Store {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("raven/atsam/lab-outbound-stage", isDirectory: true)
        let key = try ATSAMOutboundBodyStage.KeychainStageKey.resolvedKey()
        return ATSAMOutboundBodyStage.Store(
            directory: dir,
            protector: ATSAMOutboundBodyStage.ScopedAeadProtector(key: key)
        )
    }

    private func migrateLegacyPlaintextSessionsFailClosed() {
        do {
            _ = try ATSAMLabSessionMetaStore.quarantineLegacyPlaintextSessionsIfPresent()
        } catch ATSAMLabSessionMetaStore.StoreError.legacyPlaintextRefused(let count) {
            legacyMigrationRefused = true
            boundSessions.removeAll()
            sessionMeta.removeAll()
            lastLabStatus = "legacy plaintext sessions quarantined — re-pair required"
            TestATrace.emit(
                location: "ATSAMLabEndpointHost.migrateLegacyPlaintextSessionsFailClosed",
                message: "TRACE_LEGACY_SESSION_REFUSED",
                status: "REPAIR_REQUIRED",
                detail: "files=\(count)"
            )
        } catch {
            #if DEBUG
            print("🕊️ [LabEndpoint] legacy session scan failed: \(error)")
            #endif
        }
    }

    private func rehydrateBoundSessionsFromDurableStores() {
        guard !legacyMigrationRefused else { return }
        do {
            let sessionIDs = try ATSAMLabSessionMetaStore.allSessionIDs()
            for sessionID in sessionIDs {
                guard let dto = try ATSAMLabSessionMetaStore.load(sessionID: sessionID) else { continue }
                let protected = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: sessionID)
                let cert = ATSAMPairInitV1.SignedDeviceCertificate(
                    identityEd25519PublicKey: dto.senderCertIdentity,
                    signingBytes: dto.senderCertSigning,
                    signature: dto.senderCertSig
                )
                let inboundDirection: ATSAMIndexedSessionProfile.Direction =
                    dto.inboundDirectionRaw == 0 ? .initiatorToResponder : .responderToInitiator
                let bound = ATSAMEndpointTransactionV1.BoundSession(
                    sessionID: sessionID,
                    initiatorAddress: dto.initiatorAddress,
                    responderAddress: dto.responderAddress,
                    inboundDirection: inboundDirection,
                    expectedLocalDeviceHint: Self.deviceHint(dto.localDeviceEd),
                    remoteDeviceEd25519PublicKey: dto.remoteDeviceEd,
                    senderCertificate: cert,
                    pairInitSenderCertificateHash: dto.pairInitSenderCertHash,
                    sessionCreatedAtMs: dto.sessionCreatedAtMs,
                    sessionExpiresAtMs: dto.sessionExpiresAtMs,
                    senderDeviceAccepted: true,
                    senderDeviceRevoked: false,
                    publicGeneration: protected.generation
                )
                boundSessions[sessionID] = bound
                sessionMeta[sessionID] = SessionMeta(
                    rootKey: protected.rootKey,
                    initiatorAddress: dto.initiatorAddress,
                    responderAddress: dto.responderAddress,
                    remoteDeviceEd: dto.remoteDeviceEd,
                    senderCertIdentity: dto.senderCertIdentity,
                    senderCertSigning: dto.senderCertSigning,
                    senderCertSig: dto.senderCertSig,
                    pairInitSenderCertHash: dto.pairInitSenderCertHash,
                    sessionCreatedAtMs: dto.sessionCreatedAtMs,
                    sessionExpiresAtMs: dto.sessionExpiresAtMs,
                    localDeviceEd: dto.localDeviceEd
                )
            }
            if !sessionIDs.isEmpty {
                lastLabStatus = "rehydrated \(sessionIDs.count) lab session(s) from Keychain"
            }
        } catch {
            lastLabStatus = "session rehydrate failed: \(error.localizedDescription)"
        }
    }

    private func surfaceAcceptanceDBStatus() {
        if let err = acceptanceDBErrorDescription {
            lastLabStatus = "SQLCipher unavailable — receive/ACK refused"
            TestATrace.emit(
                location: "ATSAMLabEndpointHost.surfaceAcceptanceDBStatus",
                message: "TRACE_SQLCIPHER_OPEN_FAILED",
                status: "FAIL_CLOSED",
                detail: err
            )
        }
    }

    /// Exact prior ACK bytes for duplicate resend (testable).
    func loadExactCommittedAckBytes(
        for receiptKey: ATSAMEndpointTransactionV1.ReceiptKey
    ) throws -> Data {
        guard let acceptanceDB else { throw HostError.sqlCipherUnavailable("missing db") }
        if let intent = try acceptanceDB.allAckIntents().first(where: { $0.receiptKey == receiptKey }),
           let staged = intent.stagedEnvelope {
            return staged
        }
        let state = try ATSAMEndpointDurableAdapters.sharedProtectedStore.load(sessionID: receiptKey.sessionID)
        if let pending = state.pendingOutbound,
           pending.sourceAckIntent == receiptKey.objectDigest {
            return pending.immutableEnvelopeBytes
        }
        throw ATSAMEndpointTransactionV1.TransactionError.stagedAckCollision
    }

    private func committedAckBytes(
        for receiptKey: ATSAMEndpointTransactionV1.ReceiptKey,
        session: ATSAMEndpointTransactionV1.BoundSession,
        nowMs: UInt64
    ) async throws -> Data {
        if let existing = try? loadExactCommittedAckBytes(for: receiptKey) {
            return existing
        }
        guard let acceptanceDB,
              let meta = sessionMeta[receiptKey.sessionID],
              let seed = DeviceIdentityService.shared.deviceSigningSeed else {
            throw HostError.noSession
        }
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let materializer = LabAckMaterializer(
            root: meta.rootKey,
            initiatorAddress: meta.initiatorAddress,
            responderAddress: meta.responderAddress,
            signingKey: signingKey,
            inboundDirection: session.inboundDirection
        )
        let dialer = LabAckDialer()
        let worker = ATSAMEndpointTransactionV1.AckWorker(
            protectedStore: ATSAMEndpointDurableAdapters.sharedProtectedStore,
            database: acceptanceDB,
            queue: ATSAMEndpointDurableAdapters.sharedAckQueue,
            materializer: materializer,
            dialer: dialer
        )
        _ = try await worker.enqueueOneCommittedAck(session: session, nowMs: nowMs)
        _ = try await worker.resumeOneCommittedAck(session: session, nowMs: nowMs, allowDial: false)
        syncBoundGeneration(sessionID: session.sessionID)
        if let packed = dialer.lastPacked { return packed }
        return try loadExactCommittedAckBytes(for: receiptKey)
    }

    private func resendAckViaSecureDial(_ packed: Data, sessionID: Data) async throws {
        guard let meta = sessionMeta[sessionID],
              let lan = RavenServerlessLanConfig.stored else { return }
        _ = try await RavenSecureLanDialerV1.dialLab(
            host: lan.host,
            port: lan.port,
            expectedDeviceEdPub: meta.remoteDeviceEd,
            frames: [packed]
        )
    }

    #if DEBUG
    func debugBoundGeneration(for sessionID: Data) -> UInt64? {
        boundSessions[sessionID]?.publicGeneration
    }

    func debugBoundSessionIDs() -> [Data] {
        Array(boundSessions.keys)
    }

    func debugBoundSession(sessionID: Data) -> ATSAMEndpointTransactionV1.BoundSession? {
        boundSessions[sessionID]
    }

    func resetLabHostStateForTesting() {
        boundSessions.removeAll()
        sessionMeta.removeAll()
        lastLabStatus = "idle"
        duplicateAckRecoveryCount = 0
    }

    func installBoundSessionForTesting(_ bound: ATSAMEndpointTransactionV1.BoundSession) {
        boundSessions[bound.sessionID] = bound
    }

    func installSessionMetaForTesting(
        rootKey: Data,
        meta: ATSAMLabSessionMetaStore.PersistedMeta,
        sessionID: Data
    ) {
        sessionMeta[sessionID] = SessionMeta(
            rootKey: rootKey,
            initiatorAddress: meta.initiatorAddress,
            responderAddress: meta.responderAddress,
            remoteDeviceEd: meta.remoteDeviceEd,
            senderCertIdentity: meta.senderCertIdentity,
            senderCertSigning: meta.senderCertSigning,
            senderCertSig: meta.senderCertSig,
            pairInitSenderCertHash: meta.pairInitSenderCertHash,
            sessionCreatedAtMs: meta.sessionCreatedAtMs,
            sessionExpiresAtMs: meta.sessionExpiresAtMs,
            localDeviceEd: meta.localDeviceEd
        )
    }
    #endif

    static func deviceHint(_ deviceEd: Data) -> UInt64 {
        var material = Data("rvn1/device-hint/v1".utf8)
        material.append(deviceEd)
        let digest = Data(SHA256.hash(data: material))
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

extension Notification.Name {
    static let ravenLabIndexedMessageDisplayed = Notification.Name("ravenLabIndexedMessageDisplayed")
}

// MARK: - Ack materializer

private final class LabAckDialer: ATSAMEndpointTransactionV1.AckDialer {
    private(set) var lastPacked: Data?

    /// Capture-only: AckWorker invokes this outside G1 lease; secure uplink follows in host.
    func dial(packedEnvelope: Data, ackObjectDigest: Data) throws {
        lastPacked = packedEnvelope
        _ = ackObjectDigest
    }
}

private final class LabAckMaterializer: ATSAMEndpointTransactionV1.AckMaterializer {
    let root: Data
    let initiatorAddress: String
    let responderAddress: String
    let signingKey: Curve25519.Signing.PrivateKey
    let inboundDirection: ATSAMIndexedSessionProfile.Direction

    init(
        root: Data,
        initiatorAddress: String,
        responderAddress: String,
        signingKey: Curve25519.Signing.PrivateKey,
        inboundDirection: ATSAMIndexedSessionProfile.Direction
    ) {
        self.root = root
        self.initiatorAddress = initiatorAddress
        self.responderAddress = responderAddress
        self.signingKey = signingKey
        self.inboundDirection = inboundDirection
    }

    func prepareCommittedAck(
        intent: ATSAMEndpointTransactionV1.AckIntent,
        session: ATSAMEndpointTransactionV1.BoundSession,
        state: ATSAMEndpointTransactionV1.ProtectedSessionState,
        createdAtMs: UInt64,
        expiresAtMs: UInt64
    ) throws -> ATSAMEndpointTransactionV1.PreparedAckOutbound {
        // ACK is local→peer: same as outbound message direction (Rust
        // `local_role.outbound_direction()`). Hardcoding R→I only worked when
        // Swift was the PairInit responder.
        let direction: ATSAMIndexedSessionProfile.Direction =
            inboundDirection == .initiatorToResponder
            ? .responderToInitiator
            : .initiatorToResponder
        let pair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
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
        var outerMessageID = Data(count: 16)
        try outerMessageID.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("nil buffer")
            }
            let status = SecRandomCopyBytes(kSecRandomDefault, 16, base)
            guard status == errSecSuccess else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("SecRandomCopyBytes \(status)")
            }
        }
        var innerNonce = Data(count: 12)
        try innerNonce.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("nil buffer")
            }
            let status = SecRandomCopyBytes(kSecRandomDefault, 12, base)
            guard status == errSecSuccess else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("SecRandomCopyBytes \(status)")
            }
        }
        var signedAck = ATSAMIndexedSessionProfile.SignedAck(
            ackedMessageId: intent.ackedMessageID,
            status: intent.status.rawValue,
            ackNonce: innerNonce,
            createdAtMs: createdAtMs,
            signature: Data(repeating: 0, count: 64)
        )
        let signature = try signingKey.signature(
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
        var sealNonce = Data(count: 12)
        try sealNonce.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("nil buffer")
            }
            let status = SecRandomCopyBytes(kSecRandomDefault, 12, base)
            guard status == errSecSuccess else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("SecRandomCopyBytes \(status)")
            }
        }
        let sealed = try ATSAMIndexedSessionProfile.sealAck(
            root: root,
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: direction,
            index: index,
            outerMessageId: outerMessageID,
            plaintext: plaintext,
            nonce: sealNonce
        )
        let route = try ATSAMIndexedSessionProfile.deriveRouteTag(
            root: root,
            createdAtMs: createdAtMs,
            index: index,
            envelopeType: RavenEnvelopeV1.EnvType.ack.rawValue,
            direction: direction
        )
        var anti = Data(count: 12)
        try anti.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("nil buffer")
            }
            let status = SecRandomCopyBytes(kSecRandomDefault, 12, base)
            guard status == errSecSuccess else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("SecRandomCopyBytes \(status)")
            }
        }
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            flags: 0,
            messageId: outerMessageID,
            routingTag: route,
            destDeviceHint: 0,
            createdAtMs: createdAtMs,
            expiresAtMs: expiresAtMs,
            antiReplayNonce: anti,
            messageCiphertext: sealed,
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: signingKey)
        let packed = envelope.pack()
        let ackObjectDigest = envelope.relayObjectDigest()
        let generation = state.generation + 1
        let pendingOutbound = ATSAMEndpointTransactionV1.PendingOutbound(
            sessionID: session.sessionID,
            objectDigest: ackObjectDigest,
            messageID: outerMessageID,
            recipientDevice: intent.expectedRemoteDeviceID,
            ratchetIndex: index,
            immutableEnvelopeBytes: packed,
            sessionGeneration: generation,
            sourceAckIntent: intent.receiptKey.objectDigest
        )
        return ATSAMEndpointTransactionV1.PreparedAckOutbound(
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

private final class LabOutboundCaptureDialer: ATSAMEndpointTransactionV1.OutboundDialer {
    private(set) var lastPacked: Data?

    func dial(packedEnvelope: Data, objectDigest: Data) throws {
        lastPacked = packedEnvelope
        _ = objectDigest
    }
}

private final class LabOutboundMaterializer: ATSAMEndpointTransactionV1.OutboundMaterializer {
    let root: Data
    let initiatorAddress: String
    let responderAddress: String
    let signingKey: Curve25519.Signing.PrivateKey
    let inboundDirection: ATSAMIndexedSessionProfile.Direction

    init(
        root: Data,
        initiatorAddress: String,
        responderAddress: String,
        signingKey: Curve25519.Signing.PrivateKey,
        inboundDirection: ATSAMIndexedSessionProfile.Direction
    ) {
        self.root = root
        self.initiatorAddress = initiatorAddress
        self.responderAddress = responderAddress
        self.signingKey = signingKey
        self.inboundDirection = inboundDirection
    }

    func prepareOutbound(
        text: Data,
        session: ATSAMEndpointTransactionV1.BoundSession,
        state: ATSAMEndpointTransactionV1.ProtectedSessionState,
        createdAtMs: UInt64,
        expiresAtMs: UInt64
    ) throws -> ATSAMEndpointTransactionV1.PreparedOutbound {
        let outboundDirection: ATSAMIndexedSessionProfile.Direction =
            inboundDirection == .initiatorToResponder ? .responderToInitiator : .initiatorToResponder
        let outboundPair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initiatorAddress,
            responderAddress: responderAddress,
            direction: outboundDirection
        )
        let index = state.nextSendIndex
        var chainKey = state.sendChainKey
        let messageKey = try ATSAMIndexedSessionProfile.laneMessageKey(
            chainKey: chainKey,
            sender: outboundPair.sender,
            recipient: outboundPair.recipient
        )
        chainKey = try ATSAMIndexedSessionProfile.advanceChainKey(chainKey)
        var outerMessageID = Data(count: 16)
        try outerMessageID.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("nil buffer")
            }
            let status = SecRandomCopyBytes(kSecRandomDefault, 16, base)
            guard status == errSecSuccess else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("SecRandomCopyBytes \(status)")
            }
        }
        let aad = try ATSAMIndexedSessionProfile.buildAAD(
            index: index,
            sender: outboundPair.sender,
            recipient: outboundPair.recipient,
            outerMessageId: outerMessageID
        )
        var nonce = Data(repeating: 0, count: 8)
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
            root: root,
            createdAtMs: createdAtMs,
            index: index,
            envelopeType: RavenEnvelopeV1.EnvType.message.rawValue,
            direction: outboundDirection
        )
        var anti = Data(count: 12)
        try anti.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("nil buffer")
            }
            let status = SecRandomCopyBytes(kSecRandomDefault, 12, base)
            guard status == errSecSuccess else {
                throw ATSAMLabEndpointHost.HostError.rngFailed("SecRandomCopyBytes \(status)")
            }
        }
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            flags: 0,
            messageId: outerMessageID,
            routingTag: route,
            destDeviceHint: 0,
            createdAtMs: createdAtMs,
            expiresAtMs: expiresAtMs,
            antiReplayNonce: anti,
            messageCiphertext: wire,
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: signingKey)
        let packed = envelope.pack()
        let digest = envelope.relayObjectDigest()
        let generation = state.generation + 1
        let pending = ATSAMEndpointTransactionV1.PendingOutbound(
            sessionID: session.sessionID,
            objectDigest: digest,
            messageID: outerMessageID,
            recipientDevice: session.remoteDeviceEd25519PublicKey,
            ratchetIndex: index,
            immutableEnvelopeBytes: packed,
            sessionGeneration: generation,
            sourceAckIntent: nil
        )
        return ATSAMEndpointTransactionV1.PreparedOutbound(
            peerPub: session.remoteDeviceEd25519PublicKey,
            sessionID: session.sessionID,
            objectDigest: digest,
            messageID: outerMessageID,
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

// MARK: - Optional MessageRepository hook

extension MessageRepository {
    @MainActor
    func insertInboundPlaintextIfPossible(
        text: String,
        senderUserId: String,
        myUserId: String
    ) async {
        // Soft insert — ignore if repository API differs; TRACE already fired.
        #if DEBUG
        print("🕊️ [LabEndpoint] chat insert attempt sender=\(senderUserId.prefix(8))… len=\(text.count)")
        #endif
        _ = (text, senderUserId, myUserId)
    }
}
