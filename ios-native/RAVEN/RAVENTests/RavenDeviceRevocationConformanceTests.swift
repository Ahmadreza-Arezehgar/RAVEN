//
//  RavenDeviceRevocationConformanceTests.swift
//  RAVENTests
//

import Foundation
import XCTest
@testable import RAVEN

final class RavenDeviceRevocationConformanceTests: XCTestCase {

    private func vectorsRoot() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared-vectors/rvn1/device_revocation")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private func load(_ name: String) throws -> [String: Any] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1/device_revocation not found")
        }
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

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func assertRevokedTargets(
        _ store: RavenDeviceRevocationConformance.Store,
        expected: [[String: Any]]
    ) {
        let got = store.revoked.sorted {
            ($0.claimDigestHex, $0.kind, $0.valueHex) < ($1.claimDigestHex, $1.kind, $1.valueHex)
        }
        XCTAssertEqual(got.count, expected.count)
        for (g, exp) in zip(got, expected) {
            XCTAssertEqual(g.kind, exp["kind"] as? String)
            XCTAssertEqual(g.valueHex, exp["value_hex"] as? String)
            XCTAssertEqual(g.claimDigestHex, exp["claim_digest_hex"] as? String)
            XCTAssertEqual(g.revocationIdHex, exp["revocation_id_hex"] as? String)
        }
    }

    private func assertCollisions(
        _ store: RavenDeviceRevocationConformance.Store,
        expected: [[String: Any]]
    ) {
        XCTAssertEqual(store.collisions.count, expected.count)
        for (g, exp) in zip(store.collisions, expected) {
            XCTAssertEqual(g.id, exp["revocation_id_hex"] as? String)
            XCTAssertEqual(g.first, exp["first_claim_digest_hex"] as? String)
            XCTAssertEqual(g.second, exp["second_claim_digest_hex"] as? String)
        }
    }

    private func peer(_ dict: [String: Any]) throws -> (Data, Data, Data, Data) {
        (
            Data(try XCTUnwrap(dict["device_id_utf8"] as? String).utf8),
            hex(try XCTUnwrap(dict["device_ed_pub_hex"] as? String)),
            hex(try XCTUnwrap(dict["device_x_pub_hex"] as? String)),
            hex(try XCTUnwrap(dict["device_cert_hash_hex"] as? String))
        )
    }

    func testUnion001() throws {
        let v = try load("union_001.json")
        let inputs = try dictionary(v["inputs"])
        let storeExpected = try dictionary(try dictionary(v["expected"])["store"])
        let store = RavenDeviceRevocationConformance.Store(
            identityAddress: try XCTUnwrap(inputs["identity_address"] as? String),
            maxClaims: 10_000
        )
        let pub = hex(try XCTUnwrap(inputs["identity_ed_pub_hex"] as? String))
        var results: [String] = []
        for hx in try XCTUnwrap(inputs["claims_wire_hex"] as? [String]) {
            results.append(
                try RavenDeviceRevocationConformance.apply(
                    store: store, wire: hex(hx), identityEdPub: pub
                ).rawValue
            )
        }
        XCTAssertEqual(results, ["applied", "applied"])
        XCTAssertEqual(
            try store.storeHash(),
            hex(try XCTUnwrap(storeExpected["revocation_store_hash_hex"] as? String))
        )
        assertRevokedTargets(
            store,
            expected: try XCTUnwrap(storeExpected["revoked_targets"] as? [[String: Any]])
        )
        assertCollisions(
            store,
            expected: try XCTUnwrap(storeExpected["revocation_id_collisions"] as? [[String: Any]])
        )
    }

    func testCollisionRevocationId001() throws {
        let v = try load("collision_revocation_id_001.json")
        let inputs = try dictionary(v["inputs"])
        let storeExpected = try dictionary(try dictionary(v["expected"])["store"])
        let store = RavenDeviceRevocationConformance.Store(
            identityAddress: try XCTUnwrap(inputs["identity_address"] as? String),
            maxClaims: 10_000
        )
        let pub = hex(try XCTUnwrap(inputs["identity_ed_pub_hex"] as? String))
        for hx in try XCTUnwrap(inputs["claims_wire_hex"] as? [String]) {
            _ = try RavenDeviceRevocationConformance.apply(
                store: store, wire: hex(hx), identityEdPub: pub
            )
        }
        XCTAssertEqual(
            try store.storeHash(),
            hex(try XCTUnwrap(storeExpected["revocation_store_hash_hex"] as? String))
        )
        assertRevokedTargets(
            store,
            expected: try XCTUnwrap(storeExpected["revoked_targets"] as? [[String: Any]])
        )
        assertCollisions(
            store,
            expected: try XCTUnwrap(storeExpected["revocation_id_collisions"] as? [[String: Any]])
        )
    }

    func testQuotaMachine001() throws {
        let v = try load("quota_machine_001.json")
        let gates = try load("apply_gates_001.json")
        let inputs = try dictionary(v["inputs"])
        let after = try dictionary(v["expected_after"])
        let store = RavenDeviceRevocationConformance.Store(
            identityAddress: try XCTUnwrap(inputs["identity_address"] as? String),
            maxClaims: try XCTUnwrap(inputs["max_claims_initial"] as? Int)
        )
        let pub = hex(try XCTUnwrap(inputs["identity_ed_pub_hex"] as? String))
        let bob = hex(try XCTUnwrap(inputs["wire_bob_hex"] as? String))
        let carol = hex(try XCTUnwrap(inputs["wire_carol_hex"] as? String))
        XCTAssertEqual(
            try RavenDeviceRevocationConformance.apply(store: store, wire: bob, identityEdPub: pub),
            .applied
        )
        XCTAssertEqual(
            try RavenDeviceRevocationConformance.apply(store: store, wire: carol, identityEdPub: pub),
            .exhausted
        )
        let steps = try XCTUnwrap(v["steps"] as? [[String: Any]])
        let step3 = try XCTUnwrap(steps.first { ($0["id"] as? Int) == 3 })
        XCTAssertEqual(
            try store.storeHash(),
            hex(try XCTUnwrap(step3["store_hash_hex"] as? String))
        )
        XCTAssertThrowsError(
            try RavenDeviceRevocationConformance.apply(
                store: store, wire: carol, identityEdPub: pub, pendingAlreadyWritten: true
            )
        ) { err in
            XCTAssertEqual(
                (err as? RavenDeviceRevocationConformance.PendingBindingError)?.fixtureCode,
                "direct_exhausted_consumption"
            )
        }
        let carolPeer = try dictionary(try dictionary(gates["inputs"])["carol_peer"])
        let (cid, ced, cx, cch) = try peer(carolPeer)
        for s in RavenDeviceRevocationConformance.surfaces {
            let r = RavenDeviceRevocationConformance.authorize(
                store: store, deviceId: cid, deviceEdPub: ced, deviceXPub: cx,
                deviceCertHash: cch, surface: s
            )
            XCTAssertFalse(r.authorized)
            XCTAssertEqual(r.reason, "IDENTITY_REVOKE_EXHAUSTED")
        }
        try RavenDeviceRevocationConformance.expandQuota(
            store: store,
            newMax: try XCTUnwrap(inputs["max_claims_after_expand"] as? Int)
        )
        XCTAssertEqual(
            try RavenDeviceRevocationConformance.reverifyJournal(store: store, identityEdPub: pub).0,
            "ok"
        )
        try RavenDeviceRevocationConformance.convertExhaustedToPending(store: store)
        XCTAssertEqual(
            try RavenDeviceRevocationConformance.apply(
                store: store, wire: carol, identityEdPub: pub, pendingAlreadyWritten: true
            ),
            .applied
        )
        XCTAssertEqual(
            try store.storeHash(),
            hex(try XCTUnwrap(after["revocation_store_hash_hex"] as? String))
        )
        assertRevokedTargets(
            store,
            expected: try XCTUnwrap(after["revoked_targets"] as? [[String: Any]])
        )
    }

    func testCorruptJournalMatrix() throws {
        let cases: [(String, UInt8)] = [
            ("corrupt_journal_truncated_001.json", 1),
            ("corrupt_journal_digest_mismatch_001.json", 2),
            ("corrupt_journal_bad_signature_001.json", 3),
        ]
        for (name, code) in cases {
            let v = try load(name)
            let inputs = try dictionary(v["inputs"])
            let expected = try dictionary(v["expected"])
            let storeExpected = try dictionary(expected["store"])
            let jb = try dictionary(inputs["journal_before"])
            let store = RavenDeviceRevocationConformance.Store(
                identityAddress: try XCTUnwrap(inputs["identity_address"] as? String),
                maxClaims: 10_000
            )
            store.journal = RavenDeviceRevocationConformance.Journal(
                kind: try XCTUnwrap(jb["kind"] as? String),
                claimDigestHex: try XCTUnwrap(jb["claim_digest_hex"] as? String),
                exactRecordBytes: hex(try XCTUnwrap(jb["exact_record_bytes_hex"] as? String))
            )
            let pub = hex(try XCTUnwrap(inputs["identity_ed_pub_hex"] as? String))
            let (res, gotCode) = try RavenDeviceRevocationConformance.reverifyJournal(
                store: store, identityEdPub: pub
            )
            XCTAssertEqual(res, "corrupt")
            XCTAssertEqual(gotCode, code)
            XCTAssertNil(store.journal)
            XCTAssertEqual(
                try store.storeHash(),
                hex(try XCTUnwrap(storeExpected["revocation_store_hash_hex"] as? String))
            )
        }
    }

    func testCorruptRecoveryAuthorizeExecuted() throws {
        let v = try load("corrupt_journal_recovery_001.json")
        let inputs = try dictionary(v["inputs"])
        let expected = try dictionary(v["expected"])
        let store = RavenDeviceRevocationConformance.Store(
            identityAddress: try XCTUnwrap(inputs["identity_address"] as? String),
            maxClaims: 10_000
        )
        for c in try XCTUnwrap(inputs["corrupt"] as? [[String: Any]]) {
            store.corrupt.append(
                RavenDeviceRevocationV1.CorruptMarker(
                    scope: try XCTUnwrap(c["scope"] as? String),
                    reasonCode: UInt8(try XCTUnwrap(c["reason_code"] as? Int))
                )
            )
        }
        let (id, ed, x, ch) = try peer(try dictionary(inputs["peer"]))
        let gates = try XCTUnwrap(expected["gates"] as? [[String: Any]])
        for (i, s) in RavenDeviceRevocationConformance.surfaces.enumerated() {
            let r = RavenDeviceRevocationConformance.authorize(
                store: store, deviceId: id, deviceEdPub: ed, deviceXPub: x,
                deviceCertHash: ch, surface: s
            )
            XCTAssertEqual(r.authorized, gates[i]["authorized"] as? Bool)
            XCTAssertEqual(r.reason, gates[i]["reason"] as? String)
            XCTAssertEqual(r.surface, gates[i]["surface"] as? String)
        }
    }

    func testApplyGatesAuthorizeExecuted() throws {
        let v = try load("apply_gates_001.json")
        let inputs = try dictionary(v["inputs"])
        let expected = try dictionary(v["expected"])
        let store = RavenDeviceRevocationConformance.Store(
            identityAddress: try XCTUnwrap(inputs["identity_address"] as? String),
            maxClaims: 10_000
        )
        let pub = hex(try XCTUnwrap(inputs["identity_ed_pub_hex"] as? String))
        _ = try RavenDeviceRevocationConformance.apply(
            store: store,
            wire: hex(try XCTUnwrap(inputs["revoked_wire_hex"] as? String)),
            identityEdPub: pub
        )
        let (bid, bed, bx, bch) = try peer(try dictionary(inputs["bob_peer"]))
        let (cid, ced, cx, cch) = try peer(try dictionary(inputs["carol_peer"]))
        let bobGates = try XCTUnwrap(expected["bob_revoked_gates"] as? [[String: Any]])
        let carolGates = try XCTUnwrap(expected["carol_unrevoked_gates"] as? [[String: Any]])
        for (i, s) in RavenDeviceRevocationConformance.surfaces.enumerated() {
            let r = RavenDeviceRevocationConformance.authorize(
                store: store, deviceId: bid, deviceEdPub: bed, deviceXPub: bx,
                deviceCertHash: bch, surface: s
            )
            XCTAssertEqual(r.authorized, bobGates[i]["authorized"] as? Bool)
            XCTAssertEqual(r.reason, bobGates[i]["reason"] as? String)
        }
        for (i, s) in RavenDeviceRevocationConformance.surfaces.enumerated() {
            let r = RavenDeviceRevocationConformance.authorize(
                store: store, deviceId: cid, deviceEdPub: ced, deviceXPub: cx,
                deviceCertHash: cch, surface: s
            )
            XCTAssertEqual(r.authorized, carolGates[i]["authorized"] as? Bool)
        }
        let ex = RavenDeviceRevocationConformance.Store(
            identityAddress: store.identityAddress, maxClaims: 1
        )
        _ = try RavenDeviceRevocationConformance.apply(
            store: ex,
            wire: hex(try XCTUnwrap(inputs["revoked_wire_hex"] as? String)),
            identityEdPub: pub
        )
        _ = try RavenDeviceRevocationConformance.apply(
            store: ex,
            wire: hex(try XCTUnwrap(inputs["carol_wire_hex"] as? String)),
            identityEdPub: pub
        )
        let exhGates = try XCTUnwrap(expected["carol_under_exhausted_gates"] as? [[String: Any]])
        for (i, s) in RavenDeviceRevocationConformance.surfaces.enumerated() {
            let r = RavenDeviceRevocationConformance.authorize(
                store: ex, deviceId: cid, deviceEdPub: ced, deviceXPub: cx,
                deviceCertHash: cch, surface: s
            )
            XCTAssertEqual(r.authorized, exhGates[i]["authorized"] as? Bool)
            XCTAssertEqual(r.reason, exhGates[i]["reason"] as? String)
        }
    }

    func testPendingBindingNegatives() throws {
        let v = try load("pending_binding_negatives_001.json")
        let inputs = try dictionary(v["inputs"])
        let pub = hex(try XCTUnwrap(inputs["identity_ed_pub_hex"] as? String))
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        for caseRow in cases {
            let store = RavenDeviceRevocationConformance.Store(
                identityAddress: try XCTUnwrap(inputs["identity_address"] as? String),
                maxClaims: 10_000
            )
            if let jb = caseRow["journal_before"] as? [String: Any] {
                store.journal = RavenDeviceRevocationConformance.Journal(
                    kind: try XCTUnwrap(jb["kind"] as? String),
                    claimDigestHex: try XCTUnwrap(jb["claim_digest_hex"] as? String),
                    exactRecordBytes: hex(try XCTUnwrap(jb["exact_record_bytes_hex"] as? String))
                )
            }
            let wire = hex(try XCTUnwrap(caseRow["apply_wire_hex"] as? String))
            XCTAssertThrowsError(
                try RavenDeviceRevocationConformance.apply(
                    store: store, wire: wire, identityEdPub: pub, pendingAlreadyWritten: true
                )
            ) { err in
                XCTAssertEqual(
                    (err as? RavenDeviceRevocationConformance.PendingBindingError)?.fixtureCode,
                    caseRow["expected_error"] as? String
                )
            }
        }
    }
}
