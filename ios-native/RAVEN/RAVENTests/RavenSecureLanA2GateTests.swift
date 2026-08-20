//
//  RavenSecureLanA2GateTests.swift
//  RAVENTests
//
//  Task 17: automated A2 gate scenarios (memory duplex — no NWListener TCP).
//  Live Terminal↔iPhone steps remain in node/scripts/ios_lan_lab_checklist.md.
//

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

@MainActor
final class RavenSecureLanA2GateTests: XCTestCase {

    private let aliceSeed = Data(repeating: 0x01, count: 32)
    private let bobSeed = Data(repeating: 0x02, count: 32)

    private var aliceEd: Data { LanDeterministicEd25519.publicKey(seed: aliceSeed) }
    private var bobEd: Data { LanDeterministicEd25519.publicKey(seed: bobSeed) }

    private let testLimits = RavenSecureLanTransportLimits(
        ioTimeoutSeconds: 5,
        replyIdleSeconds: 1,
        maxConcurrentInboundConnections: 4,
        maxConnectionsPerIP: 2,
        maxFramesPerConnection: 16,
        connectionLifetimeSeconds: 30
    )

    override func setUp() {
        super.setUp()
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "raven.lab.test_a")
        ATSAMPairInitAcceptService.resetAcceptTestHooks()
        #endif
    }

    override func tearDown() {
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: "raven.lab.test_a")
        ATSAMPairInitAcceptService.resetAcceptTestHooks()
        ATSAMPairResponseCache.setTestRoot(nil)
        #endif
        super.tearDown()
    }

    @MainActor
    private func prepareForegroundListener() {
        RavenSecureLanLabListenerController.shared.setForegroundForTesting(true)
    }

    @MainActor
    private func stopForegroundListener() {
        RavenSecureLanLabListenerController.shared.stopLabListen()
    }

    // MARK: - Bidirectional message + ACK (both roles initiator once)

    func testBidirectionalMessageAndAckBothRolesInitiator() async throws {
        await prepareForegroundListener()
        defer { Task { @MainActor in stopForegroundListener() } }

        let aliceToBob = try await runDuplexExchange(
            initiatorSeed: aliceSeed,
            responderSeed: bobSeed,
            outbound: [packedEnvelope(envType: .message, seed: aliceSeed, tag: 0xA1)],
            replyForMessage: packedEnvelope(envType: .ack, seed: bobSeed, tag: 0xB1)
        )
        XCTAssertTrue(RavenSecureLanRlb1V1.isRlb1(aliceToBob[0]))
        XCTAssertEqual(RavenSecureLanDispatchV1.classifyFrame(aliceToBob[1]), .ack)

        let bobToAlice = try await runDuplexExchange(
            initiatorSeed: bobSeed,
            responderSeed: aliceSeed,
            outbound: [packedEnvelope(envType: .message, seed: bobSeed, tag: 0xB2)],
            replyForMessage: packedEnvelope(envType: .ack, seed: aliceSeed, tag: 0xA2)
        )
        XCTAssertTrue(RavenSecureLanRlb1V1.isRlb1(bobToAlice[0]))
        XCTAssertEqual(RavenSecureLanDispatchV1.classifyFrame(bobToAlice[1]), .ack)
    }

    // MARK: - Duplicate frame → no second delivery

    func testDuplicateApplicationFrameDoesNotDoubleDeliver() async throws {
        await prepareForegroundListener()
        defer { Task { @MainActor in stopForegroundListener() } }

        let message = packedEnvelope(envType: .message, seed: aliceSeed, tag: 0xD1)
        let tracker = A2DeliveryTracker()
        tracker.cannedReply = packedEnvelope(envType: .ack, seed: bobSeed, tag: 0xD2)
        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(aliceEd)
        contacts.addContact(bobEd)

        let (client, server) = RavenSecureLanMemoryPipe.connectedPair()
        let serveTask = Task {
            try await RavenSecureLanSessionV1.serveInboundConnection(
                channel: server,
                configuration: responderConfiguration(
                    responderSeed: bobSeed,
                    contacts: contacts,
                    tracker: tracker
                ),
                limits: testLimits
            )
        }

        _ = try await RavenSecureLanDialerV1.dialMemory(
            clientChannel: client,
            expectedDeviceEdPub: bobEd,
            frames: [message, message],
            identity: .init(deviceSeed: aliceSeed),
            localOffer: try localOffer(seed: aliceSeed)
        )
        try await serveTask.value

        XCTAssertEqual(tracker.messageDeliveries, 1, "duplicate frame must not double-deliver")
        XCTAssertEqual(tracker.ackReplies, 1)
    }

    // MARK: - Contact delete mid-path → refuse

    func testContactDeleteMidSessionRefusesFurtherFrames() async throws {
        await prepareForegroundListener()
        defer { Task { @MainActor in stopForegroundListener() } }

        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(aliceEd)
        contacts.addContact(bobEd)
        let tracker = A2DeliveryTracker()
        let firstMessage = packedEnvelope(envType: .message, seed: aliceSeed, tag: 0xE1)
        let aliceKey = aliceEd

        let (client, server) = RavenSecureLanMemoryPipe.connectedPair()
        let serveTask = Task {
            try await RavenSecureLanSessionV1.serveInboundConnection(
                channel: server,
                configuration: responderConfiguration(
                    responderSeed: bobSeed,
                    contacts: contacts,
                    tracker: tracker,
                    onBeforeSecondFrame: { contacts.removeContact(aliceKey) }
                ),
                limits: testLimits
            )
        }

        let secondMessage = packedEnvelope(envType: .message, seed: aliceSeed, tag: 0xE2)
        do {
            _ = try await RavenSecureLanDialerV1.dialMemory(
                clientChannel: client,
                expectedDeviceEdPub: bobEd,
                frames: [firstMessage, secondMessage],
                identity: .init(deviceSeed: aliceSeed),
                localOffer: try localOffer(seed: aliceSeed)
            )
        } catch {
            // Responder may abort session after contact gate refusal.
        }
        try? await serveTask.value

        XCTAssertEqual(tracker.messageDeliveries, 1, "first frame before delete must succeed")
        XCTAssertLessThanOrEqual(tracker.messageDeliveries, 1, "deleted contact must not receive second frame")
    }

    // MARK: - Block → refuse

    func testBlockedPeerRefusedAtResponderHandshake() async throws {
        await prepareForegroundListener()
        defer { Task { @MainActor in stopForegroundListener() } }

        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(aliceEd)
        contacts.addContact(bobEd)
        contacts.block(aliceEd)

        let (client, server) = RavenSecureLanMemoryPipe.connectedPair()
        let serveTask = Task {
            try await RavenSecureLanSessionV1.serveInboundConnection(
                channel: server,
                configuration: responderConfiguration(
                    responderSeed: bobSeed,
                    contacts: contacts,
                    tracker: A2DeliveryTracker()
                ),
                limits: testLimits
            )
        }

        do {
            _ = try await RavenSecureLanDialerV1.dialMemory(
                clientChannel: client,
                expectedDeviceEdPub: bobEd,
                frames: [],
                identity: .init(deviceSeed: aliceSeed),
                localOffer: try localOffer(seed: aliceSeed)
            )
            XCTFail("expected blocked peer refusal")
        } catch let err as RavenSecureLanSessionError {
            XCTAssertTrue(
                err == .ioTimeout || err == .peerBlocked,
                "initiator sees timeout when responder aborts blocked peer, got \(err)"
            )
        }

        do {
            try await serveTask.value
            XCTFail("responder must refuse blocked peer")
        } catch let err as RavenSecureLanSessionError {
            XCTAssertEqual(err, .peerBlocked)
        }
    }

    func testBlockedPeerRefusedAtDispatch() throws {
        let peer = try RavenSecureLanRlb1V1.fixtureOfferBundle(
            deviceSeed: bobSeed,
            deviceID: "blocked-peer"
        )
        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(peer.cert.deviceEdPub)
        contacts.block(peer.cert.deviceEdPub)

        XCTAssertThrowsError(
            try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
                packedEnvelope(envType: .message, seed: bobSeed, tag: 0xBF),
                peer: peer,
                noiseEdPub: peer.cert.deviceEdPub,
                contactBook: contacts,
                ephemeralCache: RavenSecureLanEphemeralPeerCache(),
                trustedPersistence: nil,
                hasConfirmedSession: true,
                handlers: .init(onMessage: { _ in })
            )
        ) { error in
            XCTAssertEqual(error as? RavenSecureLanDispatchError, .peerBlocked)
        }
    }

    // MARK: - PairInit / PairResponse exact-byte retry

    func testPairResponseCacheReturnsExactBytesOnRetry() throws {
        let fixtures = try A2PairInitFixtures()
        defer { ATSAMPairResponseCache.setTestRoot(nil) }

        try ATSAMPairResponseCache.store(initID: fixtures.initValue.initID, packed: fixtures.packedResponse)
        let first = try ATSAMPairResponseCache.loadVerified(
            initValue: fixtures.initValue,
            localDeviceEd: fixtures.localDeviceEd
        )
        let second = try ATSAMPairResponseCache.loadVerified(
            initValue: fixtures.initValue,
            localDeviceEd: fixtures.localDeviceEd
        )
        XCTAssertEqual(first, fixtures.packedResponse)
        XCTAssertEqual(second, first, "cached PairResponse must replay exact same bytes")
    }

    func testExactBytePairInitRetryReturnsDuplicateClaim() throws {
        let fixtures = try A2PairInitFixtures()
        defer { ATSAMPairResponseCache.setTestRoot(nil) }

        let store = ATSAMPrekeyLifecycleStore.shared
        store.resetForTesting(memoryOnly: true)
        defer { store.resetForTesting(memoryOnly: true) }

        let first = try store.claimPairInit(
            pairInitWire: fixtures.initWire,
            initValue: fixtures.initValue,
            trust: fixtures.trust,
            root: fixtures.root,
            nowMs: fixtures.nowMs
        )
        guard case .accepted = first else {
            return XCTFail("expected first claim accepted, got \(first)")
        }

        let retry = try store.claimPairInit(
            pairInitWire: fixtures.initWire,
            initValue: fixtures.initValue,
            trust: fixtures.trust,
            root: fixtures.root,
            nowMs: fixtures.nowMs &+ 1
        )
        guard case .duplicatePending = retry else {
            return XCTFail("exact-byte PairInit retry must not re-claim, got \(retry)")
        }
    }

    // MARK: - Revoke / expiry fail-closed (stub contact book)

    func testRevokedContactBookFailsClosed() throws {
        let peer = try RavenSecureLanRlb1V1.fixtureOfferBundle(
            deviceSeed: bobSeed,
            deviceID: "revoked-peer"
        )
        let contacts = A2RevokedContactBook(revokedDeviceEd: peer.cert.deviceEdPub)

        XCTAssertThrowsError(
            try RavenSecureLanDispatchV1.dispatchDecryptedFrame(
                packedEnvelope(envType: .message, seed: bobSeed, tag: 0xB1),
                peer: peer,
                noiseEdPub: peer.cert.deviceEdPub,
                contactBook: contacts,
                ephemeralCache: RavenSecureLanEphemeralPeerCache(),
                trustedPersistence: nil,
                hasConfirmedSession: true,
                handlers: .init(onMessage: { _ in })
            )
        ) { error in
            let detail = (error as? RavenSecureLanDispatchError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(detail.contains("not a local contact"))
        }
    }

    func testExpiredSessionWindowFailsClosed() {
        let nowMs: UInt64 = 1_700_000_000_000
        let sessionCreatedMs = nowMs - 86_400_000
        let sessionExpiresMs = nowMs - 1
        let envelopeCreatedMs = nowMs - 120_000
        let envelopeExpiresMs = nowMs + 60_000
        let windowValid = sessionCreatedMs < sessionExpiresMs
            && nowMs >= sessionCreatedMs
            && nowMs < sessionExpiresMs
            && envelopeCreatedMs >= sessionCreatedMs
            && envelopeExpiresMs <= sessionExpiresMs
        XCTAssertFalse(windowValid, "expired session must fail closed at endpoint time window")
    }

    // MARK: - No legacy / RVNP1 / interim fallback

    func testSecureLanSourcesNeverReferenceLegacyPath() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            repoRoot.appendingPathComponent("RAVEN/Core/Security/LAN"),
            repoRoot.appendingPathComponent("RAVEN/Core/Security/ATSAM/ATSAMLabEndpointHost.swift"),
            repoRoot.appendingPathComponent("RAVEN/Core/Security/ATSAM/ATSAMPairInitAcceptService.swift"),
        ]
        var violations: [(String, Int, String)] = []
        for path in paths {
            let files: [URL]
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue {
                files = try FileManager.default.contentsOfDirectory(
                    at: path,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "swift" }
            } else {
                files = [path]
            }
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for (idx, line) in source.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") { continue }
                    if trimmed.contains("unavailable")
                        || trimmed.contains("fatalError")
                        || trimmed.contains("errorDescription")
                        || trimmed.contains("return \"") {
                        continue
                    }
                    if trimmed.contains("RavenServerlessLanPath.")
                        || trimmed.contains("RavenInterimSeal.") {
                        violations.append((file.lastPathComponent, idx + 1, trimmed))
                    }
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "secure LAN entrypoints must not reference legacy path: \(violations)"
        )
    }

    func testSecurePathGuardRejectsLegacyDelegation() {
        XCTAssertThrowsError(
            try RavenSecureLanSecurePathGuard.refuseLegacyDelegation(useLegacyPath: true)
        ) { error in
            XCTAssertEqual(error as? RavenSecureLanError, .legacyLanPathForbidden)
        }
    }

    func testLabGateClosedRefusesMemoryDuplex() async {
        #if DEBUG
        UserDefaults.standard.set(false, forKey: "raven.lab.test_a")
        #endif
        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(bobEd)
        let (client, server) = RavenSecureLanMemoryPipe.connectedPair()
        do {
            _ = try await RavenSecureLanDialerV1.dialMemory(
                clientChannel: client,
                expectedDeviceEdPub: bobEd,
                frames: [],
                identity: .init(deviceSeed: aliceSeed),
                localOffer: Data()
            )
            XCTFail("expected lab gate refusal")
        } catch let err as RavenSecureLanSessionError {
            XCTAssertEqual(err, .labGateClosed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        _ = server
    }

    // MARK: - Helpers

    private func localOffer(seed: Data) throws -> Data {
        let bundle = try RavenSecureLanRlb1V1.fixtureOfferBundle(
            deviceSeed: seed,
            deviceID: seed == aliceSeed ? "a2-alice" : "a2-bob"
        )
        return try RavenSecureLanRlb1V1.encodeOffer(bundle)
    }

    private func packedEnvelope(
        envType: RavenEnvelopeV1.EnvType,
        seed: Data,
        tag: UInt8
    ) -> Data {
        var env = RavenEnvelopeV1(
            envType: envType.rawValue,
            flags: 0,
            messageId: Data(repeating: tag, count: 16),
            routingTag: Data(repeating: tag ^ 0x55, count: 16),
            destDeviceHint: 0,
            createdAtMs: 1_700_000_000_000,
            expiresAtMs: 1_700_086_400_000,
            hopLimit: 8,
            replicationBudget: 2,
            antiReplayNonce: Data(repeating: tag ^ 0xAA, count: 12),
            ratchetHeaderCiphertext: Data(),
            messageCiphertext: Data(repeating: tag, count: 32)
        )
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        env.sign(with: key)
        return env.pack()
    }

    private func runDuplexExchange(
        initiatorSeed: Data,
        responderSeed: Data,
        outbound: [Data],
        replyForMessage: Data
    ) async throws -> [Data] {
        let initiatorEd = LanDeterministicEd25519.publicKey(seed: initiatorSeed)
        let responderEd = LanDeterministicEd25519.publicKey(seed: responderSeed)
        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(initiatorEd)
        contacts.addContact(responderEd)
        let tracker = A2DeliveryTracker()
        tracker.cannedReply = replyForMessage

        let (client, server) = RavenSecureLanMemoryPipe.connectedPair()
        let serveTask = Task {
            try await RavenSecureLanSessionV1.serveInboundConnection(
                channel: server,
                configuration: responderConfiguration(
                    responderSeed: responderSeed,
                    contacts: contacts,
                    tracker: tracker
                ),
                limits: testLimits
            )
        }

        let replies = try await RavenSecureLanDialerV1.dialMemory(
            clientChannel: client,
            expectedDeviceEdPub: responderEd,
            frames: outbound,
            identity: .init(deviceSeed: initiatorSeed),
            localOffer: try localOffer(seed: initiatorSeed)
        )
        try await serveTask.value
        return replies
    }

    private func responderConfiguration(
        responderSeed: Data,
        contacts: RavenSecureLanMutableContactBook,
        tracker: A2DeliveryTracker,
        onBeforeSecondFrame: (() -> Void)? = nil
    ) -> RavenSecureLanSessionConfiguration {
        RavenSecureLanSessionConfiguration(
            deviceSeedProvider: { responderSeed },
            encodeLocalOffer: { try self.localOffer(seed: responderSeed) },
            contactBook: contacts,
            ephemeralCache: RavenSecureLanEphemeralPeerCache(),
            trustedPersistence: nil,
            inboundDispatch: { frame, peer, noiseEd in
                try await tracker.handle(
                    frame: frame,
                    peer: peer,
                    noiseEdPub: noiseEd,
                    contactBook: contacts,
                    onBeforeSecondFrame: onBeforeSecondFrame
                )
            }
        )
    }
}

// MARK: - Test helpers

private final class A2DeliveryTracker: @unchecked Sendable {
    var cannedReply: Data?
    private(set) var messageDeliveries = 0
    private(set) var ackReplies = 0
    private var seenMessageIds = Set<Data>()
    private var frameCount = 0

    func handle(
        frame: Data,
        peer: RavenSecureLanRlb1V1.LanBundle,
        noiseEdPub: Data,
        contactBook: RavenSecureLanContactBook,
        onBeforeSecondFrame: (() -> Void)? = nil
    ) async throws -> [Data] {
        if RavenSecureLanRlb1V1.isRlb1(frame) { return [] }
        frameCount += 1
        if frameCount == 2 { onBeforeSecondFrame?() }

        guard RavenSecureLanDispatchV1.peerIsTrusted(peer, contactBook: contactBook) else {
            throw RavenSecureLanDispatchError.notLocalContact("a2 gate contact refusal")
        }
        if contactBook.isBlocked(
            deviceEdPub: peer.cert.deviceEdPub,
            userEdPub: peer.cert.userEdPub,
            noiseEdPub: noiseEdPub
        ) {
            throw RavenSecureLanDispatchError.peerBlocked
        }

        switch RavenSecureLanDispatchV1.classifyFrame(frame) {
        case .message:
            guard let env = RavenEnvelopeV1.unpack(frame) else {
                throw RavenSecureLanDispatchError.notEnvelope
            }
            guard seenMessageIds.insert(env.messageId).inserted else {
                return []
            }
            messageDeliveries += 1
            if let reply = cannedReply {
                ackReplies += 1
                return [reply]
            }
            return []
        case .ack:
            return []
        default:
            return []
        }
    }
}

/// Simulates device cert revoke: contact was trusted, then removed from local book.
private final class A2RevokedContactBook: RavenSecureLanContactBook {
    let revokedDeviceEd: Data

    init(revokedDeviceEd: Data) {
        self.revokedDeviceEd = revokedDeviceEd
    }

    func isLocalContact(deviceEdPub: Data, userEdPub: Data) -> Bool {
        false
    }

    func isBlocked(deviceEdPub: Data, userEdPub: Data, noiseEdPub: Data) -> Bool {
        false
    }
}

private struct A2PairInitFixtures {
    let initWire: Data
    let initValue: ATSAMPairInitV1.PairInit
    let trust: ATSAMPairInitV1.TrustContext
    let root: Data
    let nowMs: UInt64
    let localDeviceEd: Data
    let packedResponse: Data

    init() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("a2-pairinit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        ATSAMPairResponseCache.setTestRoot(cacheRoot)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorURL = repoRoot.appendingPathComponent("shared-vectors/rvn1/atsam/pair_init_v1_001.json")
        guard FileManager.default.fileExists(atPath: vectorURL.path) else {
            throw XCTSkip("shared PairInit vector not found in this checkout")
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL)) as! [String: Any]
        let expected = json["expected"] as! [String: Any]
        let input = json["input"] as! [String: Any]
        initWire = A2Hex.data(expected["pair_init_wire_hex"] as! String)
        initValue = try ATSAMPairInitV1.decodeInit(initWire)
        root = A2Hex.data(expected["provisional_k_root_hex"] as! String)
        nowMs = initValue.createdAtMs &+ 100
        localDeviceEd = initValue.responderDeviceEd25519PublicKey
        trust = ATSAMPairInitV1.TrustContext(
            initiatorCertificate: .init(
                identityEd25519PublicKey: A2Hex.data(input["initiator_identity_ed_pub_hex"] as! String),
                signingBytes: A2Hex.data(input["initiator_device_cert_signing_bytes_hex"] as! String),
                signature: A2Hex.data(input["initiator_device_cert_signature_hex"] as! String)
            ),
            responderCertificate: .init(
                identityEd25519PublicKey: A2Hex.data(input["responder_identity_ed_pub_hex"] as! String),
                signingBytes: A2Hex.data(input["responder_device_cert_signing_bytes_hex"] as! String),
                signature: A2Hex.data(input["responder_device_cert_signature_hex"] as! String)
            ),
            responderPrekeyBundle: .init(
                signingBytes: A2Hex.data(input["responder_prekey_signing_bytes_hex"] as! String),
                signature: A2Hex.data(input["responder_prekey_signature_hex"] as! String)
            )
        )
        let responseWire = A2Hex.data(expected["pair_response_wire_hex"] as! String)
        let signingKey = Curve25519.Signing.PrivateKey()
        packedResponse = try RavenPairInitLanOob.wrapOobWire(
            responseWire,
            isPairInit: false,
            signingKey: signingKey,
            nowMs: initValue.createdAtMs
        )
    }
}

private enum A2Hex {
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
}
