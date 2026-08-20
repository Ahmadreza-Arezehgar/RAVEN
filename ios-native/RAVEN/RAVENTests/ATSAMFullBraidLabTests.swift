//
//  ATSAMFullBraidLabTests.swift
//  RAVENTests — lab-only Full Braid vector + optional Rust FFI coverage.
//
//  Always-on (no Rust FFI link):
//    xcodebuild test -project RAVEN.xcodeproj -scheme RAVEN \
//      -destination 'platform=iOS Simulator,name=RAVEN-iPhone-15' \
//      -only-testing:RAVENTests/ATSAMFullBraidLabTests
//  Optional linked FFI gate:
//    ./node/scripts/ios_full_braid_lab_gate.sh
//

#if DEBUG

import Foundation
import XCTest

final class ATSAMFullBraidLabTests: XCTestCase {

    func testProductionFlagStaysOff() throws {
        try ATSAMFullBraidLab.assertLabLockedOff()
        XCTAssertFalse(ATSAMFullBraidLab.productionEnabled)
    }

    func testSharedVectorSchemaAndMagics() throws {
        let fixture = try loadSmRoundFixture()
        XCTAssertTrue(fixture.labOnly)
        XCTAssertFalse(fixture.productionEnabled)
        XCTAssertEqual(fixture.profile, "ATSAM/hybrid-ratchet/v2/full-braid")
        XCTAssertEqual(fixture.name, "Full Braid SM Send/Receive transition_prepare round")

        try ATSAMFullBraidLab.requireRvfb1Magic(
            fixture.aliceBefore,
            field: "alice_before_hex"
        )
        try ATSAMFullBraidLab.requireRvfb1Magic(
            fixture.bobBefore,
            field: "bob_before_hex"
        )
        try ATSAMFullBraidLab.requireRvfb1Magic(
            fixture.aliceCandidate,
            field: "alice_candidate_hex"
        )
        try ATSAMFullBraidLab.requireRvfb1Magic(
            fixture.bobCandidate,
            field: "bob_candidate_hex"
        )

        XCTAssertEqual(fixture.aliceAgent, 1)
        XCTAssertEqual(fixture.bobAgent, 5)
        XCTAssertEqual(fixture.aliceMeta.pendingPhase, 1)
        XCTAssertEqual(fixture.bobMeta.pendingPhase, 1)
        XCTAssertEqual(fixture.aliceMeta.transitionId.count, 32)
        XCTAssertEqual(fixture.bobMeta.transitionId.count, 32)
        XCTAssertFalse(fixture.aliceIntent.isEmpty)
        XCTAssertFalse(fixture.bobIntent.isEmpty)
        XCTAssertFalse(fixture.aliceRvbo1.isEmpty)
        XCTAssertFalse(fixture.bobRvbo1.isEmpty)
    }

    func testLayoutConstantsMatchHeader() {
        XCTAssertEqual(ATSAMFullBraidLab.sizesLength, 16)
        XCTAssertEqual(ATSAMFullBraidLab.metaLength, 64)
        XCTAssertEqual(MemoryLayout<ATSAMFullBraidLab.Sizes>.size, 16)
        XCTAssertEqual(MemoryLayout<ATSAMFullBraidLab.ResultMeta>.size, 64)
        XCTAssertEqual(ATSAMFullBraidLab.maxState, 262_144)
        XCTAssertEqual(ATSAMFullBraidLab.maxRvbo1, 16_545)
        XCTAssertEqual(ATSAMFullBraidLab.maxRvbj1, 279_055)
    }

    func testRequireMagicRejectsTamperedPrefix() {
        var before = try! loadSmRoundFixture().aliceBefore
        before[0] ^= 0x01
        XCTAssertThrowsError(
            try ATSAMFullBraidLab.requireRvfb1Magic(before, field: "tampered")
        ) { error in
            XCTAssertEqual(
                error as? ATSAMFullBraidLab.ValidationError,
                .invalidMagic(field: "tampered")
            )
        }
    }

    #if RAVEN_FULL_BRAID_FFI

    func testFFIExportedLayoutConstants() throws {
        ATSAMFullBraidLab.assertExportedLayoutConstants()
    }

