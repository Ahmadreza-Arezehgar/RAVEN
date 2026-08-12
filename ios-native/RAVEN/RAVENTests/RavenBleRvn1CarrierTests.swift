//
//  RavenBleRvn1CarrierTests.swift
//  RAVENTests — Phase G BLE raw RVN1 packing behind flag; Mesh path untouched.
//

import XCTest
import CryptoKit
@testable import RAVEN

final class RavenBleRvn1CarrierTests: XCTestCase {

    override func tearDown() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        super.tearDown()
    }

    func testLooksLikeRequiresMagicAndLength() {
        XCTAssertFalse(RavenBleRvn1Carrier.looksLikeRavenEnvelopeV1(Data()))
        XCTAssertFalse(RavenBleRvn1Carrier.looksLikeRavenEnvelopeV1(Data("{json}".utf8)))
        var short = RavenEnvelopeV1.magic
        short.append(1)
        XCTAssertFalse(RavenBleRvn1Carrier.looksLikeRavenEnvelopeV1(short))
    }

    func testIngestFlagOffIgnoresRvn1() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        let sk = Curve25519.Signing.PrivateKey()
        let packed = RavenBleRvn1Carrier.packSealedForBle(
            sealedBody: Data(repeating: 7, count: 40),
            messageId: Data(repeating: 1, count: 16),
            routingTag: Data(repeating: 2, count: 16),
            signingKey: sk
        )
        XCTAssertEqual(RavenBleRvn1Carrier.ingest(packed), .flagOff)
    }

    func testPackFakeBleRoundtripVerified() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let sk = Curve25519.Signing.PrivateKey()
        var body = RavenInterimSeal.magic
        body.append(RavenInterimSeal.atsamProtoV2)
        body.append(0x01)
        body.append(Data(repeating: 9, count: 40))
        let mid = Data(repeating: 3, count: 16)
        let packed = RavenBleRvn1Carrier.packSealedForBle(
            sealedBody: body,
            messageId: mid,
            routingTag: Data(repeating: 4, count: 16),
            signingKey: sk,
            hybridPQHint: true,
            nowMs: 1_700_000_000_000
        )
        XCTAssertTrue(RavenBleRvn1Carrier.looksLikeRavenEnvelopeV1(packed))
        // Mesh JSON must still be distinguishable.
        XCTAssertFalse(packed.first == UInt8(ascii: "{"))

        switch RavenBleRvn1Carrier.ingest(packed, senderPublicKey: sk.publicKey) {
        case let .verified(messageId, sealedBody, hybridPQ):
            XCTAssertEqual(messageId, mid)
            XCTAssertEqual(sealedBody, body)
            XCTAssertTrue(hybridPQ)
        default:
            XCTFail("expected verified")
        }
    }

    func testBadSignatureRejected() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let sk = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let packed = RavenBleRvn1Carrier.packSealedForBle(
            sealedBody: Data(repeating: 1, count: 20),
            messageId: Data(repeating: 1, count: 16),
            routingTag: Data(repeating: 2, count: 16),
            signingKey: sk
        )
        XCTAssertEqual(
            RavenBleRvn1Carrier.ingest(packed, senderPublicKey: other.publicKey),
            .badSignature
        )
    }

    func testBleAttemptedWheneverPeersNearby() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        // Parallel with LAN — Wi‑Fi up no longer blocks BLE RVN1.
        XCTAssertTrue(
            RavenBleRvn1Carrier.shouldAttemptBle(
                wifiUp: false, peerOnLan: false, blePeersNearby: true
            )
        )
        XCTAssertTrue(
            RavenBleRvn1Carrier.shouldAttemptBle(
                wifiUp: true, peerOnLan: true, blePeersNearby: true
            )
        )
        XCTAssertFalse(
            RavenBleRvn1Carrier.shouldAttemptBle(
                wifiUp: true, peerOnLan: true, blePeersNearby: false
            )
        )
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        XCTAssertFalse(
            RavenBleRvn1Carrier.shouldAttemptBle(
                wifiUp: false, peerOnLan: false, blePeersNearby: true
            )
        )
    }

    func testMeshJsonStillNotRvn1() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let json = Data("{\"clientMessageId\":\"x\"}".utf8)
        XCTAssertEqual(RavenBleRvn1Carrier.ingest(json), .notRvn1)
    }

    func testIngestAckOpaque() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let sk = Curve25519.Signing.PrivateKey()
        let acked = Data(repeating: 0x42, count: 16)
        var body = Data()
        body.append(acked)
        body.append(1) // delivered
        body.append(Data(repeating: 9, count: 12))
        body.append(contentsOf: withUnsafeBytes(of: UInt64(1_700_000_000_000).bigEndian) { Data($0) })
        body.append(Data(repeating: 0, count: 64))
        var env = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            messageId: Data(repeating: 0xAC, count: 16),
            routingTag: Data(repeating: 7, count: 16),
            createdAtMs: 1_700_000_000_000,
            expiresAtMs: .max,
            hopLimit: 4,
            replicationBudget: 1,
            antiReplayNonce: Data(repeating: 3, count: 12),
            messageCiphertext: body
        )
        env.sign(with: sk)
        let packed = env.pack()
        switch RavenBleRvn1Carrier.ingest(packed) {
        case let .ack(_, ackedMessageId, gotPacked):
            XCTAssertEqual(ackedMessageId, acked)
            XCTAssertEqual(gotPacked, packed)
        default:
            XCTFail("expected ack")
        }
    }
}
