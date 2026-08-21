//
//  ATSAMFullBraidProtectedAnchorV1Tests.swift
//  RAVENTests — Task 0B.1 shared-vector parity (lab-only).
//

import Foundation
import XCTest
@testable import RAVEN

final class ATSAMFullBraidProtectedAnchorV1Tests: XCTestCase {

    func testSharedVectorScopeKDFRVFA1Append() throws {
        let vector = try loadVector()
        XCTAssertEqual(vector["production_enabled"] as? Bool, false)
        XCTAssertEqual(vector["lab_only"] as? Bool, true)
        XCTAssertEqual(ATSAMFullBraidProtectedAnchorV1.initialAnchorSeq, 1)

        let inputs = try XCTUnwrap(vector["inputs"] as? [String: Any])
        let expected = try XCTUnwrap(vector["expected"] as? [String: Any])
        let negatives = try XCTUnwrap(vector["negatives"] as? [String: Any])

        let seed = hex(try XCTUnwrap(inputs["seed_hex"] as? String))
        let session = hex(try XCTUnwrap(inputs["session_id_hex"] as? String))
        var keys = try ATSAMFullBraidProtectedAnchorV1.deriveStoreKeys(seed32: seed)
        defer { keys.zeroize() }

        XCTAssertEqual(
            ATSAMFullBraidProtectedAnchorV1.appleScopeID().hexString,
            expected["apple_scope_id_hex"] as? String
        )
        let terminalRoot = Data((try XCTUnwrap(inputs["terminal_root_utf8"] as? String)).utf8)
        XCTAssertEqual(
            try ATSAMFullBraidProtectedAnchorV1.terminalScopeID(canonicalRootBytes: terminalRoot).hexString,
            expected["terminal_scope_id_hex"] as? String
        )
        XCTAssertEqual(keys.kState.hexString, expected["k_state_hex"] as? String)
        XCTAssertEqual(keys.kIndex.hexString, expected["k_index_hex"] as? String)
        XCTAssertEqual(keys.kSQL.hexString, expected["k_sql_hex"] as? String)
        XCTAssertEqual(keys.kLocal.hexString, expected["k_local_hex"] as? String)
        XCTAssertEqual(keys.kAnchor.hexString, expected["k_anchor_hex"] as? String)
        XCTAssertEqual(keys.kSQLSalt.hexString, expected["k_sql_salt_hex"] as? String)

        let rk = try ATSAMFullBraidProtectedAnchorV1.recordKey(kIndex: keys.kIndex, sessionID: session)
        XCTAssertEqual(rk.hexString, expected["record_key_hex"] as? String)

        let raw1 = hex(try XCTUnwrap(expected["rvfa1_seq1_hex"] as? String))
        let raw2 = hex(try XCTUnwrap(expected["rvfa1_seq2_hex"] as? String))
        let raw3 = hex(try XCTUnwrap(expected["rvfa1_seq3_hex"] as? String))
        let raw4 = hex(try XCTUnwrap(expected["rvfa1_seq4_hex"] as? String))
        let conflict = hex(try XCTUnwrap(expected["rvfa1_seq2_conflict_hex"] as? String))
        let deleting = hex(try XCTUnwrap(expected["rvfa1_deleting_seq2_hex"] as? String))
        XCTAssertEqual(raw1.count, ATSAMFullBraidProtectedAnchorV1.rvfa1Length)

        let decoded = try ATSAMFullBraidProtectedAnchorV1.decodeRVFA1(raw1, kAnchor: keys.kAnchor)
        XCTAssertEqual(decoded.anchorSeq, 1)
        XCTAssertEqual(decoded.recordKey, rk)
        XCTAssertEqual(decoded.transitionID, Data(count: 32))

        func decide(_ existing: [Data], _ candidate: Data) -> String {
            ATSAMFullBraidProtectedAnchorV1.classifyAppend(
                existingRaw: existing,
                candidateRaw: candidate,
                kAnchor: keys.kAnchor,
                kIndex: keys.kIndex
            ).rawValue
        }

        XCTAssertEqual(decide([], raw1), expected["append_empty_seq1"] as? String)
        XCTAssertEqual(decide([raw1], raw1), expected["append_replay_seq1"] as? String)
        XCTAssertEqual(decide([raw1], raw2), expected["append_seq2_after_seq1"] as? String)
        XCTAssertEqual(decide([raw1, raw2], conflict), expected["append_conflict_same_seq"] as? String)
        XCTAssertEqual(decide([], raw2), expected["append_first_nonzero_not_one"] as? String)

        var gap = try ATSAMFullBraidProtectedAnchorV1.decodeRVFA1(raw2, kAnchor: keys.kAnchor)
        gap.anchorSeq = 4
        gap.generation = 4
        gap.clearedStateDigest = Data(repeating: 0x66, count: 32)
        gap.clearedStoreRevision = 9
        gap.transitionID = Data(repeating: 0x77, count: 32)
        gap.horizonMS = 0
        gap.hmac = Data(count: 32)
        let gapRaw = try ATSAMFullBraidProtectedAnchorV1.encodeRVFA1(gap, kAnchor: keys.kAnchor)
        XCTAssertEqual(decide([raw1, raw2], gapRaw), expected["append_gap_seq4"] as? String)
        XCTAssertEqual(decide([raw1, raw3], raw4), expected["append_gapped_chain_seq4"] as? String)
        XCTAssertEqual(decide([raw1, raw3], raw3), expected["append_replay_on_gapped_chain"] as? String)

        let tombAfterHead = hex(try XCTUnwrap(negatives["tombstone_after_head_hex"] as? String))
        XCTAssertEqual(decide([raw1, tombAfterHead], raw1), expected["append_bad_status_in_chain"] as? String)
        XCTAssertEqual(
            decide([], hex(try XCTUnwrap(negatives["bad_record_key_hex"] as? String))),
            expected["append_bad_record_key"] as? String
        )
        XCTAssertEqual(
            decide([], hex(try XCTUnwrap(negatives["head_nonzero_horizon_hex"] as? String))),
            expected["append_head_nonzero_horizon"] as? String
        )
        XCTAssertEqual(decide([raw1], tombAfterHead), expected["append_bad_status_transition"] as? String)
        XCTAssertEqual(
            decide([raw1], hex(try XCTUnwrap(negatives["tombstone_zero_horizon_hex"] as? String))),
            expected["append_tombstone_zero_horizon"] as? String
        )
        XCTAssertEqual(
            decide([raw1], hex(try XCTUnwrap(negatives["tombstone_nonzero_transition_hex"] as? String))),
            expected["append_tombstone_nonzero_transition"] as? String
        )
        XCTAssertEqual(
            decide([raw1], hex(try XCTUnwrap(negatives["noninitial_head_zero_transition_hex"] as? String))),
            expected["append_noninitial_head_zero_transition"] as? String
        )
        XCTAssertEqual(
            decide([raw1], hex(try XCTUnwrap(negatives["deleting_zero_transition_hex"] as? String))),
            expected["append_deleting_zero_transition"] as? String
        )
        XCTAssertEqual(decide([raw1], deleting), expected["append_deleting_after_seq1"] as? String)

        let d44 = Data(repeating: 0x44, count: 32)
        let d33 = Data(repeating: 0x33, count: 32)
        XCTAssertEqual(
            ATSAMFullBraidProtectedAnchorV1.openRollbackClass(
                anchorGeneration: 2, anchorDigest: d44, anchorRevision: 8,
                fileGeneration: 2, fileDigest: d44, fileRevision: 8
            ),
            expected["open_aligned"] as? String
        )
        XCTAssertEqual(
            ATSAMFullBraidProtectedAnchorV1.openRollbackClass(
                anchorGeneration: 2, anchorDigest: d44, anchorRevision: 8,
                fileGeneration: 1, fileDigest: d33, fileRevision: 7
            ),
            expected["open_container_behind"] as? String
        )
        XCTAssertEqual(
            ATSAMFullBraidProtectedAnchorV1.openRollbackClass(
                anchorGeneration: 1, anchorDigest: d33, anchorRevision: 7,
                fileGeneration: 2, fileDigest: d44, fileRevision: 8
            ),
            expected["open_anchor_behind"] as? String
        )
        XCTAssertEqual(
            ATSAMFullBraidProtectedAnchorV1.openRollbackClass(
                anchorGeneration: 2, anchorDigest: d44, anchorRevision: 8,
                fileGeneration: 2, fileDigest: d33, fileRevision: 8
            ),
            expected["open_digest_mismatch"] as? String
        )

        XCTAssertThrowsError(
            try ATSAMFullBraidProtectedAnchorV1.scopeID(
                platformAppID: ATSAMFullBraidProtectedAnchorV1.appleAppID,
                logicalRootID: Data((try XCTUnwrap(negatives["forbidden_shared_group"] as? String)).utf8)
            )
        )
        XCTAssertThrowsError(
            try ATSAMFullBraidProtectedAnchorV1.decodeRVFA1(
                hex(try XCTUnwrap(negatives["bad_hmac_hex"] as? String)),
                kAnchor: keys.kAnchor
            )
        )

        var mismatch = decoded
        mismatch.hmac = Data(repeating: 0xff, count: 32)
        XCTAssertThrowsError(
            try ATSAMFullBraidProtectedAnchorV1.encodeRVFA1(mismatch, kAnchor: keys.kAnchor)
        )
        XCTAssertEqual(negatives["encode_provided_hmac_mismatch"] as? String, "CodecError")
        XCTAssertFalse(ATSAMFullBraidProtectedAnchorV1.productionEnabled)
        XCTAssertEqual(
            ATSAMFullBraidProtectedAnchorV1.releaseHold,
            "FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED"
        )
        XCTAssertEqual(ATSAMFullBraidProtectedAnchorV1.maxFullBraidSessions, 4096)
        XCTAssertEqual(ATSAMFullBraidProtectedAnchorV1.windowsCredMaxBlob, 2560)
        XCTAssertEqual(ATSAMFullBraidProtectedAnchorV1.errorCodes.count, 11)
    }

    private func loadVector() throws -> [String: Any] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1/atsam not found")
        }
        let url = root.appendingPathComponent("full_braid_protected_anchor_001.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func vectorsRoot() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared-vectors/rvn1/atsam")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
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
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