    func testFFITransitionPrepareMatchesSharedVector() throws {
        let fixture = try loadSmRoundFixture()

        var alice = try ATSAMFullBraidLab.transitionPrepare(
            state: fixture.aliceBefore,
            input: fixture.sendInput,
            env: fixture.sendEnv
        )
        defer { alice.wipeSecrets() }
        XCTAssertEqual(alice.candidate, fixture.aliceCandidate)
        XCTAssertEqual(alice.outputs, fixture.aliceRvbo1)
        XCTAssertEqual(alice.intent, fixture.aliceIntent)
        XCTAssertEqual(alice.meta.sendingEpoch, fixture.aliceMeta.sendingEpoch)
        XCTAssertEqual(alice.meta.receivingEpoch, fixture.aliceMeta.receivingEpoch)
        XCTAssertEqual(alice.meta.outputKeyEpoch, fixture.aliceMeta.outputKeyEpoch)
        XCTAssertEqual(alice.meta.flags, fixture.aliceMeta.flags)
        XCTAssertEqual(alice.meta.terminalReason, fixture.aliceMeta.terminalReason)
        XCTAssertEqual(alice.meta.pendingPhase, fixture.aliceMeta.pendingPhase)
        XCTAssertEqual(alice.meta.transitionIdData, fixture.aliceMeta.transitionId)

        var bob = try ATSAMFullBraidLab.transitionPrepare(
            state: fixture.bobBefore,
            input: fixture.receiveInput,
            env: fixture.receiveEnv
        )
        defer { bob.wipeSecrets() }
        XCTAssertEqual(bob.candidate, fixture.bobCandidate)
        XCTAssertEqual(bob.outputs, fixture.bobRvbo1)
        XCTAssertEqual(bob.intent, fixture.bobIntent)
        XCTAssertEqual(bob.meta.sendingEpoch, fixture.bobMeta.sendingEpoch)
        XCTAssertEqual(bob.meta.receivingEpoch, fixture.bobMeta.receivingEpoch)
        XCTAssertEqual(bob.meta.outputKeyEpoch, fixture.bobMeta.outputKeyEpoch)
        XCTAssertEqual(bob.meta.flags, fixture.bobMeta.flags)
        XCTAssertEqual(bob.meta.terminalReason, fixture.bobMeta.terminalReason)
        XCTAssertEqual(bob.meta.pendingPhase, fixture.bobMeta.pendingPhase)
        XCTAssertEqual(bob.meta.transitionIdData, fixture.bobMeta.transitionId)
    }

    func testFFIFullExchangeAEADCheckpointsMatchSharedVector() throws {
        let checkpoints = try loadFullExchangeCheckpoints()
        XCTAssertEqual(checkpoints.count, 4)

        for checkpoint in checkpoints {
            var result = try ATSAMFullBraidLab.transitionPrepare(
                state: checkpoint.before,
                input: checkpoint.input,
                env: checkpoint.env
            )
            defer { result.wipeSecrets() }

            XCTAssertEqual(
                result.candidate,
                checkpoint.preparedCandidate,
                "\(checkpoint.name): prepared_candidate"
            )
            XCTAssertEqual(
                result.outputs,
                checkpoint.rvbo1,
                "\(checkpoint.name): rvbo1"
            )
            XCTAssertEqual(
                result.intent,
                checkpoint.rvbj1,
                "\(checkpoint.name): rvbj1"
            )
            XCTAssertEqual(
                result.meta.sendingEpoch,
                checkpoint.meta.sendingEpoch,
                "\(checkpoint.name): sending_epoch"
            )
            XCTAssertEqual(
                result.meta.receivingEpoch,
                checkpoint.meta.receivingEpoch,
                "\(checkpoint.name): receiving_epoch"
            )
            XCTAssertEqual(
                result.meta.outputKeyEpoch,
                checkpoint.meta.outputKeyEpoch,
                "\(checkpoint.name): output_key_epoch"
            )
            XCTAssertEqual(
                result.meta.flags,
                checkpoint.meta.flags,
                "\(checkpoint.name): flags"
            )
            XCTAssertEqual(
                result.meta.terminalReason,
                checkpoint.meta.terminalReason,
                "\(checkpoint.name): terminal_reason"
            )
            XCTAssertEqual(
                result.meta.pendingPhase,
                checkpoint.meta.pendingPhase,
                "\(checkpoint.name): pending_phase"
            )
            XCTAssertEqual(
                result.meta.transitionIdData,
                checkpoint.meta.transitionId,
                "\(checkpoint.name): transition_id"
            )
        }
    }

