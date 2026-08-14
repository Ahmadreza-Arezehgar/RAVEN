//
//  ATSAMIndexedSessionProfileTests.swift
//  RAVENTests
//
//  Cross-language KAT coverage for the production-disabled
//  ATSAM/indexed-session/v1 reference profile.
//

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

final class ATSAMIndexedSessionProfileTests: XCTestCase {

    private typealias Profile = ATSAMIndexedSessionProfile

    private func vectorsRoot() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RAVENTests
            .deletingLastPathComponent() // RAVEN
            .deletingLastPathComponent() // ios-native
            .deletingLastPathComponent() // repository
            .appendingPathComponent("shared-vectors/rvn1/atsam")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private func loadVector(_ name: String) throws -> [String: Any] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1/atsam not found")
        }
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
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

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func dictionaries(_ value: Any?) throws -> [[String: Any]] {
        try XCTUnwrap(value as? [[String: Any]])
    }

    private func uint64(_ value: Any?) throws -> UInt64 {
        try XCTUnwrap(value as? NSNumber).uint64Value
    }

    private func uint32(_ value: Any?) throws -> UInt32 {
        UInt32(try uint64(value))
    }

    private func uint8(_ value: Any?) throws -> UInt8 {
        UInt8(try uint64(value))
    }

    private func assertHex(
        _ actual: Data,
        equals key: String,
        in expected: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            hexString(actual),
            try XCTUnwrap(expected[key] as? String),
            key,
            file: file,
            line: line
        )
    }

    func testSubkeyVectorMatchesEveryDirectionalOutput() throws {
        let vector = try loadVector("indexed_session_v1_subkeys_001.json")
        let input = try dictionary(vector["input"])
        let expected = try dictionary(vector["expected"])
        let root = hex(try XCTUnwrap(input["k_root_hex"] as? String))
        let initiator = try XCTUnwrap(input["initiator_address"] as? String)
        let responder = try XCTUnwrap(input["responder_address"] as? String)
        let mailboxTime = try uint64(input["mailbox_time_ms"])

        XCTAssertFalse(Profile.productionEnabled)
        XCTAssertEqual(vector["production_enabled"] as? Bool, false)
        XCTAssertEqual(vector["profile_version"] as? String, Profile.profileIdentifier)
        try assertHex(
            Profile.sessionContext(
                initiatorAddress: initiator,
                responderAddress: responder
            ),
            equals: "session_context_hex",
            in: expected
        )
        try assertHex(Profile.ackBaseKey(root: root), equals: "ack_base_key_hex", in: expected)
        try assertHex(Profile.routeMasterKey(root: root), equals: "route_master_key_hex", in: expected)

        for directionVector in try dictionaries(expected["directions"]) {
            let directionRaw = try uint8(directionVector["direction"])
            let direction = try XCTUnwrap(Profile.Direction(rawValue: directionRaw))
            let pair = try Profile.endpoints(
                initiatorAddress: initiator,
                responderAddress: responder,
                direction: direction
            )
            XCTAssertEqual(pair.sender, directionVector["sender_address"] as? String)
            XCTAssertEqual(pair.recipient, directionVector["recipient_address"] as? String)

            try assertHex(
                Profile.messageChainKeyAtIndex(
                    root: root,
                    initiatorAddress: initiator,
                    responderAddress: responder,
                    direction: direction,
                    index: 0
                ),
                equals: "message_ck0_hex",
                in: directionVector
            )
            try assertHex(
                Profile.messageKeyAtIndex(
                    root: root,
                    initiatorAddress: initiator,
                    responderAddress: responder,
                    direction: direction,
                    index: 0
                ),
                equals: "message_key_index0_hex",
                in: directionVector
            )
            try assertHex(
                Profile.ackChainKeyAtIndex(
                    root: root,
                    initiatorAddress: initiator,
                    responderAddress: responder,
                    direction: direction,
                    index: 0
                ),
                equals: "ack_ck0_hex",
                in: directionVector
            )
            try assertHex(
                Profile.ackKeyAtIndex(
                    root: root,
                    initiatorAddress: initiator,
                    responderAddress: responder,
                    direction: direction,
                    index: 0
                ),
                equals: "ack_key_index0_hex",
                in: directionVector
            )
            try assertHex(
                Profile.routeDirectionKey(root: root, direction: direction),
                equals: "route_direction_key_hex",
                in: directionVector
            )

            let coordinates = Profile.mailboxCoordinates(
                unixMs: mailboxTime,
                direction: direction
            )
            XCTAssertEqual(coordinates.dayEpoch, try uint64(directionVector["mailbox_day_epoch"]))
            XCTAssertEqual(coordinates.slot, try uint64(directionVector["mailbox_slot"]))

            let tags = try Profile.deriveMailboxTags(
                root: root,
                unixMs: mailboxTime,
                direction: direction
            )
            try assertHex(tags.mailboxTag, equals: "mailbox_tag_hex", in: directionVector)
            try assertHex(tags.storeTag, equals: "store_tag_hex", in: directionVector)
        }
    }

    func testSignedAndSealedAckVectorMatchesAllRelevantBytes() throws {
        let vector = try loadVector("indexed_session_v1_sealed_ack_001.json")
        let input = try dictionary(vector["input"])
        let expected = try dictionary(vector["expected"])
        let allocator = try dictionary(vector["allocator"])

        let root = hex(try XCTUnwrap(input["k_root_hex"] as? String))
        let initiator = try XCTUnwrap(input["initiator_address"] as? String)
        let responder = try XCTUnwrap(input["responder_address"] as? String)
        let direction = try XCTUnwrap(
            Profile.Direction(rawValue: try uint8(input["direction"]))
        )
        let index = try uint32(input["ack_chain_index"])
        let createdAt = try uint64(input["created_at_ms"])
        let messageId = hex(try XCTUnwrap(input["outer_message_id_hex"] as? String))
        let status = try uint8(input["status"])

        XCTAssertFalse(Profile.productionEnabled)
        XCTAssertEqual(Profile.protocolByte, try uint8(expected["rvna1_proto"]))
        XCTAssertEqual(Profile.suiteByte, try uint8(expected["rvna1_suite"]))
        XCTAssertEqual(
            try Profile.uuidText(messageId: messageId),
            input["outer_message_id_aad_uuid"] as? String
        )

        let coordinates = try Profile.routeCoordinates(
            createdAtMs: createdAt,
            index: index,
            envelopeType: try uint8(allocator["env_type"]),
            direction: direction
        )
        XCTAssertEqual(coordinates.epoch, try uint64(allocator["epoch"]))
        XCTAssertEqual(coordinates.counter, try uint64(allocator["counter"]))
        try assertHex(
            Profile.deriveRouteTag(
                root: root,
                createdAtMs: createdAt,
                index: index,
                envelopeType: RavenEnvelopeV1.EnvType.ack.rawValue,
                direction: direction
            ),
            equals: "routing_tag_hex",
            in: expected
        )
        try assertHex(
            Profile.ackKeyAtIndex(
                root: root,
                initiatorAddress: initiator,
                responderAddress: responder,
                direction: direction,
                index: index
            ),
            equals: "ack_key_index7_hex",
            in: expected
        )

        let pair = try Profile.endpoints(
            initiatorAddress: initiator,
            responderAddress: responder,
            direction: direction
        )
        try assertHex(
            Profile.buildAAD(
                index: index,
                sender: pair.sender,
                recipient: pair.recipient,
                outerMessageId: messageId
            ),
            equals: "aad_sha256_hex",
            in: expected
        )

        let signedAck = Profile.SignedAck(
            ackedMessageId: hex(try XCTUnwrap(input["acked_message_id_hex"] as? String)),
            status: status,
            ackNonce: hex(try XCTUnwrap(input["ack_nonce_hex"] as? String)),
            createdAtMs: createdAt,
            signature: hex(try XCTUnwrap(expected["inner_signature_hex"] as? String))
        )
        let signingBytes = try Profile.ackSigningBytes(signedAck)
        try assertHex(signingBytes, equals: "ack_signing_bytes_hex", in: expected)
        let plaintext = try Profile.encodeSignedAck(signedAck)
        XCTAssertEqual(plaintext.count, try Int(XCTUnwrap(expected["ack_plaintext_len"] as? NSNumber).intValue))
        try assertHex(plaintext, equals: "ack_plaintext_hex", in: expected)
        XCTAssertEqual(try Profile.decodeSignedAck(plaintext), signedAck)

        let signerPublic = try Curve25519.Signing.PublicKey(
            rawRepresentation: hex(try XCTUnwrap(input["inner_signer_ed_public_hex"] as? String))
        )
        XCTAssertTrue(signerPublic.isValidSignature(signedAck.signature, for: signingBytes))

        let sealed = try Profile.sealAck(
            root: root,
            initiatorAddress: initiator,
            responderAddress: responder,
            direction: direction,
            index: index,
            outerMessageId: messageId,
            plaintext: plaintext,
            nonce: hex(try XCTUnwrap(input["seal_nonce_hex"] as? String))
        )
        XCTAssertEqual(sealed.count, try Int(XCTUnwrap(expected["sealed_body_len"] as? NSNumber).intValue))
        try assertHex(sealed, equals: "sealed_body_hex", in: expected)
        XCTAssertEqual(
            try Profile.openAck(
                root: root,
                initiatorAddress: initiator,
                responderAddress: responder,
                direction: direction,
                outerMessageId: messageId,
                wire: sealed
            ),
            plaintext
        )

        let routeTag = hex(try XCTUnwrap(expected["routing_tag_hex"] as? String))
        let envelope = RavenEnvelopeV1(
            envType: RavenEnvelopeV1.EnvType.ack.rawValue,
            flags: UInt16(try uint64(input["outer_flags"])),
            messageId: messageId,
            routingTag: routeTag,
            createdAtMs: createdAt,
            expiresAtMs: try uint64(input["expires_at_ms"]),
            hopLimit: try uint8(input["hop_limit"]),
            replicationBudget: try uint8(input["replication_budget"]),
            antiReplayNonce: hex(try XCTUnwrap(input["anti_replay_nonce_hex"] as? String)),
            messageCiphertext: sealed,
            senderAuthentication: hex(try XCTUnwrap(expected["outer_signature_hex"] as? String))
        )
        try assertHex(envelope.signingBytes(), equals: "outer_signing_bytes_hex", in: expected)
        XCTAssertTrue(envelope.verify(publicKey: signerPublic))
        let packed = envelope.pack()
        XCTAssertEqual(packed.count, try Int(XCTUnwrap(expected["packed_envelope_len"] as? NSNumber).intValue))
        try assertHex(packed, equals: "packed_envelope_hex", in: expected)
        XCTAssertEqual(try XCTUnwrap(RavenEnvelopeV1.unpack(packed)), envelope)
    }

    func testCanonicalAddressAndFixedWidthInputsFailClosed() throws {
        let vector = try loadVector("indexed_session_v1_subkeys_001.json")
        let input = try dictionary(vector["input"])
        let alice = try XCTUnwrap(input["initiator_address"] as? String)
        let bob = try XCTUnwrap(input["responder_address"] as? String)
        let root = hex(try XCTUnwrap(input["k_root_hex"] as? String))

        XCTAssertNoThrow(try Profile.requireCanonicalAddress(alice))
        for malformed in [alice.uppercased(), " \(alice)", "\(alice) ", "rvn1:ABCD", "rvn1qqqqqq"] {
            XCTAssertThrowsError(try Profile.requireCanonicalAddress(malformed)) { error in
                XCTAssertEqual(error as? Profile.ProfileError, .nonCanonicalAddress)
            }
        }
        XCTAssertThrowsError(
            try Profile.sessionContext(initiatorAddress: alice, responderAddress: alice)
        ) { error in
            XCTAssertEqual(error as? Profile.ProfileError, .sameEndpoint)
        }
        XCTAssertNil(Profile.Direction(rawValue: 2))

        XCTAssertThrowsError(
            try Profile.messageKeyAtIndex(
                root: Data(repeating: 0, count: 31),
                initiatorAddress: alice,
                responderAddress: bob,
                direction: .initiatorToResponder,
                index: 0
            )
        ) { error in
            XCTAssertEqual(error as? Profile.ProfileError, .invalidRootLength)
        }
        for envelopeType: UInt8 in [0, 5, .max] {
            XCTAssertThrowsError(
                try Profile.routeCoordinates(
                    createdAtMs: 1,
                    index: 0,
                    envelopeType: envelopeType,
                    direction: .initiatorToResponder
                )
            ) { error in
                XCTAssertEqual(error as? Profile.ProfileError, .invalidEnvelopeType)
            }
        }
        XCTAssertThrowsError(try Profile.uuidText(messageId: Data(repeating: 0, count: 15))) { error in
            XCTAssertEqual(error as? Profile.ProfileError, .invalidMessageIdLength)
        }
        XCTAssertEqual(
            try Profile.uuidText(messageId: hex("00112233445546778899aabbccddeeff")),
            "00112233-4455-4677-8899-AABBCCDDEEFF"
        )

        let validAck = Profile.SignedAck(
            ackedMessageId: Data(repeating: 1, count: 16),
            status: 1,
            ackNonce: Data(repeating: 2, count: 12),
            createdAtMs: 3,
            signature: Data(repeating: 4, count: 64)
        )
        for status: UInt8 in [0, 3, .max] {
            let invalid = Profile.SignedAck(
                ackedMessageId: validAck.ackedMessageId,
                status: status,
                ackNonce: validAck.ackNonce,
                createdAtMs: validAck.createdAtMs,
                signature: validAck.signature
            )
            XCTAssertThrowsError(try Profile.encodeSignedAck(invalid)) { error in
                XCTAssertEqual(error as? Profile.ProfileError, .invalidAckStatus)
            }
        }
        XCTAssertThrowsError(try Profile.decodeSignedAck(Data(repeating: 0, count: 100))) { error in
            XCTAssertEqual(error as? Profile.ProfileError, .invalidSignedAckLength)
        }
        XCTAssertNoThrow(try Profile.ackBaseKey(root: root))
    }

    func testSealedAckRejectsTamperWrongDirectionWrongOuterIdAndBadHeader() throws {
        let vector = try loadVector("indexed_session_v1_sealed_ack_001.json")
        let input = try dictionary(vector["input"])
        let expected = try dictionary(vector["expected"])
        let root = hex(try XCTUnwrap(input["k_root_hex"] as? String))
        let initiator = try XCTUnwrap(input["initiator_address"] as? String)
        let responder = try XCTUnwrap(input["responder_address"] as? String)
        let messageId = hex(try XCTUnwrap(input["outer_message_id_hex"] as? String))
        let sealed = hex(try XCTUnwrap(expected["sealed_body_hex"] as? String))

        var tampered = sealed
        tampered[50] ^= 0x01
        XCTAssertThrowsError(
            try Profile.openAck(
                root: root,
                initiatorAddress: initiator,
                responderAddress: responder,
                direction: .responderToInitiator,
                outerMessageId: messageId,
                wire: tampered
            )
        ) { error in
            XCTAssertEqual(error as? Profile.ProfileError, .authenticationFailed)
        }

        XCTAssertThrowsError(
            try Profile.openAck(
                root: root,
                initiatorAddress: initiator,
                responderAddress: responder,
                direction: .initiatorToResponder,
                outerMessageId: messageId,
                wire: sealed
            )
        ) { error in
            XCTAssertEqual(error as? Profile.ProfileError, .authenticationFailed)
        }

        var wrongMessageId = messageId
        wrongMessageId[15] ^= 0x01
        XCTAssertThrowsError(
            try Profile.openAck(
                root: root,
                initiatorAddress: initiator,
                responderAddress: responder,
                direction: .responderToInitiator,
                outerMessageId: wrongMessageId,
                wire: sealed
            )
        ) { error in
            XCTAssertEqual(error as? Profile.ProfileError, .authenticationFailed)
        }

        var badHeader = sealed
        badHeader[8] = 0x02
        XCTAssertThrowsError(
            try Profile.openAck(
                root: root,
                initiatorAddress: initiator,
                responderAddress: responder,
                direction: .responderToInitiator,
                outerMessageId: messageId,
                wire: badHeader
            )
        ) { error in
            XCTAssertEqual(error as? Profile.ProfileError, .invalidSealedAckHeader)
        }
        XCTAssertThrowsError(
            try Profile.openAck(
                root: root,
                initiatorAddress: initiator.uppercased(),
                responderAddress: responder,
                direction: .responderToInitiator,
                outerMessageId: messageId,
                wire: sealed
            )
        ) { error in
            XCTAssertEqual(error as? Profile.ProfileError, .nonCanonicalAddress)
        }
    }
}
