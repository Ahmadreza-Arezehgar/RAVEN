//
//  RavenContactRequestV1Tests.swift
//  RAVENTests — contact request seal/open + ciphertext-only.
//

import XCTest
import CryptoKit
@testable import RAVEN

final class RavenContactRequestV1Tests: XCTestCase {

    func testSealOpenRoundTrip() throws {
        let sender = Curve25519.Signing.PrivateKey()
        let recipient = Curve25519.Signing.PrivateKey()
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: sender.publicKey.rawRepresentation)!
        let recipientAddr = RavenAddressV1.encode(ed25519PublicKey: recipient.publicKey.rawRepresentation)!
        var requestId = Data(count: 16)
        for i in 0..<16 { requestId[i] = UInt8(i &+ 1) }
        let now: UInt64 = 1_700_000_000_000
        let inner = ContactRequestInner(
            requestId: requestId,
            senderRavenId: senderAddr,
            senderDisplayName: "Ada",
            senderAliases: ["ada"],
            senderProfileDigest: Data(count: 32),
            optionalMessage: "hello",
            createdAt: now,
            expiresAt: now &+ 86_400_000
        )
        let req = try RavenContactRequestV1.create(
            senderSigningKey: sender,
            recipientPub: recipient.publicKey.rawRepresentation,
            recipientAddr: recipientAddr,
            inner: inner
        )
        XCTAssertTrue(req.isCiphertextOnly)
        try req.verifyOuter(nowMs: now)
        let opened = try req.open(recipientSigningKey: recipient)
        XCTAssertEqual(opened.senderDisplayName, "Ada")
        XCTAssertEqual(opened.optionalMessage, "hello")
        XCTAssertEqual(opened.senderAliases, ["ada"])
        XCTAssertEqual(opened.requestId, requestId)
    }

    func testAcceptSignVerify() throws {
        let accepter = Curve25519.Signing.PrivateKey()
        var accept = ContactAcceptV1(
            requestId: Data(repeating: 7, count: 16),
            accepterRavenId: "",
            requesterRavenId: "rvn1req",
            acceptedAt: 99,
            signature: Data(),
            accepterPub: Data()
        )
        try accept.sign(with: accepter)
        try accept.verify()
        XCTAssertFalse(accept.accepterRavenId.isEmpty)
    }
}
