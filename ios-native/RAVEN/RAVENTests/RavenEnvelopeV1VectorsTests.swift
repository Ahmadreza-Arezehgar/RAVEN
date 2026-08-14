//
//  RavenEnvelopeV1VectorsTests.swift
//  RAVENTests — shared-vectors/rvn1 envelope + address parity with Rust/Python.
//

import XCTest
import CryptoKit
@testable import RAVEN

final class RavenEnvelopeV1VectorsTests: XCTestCase {

    private func vectorsRoot() -> URL? {
        // Prefer monorepo shared-vectors when running from source tree.
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // RAVENTests
                .deletingLastPathComponent() // RAVEN
                .deletingLastPathComponent() // ios-native
                .deletingLastPathComponent() // repo
                .appendingPathComponent("shared-vectors/rvn1"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func loadJSON(_ rel: String) throws -> [String: Any] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1 not found — open monorepo checkout")
        }
        let url = root.appendingPathComponent(rel)
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    private func hex(_ s: String) -> Data {
        var data = Data()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            data.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return data
    }

    private func structurallyValidEnvelope() -> RavenEnvelopeV1 {
        RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            messageId: Data(repeating: 0x11, count: 16),
            routingTag: Data(repeating: 0x22, count: 16),
            createdAtMs: 10,
            expiresAtMs: 20,
            hopLimit: 8,
            replicationBudget: 3,
            antiReplayNonce: Data(repeating: 0x33, count: 12),
            ratchetHeaderCiphertext: Data(repeating: 0x44, count: 3),
            messageCiphertext: Data(repeating: 0x55, count: 5),
            // Structure decoding checks the canonical signature width.
            // Authenticity remains the caller's subsequent endpoint check.
            senderAuthentication: Data(repeating: 0, count: 64)
        )
    }

    func testAliceAddressMatchesVector() throws {
        let v = try loadJSON("address/encode_alice.json")
        let inputs = v["inputs"] as! [String: Any]
        let expected = v["expected"] as! [String: Any]
        let ed = hex(inputs["ed_public_hex"] as! String)
        let addr = RavenAddressV1.encode(ed25519PublicKey: ed)
        XCTAssertEqual(addr, expected["address"] as? String)
    }

    func testRoutingTagMatchesFrozenVectors() throws {
        let first = try loadJSON("routing/tag_alice_bob_000.json")
        let firstInputs = first["inputs"] as! [String: Any]
        let firstExpected = first["expected"] as! [String: Any]
        let key = hex(firstInputs["k_route_hex"] as! String)
        let epoch = firstInputs["epoch"] as! UInt64
        let firstCounter = firstInputs["counter"] as! UInt64
        let firstTag = try XCTUnwrap(
            RavenRoutingTagV1.derive(kRoute: key, epoch: epoch, counter: firstCounter)
        )
        XCTAssertEqual(
            firstTag.map { String(format: "%02x", $0) }.joined(),
            firstExpected["tag_hex"] as? String
        )

        let second = try loadJSON("routing/tag_unlinkable_001.json")
        let secondInputs = second["inputs"] as! [String: Any]
        let secondExpected = second["expected"] as! [String: Any]
        let secondTag = try XCTUnwrap(
            RavenRoutingTagV1.derive(
                kRoute: key,
                epoch: secondInputs["epoch"] as! UInt64,
                counter: secondInputs["counter"] as! UInt64
            )
        )
        XCTAssertEqual(
            secondTag.map { String(format: "%02x", $0) }.joined(),
            secondExpected["tag_hex"] as? String
        )
        XCTAssertTrue(RavenRoutingTagV1.matches(firstTag, firstTag))
        XCTAssertFalse(RavenRoutingTagV1.matches(firstTag, secondTag))
    }

    func testEnvelopePackSignMatchesVector() throws {
        let v = try loadJSON("envelope/message_alice_to_bob.json")
        let inputs = v["inputs"] as! [String: Any]
        let expected = v["expected"] as! [String: Any]

        var nonce = Data(repeating: 0, count: 12)
        nonce[11] = 1

        var env = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            flags: 0,
            messageId: hex(inputs["message_id_hex"] as! String),
            routingTag: hex(inputs["routing_tag_hex"] as! String),
            destDeviceHint: 0,
            createdAtMs: inputs["created_at_ms"] as! UInt64,
            expiresAtMs: inputs["expires_at_ms"] as! UInt64,
            hopLimit: 8,
            replicationBudget: 3,
            antiReplayNonce: nonce,
            ratchetHeaderCiphertext: hex(inputs["ratchet_header_ciphertext_hex"] as! String),
            messageCiphertext: hex(inputs["message_ciphertext_hex"] as! String)
        )

        XCTAssertEqual(
            env.signingBytes().map { String(format: "%02x", $0) }.joined(),
            expected["signing_bytes_hex"] as? String
        )

        // Alice RFC-8032 seed. CryptoKit may emit a *randomized* Ed25519
        // signature (still verifies under the same public key), so we do not
        // assert byte-identical auth vs dalek/Python — only verify + wire layout.
        let seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let sk = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        env.sign(with: sk)
        let pub = hex(inputs["signer_ed_public_hex"] as! String)
        let pk = try Curve25519.Signing.PublicKey(rawRepresentation: pub)
        XCTAssertTrue(env.verify(publicKey: pk))

