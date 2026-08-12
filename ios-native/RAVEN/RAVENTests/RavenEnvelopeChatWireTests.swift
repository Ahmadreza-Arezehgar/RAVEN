//
//  RavenEnvelopeChatWireTests.swift
//  RAVENTests — Delivered ticks + sealer boundary (BridgeSubsystem separate).
//

import XCTest
import CryptoKit
@testable import RAVEN

final class RavenEnvelopeChatWireTests: XCTestCase {

    override func tearDown() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        Task { @MainActor in
            RavenEnvelopeChatWire.shared.stop()
        }
        super.tearDown()
    }

    func testUuidMessageIdRoundTrip() {
        let mid = UUID().uuidString
        let envId = RavenEnvelopeMessageId.envelopeMessageId(fromClientMessageId: mid)
        XCTAssertEqual(envId.count, 16)
        XCTAssertEqual(
            RavenEnvelopeMessageId.clientMessageId(fromEnvelopeMessageId: envId)?.lowercased(),
            mid.lowercased()
        )
    }

    func testSealerEncodedBodyIsBase64() {
        let body = Data([0x52, 0x56, 0x4E, 0x53, 0x31, 0, 0, 0, 1, 2, 3])
        let enc = RavenEnvelopeMessageId.sealerEncodedBody(body)
        XCTAssertEqual(Data(base64Encoded: enc), body)
    }

    @MainActor
    func testRegisterAndResolveOutbound() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let mid = UUID().uuidString
        let envId = RavenEnvelopeMessageId.envelopeMessageId(fromClientMessageId: mid)
        RavenEnvelopeChatWire.shared.registerOutbound(clientMessageId: mid, envelopeMessageId: envId)
        XCTAssertTrue(RavenEnvelopeChatWire.shared.hasPendingOutbound(envelopeMessageId: envId))
        XCTAssertEqual(
            RavenEnvelopeChatWire.shared.resolveClientMessageId(ackedEnvelopeId: envId),
            mid
        )
    }

    @MainActor
    func testPublishAckNotificationKind() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let acked = Data(repeating: 0xAB, count: 16)
        let packed = Data(repeating: 0x01, count: 8)
        let exp = expectation(description: "ack ingest")
        let obs = NotificationCenter.default.addObserver(
            forName: .ravenEnvelopeV1EndpointIngest,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.userInfo?["kind"] as? String, "ack")
            XCTAssertEqual(note.userInfo?["ackedMessageId"] as? Data, acked)
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        RavenEnvelopeEndpointIngest.publishAck(ackedMessageId: acked, packed: packed)
        wait(for: [exp], timeout: 2)
    }

    @MainActor
    func testPublishSealedBodyIncludesKindMessage() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let mid = Data(repeating: 0x11, count: 16)
        let body = Data(repeating: 0x22, count: 16)
        let exp = expectation(description: "msg ingest")
        let obs = NotificationCenter.default.addObserver(
            forName: .ravenEnvelopeV1EndpointIngest,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.userInfo?["kind"] as? String, "message")
            XCTAssertEqual(note.userInfo?["senderUserId"] as? String, "alice")
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        RavenEnvelopeEndpointIngest.publishSealedBody(
            messageId: mid,
            sealedBody: body,
            hybridPQ: false,
            peerKey: "ble-x",
            senderUserId: "alice"
        )
        wait(for: [exp], timeout: 2)
    }

    @MainActor
    func testChatWireApplyDeliveredPostsMeshAck() async {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let mid = UUID().uuidString
        let envId = RavenEnvelopeMessageId.envelopeMessageId(fromClientMessageId: mid)
        RavenEnvelopeChatWire.shared.registerOutbound(clientMessageId: mid, envelopeMessageId: envId)

        let exp = expectation(description: "MeshACKReceived")
        let obs = NotificationCenter.default.addObserver(
            forName: Notification.Name("MeshACKReceived"),
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.userInfo?["messageId"] as? String, mid)
            XCTAssertEqual(note.userInfo?["status"] as? String, MessageStatus.delivered.rawValue)
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        let resolved = await RavenEnvelopeChatWire.shared.applyDeliveredFromAck(ackedEnvelopeId: envId)
        XCTAssertEqual(resolved, mid)
        await fulfillment(of: [exp], timeout: 3)
    }
}
