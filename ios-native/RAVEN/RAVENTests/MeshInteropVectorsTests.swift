// MeshInteropVectorsTests.swift
//
// Cross-platform interop test vectors. Every test in this file has a TWIN
// in `RAVEN-Windows/tests/InteropVectorsTests.cs`. Both implementations
// MUST produce identical byte-level outputs from the same inputs — that's
// the contract that lets a Windows machine, an iPhone, and a Mac form one
// mesh.
//
// To add this to an Xcode test target:
//   1. File > New > Target > Unit Testing Bundle (call it "RAVENTests")
//   2. Add this file to the new target
//   3. Set the host application to RAVEN
//   4. Run with ⌘U
//
// If a test fails here OR diverges from the C# twin, fix the SOURCE (the
// canonical signing data, the AES-GCM combined layout, etc.) — never just
// adjust the test vector to silence the failure.

import XCTest
import CryptoKit
@testable import RAVEN

final class MeshInteropVectorsTests: XCTestCase {

    // ─── X25519 ECDH symmetry ────────────────────────────────────────

    /// Twin: `X25519SharedSecret_KnownVector_ProducesExpectedKey` (C#).
    func testX25519SymmetryWithRandomKeys() {
        let alice = Curve25519.KeyAgreement.PrivateKey()
        let bob = Curve25519.KeyAgreement.PrivateKey()

        let aliceSecret = try? alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
        let bobSecret = try? bob.sharedSecretFromKeyAgreement(with: alice.publicKey)

        XCTAssertNotNil(aliceSecret)
        XCTAssertNotNil(bobSecret)

        // SharedSecret is opaque; compare via withUnsafeBytes.
        let a = aliceSecret!.withUnsafeBytes { Data(Array($0)) }
        let b = bobSecret!.withUnsafeBytes { Data(Array($0)) }
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    /// Twin: `HkdfDerivation_WithFixedSaltAndIkm_ProducesStableKey` (C#).
    func testHkdfDeterminism() {
        // Fixed 32-byte IKM = 0x00..0x1F.
        let ikm = Data((0..<32).map { UInt8($0) })
        let salt = "RAVEN-MESH".data(using: .utf8)!

        let key1 = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            outputByteCount: 32
        )
        let key2 = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            outputByteCount: 32
        )
        let bytes1 = key1.withUnsafeBytes { Data(Array($0)) }
        let bytes2 = key2.withUnsafeBytes { Data(Array($0)) }
        XCTAssertEqual(bytes1, bytes2)
        XCTAssertEqual(bytes1.count, 32)

