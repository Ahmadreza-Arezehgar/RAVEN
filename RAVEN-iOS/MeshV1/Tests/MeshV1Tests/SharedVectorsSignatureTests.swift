// Asserts that the iOS Ed25519 + canonicalization pipeline produces
// VERIFIABLE signatures against the vectors in `shared-vectors/v1/`.
//
// Apple's `Curve25519.Signing` uses **randomized Ed25519** (hedge nonces for
// side-channel and faulty-RNG defense), so iOS signatures over the same
// (key, message) are NOT byte-identical to the deterministic signatures
// the Python regenerator and BouncyCastle (Android) produce. They are,
// however, all valid Ed25519 signatures — every conforming verifier
// (Apple, BC, OpenSSL, libsodium) accepts them.
//
// What we test here:
//   1. The canonical bytes match the fixtures (covered in SharedVectorsTests).
//   2. The fixture's deterministic signature still verifies under Apple's API.
//   3. iOS-produced signatures round-trip via Apple's own verifier.
//   4. Tampered inputs fail verification.
//
// Byte equality of iOS-produced signatures is NOT asserted by design.
import CryptoKit
import XCTest
@testable import MeshV1

final class SharedVectorsSignatureTests: XCTestCase {

    private func loadJSON(_ rel: String) throws -> [String: Any] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("v1/" + rel)
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func fromHex(_ s: String) -> Data {
        var out = [UInt8]()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            if let b = UInt8(s[idx..<next], radix: 16) { out.append(b) }
            idx = next
        }
        return Data(out)
    }

    private lazy var identities: [String: [String: Any]] = {
        let url = Bundle.module.resourceURL!.appendingPathComponent("v1/identities.json")
        let data = try! Data(contentsOf: url)
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return root["identities"] as! [String: [String: Any]]
    }()

    private func privKey(_ id: String) -> Data { fromHex(identities[id]!["ed_private_hex"] as! String) }
    private func pubKey(_ id: String) -> Data { Data(base64Encoded: identities[id]!["ed_public_b64"] as! String)! }

    // ----- canonical Python-derived signatures still verify on Apple -----

    func test_dm_pipe_001_python_signature_verifies_on_apple() throws {
        let v = try loadJSON("canonicalization/dm_pipe_001.json")
        let env = buildSecureEnvelope((v["inputs"] as! [String: Any])["envelope"] as! [String: Any], geo: nil)
        let expectedSig = fromHex((v["expected"] as! [String: Any])["signature_hex"] as! String)
        XCTAssertTrue(MeshSigner.verifyDm(env, signature: expectedSig, publicKey: pubKey("alice")))
    }

    func test_dm_pipe_002_python_signature_verifies_with_geo() throws {
        let v = try loadJSON("canonicalization/dm_pipe_002.json")
        let envJson = (v["inputs"] as! [String: Any])["envelope"] as! [String: Any]
        let gf = envJson["geoFence"] as! [String: Any]
        let env = buildSecureEnvelope(envJson, geo: GeoFence(
            h3Cell: gf["h3Cell"] as! String,
            radiusInCells: gf["radiusInCells"] as! Int,
            deliverOnlyInside: gf["deliverOnlyInside"] as! Bool
        ))
        let expected = fromHex((v["expected"] as! [String: Any])["signature_hex"] as! String)
        XCTAssertTrue(MeshSigner.verifyDm(env, signature: expected, publicKey: pubKey("alice")))
    }

    func test_post_pipe_001_python_signature_verifies() throws {
        let v = try loadJSON("canonicalization/post_pipe_001.json")
        let p = (v["inputs"] as! [String: Any])["post"] as! [String: Any]
        let post = MeshPostEnvelope(
            postId: p["postId"] as! String,
            authorId: p["authorId"] as! String,
            authorUsername: p["authorUsername"] as! String,
            authorAvatar: p["authorAvatar"] as? String,
            createdAtSec: (p["createdAtSec"] as! NSNumber).doubleValue,
            scope: p["scope"] as! String,
            text: p["text"] as! String,
            signerPublicKeyB64: p["signerPublicKeyB64"] as? String
        )
        let expected = fromHex((v["expected"] as! [String: Any])["signature_hex"] as! String)
        XCTAssertTrue(MeshSigner.verifyPost(post, signature: expected, publicKey: pubKey("alice")))
    }

    func test_ack_pipe_001_python_signature_verifies() throws {
        let v = try loadJSON("canonicalization/ack_pipe_001.json")
        let a = (v["inputs"] as! [String: Any])["ack"] as! [String: Any]
        let ack = MeshACKEnvelope(
            originalMessageId: a["originalMessageId"] as! String,
            senderId: a["senderId"] as! String,
            recipientId: a["recipientId"] as! String,
            status: a["status"] as! String,
            timestampSec: (a["timestampSec"] as! NSNumber).doubleValue
        )
        let expected = fromHex((v["expected"] as! [String: Any])["signature_hex"] as! String)
        XCTAssertTrue(MeshSigner.verifyAck(ack, signature: expected, publicKey: pubKey("bob")))
    }

    func test_stop_pipe_001_python_signature_verifies() throws {
        let v = try loadJSON("canonicalization/stop_pipe_001.json")
        let s = (v["inputs"] as! [String: Any])["stop"] as! [String: Any]
        let stop = StopCommand(
            messageId: s["messageId"] as! String,
            timestampSec: (s["timestampSec"] as! NSNumber).doubleValue
        )
        let expected = fromHex((v["expected"] as! [String: Any])["signature_hex"] as! String)
        XCTAssertTrue(MeshSigner.verifyStop(stop, signature: expected, publicKey: pubKey("alice")))
    }

    // ----- iOS-produced signatures round-trip via Apple's verifier -----

    func test_dm_apple_sign_then_apple_verify_round_trip() throws {
        let v = try loadJSON("canonicalization/dm_pipe_001.json")
        let env = buildSecureEnvelope((v["inputs"] as! [String: Any])["envelope"] as! [String: Any], geo: nil)
        let sig = try MeshSigner.signDm(env, privateKey: privKey("alice"))
        XCTAssertTrue(MeshSigner.verifyDm(env, signature: sig, publicKey: pubKey("alice")))
    }

    func test_post_apple_sign_then_apple_verify_round_trip() throws {
        let v = try loadJSON("canonicalization/post_pipe_001.json")
        let p = (v["inputs"] as! [String: Any])["post"] as! [String: Any]
        let post = MeshPostEnvelope(
            postId: p["postId"] as! String,
            authorId: p["authorId"] as! String,
            authorUsername: p["authorUsername"] as! String,
            authorAvatar: p["authorAvatar"] as? String,
            createdAtSec: (p["createdAtSec"] as! NSNumber).doubleValue,
            scope: p["scope"] as! String,
            text: p["text"] as! String,
            signerPublicKeyB64: p["signerPublicKeyB64"] as? String
        )
        let sig = try MeshSigner.signPost(post, privateKey: privKey("alice"))
        XCTAssertTrue(MeshSigner.verifyPost(post, signature: sig, publicKey: pubKey("alice")))
    }

    // ----- tampered inputs fail verification -----

    func test_dm_tampered_text_fails_verification() throws {
        let v = try loadJSON("canonicalization/dm_pipe_001.json")
        var env = buildSecureEnvelope((v["inputs"] as! [String: Any])["envelope"] as! [String: Any], geo: nil)
        let originalSig = fromHex((v["expected"] as! [String: Any])["signature_hex"] as! String)
        env.text = "hello from BOB"
        XCTAssertFalse(MeshSigner.verifyDm(env, signature: originalSig, publicKey: pubKey("alice")))
    }

    func test_crypto_ed25519_verify_001_positive_and_tampered() throws {
        let v = try loadJSON("crypto/ed25519_verify_001.json")
        let pub = fromHex((v["inputs"] as! [String: Any])["public_key_hex"] as! String)
        let msg = Data(((v["inputs"] as! [String: Any])["message_utf8"] as! String).utf8)
        let sig = fromHex((v["inputs"] as! [String: Any])["signature_hex"] as! String)
        let tampered = Data(((v["inputs"] as! [String: Any])["tampered_message_utf8"] as! String).utf8)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: pub)
        XCTAssertTrue(key.isValidSignature(sig, for: msg))
        XCTAssertFalse(key.isValidSignature(sig, for: tampered))
    }

    // ----- helpers -----

    private func buildSecureEnvelope(_ envJson: [String: Any], geo: GeoFence?) -> SecureMeshEnvelope {
        SecureMeshEnvelope(
            clientMessageId: envJson["clientMessageId"] as! String,
            roomId: envJson["roomId"] as! String,
            senderId: envJson["senderId"] as! String,
            senderName: envJson["senderName"] as! String,
            recipientId: envJson["recipientId"] as! String,
            type: envJson["type"] as! Int,
            text: envJson["text"] as? String,
            timestampSec: Double(envJson["timestampMs"] as! Int64) / 1000.0,
            originDeviceId: envJson["originDeviceId"] as! String,
            nonceB64: envJson["nonceB64"] as! String,
            senderPublicKeyB64: envJson["senderPublicKeyB64"] as! String,
            geoFence: geo
        )
    }
}
