//
//  RavenContactRequestV1Tests.swift
//  RAVENTests — contact request seal/open + ciphertext-only.
//

import XCTest
import CryptoKit
@testable import RAVEN

final class RavenContactRequestV1Tests: XCTestCase {

    private let root = ATSAMRootKey(rootBytes: Data(repeating: 0x5D, count: 32))

    func testRootlessCompatibilityAPIAlwaysFailsClosed() throws {
        let sender = Curve25519.Signing.PrivateKey()
        let recipient = Curve25519.Signing.PrivateKey()
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: sender.publicKey.rawRepresentation)!
        let recipientAddr = RavenAddressV1.encode(ed25519PublicKey: recipient.publicKey.rawRepresentation)!
        let inner = makeInner(senderAddr: senderAddr)

        XCTAssertThrowsError(
            try RavenContactRequestV1.create(
                senderSigningKey: sender,
                recipientPub: recipient.publicKey.rawRepresentation,
                recipientAddr: recipientAddr,
                inner: inner
            )
        ) { error in
            XCTAssertEqual(error as? RavenContactRequestError, .sessionRequired)
        }
    }

    func testATSAMRootSealOpenRoundTrip() throws {
        let sender = Curve25519.Signing.PrivateKey()
        let recipient = Curve25519.Signing.PrivateKey()
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: sender.publicKey.rawRepresentation)!
        let recipientAddr = RavenAddressV1.encode(ed25519PublicKey: recipient.publicKey.rawRepresentation)!
        let inner = makeInner(senderAddr: senderAddr)
        let req = try RavenContactRequestV1.createWithATSAMRoot(
            senderSigningKey: sender,
            recipientPub: recipient.publicKey.rawRepresentation,
            recipientAddr: recipientAddr,
            inner: inner,
            root: root,
            chainIndex: 7,
            nonce: Data(repeating: 0xA7, count: 12)
        )
        XCTAssertTrue(req.isCiphertextOnly)
        XCTAssertEqual(req.ciphertext.prefix(10), Data([0x52, 0x56, 0x4E, 0x41, 0x31, 0, 0, 0, 2, 1]))
        try req.verifyOuter(nowMs: inner.createdAt)
        let opened = try req.openWithATSAMRoot(recipientSigningKey: recipient, root: root)
        XCTAssertEqual(opened.senderDisplayName, "Ada")
        XCTAssertEqual(opened.optionalMessage, "hello")
        XCTAssertEqual(opened.senderAliases, ["ada"])
        XCTAssertEqual(opened.requestId, inner.requestId)

        let wrongRoot = ATSAMRootKey(rootBytes: Data(repeating: 0xA5, count: 32))
        XCTAssertThrowsError(
            try req.openWithATSAMRoot(recipientSigningKey: recipient, root: wrongRoot)
        )
        XCTAssertThrowsError(try req.open(recipientSigningKey: recipient)) { error in
            XCTAssertEqual(error as? RavenContactRequestError, .sessionRequired)
        }
    }

    func testATSAMRootCiphertextMatchesRustFixedVector() throws {
        let sender = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x11, count: 32)
        )
        let recipient = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x22, count: 32)
        )
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: sender.publicKey.rawRepresentation)!
        let recipientPub = recipient.publicKey.rawRepresentation
        let recipientAddr = RavenAddressV1.encode(ed25519PublicKey: recipientPub)!
        let req = try RavenContactRequestV1.createWithATSAMRoot(
            senderSigningKey: sender,
            recipientPub: recipientPub,
            recipientAddr: recipientAddr,
            inner: makeInner(senderAddr: senderAddr),
            root: root,
            chainIndex: 7,
            nonce: Data(repeating: 0xA7, count: 12)
        )
        XCTAssertEqual(
            req.ciphertext.ravenHex,
            "52564e4131000000020100000007a7a7a7a7a7a7a7a7a7a7a7a7280fecc70f23af7bcdb9ec51dab82dc364a5b2bf6d8a59daf128f9336594e7710ac2ab955cbeffe1ac435960df222d290fab8eccd38d30b6a162de4f1dbf9edbd49844423e00485180c9e58261cff86a85a015c6b8bf0bd10262c7f3e0e997368e6ed855aacc299921837baa83db0347e53dae544dd8c21488fa0cd46bb9cd213ec759fe36ee5b6219647ddfaf5710f6def129b810464833034274f7c4f5dba7f76cded7f8b215"
        )
    }

    func testPortableRootHelperRejectsHostileChainIndexWithoutWork() throws {
        let sender = Curve25519.Signing.PrivateKey()
        let recipient = Curve25519.Signing.PrivateKey()
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: sender.publicKey.rawRepresentation)!
        let recipientPub = recipient.publicKey.rawRepresentation
        let recipientAddr = RavenAddressV1.encode(ed25519PublicKey: recipientPub)!
        XCTAssertThrowsError(
            try RavenContactRequestV1.createWithATSAMRoot(
                senderSigningKey: sender,
                recipientPub: recipientPub,
                recipientAddr: recipientAddr,
                inner: makeInner(senderAddr: senderAddr),
                root: root,
                chainIndex: 4_097,
                nonce: Data(repeating: 0xA7, count: 12)
            )
        ) { error in
            XCTAssertEqual(error as? RavenContactRequestError, .sealFailed)
        }
    }

    func testRootCodecRejectsUnboundAndOversizedInnerFieldsWithoutTrap() throws {
        let sender = Curve25519.Signing.PrivateKey()
        let recipient = Curve25519.Signing.PrivateKey()
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: sender.publicKey.rawRepresentation)!
        let recipientPub = recipient.publicKey.rawRepresentation
        let recipientAddr = RavenAddressV1.encode(ed25519PublicKey: recipientPub)!
        var inner = makeInner(senderAddr: recipientAddr)
        XCTAssertThrowsError(
            try RavenContactRequestV1.createWithATSAMRoot(
                senderSigningKey: sender,
                recipientPub: recipientPub,
                recipientAddr: recipientAddr,
                inner: inner,
                root: root,
                chainIndex: 0,
                nonce: Data(repeating: 0xA7, count: 12)
            )
        ) { error in
            XCTAssertEqual(error as? RavenContactRequestError, .idMismatch)
        }

        inner.senderRavenId = senderAddr
        inner.optionalMessage = String(repeating: "a", count: Int(UInt16.max) + 1)
        XCTAssertThrowsError(try inner.encode()) { error in
            XCTAssertEqual(error as? RavenContactRequestError, .oversized)
        }
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

    private func makeInner(senderAddr: String) -> ContactRequestInner {
        var requestId = Data(count: 16)
        for i in 0..<16 { requestId[i] = UInt8(i &+ 1) }
        let now: UInt64 = 1_700_000_000_000
        return ContactRequestInner(
            requestId: requestId,
            senderRavenId: senderAddr,
            senderDisplayName: "Ada",
            senderAliases: ["ada"],
            senderProfileDigest: Data(count: 32),
            optionalMessage: "hello",
            createdAt: now,
            expiresAt: now &+ 86_400_000
        )
    }
}
