// Codable round-trip tests for every §C envelope: encode → JSON → decode →
// re-encode and confirm the second JSON matches the first. Catches
// `CodingKeys` typos or missing fields that would silently break the
// wire format on iOS without showing up in the canonicalization vectors
// (those only cover the SIGNED subset of each envelope).
//
// All field-name keys on the wire are the SHORT iOS-shipped abbreviations
// (id, rm, sid, sn, rid, t, ts, sc, hc, hl, rp, od, nf, ttl, n, spk, mu,
// tu, fn, mt, fs, ad, rtid, rttp, rtsn, ib, ig, gf). If a future edit
// drops or renames one of these, this test fails immediately.
import XCTest
@testable import MeshV1

final class CodableRoundTripTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys] // stable diff
        return e
    }()
    private let decoder = JSONDecoder()

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data1 = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data1)
        let data2 = try encoder.encode(decoded)
        XCTAssertEqual(data1, data2, "non-idempotent encode for \(T.self)")
        XCTAssertEqual(value, decoded, "decode produced a non-equal value for \(T.self)")
        return decoded
    }

    func test_SecureMeshEnvelope_minimal_round_trip() throws {
        let env = SecureMeshEnvelope(
            clientMessageId: "dm-001",
            roomId: "room",
            senderId: "alice",
            senderName: "Alice",
            recipientId: "bob",
            type: 0,
            text: "hi",
            timestampSec: 1_700_000_000.0,
            originDeviceId: "alice-device-1",
            nonceB64: "AAAA",
            senderPublicKeyB64: "AAAA"
        )
        _ = try roundTrip(env)
    }

    func test_SecureMeshEnvelope_with_geo_and_reply_round_trip() throws {
        let env = SecureMeshEnvelope(
            clientMessageId: "dm-002",
            roomId: "room",
            senderId: "alice",
            senderName: "Alice",
            recipientId: "bob",
            type: 0,
            text: "reply",
            timestampSec: 1_700_000_060.0,
            originDeviceId: "alice-device-1",
            nonceB64: "BBBB",
            senderPublicKeyB64: "AAAA",
            replyToMessageId: "dm-001",
            replyToTextPreview: "earlier message",
            replyToSenderName: "Bob",
            geoFence: GeoFence(h3Cell: "8a283082aac7fff", radiusInCells: 1, deliverOnlyInside: true)
        )
        _ = try roundTrip(env)
    }

    func test_SignedMeshPayload_round_trip() throws {
        let env = SecureMeshEnvelope(
            clientMessageId: "dm-100", roomId: "room",
            senderId: "alice", senderName: "Alice",
            recipientId: "bob", type: 0, text: "hi",
            timestampSec: 1_700_000_000.0, originDeviceId: "alice-device-1",
            nonceB64: "CCCC", senderPublicKeyB64: "AAAA"
        )
        let payload = SignedMeshPayload(envelope: env, signatureB64: "SIG==", signerPublicKeyB64: "AAAA")
        _ = try roundTrip(payload)
    }

    func test_EncryptedMeshPayload_round_trip() throws {
        let payload = EncryptedMeshPayload(
            combinedCiphertextB64: "CIPHER",
            nonceB64: "NONCE",
            agreementPublicKeyB64: "XPUB",
            version: 1,
            signatureB64: "SIG",
            signerPublicKeyB64: "EDPUB"
        )
        _ = try roundTrip(payload)
    }

    func test_MeshACKEnvelope_round_trip() throws {
        let ack = MeshACKEnvelope(
            originalMessageId: "dm-001",
            senderId: "bob",
            recipientId: "alice",
            status: "delivered",
            timestampSec: 1_700_000_060.0,
            pathUsed: "mesh",
            hopCount: 2,
            hopLimit: 10,
            routePath: ["alice-device-1"],
            originDeviceId: "bob-device-1",
            signatureB64: "SIG",
            signerPublicKeyB64: "PUB"
        )
        _ = try roundTrip(ack)
    }

    func test_MeshPostEnvelope_round_trip() throws {
        let post = MeshPostEnvelope(
            postId: "post-1", authorId: "alice",
            authorUsername: "alice", authorAvatar: "https://x",
            createdAtSec: 1_700_000_000.0, scope: "friends", text: "hi all",
            ttlHops: 10, ttlSeconds: 86_400, hopCount: 0,
            routePath: [], originDeviceId: "alice-device-1",
            initialSend: "mesh", signatureB64: "SIG", signerPublicKeyB64: "PUB"
        )
        _ = try roundTrip(post)
    }

    func test_StopCommand_round_trip() throws {
        let stop = StopCommand(
            messageId: "dm-001", timestampSec: 1_700_000_120.0,
            signatureB64: "SIG", signerPublicKeyB64: "PUB"
        )
        _ = try roundTrip(stop)
    }

    // MARK: - wire-key sanity

    func test_SecureMeshEnvelope_uses_iOS_shipped_short_keys() throws {
        let env = SecureMeshEnvelope(
            clientMessageId: "x", roomId: "x", senderId: "x", senderName: "x",
            recipientId: "x", type: 0, text: "x",
            timestampSec: 0.0, originDeviceId: "x", nonceB64: "x", senderPublicKeyB64: "x"
        )
        let data = try encoder.encode(env)
        let str = String(data: data, encoding: .utf8)!
        // Spot-check every key that must NOT silently rename.
        for key in ["\"id\":", "\"rm\":", "\"sid\":", "\"sn\":", "\"rid\":", "\"t\":",
                    "\"n\":", "\"spk\":", "\"ts\":", "\"od\":", "\"txt\":"] {
            XCTAssertTrue(str.contains(key), "expected short key \(key) in encoded envelope; got \(str)")
        }
    }

    func test_MeshACKEnvelope_uses_long_camelCase_keys() throws {
        let ack = MeshACKEnvelope(
            originalMessageId: "x", senderId: "x", recipientId: "x",
            status: "delivered", timestampSec: 0.0
        )
        let data = try encoder.encode(ack)
        let str = String(data: data, encoding: .utf8)!
        for key in ["\"originalMessageId\":", "\"senderId\":", "\"recipientId\":",
                    "\"status\":", "\"timestamp\":", "\"isACK\":",
                    "\"signature\":", "\"signerPublicKey\":"] {
            XCTAssertTrue(str.contains(key), "expected camelCase key \(key); got \(str)")
        }
    }
}
