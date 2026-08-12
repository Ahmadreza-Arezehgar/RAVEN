//
//  RavenEnvelopeEndpointIngestTests.swift
//  RAVENTests — destination sealed-body handoff (BridgeSubsystem separate).
//

import XCTest
import CryptoKit
@testable import RAVEN

final class RavenEnvelopeEndpointIngestTests: XCTestCase {

    override func tearDown() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        super.tearDown()
    }

    func testClassifyMessageDeliversSealedBody() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let sk = Curve25519.Signing.PrivateKey()
        var sealed = RavenInterimSeal.magic
        sealed.append(RavenInterimSeal.atsamProtoV2)
        sealed.append(0x01)
        sealed.append(Data(repeating: 0x5A, count: 48))
        let mid = Data(repeating: 0xCC, count: 16)
        let packed = RavenBleRvn1Carrier.packSealedForBle(
            sealedBody: sealed,
            messageId: mid,
            routingTag: Data(repeating: 1, count: 16),
            signingKey: sk,
            hybridPQHint: true
        )
        switch RavenEnvelopeEndpointIngest.classify(packed: packed, flagOn: true) {
        case let .deliverSealedBody(messageId, sealedBody, hybridPQ):
            XCTAssertEqual(messageId, mid)
            XCTAssertEqual(sealedBody, sealed)
            XCTAssertTrue(hybridPQ)
        default:
            XCTFail("expected deliverSealedBody")
        }
    }

    func testClassifyAckAcceptsOpaqueAckedId() {
        let sk = Curve25519.Signing.PrivateKey()
        let acked = Data(repeating: 0xDD, count: 16)
        var body = Data()
        body.append(acked)
        body.append(1)
        body.append(Data(repeating: 2, count: 12))
        body.append(contentsOf: withUnsafeBytes(of: UInt64(1).bigEndian) { Data($0) })
        body.append(Data(repeating: 3, count: 64))
        var env = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            messageId: Data(repeating: 0xEE, count: 16),
            routingTag: Data(repeating: 4, count: 16),
            createdAtMs: 1,
            expiresAtMs: .max,
            hopLimit: 2,
            replicationBudget: 1,
            antiReplayNonce: Data(repeating: 5, count: 12),
            messageCiphertext: body
        )
        env.sign(with: sk)
        switch RavenEnvelopeEndpointIngest.classify(packed: env.pack(), flagOn: true) {
        case let .acceptAck(ackedMessageId, _):
            XCTAssertEqual(ackedMessageId, acked)
        default:
            XCTFail("expected acceptAck")
        }
    }

    func testFlagOff() {
        let sk = Curve25519.Signing.PrivateKey()
        let packed = RavenBleRvn1Carrier.packSealedForBle(
            sealedBody: Data(repeating: 1, count: 20),
            messageId: Data(repeating: 1, count: 16),
            routingTag: Data(repeating: 2, count: 16),
            signingKey: sk
        )
        XCTAssertEqual(
            RavenEnvelopeEndpointIngest.classify(packed: packed, flagOn: false),
            .flagOff
        )
    }

    func testDestinationBeatsBridgeRole() {
        XCTAssertEqual(
            RavenEnvelopeEndpointIngest.classifyRole(
                envType: 1,
                localIsDestination: true,
                bridgeEnabled: true
            ),
            .deliverToEndpoint
        )
        XCTAssertEqual(
            RavenEnvelopeEndpointIngest.classifyRole(
                envType: 1,
                localIsDestination: false,
                bridgeEnabled: true
            ),
            .bridgeForward
        )
        XCTAssertEqual(
            RavenEnvelopeEndpointIngest.classifyRole(
                envType: 2,
                localIsDestination: false,
                bridgeEnabled: true
            ),
            .ackRelay
        )
    }

    @MainActor
    func testPublishPostsNotification() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let mid = Data(repeating: 0x11, count: 16)
        let body = Data(repeating: 0x22, count: 32)
        let exp = expectation(description: "ingest note")
        let obs = NotificationCenter.default.addObserver(
            forName: .ravenEnvelopeV1EndpointIngest,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.userInfo?["messageId"] as? Data, mid)
            XCTAssertEqual(note.userInfo?["sealedBody"] as? Data, body)
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        RavenEnvelopeEndpointIngest.publishSealedBody(
            messageId: mid,
            sealedBody: body,
            hybridPQ: false,
            peerKey: "test"
        )
        wait(for: [exp], timeout: 2)
    }
}
