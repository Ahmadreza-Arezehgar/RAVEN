//
//  RavenDeviceRevocationV1Tests.swift
//  RAVENTests
//
//  Cross-language KAT coverage for RavenDeviceRevocationV1 vector freeze.
//

import Foundation
import XCTest
@testable import RAVEN

final class RavenDeviceRevocationV1Tests: XCTestCase {

    private func vectorsRoot() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RAVENTests
            .deletingLastPathComponent() // RAVEN
            .deletingLastPathComponent() // ios-native
            .deletingLastPathComponent() // repository
            .appendingPathComponent("shared-vectors/rvn1/device_revocation")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private func negativeRoot() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared-vectors/rvn1/negative")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private func loadJSON(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func loadVector(_ name: String) throws -> [String: Any] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1/device_revocation not found")
        }
        return try loadJSON(at: root.appendingPathComponent(name))
    }

    private func hex(_ value: String) -> Data {
        precondition(value.count.isMultiple(of: 2))
        var result = Data(capacity: value.count / 2)
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let next = value.index(cursor, offsetBy: 2)
            result.append(UInt8(value[cursor..<next], radix: 16)!)
            cursor = next
        }
        return result
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    func testValid001Wire() throws {
        let vector = try loadVector("valid_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])
        let wire = hex(try XCTUnwrap(expected["wire_hex"] as? String))
        XCTAssertEqual(wire.count, expected["wire_len"] as? Int)

        let record = try RavenDeviceRevocationV1.decode(wire)
        XCTAssertEqual(String(data: record.deviceId, encoding: .utf8), inputs["device_id_utf8"] as? String)
        XCTAssertEqual(String(data: record.issuerDeviceId, encoding: .utf8), inputs["issuer_device_id_utf8"] as? String)
        XCTAssertEqual(record.identityAddress, inputs["identity_address"] as? String)
        XCTAssertEqual(record.issuerSeq, UInt64(try XCTUnwrap(inputs["issuer_seq"] as? Int)))
        XCTAssertEqual(record.reasonCode, UInt8(try XCTUnwrap(inputs["reason_code"] as? Int)))
        XCTAssertEqual(record.createdAtMs, UInt64(try XCTUnwrap(inputs["created_at_ms"] as? Int)))
        XCTAssertEqual(record.revocationId, hex(try XCTUnwrap(inputs["revocation_id_hex"] as? String)))
        XCTAssertEqual(record.signature, hex(try XCTUnwrap(expected["signature_hex"] as? String)))

        let signing = try RavenDeviceRevocationV1.signingBytes(record)
        XCTAssertEqual(signing, hex(try XCTUnwrap(expected["signing_bytes_hex"] as? String)))
        XCTAssertEqual(try RavenDeviceRevocationV1.encode(record), wire)

        try RavenDeviceRevocationV1.verify(
            record,
            identityEdPub: hex(try XCTUnwrap(inputs["identity_ed_pub_hex"] as? String))
        )
        XCTAssertEqual(
            RavenDeviceRevocationV1.claimDigest(wire),
            hex(try XCTUnwrap(expected["claim_digest_hex"] as? String))
        )

        let offsets = try dictionary(expected["offsets"])
        XCTAssertEqual(offsets["total_len"] as? Int, 276)
        XCTAssertEqual(offsets["device_id"] as? Int, 56)
        XCTAssertEqual(offsets["signature"] as? Int, 212)
    }

    func testStoreHash001() throws {
        let vector = try loadVector("store_hash_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])
        let wires = try XCTUnwrap(inputs["claims_wire_hex"] as? [String]).map(hex)
        let hash = try RavenDeviceRevocationV1.storeHash(
            generation: UInt64(try XCTUnwrap(inputs["generation"] as? Int)),
            claimWires: wires
        )
        XCTAssertEqual(hash, hex(try XCTUnwrap(expected["revocation_store_hash_hex"] as? String)))
    }

    func testStoreHashExhausted001() throws {
        let vector = try loadVector("store_hash_exhausted_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])
        let exhArr = try XCTUnwrap(inputs["exhausted"] as? [[String: Any]])
        let markers: [RavenDeviceRevocationV1.ExhaustedMarker] = try exhArr.map { row in
            let exact = hex(try XCTUnwrap(row["exact_record_bytes_hex"] as? String))
            return RavenDeviceRevocationV1.ExhaustedMarker(
                identityAddress: try XCTUnwrap(row["identity_address"] as? String),
                claimDigest: hex(try XCTUnwrap(row["claim_digest_hex"] as? String)),
                exactRecordBytes: exact
            )
        }
        let hash = try RavenDeviceRevocationV1.storeHash(
            generation: UInt64(try XCTUnwrap(inputs["generation"] as? Int)),
            claimWires: [],
            exhausted: markers
        )
        XCTAssertEqual(hash, hex(try XCTUnwrap(expected["revocation_store_hash_hex"] as? String)))
    }

    func testCrashReplayOrder001() throws {
        let vector = try loadVector("crash_replay_order_001.json")
        let steps = try XCTUnwrap(vector["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual(steps[1]["action"] as? String, "reverify_exact_bytes")
        XCTAssertEqual(steps[2]["action"] as? String, "journal_convert")
        XCTAssertEqual(steps[2]["from"] as? String, "PENDING_REVOKE_EXHAUSTED")
        XCTAssertEqual(steps[2]["to"] as? String, "PENDING_REVOKE")
        XCTAssertEqual(steps[2]["same_exact_bytes"] as? Bool, true)
        XCTAssertEqual(steps[3]["action"] as? String, "sql_atomic")
        let ops = try XCTUnwrap(steps[3]["ops"] as? [String])
        XCTAssertEqual(ops, [
            "insert_claim",
            "append_revoked_targets",
            "delete_IDENTITY_REVOKE_EXHAUSTED",
            "upsert_cleanup",
            "bump_generation",
        ])
        XCTAssertEqual(steps[4]["action"] as? String, "write_FINALIZED_REVOKE_ANCHOR")
        XCTAssertEqual(steps[5]["action"] as? String, "clear_PENDING_REVOKE")

        let after = try dictionary(vector["expected_after"])
        let wires = try XCTUnwrap(after["claims_wire_hex"] as? [String]).map(hex)
        let hash = try RavenDeviceRevocationV1.storeHash(
            generation: UInt64(try XCTUnwrap(after["generation"] as? Int)),
            claimWires: wires
        )
        XCTAssertEqual(hash, hex(try XCTUnwrap(after["revocation_store_hash_hex"] as? String)))
    }

    func testWrongSignerNegative() throws {
        guard let root = negativeRoot() else {
            throw XCTSkip("shared-vectors/rvn1/negative not found")
        }
        let vector = try loadJSON(at: root.appendingPathComponent("device_revocation_wrong_signer.json"))
        let inputs = try dictionary(vector["inputs"])
        let wire = hex(try XCTUnwrap(inputs["wire_hex"] as? String))
        let record = try RavenDeviceRevocationV1.decode(wire)
        XCTAssertThrowsError(
            try RavenDeviceRevocationV1.verify(
                record,
                identityEdPub: hex(try XCTUnwrap(inputs["claimed_identity_ed_pub_hex"] as? String))
            )
        )
    }
}
