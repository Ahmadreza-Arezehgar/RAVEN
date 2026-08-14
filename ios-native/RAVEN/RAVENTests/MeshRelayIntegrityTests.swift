// MeshRelayIntegrityTests.swift
//
// Does multi-hop mesh relay actually work?
//
// RAVEN's headline capability is delivering a message through intermediate
// devices when neither endpoint can reach the other. That only works if the
// ORIGIN's signature still verifies after a relay forwards the envelope: a
// relay re-wraps a `MeshEnvelope` into a `SecureMeshEnvelope` via
// `toSecureEnvelope()`, and the receiver checks `originalSignature` against the
// signing bytes it reconstructs from what arrived.
//
// `signingData()` binds `nonce` and `senderPublicKey`. Neither field exists on
// `MeshEnvelope`, so both are LOST the moment an envelope is relayed —
// `toSecureEnvelope()` mints a fresh random nonce and stamps the forwarding
// device's own key. The reconstructed bytes therefore differ from what the
// origin signed, and every honest multi-hop delivery is rejected.
//
// These tests pin the invariant that makes relay possible: an envelope that
// survives a hop must still produce the origin's signing bytes.
//
// Naming follows the existing MeshInteropVectorsTests style.

import XCTest
import CryptoKit
@testable import RAVEN

final class MeshRelayIntegrityTests: XCTestCase {

    /// Build the envelope an origin device would emit.
    private func makeOriginEnvelope() -> MeshEnvelope {
        MeshEnvelope(
            clientMessageId: "msg-relay-001",
            roomId: "room-alice-bob",
            senderId: "ALIC-EAAA-AAAA",
            senderName: "Alice",
            recipientId: "SARA-BBBB-BBBB",
            type: 0,
            text: "routed through a stranger's phone",
            // Must be recent: the decoder enforces a ±30-day wire bound, so a
            // hardcoded historical timestamp fails to decode on the relay path.
            timestamp: Date().timeIntervalSince1970,
            sprayCounter: 5,
            hopCount: 0,
            hopLimit: 10,
            routePath: [],
            originDeviceId: "device-alice",
            needsForwarding: true
        )
    }

    /// The signing bytes must be reproducible from what actually travels on the
    /// wire. If a field the signature covers is not carried by `MeshEnvelope`,
    /// a relay cannot reconstruct it and the origin signature is unverifiable
    /// by construction.
    func testRelayedEnvelopeReproducesOriginSigningBytes() throws {
        let origin = makeOriginEnvelope()

        // Origin wraps and signs.
        let originSecure = origin.toSecureEnvelope()
        let originBytes = originSecure.signingData()

        // A relay receives the MeshEnvelope, forwards it one hop, and re-wraps
        // it exactly as BLEMeshEngine does before re-broadcasting.
        let relayed = origin.forwarded(by: "device-relay")
        let relayedSecure = relayed.toSecureEnvelope()
        let relayedBytes = relayedSecure.signingData()

        XCTAssertEqual(
            originBytes, relayedBytes,
            """
            Relayed envelope does not reproduce the origin's signing bytes, so \
            `originalSignature` can never verify at hop >= 1 and every honest \
            multi-hop delivery is dropped. Fields bound by signingData() must \
            either be carried on MeshEnvelope or excluded from the signature.
            """
        )
    }

    /// The concrete end-to-end property: sign as the origin, relay one hop,
    /// verify as the recipient.
    func testOriginSignatureVerifiesAfterOneHop() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let origin = makeOriginEnvelope()

        let originSecure = origin.toSecureEnvelope()
        let signature = try signingKey.signature(for: originSecure.signingData())

        // One hop later, the receiver rebuilds the signing bytes from the
        // envelope it actually received.
        let relayedSecure = origin.forwarded(by: "device-relay").toSecureEnvelope()

        XCTAssertTrue(
            signingKey.publicKey.isValidSignature(signature, for: relayedSecure.signingData()),
            "Origin signature failed to verify after a single relay hop — multi-hop mesh relay is non-functional."
        )
    }

    /// Sanity check that the signature scheme itself is fine at hop 0, so a
    /// failure above is specifically about relaying rather than signing.
    func testOriginSignatureVerifiesAtZeroHops() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let secure = makeOriginEnvelope().toSecureEnvelope()
        let bytes = secure.signingData()
        let signature = try signingKey.signature(for: bytes)
        XCTAssertTrue(signingKey.publicKey.isValidSignature(signature, for: bytes))
    }

    /// The real relay path is JSON over BLE, so the origin bindings must
    /// survive an encode/decode round trip — a relay reconstructs the envelope
    /// from bytes, not from an in-process copy.
    func testOriginBindingsSurviveWireRoundTripAcrossMultipleHops() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let origin = makeOriginEnvelope()
        let signature = try signingKey.signature(for: origin.toSecureEnvelope().signingData())

        // Three relays, each decoding from the wire, forwarding, re-encoding.
        var current = origin
        for hop in 1...3 {
            let wire = try JSONEncoder().encode(current.forwarded(by: "relay-\(hop)"))
            current = try JSONDecoder().decode(MeshEnvelope.self, from: wire)

            XCTAssertEqual(current.hopCount, hop, "hop count did not advance")
            XCTAssertTrue(
                signingKey.publicKey.isValidSignature(
                    signature, for: current.toSecureEnvelope().signingData()),
                "Origin signature failed after \(hop) wire hop(s) — store-and-forward is broken."
            )
        }
    }

    /// A relay must not be able to substitute its own key for the origin's and
    /// still have the envelope verify.
    func testRelayCannotSubstituteOriginKey() throws {
        let originKey = Curve25519.Signing.PrivateKey()
        let attackerKey = Curve25519.Signing.PrivateKey()
        let origin = makeOriginEnvelope()
        let signature = try originKey.signature(for: origin.toSecureEnvelope().signingData())

        var tampered = origin.forwarded(by: "hostile-relay")
        tampered.originSenderPublicKey = attackerKey.publicKey.rawRepresentation.base64EncodedString()

        XCTAssertFalse(
            originKey.publicKey.isValidSignature(
                signature, for: tampered.toSecureEnvelope().signingData()),
            "Swapping the origin key left the signature valid — the binding is not enforced."
        )
    }

    /// Mutable routing metadata must NOT be bound into the signature, or an
    /// honest relay incrementing the hop count would invalidate it.
    func testRoutingMetadataIsNotBoundIntoSignature() {
        let origin = makeOriginEnvelope()
        var bumped = origin
        bumped.hopCount += 3
        bumped.sprayCounter = max(0, bumped.sprayCounter - 1)
        bumped.routePath = ["r1", "r2"]

        XCTAssertEqual(
            origin.toSecureEnvelope().signingData(),
            bumped.toSecureEnvelope().signingData(),
            "Mutable relay metadata is bound into the signature; honest forwarding would break it."
        )
    }
}
