//
//  ATSAMHybridRatchetV2TRTests.swift
//  RAVENTests
//

import Foundation
import XCTest
@testable import RAVEN

final class ATSAMHybridRatchetV2TRTests: XCTestCase {

    private func vectorsRoot() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared-vectors/rvn1/atsam")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private func loadVector(_ name: String) throws -> [String: Any] {
        guard let root = vectorsRoot() else { throw XCTSkip("shared-vectors/rvn1/atsam not found") }
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

    private func dict(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    func testProductionOff() {
        XCTAssertFalse(ATSAMHybridRatchetV2TR.productionEnabled)
    }

    func testEcDhRatchet001() throws {
        let vector = try loadVector("tr_ec_dh_ratchet_001.json")
        let inputs = try dict(vector["inputs"])
        let expected = try dict(vector["expected"])

        let out = try ATSAMHybridRatchetV2TR.runEcDhRatchetMatrix(
            rk0: hex(try XCTUnwrap(inputs["rk0_hex"] as? String)),
            alicePriv0: hex(try XCTUnwrap(inputs["alice_priv0_hex"] as? String)),
            bobPriv0: hex(try XCTUnwrap(inputs["bob_priv0_hex"] as? String)),
            bobPriv1: hex(try XCTUnwrap(inputs["bob_priv1_hex"] as? String)),
            alicePriv1: hex(try XCTUnwrap(inputs["alice_priv1_hex"] as? String))
        )

        XCTAssertEqual(out["cross_boundary_ok"] as? Bool, true)
        XCTAssertEqual(out["alice_pub0_hex"] as? String, expected["alice_pub0_hex"] as? String)
        XCTAssertEqual(out["bob_pub0_hex"] as? String, expected["bob_pub0_hex"] as? String)
        XCTAssertEqual(out["bob_pub1_hex"] as? String, expected["bob_pub1_hex"] as? String)
        XCTAssertEqual(out["alice_pub1_hex"] as? String, expected["alice_pub1_hex"] as? String)
        XCTAssertEqual(out["alice_mks_hex"] as? [String], expected["alice_mks_hex"] as? [String])
        XCTAssertEqual(out["bob_recovered_mks_hex"] as? [String], expected["bob_recovered_mks_hex"] as? [String])
        XCTAssertEqual(out["bob_send_mk_hex"] as? String, expected["bob_send_mk_hex"] as? String)
        XCTAssertEqual(out["alice_recovered_bob_mk_hex"] as? String, expected["alice_recovered_bob_mk_hex"] as? String)
        XCTAssertEqual(out["final_alice_fp_hex"] as? String, expected["final_alice_fp_hex"] as? String)
        XCTAssertEqual(out["final_bob_fp_hex"] as? String, expected["final_bob_fp_hex"] as? String)
        XCTAssertEqual(out["recv_order"] as? [Int], expected["recv_order"] as? [Int])

        let neg = try dict(out["negatives"])
        let expNeg = try dict(expected["negatives"])
        XCTAssertTrue((neg["all_zero_pub"] as? String)?.contains("rejected") == true)
        XCTAssertTrue((neg["all_zero_priv"] as? String)?.contains("rejected") == true)
        XCTAssertEqual(neg["all_zero_pub"] as? String, expNeg["all_zero_pub"] as? String)
        XCTAssertEqual(neg["all_zero_priv"] as? String, expNeg["all_zero_priv"] as? String)
    }

    func testBraidKemChunk001() throws {
        guard let root = vectorsRoot() else { throw XCTSkip("shared-vectors/rvn1/atsam not found") }
        let vector = try loadVector("tr_braid_kem_chunk_001.json")
        let inputs = try dict(vector["inputs"])
        let expected = try dict(vector["expected"])

        let out = try ATSAMHybridRatchetV2TR.runBraidKemChunkMatrix(
            sessionId: hex(try XCTUnwrap(inputs["session_id_hex"] as? String)),
            skScka: hex(try XCTUnwrap(inputs["sk_scka_hex"] as? String)),
            vectorsRoot: root
        )

        XCTAssertEqual(out["reassembled_ct_ok"] as? Bool, true)
        XCTAssertEqual(out["tamper_result"] as? String, "braid chunk tamper")
        XCTAssertEqual(out["prev_dk_zeroed"] as? Bool, true)
        XCTAssertEqual(out["epoch_promoted"] as? Bool, true)
        XCTAssertEqual(out["chunk_count"] as? Int, expected["chunk_count"] as? Int)
        XCTAssertEqual(out["chunk_size"] as? Int, expected["chunk_size"] as? Int)
        XCTAssertEqual(out["ct_len"] as? Int, expected["ct_len"] as? Int)
        XCTAssertEqual(out["ek_len"] as? Int, expected["ek_len"] as? Int)
        XCTAssertEqual(out["z_pq_hex"] as? String, expected["z_pq_hex"] as? String)
        XCTAssertEqual(out["scka_rk_hex"] as? String, expected["scka_rk_hex"] as? String)
        XCTAssertEqual(out["alice_ck_send_hex"] as? String, expected["alice_ck_send_hex"] as? String)
        XCTAssertEqual(out["bob_ck_recv_hex"] as? String, expected["bob_ck_recv_hex"] as? String)
        XCTAssertEqual(out["first_chunk_wire_hex"] as? String, expected["first_chunk_wire_hex"] as? String)
        XCTAssertEqual(out["deliver_order"] as? [Int], expected["deliver_order"] as? [Int])
        XCTAssertEqual(out["hdr_chunk_type"] as? Int, expected["hdr_chunk_type"] as? Int)
        XCTAssertEqual(out["ct1_chunk_type"] as? Int, expected["ct1_chunk_type"] as? Int)
        XCTAssertEqual(out["ct2_chunk_type"] as? Int, expected["ct2_chunk_type"] as? Int)
    }

    func testBraidCodecNegatives001() throws {
        let vector = try loadVector("tr_braid_codec_negatives_001.json")
        let inputs = try dict(vector["inputs"])
        let expected = try dict(vector["expected"])

        let out = try ATSAMHybridRatchetV2TR.runBraidCodecNegatives(
            sessionId: hex(try XCTUnwrap(inputs["session_id_hex"] as? String))
        )

        XCTAssertEqual(out["braid_header_len"] as? Int, expected["braid_header_len"] as? Int)
        XCTAssertEqual(out["braid_digest_len"] as? Int, expected["braid_digest_len"] as? Int)
        XCTAssertEqual(out["braid_max_payload"] as? Int, expected["braid_max_payload"] as? Int)
        XCTAssertEqual(out["braid_max_chunks"] as? Int, expected["braid_max_chunks"] as? Int)
        XCTAssertEqual(out["braid_max_total_bytes"] as? Int, expected["braid_max_total_bytes"] as? Int)
        XCTAssertEqual(out["max_mkskipped_retained"] as? Int, expected["max_mkskipped_retained"] as? Int)
        XCTAssertEqual(out["epoch_type"] as? String, expected["epoch_type"] as? String)
        XCTAssertEqual(out["mlkem768_header_size"] as? Int, expected["mlkem768_header_size"] as? Int)
        XCTAssertEqual(out["mlkem768_ek_vector_size"] as? Int, expected["mlkem768_ek_vector_size"] as? Int)
        XCTAssertEqual(out["mlkem768_ek_fips_size"] as? Int, expected["mlkem768_ek_fips_size"] as? Int)
        XCTAssertEqual(out["mlkem768_ct1_size"] as? Int, expected["mlkem768_ct1_size"] as? Int)
        XCTAssertEqual(out["mlkem768_ct2_size"] as? Int, expected["mlkem768_ct2_size"] as? Int)

        let cases = try XCTUnwrap(out["cases"] as? [[String: Any]])
        let expCases = try XCTUnwrap(expected["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, expCases.count)
        for (got, want) in zip(cases, expCases) {
            XCTAssertEqual(got["name"] as? String, want["name"] as? String)
            XCTAssertEqual(got["result"] as? String, want["result"] as? String)
            if let reason = want["reason"] as? String {
                XCTAssertEqual(got["reason"] as? String, reason)
            }
            if let note = want["note"] as? String {
                XCTAssertEqual(got["note"] as? String, note)
            }
        }
    }

    func testTrComboMulti001() throws {
        let vector = try loadVector("tr_combo_multi_001.json")
        let inputs = try dict(vector["inputs"])
        let expected = try dict(vector["expected"])

        let out = try ATSAMHybridRatchetV2TR.runTrComboMatrix(
            skEc: hex(try XCTUnwrap(inputs["sk_ec_hex"] as? String)),
            skScka: hex(try XCTUnwrap(inputs["sk_scka_hex"] as? String)),
            sessionId: hex(try XCTUnwrap(inputs["session_id_hex"] as? String)),
            alicePriv0: hex(try XCTUnwrap(inputs["alice_priv0_hex"] as? String)),
            bobPriv0: hex(try XCTUnwrap(inputs["bob_priv0_hex"] as? String)),
            bobPriv1: hex(try XCTUnwrap(inputs["bob_priv1_hex"] as? String)),
            alicePriv1: hex(try XCTUnwrap(inputs["alice_priv1_hex"] as? String)),
            ssScka1: hex(try XCTUnwrap(inputs["ss_scka1_hex"] as? String)),
            ssScka2: hex(try XCTUnwrap(inputs["ss_scka2_hex"] as? String))
        )

        XCTAssertEqual(out["dh_epochs"] as? Int, 2)
        XCTAssertEqual(out["scka_epochs"] as? Int, 2)
        XCTAssertEqual(out["session_id_hex"] as? String, expected["session_id_hex"] as? String)
        XCTAssertEqual(out["final_alice_ec_fp_hex"] as? String, expected["final_alice_ec_fp_hex"] as? String)
        XCTAssertEqual(out["final_bob_ec_fp_hex"] as? String, expected["final_bob_ec_fp_hex"] as? String)

        let steps = try XCTUnwrap(out["steps"] as? [[String: Any]])
        let expSteps = try XCTUnwrap(expected["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.count, expSteps.count)
        for (got, want) in zip(steps, expSteps) {
            XCTAssertEqual(got["phase"] as? String, want["phase"] as? String)
            XCTAssertEqual(got["hybrid_key_hex"] as? String, want["hybrid_key_hex"] as? String)
            if let rk = want["rk_hex"] as? String {
                XCTAssertEqual(got["rk_hex"] as? String, rk)
                XCTAssertEqual(got["alice_send_equals_bob_recv"] as? Bool, want["alice_send_equals_bob_recv"] as? Bool)
            }
            if let alicePub = want["alice_dh_pub1_hex"] as? String {
                XCTAssertEqual(got["alice_dh_pub1_hex"] as? String, alicePub)
                XCTAssertEqual(got["bob_dh_pub1_hex"] as? String, want["bob_dh_pub1_hex"] as? String)
                XCTAssertEqual(got["bob_send_equals_alice_recv"] as? Bool, want["bob_send_equals_alice_recv"] as? Bool)
            }
        }
    }
}