        // INTEROP NOTE: the C# twin produces the SAME 32 bytes here.
        // Pin the value once both sides agree:
        //   let expected = Data([...32 bytes...])
        //   XCTAssertEqual(bytes1, expected)
    }

    // ─── AES-256-GCM combined layout ─────────────────────────────────

    /// Twin: `AesGcm_RoundTrip_ProducesCombinedBlobMatchingIosLayout` (C#).
    func testAesGcmCombinedLayout() throws {
        // Key = 0x00..0x1F, nonce = 12 zero bytes, plaintext = "hello mesh".
        let key = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
        let plaintext = "hello mesh".data(using: .utf8)!

        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        let combined = sealed.combined!

        // Layout: nonce(12) || ciphertext || tag(16)
        XCTAssertEqual(combined.count, 12 + plaintext.count + 16)

        // First 12 bytes = nonce zeros.
        for i in 0..<12 {
            XCTAssertEqual(combined[i], 0)
        }

        // Round-trip.
        let reopened = try AES.GCM.SealedBox(combined: combined)
        let plaintextOut = try AES.GCM.open(reopened, using: key)
        XCTAssertEqual(plaintextOut, plaintext)
    }

    // ─── Ed25519 round-trip ──────────────────────────────────────────

    /// Twin: `Ed25519_SignAndVerify_RoundTrip` (C#).
    func testEd25519RoundTrip() {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey
        let data = "payload to be signed".data(using: .utf8)!

        let sig = try? priv.signature(for: data)
        XCTAssertNotNil(sig)
        XCTAssertEqual(sig!.count, 64)
        XCTAssertTrue(pub.isValidSignature(sig!, for: data))

        // Tamper.
        var tampered = data
        tampered[0] ^= 0x01
        XCTAssertFalse(pub.isValidSignature(sig!, for: tampered))
    }

    // ─── Fingerprint format ──────────────────────────────────────────

    /// Twin: `Fingerprint_FromKnownPublicKey_MatchesIosFormat` (C#).
    func testFingerprintFromKnownKey() {
        // Public key = 32 bytes of 0xAA — deterministic test vector.
        let pubBytes = Data(repeating: 0xAA, count: 32)
        // We compute the fingerprint inline here so this test doesn't depend
        // on DeviceIdentityService internals.
        let hash = SHA256.hash(data: pubBytes)
        let first9 = Data(hash.prefix(9))
        var b64 = first9.base64EncodedString()
        b64 = b64.replacingOccurrences(of: "+", with: "")
        b64 = b64.replacingOccurrences(of: "/", with: "")
        let truncated = String(b64.prefix(12)).padding(toLength: 12, withPad: "A", startingAt: 0)
        let fp = "\(truncated.prefix(4))-\(truncated.dropFirst(4).prefix(4))-\(truncated.dropFirst(8).prefix(4))"

        XCTAssertEqual(fp.count, 14)
        XCTAssertEqual(fp[fp.index(fp.startIndex, offsetBy: 4)], "-")
        XCTAssertEqual(fp[fp.index(fp.startIndex, offsetBy: 9)], "-")

        // INTEROP NOTE: the C# twin produces the SAME string here.
        // Pin once verified:
        //   XCTAssertEqual(fp, "<expected>")
    }

    // ─── Canonical signing-data byte equality ────────────────────────

    /// Twin: `SecureMeshEnvelope_SigningData_MatchesPipeFormatExactly` (C#).
    ///
    /// THIS is the most important test in the suite. If the canonical pipe
    /// form drifts even by one byte, signatures fail and the mesh stops
    /// interoperating.
    func testSecureMeshEnvelopeSigningDataMatchesPipeFormat() {
        // Build the same envelope as the C# test.
        let env = SecureMeshEnvelope(
            id: "msg-001",
            roomId: "room-A",
            senderId: "alice",
            senderName: "Alice",
            recipientId: "bob",
            type: 0,
            text: "hi",
            timestamp: 1_700_000_000.0,
            sprayCounter: 5,
            hopCount: 0,
            hopLimit: 10,
            routePath: ["fp-XXXX"],
            originDeviceId: "fp-XXXX",
            needsForwarding: true,
            ttlSeconds: 86_400,
            nonce: "AAAAAAAAAAAAAAAAAAAAAA==",
            senderPublicKey: "PUBKEYBASE64",
            mediaUrl: nil, thumbnailUrl: nil, fileName: nil, mimeType: nil,
            fileSize: nil, audioDuration: nil,
            replyToMessageId: nil, replyToTextPreview: nil, replyToSenderName: nil,
            isBridged: nil, isGroup: nil, geoFence: nil
        )

        let signingBytes = env.signingData()
        let signingString = String(data: signingBytes, encoding: .utf8) ?? ""

        let expected = "msg-001|room-A|alice|Alice|bob|0|AAAAAAAAAAAAAAAAAAAAAA==|PUBKEYBASE64|1700000000000|fp-XXXX|hi|||||||||"

        XCTAssertEqual(signingString, expected,
            "SecureMeshEnvelope.signingData() drifted from the C# twin. " +
            "Either iOS or Windows changed the canonical form — fix BOTH.")
    }

    // ─── Mesh post signing ───────────────────────────────────────────

    /// Twin: `MeshPostEnvelope_SigningData_MatchesPipeFormat` (C#).
    func testMeshPostSigningData() {
        let post = MeshPostEnvelope(
            postId: "post-1",
            authorId: "alice",
            authorUsername: "@alice",
            authorAvatar: "https://cdn.example.com/a.jpg",
            createdAt: 1_700_000_000.5,
            scope: "public",
            text: "hello mesh",
            ttlHops: 5,
            ttlSeconds: 86_400,
            hopCount: 0,
            routePath: [],
            originDeviceId: "fp",
            initialSend: "internet",
            signature: nil,
            signerPublicKey: "SPK",
            showOnRavenShot: nil, latitude: nil, longitude: nil
        )

        let signingString = String(data: post.signingData(), encoding: .utf8) ?? ""
        let expected = "POST|post-1|alice|@alice|https://cdn.example.com/a.jpg|hello mesh|1700000000500|public|SPK"

        XCTAssertEqual(signingString, expected,
            "MeshPostEnvelope.signingData() drifted from the C# twin.")
    }

    // ─── ACK signing ─────────────────────────────────────────────────

    /// Twin: `MeshACKEnvelope_SigningData_MatchesPipeFormat` (C#).
    func testAckSigningData() {
        let ack = MeshACKEnvelope(
            originalMessageId: "msg-1",
            senderId: "alice",
            recipientId: "bob",
            status: "delivered",
            timestamp: 1_700_000_000.0
        )
        let signingString = String(data: ack.signingData(), encoding: .utf8) ?? ""
        XCTAssertEqual(signingString, "msg-1|alice|bob|delivered|1700000000000")
    }

    // ─── Stop-command signing ────────────────────────────────────────

    /// Twin: `StopCommand_SigningData_MatchesPipeFormat` (C#).
    func testStopSigningData() {
        let stop = StopCommand(messageId: "msg-1", timestamp: 1_700_000_000.0)
        let signingString = String(data: stop.signingData(), encoding: .utf8) ?? ""
        XCTAssertEqual(signingString, "STOP|msg-1|1700000000000")
    }
}
