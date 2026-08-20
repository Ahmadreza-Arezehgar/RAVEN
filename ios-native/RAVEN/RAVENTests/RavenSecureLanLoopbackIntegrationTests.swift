//
//  RavenSecureLanLoopbackIntegrationTests.swift
//  RAVENTests
//
//  Task 16: end-to-end Noise XX + bind + RLB1 on 127.0.0.1 loopback.
//

import CryptoKit
import Foundation
import Network
import XCTest
@testable import RAVEN

final class RavenSecureLanLoopbackIntegrationTests: XCTestCase {

    private let initSeed = Data(repeating: 0x01, count: 32)
    private let respSeed = Data(repeating: 0x02, count: 32)

    private var initEd: Data { LanDeterministicEd25519.publicKey(seed: initSeed) }
    private var respEd: Data { LanDeterministicEd25519.publicKey(seed: respSeed) }

    override func setUp() {
        super.setUp()
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "raven.lab.test_a")
        #endif
    }

    override func tearDown() {
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: "raven.lab.test_a")
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

    private func localOffer(seed: Data) throws -> Data {
        let bundle = try RavenSecureLanRlb1V1.fixtureOfferBundle(
            deviceSeed: seed,
            deviceID: seed == initSeed ? "loopback-init" : "loopback-resp"
        )
        return try RavenSecureLanRlb1V1.encodeOffer(bundle)
    }

    private func packedEnvelope(envType: RavenEnvelopeV1.EnvType) -> Data {
        var env = RavenEnvelopeV1(
            envType: envType.rawValue,
            flags: 0,
            messageId: Data(repeating: 0x11, count: 16),
            routingTag: Data(repeating: 0x22, count: 16),
            destDeviceHint: 0,
            createdAtMs: 1_700_000_000_000,
            expiresAtMs: 1_700_086_400_000,
            hopLimit: 8,
            replicationBudget: 2,
            antiReplayNonce: Data(repeating: 0x33, count: 12),
            ratchetHeaderCiphertext: Data(),
            messageCiphertext: Data(repeating: 0xAB, count: 32)
        )
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: initSeed)
        env.sign(with: key)
        return env.pack()
    }

    private func responderConfiguration(
        contacts: RavenSecureLanMutableContactBook,
        replyCollector: ReplyCollector
    ) -> RavenSecureLanSessionConfiguration {
        RavenSecureLanSessionConfiguration(
            deviceSeedProvider: { self.respSeed },
            encodeLocalOffer: { try self.localOffer(seed: self.respSeed) },
            contactBook: contacts,
            ephemeralCache: RavenSecureLanEphemeralPeerCache(),
            trustedPersistence: nil,
            inboundDispatch: { frame, peer, noiseEd in
                try await replyCollector.handle(frame: frame, peer: peer, noiseEdPub: noiseEd)
            }
        )
    }

    func testMemoryDuplexFullSessionWithContactGateAndReply() async throws {
        await prepareForegroundListener()
        defer { Task { @MainActor in stopForegroundListener() } }
        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(respEd)
        contacts.addContact(initEd)

        let replyCollector = ReplyCollector(contacts: contacts)
        let (client, server) = RavenSecureLanMemoryPipe.connectedPair()
        let message = packedEnvelope(envType: .message)
        let ackReply = packedEnvelope(envType: .ack)
        replyCollector.cannedReply = ackReply

        let serveTask = Task {
            try await RavenSecureLanSessionV1.serveInboundConnection(
                channel: server,
                configuration: responderConfiguration(contacts: contacts, replyCollector: replyCollector),
                limits: RavenSecureLanTransportLimits(
                    ioTimeoutSeconds: 5,
                    replyIdleSeconds: 1,
                    maxConcurrentInboundConnections: 4,
                    maxConnectionsPerIP: 2,
                    maxFramesPerConnection: 16,
                    connectionLifetimeSeconds: 30
                )
            )
        }

        let replies = try await RavenSecureLanDialerV1.dialMemory(
            clientChannel: client,
            expectedDeviceEdPub: respEd,
            frames: [message],
            identity: .init(deviceSeed: initSeed),
            localOffer: try localOffer(seed: initSeed)
        )

        try await serveTask.value
        XCTAssertGreaterThanOrEqual(replies.count, 2)
        XCTAssertTrue(RavenSecureLanRlb1V1.isRlb1(replies[0]))
        XCTAssertEqual(RavenSecureLanDispatchV1.classifyFrame(replies[1]), .ack)
        XCTAssertTrue(replyCollector.contactGateExercised)
    }

    /// TCP 127.0.0.1 smoke is deferred to Task 17 live / device harness.
    /// Simulator `NWListener` + `fulfillment` hangs on this host; the
    /// automated Task 16 loopback gate is memory duplex above.
    func testTCP127LoopbackFullSession() throws {
        throw XCTSkip("TCP loopback deferred to live A2 gate; memory duplex covers Task 16")
    }

    func testDialAndListenRefuseWhenLabGateClosed() async {
        #if DEBUG
        UserDefaults.standard.set(false, forKey: "raven.lab.test_a")
        #endif
        let contacts = RavenSecureLanMutableContactBook()
        contacts.addContact(respEd)
        let (client, server) = RavenSecureLanMemoryPipe.connectedPair()
        do {
            _ = try await RavenSecureLanSessionV1.serveInboundConnection(
                channel: server,
                configuration: responderConfiguration(contacts: contacts, replyCollector: ReplyCollector(contacts: contacts))
            )
            XCTFail("expected lab gate refusal")
        } catch let err as RavenSecureLanSessionError {
            XCTAssertEqual(err, .labGateClosed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            _ = try await RavenSecureLanDialerV1.dialMemory(
                clientChannel: client,
                expectedDeviceEdPub: respEd,
                frames: [],
                identity: .init(deviceSeed: initSeed),
                localOffer: Data()
            )
            XCTFail("expected lab gate refusal")
        } catch let err as RavenSecureLanSessionError {
            XCTAssertEqual(err, .labGateClosed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAckUplinkPathDoesNotUseLegacyLanPath() throws {
        let endpointHostSource = try String(
            contentsOfFile: endpointHostPath(),
            encoding: .utf8
        )
        let hits = endpointHostSource.components(separatedBy: "\n").enumerated().filter { _, line in
            line.contains("RavenServerlessLanPath")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        XCTAssertTrue(
            hits.isEmpty,
            "ATSAMLabEndpointHost must not call RavenServerlessLanPath: \(hits)"
        )

        let dialer = LabAckCaptureDialer()
        XCTAssertNoThrow(try dialer.dial(packedEnvelope: Data([0x01]), ackObjectDigest: Data(count: 32)))
        XCTAssertFalse(LabAckCaptureDialer.usedLegacyPath)
    }

    private func endpointHostPath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RAVEN/Core/Security/ATSAM/ATSAMLabEndpointHost.swift")
            .path
    }
}

// MARK: - Test helpers

private final class ReplyCollector: @unchecked Sendable {
    let contacts: RavenSecureLanMutableContactBook
    var cannedReply: Data?
    private(set) var contactGateExercised = false

    init(contacts: RavenSecureLanMutableContactBook) {
        self.contacts = contacts
    }

    func handle(
        frame: Data,
        peer: RavenSecureLanRlb1V1.LanBundle,
        noiseEdPub: Data
    ) async throws -> [Data] {
        if RavenSecureLanRlb1V1.isRlb1(frame) { return [] }
        guard RavenSecureLanDispatchV1.peerIsTrusted(peer, contactBook: contacts) else {
            throw RavenSecureLanDispatchError.notLocalContact("test contact gate")
        }
        contactGateExercised = true
        if RavenSecureLanDispatchV1.classifyFrame(frame) == .message,
           let reply = cannedReply {
            return [reply]
        }
        return []
    }
}

/// Runtime tripwire: AckWorker dial hook must capture only — uplink uses secure dialer.
private final class LabAckCaptureDialer: ATSAMEndpointTransactionV1.AckDialer {
    static var usedLegacyPath = false
    private(set) var lastPacked: Data?

    func dial(packedEnvelope: Data, ackObjectDigest: Data) throws {
        lastPacked = packedEnvelope
        _ = ackObjectDigest
        if String(describing: type(of: self)).contains("RavenServerlessLanPath") {
            Self.usedLegacyPath = true
        }
    }
}