        let packed = env.pack()
        let roundtrip = try XCTUnwrap(RavenEnvelopeV1.unpack(packed))
        XCTAssertEqual(roundtrip.messageId, env.messageId)
        XCTAssertEqual(roundtrip.messageCiphertext, env.messageCiphertext)
        XCTAssertTrue(roundtrip.verify(publicKey: pk))

        // Shared-vector packed bytes (dalek signature) must also verify on iOS.
        let vectorPacked = hex(expected["packed_hex"] as! String)
        let fromVector = try XCTUnwrap(RavenEnvelopeV1.unpack(vectorPacked))
        XCTAssertTrue(fromVector.verify(publicKey: pk))
        XCTAssertEqual(
            fromVector.senderAuthentication.map { String(format: "%02x", $0) }.joined(),
            expected["sender_authentication_hex"] as? String
        )    }

    func testBadMagicRejected() throws {
        let v = try loadJSON("negative/envelope_bad_magic.json")
        let inputs = v["inputs"] as! [String: Any]
        let raw = hex(inputs["packed_hex"] as! String)
        XCTAssertNil(RavenEnvelopeV1.unpack(raw))
    }

    func testStrictUnpackAcceptsRegisteredTypeAndDefinedFlags() {
        var envelope = structurallyValidEnvelope()
        envelope.envType = RavenEnvelopeV1.EnvType.capabilities.rawValue
        envelope.flags = 0b0000_0011

        XCTAssertEqual(RavenEnvelopeV1.unpack(envelope.pack()), envelope)
    }

    func testStrictUnpackRejectsUnknownTypeAndReservedFlags() {
        let packed = structurallyValidEnvelope().pack()

        for unknownType: UInt8 in [0, 5, .max] {
            var malformed = packed
            malformed[5] = unknownType
            XCTAssertNil(RavenEnvelopeV1.unpack(malformed))
        }

        var reservedFlags = packed
        reservedFlags.replaceSubrange(6..<8, with: [0x00, 0x04])
        XCTAssertNil(RavenEnvelopeV1.unpack(reservedFlags))
    }

    func testStrictUnpackRequiresCanonicalAuthenticationLength() {
        var envelope = structurallyValidEnvelope()
        envelope.senderAuthentication = Data(repeating: 0, count: 63)
        XCTAssertNil(RavenEnvelopeV1.unpack(envelope.pack()))

        envelope.senderAuthentication = Data()
        XCTAssertNil(RavenEnvelopeV1.unpack(envelope.pack()))
    }

    func testStrictUnpackRejectsNonIncreasingTimeInterval() {
        var envelope = structurallyValidEnvelope()
        envelope.expiresAtMs = envelope.createdAtMs
        XCTAssertNil(RavenEnvelopeV1.unpack(envelope.pack()))

        envelope.expiresAtMs = envelope.createdAtMs - 1
        XCTAssertNil(RavenEnvelopeV1.unpack(envelope.pack()))
    }

    func testStrictUnpackRejectsLengthAbuseAndOversizedFrames() {
        var impossibleBody = structurallyValidEnvelope().pack()
        impossibleBody.replaceSubrange(80..<84, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertNil(RavenEnvelopeV1.unpack(impossibleBody))

        let oversized = Data(repeating: 0, count: RavenEnvelopeV1.maximumWireLength + 1)
        XCTAssertNil(RavenEnvelopeV1.unpack(oversized))
    }

    func testTamperedBodyFailsVerify() throws {
        let v = try loadJSON("negative/envelope_tampered_body.json")
        let inputs = v["inputs"] as! [String: Any]
        let raw = hex(inputs["packed_hex"] as! String)
        let env = try XCTUnwrap(RavenEnvelopeV1.unpack(raw))
        let pub = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let pk = try Curve25519.Signing.PublicKey(rawRepresentation: pub)
        XCTAssertFalse(env.verify(publicKey: pk))
    }

    func testRelayObjectDigestIgnoresHopMutationButNotBodyCollision() {
        let signer = Curve25519.Signing.PrivateKey()
        var first = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.message.rawValue,
            messageId: Data(repeating: 0x11, count: 16),
            routingTag: Data(repeating: 0x22, count: 16),
            createdAtMs: 10,
            expiresAtMs: 20,
            hopLimit: 8,
            replicationBudget: 3,
            antiReplayNonce: Data(repeating: 0x33, count: 12),
            messageCiphertext: Data("first".utf8)
        )
        first.sign(with: signer)

        var forwarded = first
        forwarded.destDeviceHint = 99
        forwarded.hopLimit = 1
        forwarded.replicationBudget = 1
        XCTAssertEqual(first.relayObjectDigest(), forwarded.relayObjectDigest())

        var collision = first
        collision.messageCiphertext = Data("second".utf8)
        collision.sign(with: signer)
        XCTAssertEqual(collision.messageId, first.messageId)
        XCTAssertNotEqual(collision.relayObjectDigest(), first.relayObjectDigest())
    }
}
