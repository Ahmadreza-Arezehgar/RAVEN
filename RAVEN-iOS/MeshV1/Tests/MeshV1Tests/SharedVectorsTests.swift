// Cross-platform byte-exact tests against `shared-vectors/v1/` fixtures.
// Mirrors `RAVEN-Android/modules/mesh/src/test/kotlin/.../SharedVectorsTest.kt`.
//
// Vectors are copied into the test bundle by `Package.swift` and accessed via
// `Bundle.module`. To re-sync after a `generate_v1.py` update, run
// `tools/sync-vectors.sh`.
import XCTest
@testable import MeshV1

final class SharedVectorsTests: XCTestCase {

    // MARK: - Resource loading

    private func loadJSON(_ relativePath: String) throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "v1/" + relativePath.replacingOccurrences(of: ".json", with: ""),
                                    withExtension: "json")
            ?? Bundle.module.resourceURL?.appendingPathComponent("v1/" + relativePath)
        guard let url else {
            XCTFail("vector not found: \(relativePath)")
            throw NSError(domain: "MeshV1Tests", code: 404)
        }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("vector \(relativePath) is not a JSON object")
            throw NSError(domain: "MeshV1Tests", code: 400)
        }
        return obj
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func fromHex(_ s: String) -> Data {
        var bytes = [UInt8]()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            if let byte = UInt8(s[idx..<next], radix: 16) {
                bytes.append(byte)
            }
            idx = next
        }
        return Data(bytes)
    }

    // MARK: - Canonicalization

    func test_dm_pipe_001_no_geo_fence() throws {
        let v = try loadJSON("canonicalization/dm_pipe_001.json")
        let inputs = v["inputs"] as! [String: Any]
        let env = inputs["envelope"] as! [String: Any]
        let secure = SecureMeshEnvelope(
            clientMessageId: env["clientMessageId"] as! String,
            roomId: env["roomId"] as! String,
            senderId: env["senderId"] as! String,
            senderName: env["senderName"] as! String,
            recipientId: env["recipientId"] as! String,
            type: env["type"] as! Int,
            text: env["text"] as? String,
            timestampSec: Double(env["timestampMs"] as! Int64) / 1000.0,
            originDeviceId: env["originDeviceId"] as! String,
            nonceB64: env["nonceB64"] as! String,
            senderPublicKeyB64: env["senderPublicKeyB64"] as! String
        )
        let actual = DmSigningCanonicalizer.bytes(secure)
        let expected = (v["expected"] as! [String: Any])["signing_bytes_hex"] as! String
        XCTAssertEqual(hex(actual), expected)
    }

    func test_dm_pipe_002_with_geo_fence() throws {
        let v = try loadJSON("canonicalization/dm_pipe_002.json")
        let inputs = v["inputs"] as! [String: Any]
        let env = inputs["envelope"] as! [String: Any]
        let gf = env["geoFence"] as! [String: Any]
        let secure = SecureMeshEnvelope(
            clientMessageId: env["clientMessageId"] as! String,
            roomId: env["roomId"] as! String,
            senderId: env["senderId"] as! String,
            senderName: env["senderName"] as! String,
            recipientId: env["recipientId"] as! String,
            type: env["type"] as! Int,
            text: env["text"] as? String,
            timestampSec: Double(env["timestampMs"] as! Int64) / 1000.0,
            originDeviceId: env["originDeviceId"] as! String,
            nonceB64: env["nonceB64"] as! String,
            senderPublicKeyB64: env["senderPublicKeyB64"] as! String,
            geoFence: GeoFence(
                h3Cell: gf["h3Cell"] as! String,
                radiusInCells: gf["radiusInCells"] as! Int,
                deliverOnlyInside: gf["deliverOnlyInside"] as! Bool
            )
        )
        let actual = DmSigningCanonicalizer.bytes(secure)
        let expected = (v["expected"] as! [String: Any])["signing_bytes_hex"] as! String
        XCTAssertEqual(hex(actual), expected)
    }

    func test_post_pipe_001() throws {
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
        let actual = PostSigningCanonicalizer.bytes(post)
        XCTAssertEqual(hex(actual), (v["expected"] as! [String: Any])["signing_bytes_hex"] as! String)
    }

    func test_ack_pipe_001() throws {
        let v = try loadJSON("canonicalization/ack_pipe_001.json")
        let a = (v["inputs"] as! [String: Any])["ack"] as! [String: Any]
        let ack = MeshACKEnvelope(
            originalMessageId: a["originalMessageId"] as! String,
            senderId: a["senderId"] as! String,
            recipientId: a["recipientId"] as! String,
            status: a["status"] as! String,
            timestampSec: (a["timestampSec"] as! NSNumber).doubleValue
        )
        let actual = AckSigningCanonicalizer.bytes(ack)
        XCTAssertEqual(hex(actual), (v["expected"] as! [String: Any])["signing_bytes_hex"] as! String)
    }

    func test_stop_pipe_001() throws {
        let v = try loadJSON("canonicalization/stop_pipe_001.json")
        let s = (v["inputs"] as! [String: Any])["stop"] as! [String: Any]
        let stop = StopCommand(
            messageId: s["messageId"] as! String,
            timestampSec: (s["timestampSec"] as! NSNumber).doubleValue
        )
        let actual = StopSigningCanonicalizer.bytes(stop)
        XCTAssertEqual(hex(actual), (v["expected"] as! [String: Any])["signing_bytes_hex"] as! String)
    }

    func test_frame_json_001() throws {
        let v = try loadJSON("canonicalization/frame_json_001.json")
        let raw = (v["inputs"] as! [String: Any])["raw_frame"] as! [String: Any]
        let bytes = try FrameJsonCanonicalizer.bytes(rawFrame: raw)
        let expected = (v["expected"] as! [String: Any])["canonical_utf8"] as! String
        XCTAssertEqual(String(data: bytes, encoding: .utf8), expected)
    }

    // MARK: - Chunking

    func test_single_chunk_001() throws {
        let v = try loadJSON("chunking/single_chunk_001.json")
        let inputs = v["inputs"] as! [String: Any]
        let payload = Data((inputs["payload_utf8"] as! String).utf8)
        let encoded = Chunking.encodeUnchunked(payload)
        let expected = (v["expected"] as! [String: Any])["packet_hex"] as! String
        XCTAssertEqual(hex(encoded), expected)
    }

    func test_multi_chunk_001() throws {
        let v = try loadJSON("chunking/multi_chunk_001.json")
        let inputs = v["inputs"] as! [String: Any]
        let payload = fromHex(inputs["payload_hex"] as! String)
        let size = inputs["chunk_payload_size"] as! Int
        let hashHex = inputs["message_hash_hex"] as! String
        let hashBytes = fromHex(hashHex)
        // Hash is stored as the canonical 32-bit value (display order = BE); we feed it through encodeChunked which writes LE.
        let messageHash = (UInt32(hashBytes[0]) << 24)
            | (UInt32(hashBytes[1]) << 16)
            | (UInt32(hashBytes[2]) << 8)
            | UInt32(hashBytes[3])
        let chunks = Chunking.encodeChunked(payload, chunkPayloadSize: size, messageHash: messageHash)
        let expectedChunks = (v["expected"] as! [String: Any])["chunks_hex"] as! [String]
        XCTAssertEqual(chunks.count, expectedChunks.count)
        for (i, c) in chunks.enumerated() {
            XCTAssertEqual(hex(c), expectedChunks[i], "chunk \(i) mismatch")
        }
    }

    func test_multi_chunk_reassembly_001() throws {
        let v = try loadJSON("chunking/multi_chunk_reassembly_001.json")
        let inputs = v["inputs"] as! [String: Any]
        let chunks = (inputs["chunks_hex_in_arrival_order"] as! [String]).map { fromHex($0) }
        let sender = inputs["sender_device_id"] as! String
        let reassembler = ChunkReassembler { 0 }
        var out: Data?
        for packet in chunks {
            if case let .chunk(header, payload) = Chunking.decode(packet) {
                if let result = reassembler.accept(senderDeviceId: sender, header: header, payload: payload) {
                    out = result
                }
            }
        }
        XCTAssertNotNil(out)
        let expected = fromHex((v["expected"] as! [String: Any])["reassembled_hex"] as! String)
        XCTAssertEqual(out, expected)
    }

    // MARK: - Routing

    func test_dedup_keys_001() throws {
        let v = try loadJSON("routing/dedup_keys_001.json")
        let i = v["inputs"] as! [String: Any]
        let e = v["expected"] as! [String: Any]
        XCTAssertEqual(DedupKeys.signedDm(clientMessageId: i["client_message_id"] as! String),
                       e["signed_dm_key"] as! String)
        XCTAssertEqual(DedupKeys.encryptedDm(nonceB64: i["nonce_b64"] as! String),
                       e["encrypted_dm_key"] as! String)
        XCTAssertEqual(DedupKeys.post(i["post_id"] as! String), e["post_key"] as! String)
        XCTAssertEqual(
            DedupKeys.ack(originalMessageId: i["client_message_id"] as! String,
                          senderId: i["ack_sender_id"] as! String,
                          recipientId: i["ack_recipient_id"] as! String,
                          status: i["ack_status"] as! String),
            e["ack_key"] as! String
        )
        XCTAssertEqual(DedupKeys.stop(i["client_message_id"] as! String), e["stop_key"] as! String)
        XCTAssertEqual(DedupKeys.frame("frame-001"), e["frame_key"] as! String)
    }

    func test_spray_transition_001() throws {
        let v = try loadJSON("routing/spray_transition_001.json")
        let d = SprayAndWait.split(currentTokens: (v["inputs"] as! [String: Any])["current_tokens"] as! Int)
        let e = v["expected"] as! [String: Any]
        XCTAssertEqual(d.tokensToGive, e["tokens_to_give"] as! Int)
        XCTAssertEqual(d.tokensRemaining, e["tokens_remaining"] as! Int)
        XCTAssertEqual(d.inWaitPhase, e["in_wait_phase"] as! Bool)
    }

    func test_spray_transition_002() throws {
        let v = try loadJSON("routing/spray_transition_002.json")
        let d = SprayAndWait.split(currentTokens: (v["inputs"] as! [String: Any])["current_tokens"] as! Int)
        let e = v["expected"] as! [String: Any]
        XCTAssertEqual(d.tokensToGive, e["tokens_to_give"] as! Int)
        XCTAssertEqual(d.tokensRemaining, e["tokens_remaining"] as! Int)
        XCTAssertEqual(d.inWaitPhase, e["in_wait_phase"] as! Bool)
    }

    func test_pairing_code_001_alice_bob() throws {
        let v = try loadJSON("routing/pairing_code_001.json")
        let i = v["inputs"] as! [String: Any]
        let nonce = fromHex(i["nonce_hex"] as! String)
        let code = PairingCode.derive(pub1B64: i["pub1_b64"] as! String,
                                      pub2B64: i["pub2_b64"] as! String,
                                      nonce: nonce)
        let e = v["expected"] as! [String: Any]
        XCTAssertEqual(code, e["code_int"] as! Int)
        XCTAssertEqual(PairingCode.format(code), e["code_str"] as! String)
    }

    // MARK: - Crypto

    func test_fingerprint_001_alice() throws {
        let v = try loadJSON("crypto/fingerprint_001.json")
        let edPub = fromHex((v["inputs"] as! [String: Any])["ed_public_hex"] as! String)
        let actual = Fingerprint.fromEd25519PublicKey(edPub)
        XCTAssertEqual(actual, (v["expected"] as! [String: Any])["fingerprint"] as! String)
    }

    // MARK: - Trust (TOFU state machine — pure spec assertions)

    func test_tofu_first_sighting_001() throws {
        let v = try loadJSON("trust/tofu_first_sighting_001.json")
        let e = v["expected"] as! [String: Any]
        XCTAssertEqual(e["state"] as! String, "unverified")
        XCTAssertEqual(e["is_trusted_relay"] as! Bool, false)
    }

    func test_tofu_verify_001() throws {
        let v = try loadJSON("trust/tofu_verify_001.json")
        let e = v["expected"] as! [String: Any]
        XCTAssertEqual(e["state"] as! String, "verified")
        XCTAssertEqual(e["is_trusted_relay"] as! Bool, true)
    }
}
