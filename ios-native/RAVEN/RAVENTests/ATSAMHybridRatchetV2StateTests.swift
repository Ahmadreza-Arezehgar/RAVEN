//
//  ATSAMHybridRatchetV2StateTests.swift
//  RAVENTests
//

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

final class ATSAMHybridRatchetV2StateTests: XCTestCase {

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
        guard let root = vectorsRoot() else { throw XCTSkip("vectors missing") }
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
        XCTAssertFalse(ATSAMHybridRatchetV2State.productionEnabled)
    }

    func testBraidEpoch001() throws {
        let v = try loadVector("tr_braid_epoch_001.json")
        let inputs = try dict(v["inputs"])
        let expected = try dict(v["expected"])
        let out = try ATSAMHybridRatchetV2State.runBraidEpochMatrix(
            skScka: hex(try XCTUnwrap(inputs["sk_scka_hex"] as? String)),
            ss1: hex(try XCTUnwrap(inputs["ss_epoch1_hex"] as? String)),
            ss2: hex(try XCTUnwrap(inputs["ss_epoch2_hex"] as? String))
        )
        let e1 = try dict(out["epoch1"])
        let x1 = try dict(expected["epoch1"])
        XCTAssertEqual(e1["rk_hex"] as? String, x1["rk_hex"] as? String)
        XCTAssertEqual(e1["alice_ck_send_hex"] as? String, x1["alice_ck_send_hex"] as? String)
        XCTAssertEqual(e1["bob_ck_recv_hex"] as? String, x1["bob_ck_recv_hex"] as? String)
        XCTAssertEqual(e1["mk_hex"] as? String, x1["mk_hex"] as? String)
        XCTAssertEqual(e1["alice_send_equals_bob_recv"] as? Bool, true)
        let e2 = try dict(out["epoch2"])
        let x2 = try dict(expected["epoch2"])
        XCTAssertEqual(e2["rk_hex"] as? String, x2["rk_hex"] as? String)
        XCTAssertEqual(e2["bob_ck_send_hex"] as? String, x2["bob_ck_send_hex"] as? String)
        XCTAssertEqual(e2["alice_ck_recv_hex"] as? String, x2["alice_ck_recv_hex"] as? String)
        XCTAssertEqual(e2["mk_hex"] as? String, x2["mk_hex"] as? String)
        XCTAssertEqual(e2["bob_send_equals_alice_recv"] as? Bool, true)
    }

    func testEcOoo001() throws {
        let v = try loadVector("tr_ec_ooo_001.json")
        let inputs = try dict(v["inputs"])
        let expected = try dict(v["expected"])
        let out = try ATSAMHybridRatchetV2State.runEcOooMatrix(
            ck0: hex(try XCTUnwrap(inputs["ck_hex"] as? String)),
            dhPub: hex(try XCTUnwrap(inputs["dh_pub_hex"] as? String))
        )
        XCTAssertEqual(out["ooo_ok"] as? Bool, true)
        XCTAssertEqual(out["recovered_mks_hex"] as? [String], expected["recovered_mks_hex"] as? [String])
        XCTAssertEqual(out["send_mks_hex"] as? [String], expected["send_mks_hex"] as? [String])
        XCTAssertEqual(out["final_skipped_count"] as? Int, expected["final_skipped_count"] as? Int)
    }

    func testSkipBoundary001() throws {
        let v = try loadVector("tr_skip_boundary_001.json")
        let inputs = try dict(v["inputs"])
        let expected = try dict(v["expected"])
        let out = ATSAMHybridRatchetV2State.runSkipBoundary(
            ck0: hex(try XCTUnwrap(inputs["ck_hex"] as? String)),
            dhPub: hex(try XCTUnwrap(inputs["dh_pub_hex"] as? String))
        )
        let cases = try XCTUnwrap(out["cases"] as? [[String: Any]])
        let expCases = try XCTUnwrap(expected["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, expCases.count)
        for (got, want) in zip(cases, expCases) {
            XCTAssertEqual(got["skip_count"] as? Int, want["skip_count"] as? Int)
            XCTAssertEqual(got["result"] as? String, want["result"] as? String)
            if (want["result"] as? String) == "ok" {
                XCTAssertEqual(got["final_ck_hex"] as? String, want["final_ck_hex"] as? String)
                XCTAssertEqual(got["first_mk_hex"] as? String, want["first_mk_hex"] as? String)
                XCTAssertEqual(got["last_mk_hex"] as? String, want["last_mk_hex"] as? String)
            } else {
                XCTAssertEqual(got["state_unchanged"] as? Bool, true)
                XCTAssertEqual(got["allocation"] as? Bool, false)
                XCTAssertEqual(got["state_advance"] as? Bool, false)
            }
        }
    }

    func testReplayDuplicate001() throws {
        let v = try loadVector("tr_replay_duplicate_001.json")
        let inputs = try dict(v["inputs"])
        let expected = try dict(v["expected"])
        let accept = try dict(inputs["accept_key"])
        let key = ATSAMHybridRatchetV2State.AcceptKey(
            sessionId: hex(try XCTUnwrap(inputs["session_id_hex"] as? String)),
            dhPub: hex(try XCTUnwrap(inputs["dh_pub_hex"] as? String)),
            n: UInt32(try XCTUnwrap(accept["n"] as? Int)),
            sckaEpoch: UInt32(try XCTUnwrap(accept["scka_epoch"] as? Int)),
            sckaCtr: UInt32(try XCTUnwrap(accept["scka_ctr"] as? Int))
        )
        let digest = hex(try XCTUnwrap(inputs["object_digest_hex"] as? String))
        let ack = hex(try XCTUnwrap(inputs["retained_ack_hex"] as? String))
        var ledger = ATSAMHybridRatchetV2State.CommitLedger()
        let (l1, r1) = ATSAMHybridRatchetV2State.commitAccept(ledger, key: key, objectDigest: digest, retainedAck: ack)
        ledger = l1
        let fp1 = ledger.fingerprint()
        let (l2, r2) = ATSAMHybridRatchetV2State.commitAccept(ledger, key: key, objectDigest: digest, retainedAck: ack)
        let fp2 = l2.fingerprint()
        let dup = ATSAMHybridRatchetV2State.duplicateAckExact(l2, objectDigest: digest)
        XCTAssertEqual(r1, expected["first_result"] as? String)
        XCTAssertEqual(r2, expected["replay_result"] as? String)
        XCTAssertEqual(fp1.hexString, expected["fp_after_accept_hex"] as? String)
        XCTAssertEqual(fp2.hexString, expected["fp_after_replay_hex"] as? String)
        XCTAssertEqual(fp1, fp2)
        XCTAssertEqual(dup, ack)
        XCTAssertEqual(l2.mutationCount, 1)
    }

    func testTamperCandidate001() throws {
        let v = try loadVector("tr_tamper_candidate_001.json")
        let inputs = try dict(v["inputs"])
        let expected = try dict(v["expected"])
        let key = hex(try XCTUnwrap(inputs["aead_key_hex"] as? String))
        let nonce = hex(try XCTUnwrap(inputs["nonce_hex"] as? String))
        let ct = hex(try XCTUnwrap(inputs["ciphertext_hex"] as? String))
        let aad = hex(try XCTUnwrap(inputs["aad_hex"] as? String))
        let live = hex(try XCTUnwrap(inputs["live_fp_hex"] as? String))

        let good = ATSAMHybridRatchetV2State.candidateDecrypt(
            key: key, nonce: nonce, ciphertext: ct, aad: aad, liveFp: live
        )
        XCTAssertEqual(good["open_result"] as? String, "ok")
        XCTAssertEqual(good["promote_live_head"] as? Bool, true)

        let cases: [(String, Data, Data, Data, Data)] = [
            ("bad_ciphertext", key, nonce, Data(ct.dropLast()) + Data([ct.last! ^ 0x01]), aad),
            ("bad_nonce", key, Data([nonce[0] ^ 0x01]) + Data(nonce.dropFirst()), ct, aad),
            ("bad_aad_header", key, nonce, ct, Data(aad.dropLast()) + Data([aad.last! ^ 0x01])),
            ("wrong_root_key", Data(SHA256.hash(data: key)), nonce, ct, aad),
        ]
        for (name, k, n, c, a) in cases {
            let got = ATSAMHybridRatchetV2State.candidateDecrypt(
                key: k, nonce: n, ciphertext: c, aad: a, liveFp: live
            )
            let want = try dict(expected[name])
            XCTAssertEqual(got["open_result"] as? String, want["open_result"] as? String, name)
            XCTAssertEqual(got["promote_live_head"] as? Bool, false, name)
            XCTAssertEqual(got["durable_mutation"] as? Bool, false, name)
            XCTAssertEqual(got["live_fp_after_hex"] as? String, live.hexString, name)
        }
    }

    func testRouteMailbox001() throws {
        let v = try loadVector("tr_route_mailbox_001.json")
        let inputs = try dict(v["inputs"])
        let expected = try dict(v["expected"])
        let master = hex(try XCTUnwrap(inputs["k_route_master_hex"] as? String))
        let sid = hex(try XCTUnwrap(inputs["session_id_hex"] as? String))
        let kr0 = try ATSAMHybridRatchetV2State.kRoute(kRouteMaster: master, direction: 0)
        let kr1 = try ATSAMHybridRatchetV2State.kRoute(kRouteMaster: master, direction: 1)
        let created = UInt64(try XCTUnwrap(inputs["created_at_ms"] as? Int))
        let n = UInt64(try XCTUnwrap(inputs["n"] as? Int))
        let appType = UInt8(try XCTUnwrap(inputs["app_type"] as? Int))
        let r0 = ATSAMHybridRatchetV2State.routingTag(
            kRouteD: kr0, createdAtMs: created, n: n, appType: appType, direction: 0, sessionId: sid
        )
        let r1 = ATSAMHybridRatchetV2State.routingTag(
            kRouteD: kr1, createdAtMs: created, n: n, appType: appType, direction: 1, sessionId: sid
        )
        let now = UInt64(try XCTUnwrap(inputs["now_ms"] as? Int))
        let m0 = ATSAMHybridRatchetV2State.mailboxTag(kRouteD: kr0, unixMs: now, direction: 0, sessionId: sid)
        let s0 = ATSAMHybridRatchetV2State.storeTag(m0)
        let plan = ATSAMHybridRatchetV2State.mailboxCatchupPlan(
            nowMs: Int64(now),
            catchupCursorDay: Int64(try XCTUnwrap(inputs["catchup_cursor_day"] as? Int)),
            mailboxTtlDays: Int64(try XCTUnwrap(inputs["mailbox_ttl_days"] as? Int))
        )
        XCTAssertEqual(kr0.hexString, expected["k_route_0_hex"] as? String)
        XCTAssertEqual(kr1.hexString, expected["k_route_1_hex"] as? String)
        XCTAssertEqual(r0.hexString, expected["routing_tag_d0_hex"] as? String)
        XCTAssertEqual(r1.hexString, expected["routing_tag_d1_hex"] as? String)
        XCTAssertNotEqual(r0, r1)
        XCTAssertEqual(m0.hexString, expected["mailbox_tag_d0_hex"] as? String)
        XCTAssertEqual(s0.hexString, expected["store_tag_d0_hex"] as? String)
        let catchup = try dict(expected["catchup"])
        XCTAssertEqual(plan.today, Int64(try XCTUnwrap(catchup["today"] as? Int)))
        XCTAssertEqual(plan.ttlHorizon, Int64(try XCTUnwrap(catchup["ttl_horizon"] as? Int)))
        XCTAssertEqual(plan.historicalDays.map { Int($0) }, catchup["historical_days"] as? [Int])
        XCTAssertEqual(plan.alwaysRepollDays.map { Int($0) }, catchup["always_repoll_days"] as? [Int])
        XCTAssertEqual(plan.lateArrivalFloor, Int64(try XCTUnwrap(catchup["late_arrival_floor"] as? Int)))
        XCTAssertEqual(plan.ttlHorizon, Int64(try XCTUnwrap(catchup["ttl_horizon"] as? Int)))
        XCTAssertEqual(plan.historicalDays.count, catchup["historical_span"] as? Int)
        XCTAssertGreaterThanOrEqual(plan.historicalDays.count, 7)
    }

    private func runCrash(_ name: String) throws -> ATSAMHybridRatchetV2State.ReceiveCommitMachine {
        let v = try loadVector(name)
        let steps = try XCTUnwrap(v["steps"] as? [[String: Any]])
        var m = ATSAMHybridRatchetV2State.ReceiveCommitMachine()
        for step in steps {
            try m.apply(try XCTUnwrap(step["action"] as? String))
        }
        XCTAssertEqual(m.state, "cleared")
        let negatives = try XCTUnwrap(v["negatives"] as? [String])
        for neg in negatives {
            var bad = ATSAMHybridRatchetV2State.ReceiveCommitMachine()
            XCTAssertThrowsError(try bad.apply(neg))
        }
        return m
    }

    func testCrashReceiveCommit001() throws {
        let m = try runCrash("tr_crash_receive_commit_001.json")
        XCTAssertTrue(m.durableMutation)
        XCTAssertEqual(m.generation, 1)
    }

    func testCrashSkippedPersist001() throws {
        let m = try runCrash("tr_crash_skipped_persist_001.json")
        XCTAssertTrue(m.skippedPersisted)
    }

    func testCrashEpochPromote001() throws {
        let m = try runCrash("tr_crash_epoch_promote_001.json")
        XCTAssertTrue(m.epochPromoted)
        XCTAssertTrue(m.durableMutation)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
