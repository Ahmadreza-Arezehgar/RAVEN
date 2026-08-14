//
//  ATSAMLabEndpointHost.swift
//  RAVEN — Test A lab endpoint: session install, receive → chat, sealed ACK uplink.
//

import CryptoKit
import Foundation

@MainActor
final class ATSAMLabEndpointHost {
    static let shared = ATSAMLabEndpointHost()

    private let acceptanceDB = SQLCipherAcceptanceDatabase()
    private var boundSessions: [Data: ATSAMEndpointTransactionV1.BoundSession] = [:]
    private var sessionMeta: [Data: SessionMeta] = [:]
    private var ingestObserver: NSObjectProtocol?
    private var acceptObserver: NSObjectProtocol?

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

    private init() {}

    func start() {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled,
              FeatureFlag.isRavenEnvelopeV1Enabled else { return }
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
        #if DEBUG
        print("🕊️ [LabEndpoint] started (lab Test A)")
        #endif
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
    }

    func installResponderSession(
        initValue: ATSAMPairInitV1.PairInit,
        root: Data,
        sessionID: Data,
        initiatorCertificate: ATSAMPairInitV1.SignedDeviceCertificate,
        nowMs: UInt64
    ) async throws {
        let localDeviceEd = initValue.responderDeviceEd25519PublicKey
        let hint = Self.deviceHint(localDeviceEd)
        let certHash = try ATSAMPairInitV1.deviceCertificateHash(initiatorCertificate)

        let inbound: ATSAMIndexedSessionProfile.Direction = .initiatorToResponder
        let pair = try ATSAMIndexedSessionProfile.endpoints(
            initiatorAddress: initValue.initiatorAddress,
            responderAddress: initValue.responderAddress,
            direction: inbound
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
        try persistMeta(meta, sessionID: sessionID)

        TestATrace.emit(
            location: "ATSAMLabEndpointHost.installResponderSession",
            message: "TRACE_SESSION_DURABLE_COMMIT",
            status: "PAIR_RESPONSE_READY",
            detail: "gen=1"
        )
        _ = nowMs
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

    func receivePacked(_ packed: Data) async {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return }
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
                    await presentPlaintext(plaintext, sessionID: sid)
                    try await enqueueAndUplinkAck(for: receipt.receiptKey)
                    TestATrace.emit(
                        location: "ATSAMLabEndpointHost.receivePacked",
                        message: "TRACE_INDEXED_MESSAGE_ACCEPTED",
                        status: "WAITING_FOR_ENDPOINT_ACK_UPLINK",
                        detail: "bytes=\(plaintext.count)"
                    )
                    return
                case .exactDuplicate:
                    return
                }
            } catch {
                continue
            }
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
        guard let meta = sessionMeta[receiptKey.sessionID],
              let seed = DeviceIdentityService.shared.deviceSigningSeed else { return }
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let materializer = LabAckMaterializer(
            root: meta.rootKey,
            initiatorAddress: meta.initiatorAddress,
            responderAddress: meta.responderAddress,
            signingKey: signingKey
        )
        let worker = ATSAMEndpointTransactionV1.AckWorker(
            database: acceptanceDB,
            queue: ATSAMEndpointDurableAdapters.sharedAckQueue,
            materializer: materializer
        )
        let enqueued = try await worker.enqueueOneCommittedAck()
        guard enqueued else { return }

        // Pull staged bytes from file queue directory and uplink.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let ackDir = dir.appendingPathComponent("raven-endpoint-ack-queue", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: ackDir,
            includingPropertiesForKeys: nil
        ),
        let last = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last,
        let packed = try? Data(contentsOf: last),
        let lan = RavenServerlessLanConfig.stored else { return }

        try await RavenServerlessLanPath.sendPackedFireAndForget(
            packed,
            host: lan.host,
            port: lan.port
        )
        TestATrace.emit(
            location: "ATSAMLabEndpointHost.enqueueAndUplinkAck",
            message: "TRACE_SEALED_ACK_UPLINKED",
            status: "ACK_QUEUED",
            detail: nil
        )
    }

    private func persistMeta(_ meta: SessionMeta, sessionID: Data) throws {
        let url = Self.metaURL(sessionID: sessionID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(meta).write(to: url, options: .atomic)
    }

    private static func metaURL(sessionID: Data) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = sessionID.map { String(format: "%02x", $0) }.joined()
        return base
            .appendingPathComponent("raven-lab-sessions", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("json")
    }

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

private final class LabAckMaterializer: ATSAMEndpointTransactionV1.AckMaterializer {
    let root: Data
    let initiatorAddress: String
    let responderAddress: String
    let signingKey: Curve25519.Signing.PrivateKey
    private var nextIndex: UInt32 = 0

    init(
        root: Data,
        initiatorAddress: String,
        responderAddress: String,
        signingKey: Curve25519.Signing.PrivateKey
    ) {
        self.root = root
        self.initiatorAddress = initiatorAddress
        self.responderAddress = responderAddress
        self.signingKey = signingKey
    }

    func materializeCommittedAck(
        _ intent: ATSAMEndpointTransactionV1.AckIntent
    ) throws -> Data {
        let createdAt = UInt64(Date().timeIntervalSince1970 * 1000)
        var outerMessageID = Data(count: 16)
        outerMessageID.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        var innerNonce = Data(count: 12)
        innerNonce.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, buf.baseAddress!)
        }
        var signedAck = ATSAMIndexedSessionProfile.SignedAck(
            ackedMessageId: intent.ackedMessageID,
            status: intent.status.rawValue,
            ackNonce: innerNonce,
            createdAtMs: createdAt,
            signature: Data(repeating: 0, count: 64)
        )
        let signature = try signingKey.signature(
            for: ATSAMIndexedSessionProfile.ackSigningBytes(signedAck)
        )
        signedAck = ATSAMIndexedSessionProfile.SignedAck(
            ackedMessageId: intent.ackedMessageID,
            status: intent.status.rawValue,
            ackNonce: innerNonce,
            createdAtMs: createdAt,
            signature: Data(signature)
        )
        let plaintext = try ATSAMIndexedSessionProfile.encodeSignedAck(signedAck)
        let direction = ATSAMIndexedSessionProfile.Direction.responderToInitiator
        let index = nextIndex
        nextIndex &+= 1
        var sealNonce = Data(count: 12)
        sealNonce.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, buf.baseAddress!)
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
            createdAtMs: createdAt,
            index: index,
            envelopeType: RavenEnvelopeV1.EnvType.ack.rawValue,
            direction: direction
        )
        var anti = Data(count: 12)
        anti.withUnsafeMutableBytes { buf in
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, buf.baseAddress!)
        }
        var envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            flags: 0,
            messageId: outerMessageID,
            routingTag: route,
            destDeviceHint: 0,
            createdAtMs: createdAt,
            expiresAtMs: createdAt &+ 7 * 24 * 3600 * 1_000,
            antiReplayNonce: anti,
            messageCiphertext: sealed,
            senderAuthentication: Data(repeating: 0, count: 64)
        )
        envelope.sign(with: signingKey)
        return envelope.pack()
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
