//
//  RavenEnvelopeSenderResolverTests.swift
//

import XCTest
import CryptoKit
@testable import RAVEN

final class RavenEnvelopeSenderResolverTests: XCTestCase {

    func testResolveViaKnownIdentityPub() {
        let sk = Curve25519.Signing.PrivateKey()
        let mid = Data(repeating: 0x42, count: 16)
        var env = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            messageId: mid,
            routingTag: Data(repeating: 1, count: 16),
            createdAtMs: 1,
            expiresAtMs: .max,
            hopLimit: 4,
            replicationBudget: 2,
            antiReplayNonce: Data(repeating: 2, count: 12),
            messageCiphertext: Data(repeating: 9, count: 24)
        )
        env.sign(with: sk)
        let pub = sk.publicKey.rawRepresentation
        let uid = DeviceIdentityService.deriveFingerprint(from: pub)
        let r = RavenEnvelopeSenderResolver.resolve(
            env: env,
            candidatePubs: [(uid, pub, "test")]
        )
        XCTAssertEqual(r?.senderUserId, uid)
        XCTAssertEqual(r?.via, "test")
    }

    func testRejectWrongKey() {
        let sk = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        var env = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            messageId: Data(repeating: 3, count: 16),
            routingTag: Data(repeating: 1, count: 16),
            createdAtMs: 1,
            expiresAtMs: .max,
            hopLimit: 4,
            replicationBudget: 2,
            antiReplayNonce: Data(repeating: 2, count: 12),
            messageCiphertext: Data([1, 2, 3, 4])
        )
        env.sign(with: sk)
        let r = RavenEnvelopeSenderResolver.resolve(
            env: env,
            candidatePubs: [("bob", other.publicKey.rawRepresentation, "wrong")]
        )
        XCTAssertNil(r)
    }

    func testPubFromHex() {
        let sk = Curve25519.Signing.PrivateKey()
        let hex = sk.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(RavenEnvelopeSenderResolver.pubFromHex(hex), sk.publicKey.rawRepresentation)
        XCTAssertNil(RavenEnvelopeSenderResolver.pubFromHex("zz"))
    }
}
