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

    func testAckV1BodyCarriesCanonicalEd25519Signature() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let acked = Data((0..<16).map(UInt8.init))
        let nonce = Data((16..<28).map(UInt8.init))
        let createdAtMs: UInt64 = 1_725_000_123_456

        let body = try RavenAckV1.signedBody(
            ackedMessageId: acked,
            ackNonce: nonce,
            createdAtMs: createdAtMs,
            signingKey: signingKey
        )

        XCTAssertEqual(body.count, 16 + 1 + 12 + 8 + 64)
        XCTAssertEqual(body.prefix(16), acked)
        XCTAssertEqual(body[16], RavenAckV1.deliveredStatus)
        XCTAssertEqual(body.subdata(in: 17..<29), nonce)
        XCTAssertEqual(body.readUInt64BE(at: 29), createdAtMs)

        let signature = body.suffix(64)
        XCTAssertFalse(signature.allSatisfy { $0 == 0 })
        let canonical = try RavenAckV1.signingBytes(
            ackedMessageId: acked,
            status: RavenAckV1.deliveredStatus,
            ackNonce: nonce,
            createdAtMs: createdAtMs
        )
        XCTAssertTrue(signingKey.publicKey.isValidSignature(signature, for: canonical))

        var wrongCanonical = canonical
        wrongCanonical[wrongCanonical.count - 1] ^= 0x01
        XCTAssertFalse(signingKey.publicKey.isValidSignature(signature, for: wrongCanonical))
    }

    func testAckV1RejectsInvalidFieldLengths() {
        let signingKey = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(
            try RavenAckV1.signedBody(
                ackedMessageId: Data(repeating: 0, count: 15),
                ackNonce: Data(repeating: 0, count: 12),
                createdAtMs: 1,
                signingKey: signingKey
            )
        )
        XCTAssertThrowsError(
            try RavenAckV1.signedBody(
                ackedMessageId: Data(repeating: 0, count: 16),
                ackNonce: Data(repeating: 0, count: 11),
                createdAtMs: 1,
                signingKey: signingKey
            )
        )
    }

    func testAckV1MatchesFrozenBobToAliceVector() throws {
        let bobSeed = hex("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: bobSeed)
        var acked = Data(repeating: 0, count: 15)
        acked.append(1)
        var nonce = Data(repeating: 0, count: 11)
        nonce.append(2)
        let createdAtMs: UInt64 = 1_700_000_001_000

        let canonical = try RavenAckV1.signingBytes(
            ackedMessageId: acked,
            status: RavenAckV1.deliveredStatus,
            ackNonce: nonce,
            createdAtMs: createdAtMs
        )
        XCTAssertEqual(
            canonical,
            hex("72766e312f61636b00000000000000000000000000000001010000000000000000000000020000018bcfe56be8")
        )

        let body = try RavenAckV1.signedBody(
            ackedMessageId: acked,
            ackNonce: nonce,
            createdAtMs: createdAtMs,
            signingKey: signingKey
        )
        let vectorSignature = hex("d07e3df8d65380cdf7c22a6451385fed401c27744d10178feb625ea398d1af0adc9b07f6d525ba32f7c8b7e35a62cd4cb3dfbdb445410251247aaf2b7ea5ae04")
        XCTAssertTrue(signingKey.publicKey.isValidSignature(vectorSignature, for: canonical))
        // Current CryptoKit uses hedged Ed25519 signing, so a fresh valid
        // signature need not byte-equal the deterministic Rust vector.
        XCTAssertTrue(signingKey.publicKey.isValidSignature(body.suffix(64), for: canonical))
    }

    private func hex(_ value: String) -> Data {
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            data.append(UInt8(value[index..<next], radix: 16)!)
            index = next
        }
        return data
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
    func testUnregisteredUuidShapedEnvelopeIdDoesNotResolve() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let envelopeId = RavenEnvelopeMessageId.envelopeMessageId(
            fromClientMessageId: UUID().uuidString
        )
        XCTAssertNil(
            RavenEnvelopeChatWire.shared.resolveClientMessageId(
                ackedEnvelopeId: envelopeId
            )
        )
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
    func testRawAckNotificationCannotPostDeliveredTick() async {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let mid = UUID().uuidString
        let envId = RavenEnvelopeMessageId.envelopeMessageId(fromClientMessageId: mid)
        RavenEnvelopeChatWire.shared.registerOutbound(clientMessageId: mid, envelopeMessageId: envId)
        RavenEnvelopeChatWire.shared.start()

        let exp = expectation(description: "raw ACK must not produce MeshACKReceived")
        exp.isInverted = true
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

        NotificationCenter.default.post(
            name: .ravenEnvelopeV1EndpointIngest,
            object: nil,
            userInfo: [
                "kind": "ack",
                "ackedMessageId": envId,
                "packed": Data(repeating: 0x01, count: 128)
            ]
        )
        await fulfillment(of: [exp], timeout: 0.2)
    }
}