    func testFFITransitionRejectsWrongDirection() throws {
        let fixture = try loadSmRoundFixture()
        // RVBI1 layout: magic(8) + schema(2) + op(1) + direction(1). Direction lives
        // in the input wire, not RVBE1 — flip Alice Send A2B→B2A and require ERR_PARSE.
        var wrongDirection = fixture.sendInput
        XCTAssertGreaterThan(wrongDirection.count, 11)
        let directionIndex = wrongDirection.index(wrongDirection.startIndex, offsetBy: 11)
        wrongDirection[directionIndex] ^= 0x01

        XCTAssertThrowsError(
            try ATSAMFullBraidLab.transitionPrepare(
                state: fixture.aliceBefore,
                input: wrongDirection,
                env: fixture.sendEnv
            )
        ) { error in
            XCTAssertEqual(
                error as? ATSAMFullBraidLab.FFIError,
                .operationFailed(name: "transition_measure", status: ATSAMFullBraidLab.errParse)
            )
        }
    }

    #else

    func testFFIPathRequiresExplicitLabLink() throws {
        throw XCTSkip(
            "Build and link raven-fb-ffi with RAVEN_FULL_BRAID_FFI; "
                + "run ./node/scripts/ios_full_braid_lab_gate.sh"
        )
    }

    func testFFIFullExchangeAEADCheckpointsMatchSharedVector() throws {
        throw XCTSkip(
            "Build and link raven-fb-ffi with RAVEN_FULL_BRAID_FFI; "
                + "run ./node/scripts/ios_full_braid_lab_gate.sh"
        )
    }

    #endif

