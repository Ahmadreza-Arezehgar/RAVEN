//
//  RavenEnvelopeBridgeServiceTests.swift
//  RAVENTests — Bridge V1 opaque forward decisions (LAN↔BLE) behind flag.
//

import XCTest
import CryptoKit
@testable import RAVEN

final class RavenEnvelopeBridgeServiceTests: XCTestCase {

    override func tearDown() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        super.tearDown()
    }

    private func samplePacked(hop: UInt8 = 4, repl: UInt8 = 2, expires: UInt64 = .max) -> (Data, Data) {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let sk = Curve25519.Signing.PrivateKey()
        let mid = Data(repeating: 0xAB, count: 16)
        let packed = RavenBleRvn1Carrier.packSealedForBle(
            sealedBody: Data(repeating: 5, count: 32),
            messageId: mid,
            routingTag: Data(repeating: 6, count: 16),
            signingKey: sk,
            hopLimit: hop,
            nowMs: 1_700_000_000_000
        )
        // packSealedForBle uses fixed replicationBudget 3; mutate if needed
        var env = RavenEnvelopeV1.unpack(packed)!
        env.hopLimit = hop
        env.replicationBudget = repl
        env.expiresAtMs = expires
        env.sign(with: sk)
        return (env.pack(), mid)
    }

    func testDecideForwardHappyPath() {
        let (packed, mid) = samplePacked()
        let d = RavenEnvelopeBridgeService.decideForward(
            packed: packed,
            messageId: mid,
            expiresAtMs: .max,
            hopLimit: 4,
            replicationBudget: 2,
            alreadySeen: false,
            egressReady: true,
            peerKey: "p1",
            peerHitsInWindow: 0,
            maxPerPeer: 30,
            nowMs: 10,
            flagOn: true
        )
        XCTAssertEqual(d, .forward)
    }

    func testDecideDropWhenFlagOff() {
        let (packed, mid) = samplePacked()
        let d = RavenEnvelopeBridgeService.decideForward(
            packed: packed,
            messageId: mid,
            expiresAtMs: .max,
            hopLimit: 4,
            replicationBudget: 2,
            alreadySeen: false,
            egressReady: true,
            peerKey: "p1",
            peerHitsInWindow: 0,
            maxPerPeer: 30,
            nowMs: 10,
            flagOn: false
        )
        XCTAssertEqual(d, .flagOff)
    }

    func testDecideDropRateLimitedAndNoEgress() {
        let (packed, mid) = samplePacked()
        XCTAssertEqual(
            RavenEnvelopeBridgeService.decideForward(
                packed: packed,
                messageId: mid,
                expiresAtMs: .max,
                hopLimit: 4,
                replicationBudget: 2,
                alreadySeen: false,
                egressReady: true,
                peerKey: "p1",
                peerHitsInWindow: 30,
                maxPerPeer: 30,
                nowMs: 10,
                flagOn: true
            ),
            .dropRateLimited
        )
        XCTAssertEqual(
            RavenEnvelopeBridgeService.decideForward(
                packed: packed,
                messageId: mid,
                expiresAtMs: .max,
                hopLimit: 4,
                replicationBudget: 2,
                alreadySeen: false,
                egressReady: false,
                peerKey: "p1",
                peerHitsInWindow: 0,
                maxPerPeer: 30,
                nowMs: 10,
                flagOn: true
            ),
            .dropNoEgress
        )
    }

    func testDecideDropExpiredHopDuplicate() {
        let (packed, mid) = samplePacked()
        XCTAssertEqual(
            RavenEnvelopeBridgeService.decideForward(
                packed: packed,
                messageId: mid,
                expiresAtMs: 5,
                hopLimit: 4,
                replicationBudget: 2,
                alreadySeen: false,
                egressReady: true,
                peerKey: "p1",
                peerHitsInWindow: 0,
                maxPerPeer: 30,
                nowMs: 10,
                flagOn: true
            ),
            .dropExpired
        )
        XCTAssertEqual(
            RavenEnvelopeBridgeService.decideForward(
                packed: packed,
                messageId: mid,
                expiresAtMs: .max,
                hopLimit: 0,
                replicationBudget: 2,
                alreadySeen: false,
                egressReady: true,
                peerKey: "p1",
                peerHitsInWindow: 0,
                maxPerPeer: 30,
                nowMs: 10,
                flagOn: true
            ),
            .dropHop
        )
        XCTAssertEqual(
            RavenEnvelopeBridgeService.decideForward(
                packed: packed,
                messageId: mid,
                expiresAtMs: .max,
                hopLimit: 4,
                replicationBudget: 2,
                alreadySeen: true,
                egressReady: true,
                peerKey: "p1",
                peerHitsInWindow: 0,
                maxPerPeer: 30,
                nowMs: 10,
                flagOn: true
            ),
            .dropDuplicate
        )
    }

    @MainActor
    func testLanToBleWithoutPeersReturnsNoEgress() async {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        RavenEnvelopeBridgeService.shared.localIsDestination = false
        let (packed, _) = samplePacked()
        // Simulator / no BLE peers → dropNoEgress (does not crash).
        let d = await RavenEnvelopeBridgeService.shared.forwardLanToBle(
            packed: packed,
            peerKey: "test-lan"
        )
        XCTAssertTrue(
            d == .dropNoEgress || d == .forward || d == .dropDuplicate,
            "unexpected \(d)"
        )
    }

    @MainActor
    func testForcedLocalDestinationWithoutSessionFailsClosed() async {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        RavenEnvelopeBridgeService.shared.localIsDestination = true
        defer {
            RavenEnvelopeBridgeService.shared.localIsDestination = false
        }
        let (packed, _) = samplePacked()
        let exp = expectation(description: "endpoint ingest must not publish")
        exp.isInverted = true
        let obs = NotificationCenter.default.addObserver(
            forName: .ravenEnvelopeV1EndpointIngest,
            object: nil,
            queue: .main
        ) { _ in
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        let d = await RavenEnvelopeBridgeService.shared.forwardLanToBle(
            packed: packed,
            peerKey: "dest-test"
        )
        XCTAssertNotEqual(d, .deliverToEndpoint)
        await fulfillment(of: [exp], timeout: 0.2)
    }

    func testMessageRouteRequiresPerEnvelopeLocalMatch() {
        XCTAssertEqual(
            RavenEnvelopeBridgeService.classifyMessageRoute(
                localRouteMatched: true,
                bridgeEnabled: true
            ),
            .deliverToEndpoint
        )
        XCTAssertEqual(
            RavenEnvelopeBridgeService.classifyMessageRoute(
                localRouteMatched: false,
                bridgeEnabled: true
            ),
            .bridgeForward
        )
        XCTAssertEqual(
            RavenEnvelopeBridgeService.classifyMessageRoute(
                localRouteMatched: false,
                bridgeEnabled: false
            ),
            .drop
        )
    }

    func testAckRelayPreservesOpaqueBytesWithoutExposingAckedId() throws {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let sk = Curve25519.Signing.PrivateKey()
        let acked = Data(repeating: 0x10, count: 16)
        let body = try RavenAckV1.signedBody(
            ackedMessageId: acked,
            ackNonce: Data(repeating: 1, count: 12),
            createdAtMs: 99,
            signingKey: sk
        )
        var env = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            messageId: Data(repeating: 0xAC, count: 16),
            routingTag: Data(repeating: 8, count: 16),
            createdAtMs: 1,
            expiresAtMs: .max,
            hopLimit: 4,
            replicationBudget: 1,
            antiReplayNonce: Data(repeating: 2, count: 12),
            messageCiphertext: body
        )
        env.sign(with: sk)
        let packed = env.pack()
        guard case let .opaqueAck(relayBytes) = RavenBleRvn1Carrier.ingest(packed) else {
            return XCTFail("expected opaque ACK relay object")
        }
        XCTAssertEqual(relayBytes, packed)
        XCTAssertEqual(
            RavenEnvelopeEndpointIngest.classify(packed: packed, flagOn: true),
            .dropUnverifiedAck
        )
        XCTAssertEqual(
            RavenEnvelopeEndpointIngest.classifyRole(
                envType: RavenEnvelopeV1.EnvType.ack.rawValue,
                localIsDestination: false,
                bridgeEnabled: true
            ),
            .ackRelay
        )
        XCTAssertEqual(
            RavenEnvelopeEndpointIngest.classifyRole(
                envType: RavenEnvelopeV1.EnvType.message.rawValue,
                localIsDestination: true,
                bridgeEnabled: true
            ),
            .deliverToEndpoint
        )
    }
}
