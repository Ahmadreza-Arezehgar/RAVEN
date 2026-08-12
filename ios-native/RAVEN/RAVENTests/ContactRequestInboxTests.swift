//
//  ContactRequestInboxTests.swift
//  RAVENTests — accept / decline / block + binding.
//

import XCTest
import CryptoKit
@testable import RAVEN

final class ContactRequestInboxTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "raven.discovery.contact_inbox.wires.v1")
        UserDefaults.standard.removeObject(forKey: "raven.discovery.contact_bindings.v1")
        UserDefaults.standard.removeObject(forKey: "raven.discovery.blocked_pubhex.v1")
    }

    func testWireRoundTripOpaque() throws {
        let sender = Curve25519.Signing.PrivateKey()
        let recipient = Curve25519.Signing.PrivateKey()
        let senderAddr = RavenAddressV1.encode(ed25519PublicKey: sender.publicKey.rawRepresentation)!
        let recipientAddr = RavenAddressV1.encode(ed25519PublicKey: recipient.publicKey.rawRepresentation)!
        var requestId = Data(count: 16)
        for i in 0..<16 { requestId[i] = UInt8(0xAC) }
        let now: UInt64 = 1_700_000_000_000
        let inner = ContactRequestInner(
            requestId: requestId,
            senderRavenId: senderAddr,
            senderDisplayName: "Ada",
            senderAliases: ["ada"],
            senderProfileDigest: Data(count: 32),
            optionalMessage: "secret note",
            createdAt: now,
            expiresAt: now &+ 86_400_000
        )
        let req = try RavenContactRequestV1.create(
            senderSigningKey: sender,
            recipientPub: recipient.publicKey.rawRepresentation,
            recipientAddr: recipientAddr,
            inner: inner
        )
        let wire = req.encodeWire()
        let lossy = String(decoding: wire, as: UTF8.self)
        XCTAssertFalse(lossy.contains("secret note"))
        XCTAssertFalse(lossy.contains("rvn1/contact-req-inner"))
        let decoded = try RavenContactRequestV1.decodeWire(wire)
        XCTAssertEqual(decoded.requestId, requestId)
        XCTAssertTrue(decoded.isCiphertextOnly)
    }

    func testAcceptBindsPetname() throws {
        let requester = Curve25519.Signing.PrivateKey()
        let accepter = Curve25519.Signing.PrivateKey()
        let requesterAddr = RavenAddressV1.encode(ed25519PublicKey: requester.publicKey.rawRepresentation)!
        let accepterAddr = RavenAddressV1.encode(ed25519PublicKey: accepter.publicKey.rawRepresentation)!
        var requestId = Data(count: 16)
        for i in 0..<16 { requestId[i] = UInt8(0xAC) }
        let now: UInt64 = 1_700_000_000_000
        let req = try RavenContactRequestV1.create(
            senderSigningKey: requester,
            recipientPub: accepter.publicKey.rawRepresentation,
            recipientAddr: accepterAddr,
            inner: ContactRequestInner(
                requestId: requestId,
                senderRavenId: requesterAddr,
                senderDisplayName: "Ada",
                senderAliases: [],
                senderProfileDigest: Data(count: 32),
                optionalMessage: "hi",
                createdAt: now,
                expiresAt: now &+ 60_000
            )
        )
        var inbox = ContactRequestInbox()
        _ = try inbox.ingest(
            outer: req,
            recipientSigningKey: accepter,
            recipientAddr: accepterAddr,
            nowMs: now
        )
        XCTAssertEqual(inbox.pending.count, 1)
        let outcome = try inbox.accept(
            requestId: requestId,
            accepterKey: accepter,
            petname: "Ada (work)",
            nowMs: now
        )
        try outcome.accept.verify()
        XCTAssertEqual(outcome.binding.ravenId, requesterAddr)
        XCTAssertEqual(outcome.binding.petname, "Ada (work)")
        XCTAssertEqual(outcome.binding.verificationState, .trustedContact)
        XCTAssertEqual(outcome.binding.pubHex, requester.publicKey.rawRepresentation.ravenHex)
        XCTAssertTrue(inbox.pending.isEmpty)

        // Persist binding store
        DiscoveryContactBindingStore.upsert(LocalDiscoveryContact(
            ravenId: outcome.binding.ravenId,
            pubHex: outcome.binding.pubHex,
            petname: outcome.binding.petname,
            publicTag: "",
            displayName: outcome.binding.petname,
            pinned: false,
            directlyVerified: false
        ))
        let loaded = DiscoveryContactBindingStore.load()
        XCTAssertTrue(loaded.contains { $0.ravenId == requesterAddr && $0.petname == "Ada (work)" })
    }

    func testDeclineRemovesPending() throws {
        let requester = Curve25519.Signing.PrivateKey()
        let accepter = Curve25519.Signing.PrivateKey()
        let requesterAddr = RavenAddressV1.encode(ed25519PublicKey: requester.publicKey.rawRepresentation)!
        let accepterAddr = RavenAddressV1.encode(ed25519PublicKey: accepter.publicKey.rawRepresentation)!
        let requestId = Data(repeating: 0xDE, count: 16)
        let now: UInt64 = 1_700_000_000_000
        let req = try RavenContactRequestV1.create(
            senderSigningKey: requester,
            recipientPub: accepter.publicKey.rawRepresentation,
            recipientAddr: accepterAddr,
            inner: ContactRequestInner(
                requestId: requestId,
                senderRavenId: requesterAddr,
                senderDisplayName: "Bob",
                senderAliases: [],
                senderProfileDigest: Data(count: 32),
                optionalMessage: "",
                createdAt: now,
                expiresAt: now &+ 60_000
            )
        )
        var inbox = ContactRequestInbox()
        _ = try inbox.ingest(
            outer: req,
            recipientSigningKey: accepter,
            recipientAddr: accepterAddr,
            nowMs: now
        )
        try inbox.decline(requestId: requestId)
        XCTAssertTrue(inbox.pending.isEmpty)
    }

    func testBlockAddsLocalBlockList() throws {
        let requester = Curve25519.Signing.PrivateKey()
        let accepter = Curve25519.Signing.PrivateKey()
        let requesterAddr = RavenAddressV1.encode(ed25519PublicKey: requester.publicKey.rawRepresentation)!
        let accepterAddr = RavenAddressV1.encode(ed25519PublicKey: accepter.publicKey.rawRepresentation)!
        let requestId = Data(repeating: 0xBB, count: 16)
        let now: UInt64 = 1_700_000_000_000
        let req = try RavenContactRequestV1.create(
            senderSigningKey: requester,
            recipientPub: accepter.publicKey.rawRepresentation,
            recipientAddr: accepterAddr,
            inner: ContactRequestInner(
                requestId: requestId,
                senderRavenId: requesterAddr,
                senderDisplayName: "Eve",
                senderAliases: [],
                senderProfileDigest: Data(count: 32),
                optionalMessage: "",
                createdAt: now,
                expiresAt: now &+ 60_000
            )
        )
        var inbox = ContactRequestInbox()
        _ = try inbox.ingest(
            outer: req,
            recipientSigningKey: accepter,
            recipientAddr: accepterAddr,
            nowMs: now
        )
        let pubHex = try inbox.block(requestId: requestId)
        DiscoveryBlockStore.block(pubHex)
        XCTAssertTrue(inbox.pending.isEmpty)
        XCTAssertTrue(DiscoveryBlockStore.load().contains(pubHex.lowercased()))
    }

    func testSenderCapAntiSpam() throws {
        let requester = Curve25519.Signing.PrivateKey()
        let accepter = Curve25519.Signing.PrivateKey()
        let requesterAddr = RavenAddressV1.encode(ed25519PublicKey: requester.publicKey.rawRepresentation)!
        let accepterAddr = RavenAddressV1.encode(ed25519PublicKey: accepter.publicKey.rawRepresentation)!
        let now: UInt64 = 1_700_000_000_000
        var inbox = ContactRequestInbox()
        for i in 0..<ContactRequestInbox.maxPerSender {
            var requestId = Data(count: 16)
            requestId[0] = UInt8(0xA0 + i)
            let req = try RavenContactRequestV1.create(
                senderSigningKey: requester,
                recipientPub: accepter.publicKey.rawRepresentation,
                recipientAddr: accepterAddr,
                inner: ContactRequestInner(
                    requestId: requestId,
                    senderRavenId: requesterAddr,
                    senderDisplayName: "Spam",
                    senderAliases: [],
                    senderProfileDigest: Data(count: 32),
                    optionalMessage: "",
                    createdAt: now,
                    expiresAt: now &+ 60_000
                )
            )
            _ = try inbox.ingest(
                outer: req,
                recipientSigningKey: accepter,
                recipientAddr: accepterAddr,
                nowMs: now
            )
        }
        XCTAssertEqual(inbox.pending.count, ContactRequestInbox.maxPerSender)
        var requestId = Data(count: 16)
        requestId[0] = 0xFF
        let extra = try RavenContactRequestV1.create(
            senderSigningKey: requester,
            recipientPub: accepter.publicKey.rawRepresentation,
            recipientAddr: accepterAddr,
            inner: ContactRequestInner(
                requestId: requestId,
                senderRavenId: requesterAddr,
                senderDisplayName: "Spam",
                senderAliases: [],
                senderProfileDigest: Data(count: 32),
                optionalMessage: "",
                createdAt: now,
                expiresAt: now &+ 60_000
            )
        )
        XCTAssertThrowsError(
            try inbox.ingest(
                outer: extra,
                recipientSigningKey: accepter,
                recipientAddr: accepterAddr,
                nowMs: now
            )
        ) { err in
            XCTAssertEqual(err as? RavenContactRequestError, .senderCap)
        }
    }

    func testNearbySafetyPhraseConfirm() {
        let token = Data(repeating: 1, count: 16)
        let commitment = Data(repeating: 2, count: 32)
        let phrase = NearbySafetyPhrase.phrase(token: token, commitment: commitment)
        XCTAssertTrue(phrase.contains("-"))
        XCTAssertTrue(NearbySafetyPhrase.matches(expected: phrase, entered: phrase))
        XCTAssertFalse(NearbySafetyPhrase.matches(expected: phrase, entered: "wrong-phrase"))
    }
}
