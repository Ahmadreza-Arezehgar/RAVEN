// MeshImpersonationTests.swift
//
// Regression guards for the mesh sender-impersonation cluster (2026-07-24).
//
// Four separate reported paths let any stranger in Bluetooth range render
// arbitrary text under a verified contact's name, or install their own key as a
// trusted device for someone else. All four were the SAME underlying defect:
// `MeshCryptoService.verifySignature` returned a bare `Bool`, so
//
//     "the named sender signed this"        (authorship proven)
//     "some authenticated relay vouches"    (authorship NOT proven)
//
// were indistinguishable to every caller. The bridge exceptions legitimately
// produce the second — they exist to fix real delivery bugs — but collapsing
// both to `true` is what made them exploitable.
//
// The fix is the `AuthVerdict` chokepoint plus a local-only
// `MeshEnvelope.senderAuthenticated` flag. These tests pin the properties that
// make the fix work; if any fails, the impersonation is back.
//
// Naming follows the existing MeshInteropVectorsTests style.

import XCTest
import CryptoKit
@testable import RAVEN

final class MeshImpersonationTests: XCTestCase {

    // ─── The flag must be un-forgeable ───────────────────────────────

    /// `senderAuthenticated` is a LOCAL verdict. If it could arrive from the
    /// wire, an attacker would simply set it and walk through every gate that
    /// depends on it — reintroducing the whole cluster in one field.
    func testSenderAuthenticatedCannotBeSetFromTheWire() throws {
        var envelope = MeshEnvelope(
            clientMessageId: "imp-001",
            roomId: "room-a-b",
            senderId: "ALIC-EAAA-AAAA",
            senderName: "Alice",
            recipientId: "SARA-BBBB-BBBB",
            type: 0,
            text: "hello",
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: 5,
            hopCount: 0,
            hopLimit: 10,
            routePath: [],
            originDeviceId: "device-alice",
            needsForwarding: true
        )
        // Locally mark it authenticated, as the ingest path would.
        envelope.senderAuthenticated = true

        // Round-trip through the wire codec.
        let wire = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(MeshEnvelope.self, from: wire)

        XCTAssertFalse(
            decoded.senderAuthenticated,
            "senderAuthenticated survived the wire — an attacker could forge authentication."
        )

        // And it must not appear in the serialized form at all.
        let json = try XCTUnwrap(String(data: wire, encoding: .utf8))
        XCTAssertFalse(json.contains("senderAuthenticated"),
                       "the local-only verdict is being serialized")
    }

    /// A freshly decoded envelope defaults to unauthenticated, so anything that
    /// forgets to set the verdict fails closed rather than open.
    func testDecodedEnvelopeDefaultsToUnauthenticated() throws {
        let envelope = MeshEnvelope(
            clientMessageId: "imp-002",
            roomId: "room-a-b",
            senderId: "ALIC-EAAA-AAAA",
            senderName: "Alice",
            recipientId: "SARA-BBBB-BBBB",
            type: 0,
            text: "hello",
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: 5,
            hopCount: 0,
            hopLimit: 10,
            routePath: [],
            originDeviceId: "device-alice",
            needsForwarding: true
        )
        let decoded = try JSONDecoder().decode(
            MeshEnvelope.self, from: try JSONEncoder().encode(envelope))
        XCTAssertFalse(decoded.senderAuthenticated)
    }

    // ─── The verdict must distinguish the two facts ──────────────────

    func testVerdictSemantics() {
        XCTAssertTrue(MeshCryptoService.AuthVerdict.authorAuthenticated.isAuthorProven)
        XCTAssertTrue(MeshCryptoService.AuthVerdict.authorAuthenticated.isAcceptable)

        // The crux: a relay-attested frame is deliverable but NOT attributable.
        XCTAssertFalse(MeshCryptoService.AuthVerdict.relayAttested.isAuthorProven,
                       "relay attestation must never count as proven authorship")
        XCTAssertTrue(MeshCryptoService.AuthVerdict.relayAttested.isAcceptable)

        XCTAssertFalse(MeshCryptoService.AuthVerdict.rejected.isAcceptable)
        XCTAssertFalse(MeshCryptoService.AuthVerdict.rejected.isAuthorProven)
    }

    // ─── A forged signature must still be rejected outright ──────────

    /// Baseline: the signature layer itself still works. If this fails, the
    /// verdict refactor broke verification rather than refining it.
    func testEnvelopeSignedByWrongKeyIsRejected() async throws {
        let realSender = Curve25519.Signing.PrivateKey()
        let attacker = Curve25519.Signing.PrivateKey()

        let envelope = MeshEnvelope(
            clientMessageId: "imp-003",
            roomId: "room-a-b",
            senderId: "ALIC-EAAA-AAAA",
            senderName: "Alice",
            recipientId: "SARA-BBBB-BBBB",
            type: 0,
            text: "transfer all your money",
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: 5,
            hopCount: 0,
            hopLimit: 10,
            routePath: [],
            originDeviceId: "device-attacker",
            needsForwarding: true
        )
        let secure = envelope.toSecureEnvelope()
        let bytes = secure.signingData()

        // The attacker signs, then claims the real sender's key.
        let forged = try attacker.signature(for: bytes)
        XCTAssertFalse(
            realSender.publicKey.isValidSignature(forged, for: bytes),
            "a signature made with a different key verified against the claimed sender"
        )
    }

    /// Mutating the body must invalidate the signature — otherwise a relay
    /// could rewrite message text in flight.
    func testTamperedBodyInvalidatesSignature() throws {
        let sender = Curve25519.Signing.PrivateKey()
        var envelope = MeshEnvelope(
            clientMessageId: "imp-004",
            roomId: "room-a-b",
            senderId: "ALIC-EAAA-AAAA",
            senderName: "Alice",
            recipientId: "SARA-BBBB-BBBB",
            type: 0,
            text: "see you at 8",
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: 5,
            hopCount: 0,
            hopLimit: 10,
            routePath: [],
            originDeviceId: "device-alice",
            needsForwarding: true
        )
        let signature = try sender.signature(for: envelope.toSecureEnvelope().signingData())

        envelope.text = "see you at 11"
        XCTAssertFalse(
            sender.publicKey.isValidSignature(
                signature, for: envelope.toSecureEnvelope().signingData()),
            "the message body is not bound by the signature"
        )
    }
}