    private func loadFullExchangeCheckpoints() throws -> [FullExchangeCheckpoint] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1 not found — open monorepo checkout")
        }
        let url = root.appendingPathComponent(
            "atsam/full_braid_full_exchange_2pq_2dh_001.json"
        )
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let records = try XCTUnwrap(object["aead_checkpoints"] as? [[String: Any]])

        return try records.map { record in
            let expected = try XCTUnwrap(record["expected"] as? [String: Any])
            let meta = try XCTUnwrap(expected["meta"] as? [String: Any])
            return FullExchangeCheckpoint(
                name: try XCTUnwrap(record["name"] as? String),
                before: try decodeHex(
                    try XCTUnwrap(record["before_hex"] as? String),
                    field: "before_hex"
                ),
                input: try decodeHex(
                    try XCTUnwrap(record["input_hex"] as? String),
                    field: "input_hex"
                ),
                env: try decodeHex(
                    try XCTUnwrap(record["env_hex"] as? String),
                    field: "env_hex"
                ),
                preparedCandidate: try decodeHex(
                    try XCTUnwrap(expected["prepared_candidate_hex"] as? String),
                    field: "prepared_candidate_hex"
                ),
                rvbo1: try decodeHex(
                    try XCTUnwrap(expected["rvbo1_hex"] as? String),
                    field: "rvbo1_hex"
                ),
                rvbj1: try decodeHex(
                    try XCTUnwrap(expected["rvbj1_hex"] as? String),
                    field: "rvbj1_hex"
                ),
                meta: FullExchangeCheckpoint.Meta(
                    sendingEpoch: try XCTUnwrap(meta["sending_epoch"] as? NSNumber).uint64Value,
                    receivingEpoch: try XCTUnwrap(meta["receiving_epoch"] as? NSNumber).uint64Value,
                    outputKeyEpoch: try XCTUnwrap(meta["output_key_epoch"] as? NSNumber).uint64Value,
                    flags: try XCTUnwrap(meta["flags"] as? NSNumber).uint32Value,
                    terminalReason: try XCTUnwrap(meta["terminal_reason"] as? NSNumber).uint16Value,
                    pendingPhase: try XCTUnwrap(meta["pending_phase"] as? NSNumber).uint16Value,
                    transitionId: try decodeHex(
                        try XCTUnwrap(meta["transition_id_hex"] as? String),
                        field: "transition_id_hex"
                    )
                )
            )
        }
    }

    private func loadSmRoundFixture() throws -> SmRoundFixture {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1 not found — open monorepo checkout")
        }
        let url = root.appendingPathComponent("atsam/full_braid_sm_round_001.json")
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let inputs = try XCTUnwrap(object["inputs"] as? [String: Any])
        let expected = try XCTUnwrap(object["expected"] as? [String: Any])
        let aliceMetaObj = try XCTUnwrap(expected["alice_meta"] as? [String: Any])
        let bobMetaObj = try XCTUnwrap(expected["bob_meta"] as? [String: Any])

        func hex(_ bag: [String: Any], _ name: String) throws -> Data {
            let value = try XCTUnwrap(bag[name] as? String, "missing \(name)")
            return try decodeHex(value, field: name)
        }

        func meta(_ bag: [String: Any]) throws -> SmRoundFixture.Meta {
            SmRoundFixture.Meta(
                sendingEpoch: UInt64(try XCTUnwrap(bag["sending_epoch"] as? Int)),
                receivingEpoch: UInt64(try XCTUnwrap(bag["receiving_epoch"] as? Int)),
                outputKeyEpoch: UInt64(try XCTUnwrap(bag["output_key_epoch"] as? Int)),
                flags: UInt32(try XCTUnwrap(bag["flags"] as? Int)),
                terminalReason: UInt16(try XCTUnwrap(bag["terminal_reason"] as? Int)),
                pendingPhase: UInt16(try XCTUnwrap(bag["pending_phase"] as? Int)),
                transitionId: try hex(bag, "transition_id_hex")
            )
        }

        return SmRoundFixture(
            labOnly: try XCTUnwrap(object["lab_only"] as? Bool),
            productionEnabled: try XCTUnwrap(object["production_enabled"] as? Bool),
            profile: try XCTUnwrap(object["profile"] as? String),
            name: try XCTUnwrap(object["name"] as? String),
            aliceBefore: try hex(inputs, "alice_before_hex"),
            bobBefore: try hex(inputs, "bob_before_hex"),
            sendInput: try hex(inputs, "send_input_hex"),
            sendEnv: try hex(inputs, "send_env_hex"),
            receiveInput: try hex(inputs, "receive_input_hex"),
            receiveEnv: try hex(inputs, "receive_env_hex"),
            aliceCandidate: try hex(expected, "alice_candidate_hex"),
            aliceRvbo1: try hex(expected, "alice_rvbo1_hex"),
            aliceIntent: try hex(expected, "alice_intent_hex"),
            bobCandidate: try hex(expected, "bob_candidate_hex"),
            bobRvbo1: try hex(expected, "bob_rvbo1_hex"),
            bobIntent: try hex(expected, "bob_intent_hex"),
            aliceAgent: try XCTUnwrap(expected["alice_agent"] as? Int),
            bobAgent: try XCTUnwrap(expected["bob_agent"] as? Int),
            aliceMeta: try meta(aliceMetaObj),
            bobMeta: try meta(bobMetaObj)
        )
    }

    private func vectorsRoot() -> URL? {
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("shared-vectors/rvn1"),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func decodeHex(_ value: String, field: String) throws -> Data {
        guard value.count.isMultiple(of: 2) else {
            throw FixtureError.invalidHex(field)
        }
        var result = Data()
        result.reserveCapacity(value.count / 2)
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let next = value.index(cursor, offsetBy: 2)
            guard let byte = UInt8(value[cursor..<next], radix: 16) else {
                throw FixtureError.invalidHex(field)
            }
            result.append(byte)
            cursor = next
        }
        return result
    }
}

private struct SmRoundFixture {
    struct Meta {
        var sendingEpoch: UInt64
        var receivingEpoch: UInt64
        var outputKeyEpoch: UInt64
        var flags: UInt32
        var terminalReason: UInt16
        var pendingPhase: UInt16
        var transitionId: Data
    }

    let labOnly: Bool
    let productionEnabled: Bool
    let profile: String
    let name: String
    let aliceBefore: Data
    let bobBefore: Data
    let sendInput: Data
    let sendEnv: Data
    let receiveInput: Data
    let receiveEnv: Data
    let aliceCandidate: Data
    let aliceRvbo1: Data
    let aliceIntent: Data
    let bobCandidate: Data
    let bobRvbo1: Data
    let bobIntent: Data
    let aliceAgent: Int
    let bobAgent: Int
    let aliceMeta: Meta
    let bobMeta: Meta
}

private struct FullExchangeCheckpoint {
    struct Meta {
        var sendingEpoch: UInt64
        var receivingEpoch: UInt64
        var outputKeyEpoch: UInt64
        var flags: UInt32
        var terminalReason: UInt16
        var pendingPhase: UInt16
        var transitionId: Data
    }

    let name: String
    let before: Data
    let input: Data
    let env: Data
    let preparedCandidate: Data
    let rvbo1: Data
    let rvbj1: Data
    let meta: Meta
}

private enum FixtureError: Error {
    case invalidHex(String)
}

#endif
