//
//  ATSAMPairInitV1Tests.swift
//  RAVENTests
//
//  Cross-language KAT and strict-negative coverage for the intentionally
//  production-disabled Raven PairInit/PairResponse V1 slice.
//

import Foundation
import XCTest
@testable import RAVEN

final class ATSAMPairInitV1Tests: XCTestCase {

    private typealias Codec = ATSAMPairInitV1

    private func vector() throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RAVENTests
            .deletingLastPathComponent() // RAVEN
            .deletingLastPathComponent() // ios-native
            .deletingLastPathComponent() // repository root
        let url = repositoryRoot.appendingPathComponent(
            "shared-vectors/rvn1/atsam/pair_init_v1_001.json"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("shared PairInit vector not found in this checkout")
        }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func string(_ key: String, in dictionary: [String: Any]) throws -> String {
        try XCTUnwrap(dictionary[key] as? String, "missing vector field: \(key)")
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

    private func hexString(_ value: Data) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }

    private func assertHex(
        _ actual: Data,
        _ key: String,
        in expected: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            hexString(actual),
            try string(key, in: expected),
            key,
            file: file,
            line: line
        )
    }

    private func trustContext(input: [String: Any]) throws -> Codec.TrustContext {
        Codec.TrustContext(
            initiatorCertificate: Codec.SignedDeviceCertificate(
                identityEd25519PublicKey: hex(
                    try string("initiator_identity_ed_pub_hex", in: input)
                ),
                signingBytes: hex(
                    try string("initiator_device_cert_signing_bytes_hex", in: input)
                ),
                signature: hex(
                    try string("initiator_device_cert_signature_hex", in: input)
                )
            ),
            responderCertificate: Codec.SignedDeviceCertificate(
                identityEd25519PublicKey: hex(
                    try string("responder_identity_ed_pub_hex", in: input)
                ),
                signingBytes: hex(
                    try string("responder_device_cert_signing_bytes_hex", in: input)
                ),
                signature: hex(
                    try string("responder_device_cert_signature_hex", in: input)
                )
            ),
            responderPrekeyBundle: Codec.SignedPrekeyBundle(
                signingBytes: hex(
                    try string("responder_prekey_signing_bytes_hex", in: input)
                ),
                signature: hex(
                    try string("responder_prekey_signature_hex", in: input)
                )
            )
        )
    }

    private func assertError<T>(
        _ expected: Codec.PairInitError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? Codec.PairInitError, expected, file: file, line: line)
        }
    }

    func testSharedVectorMatchesCodecHashesRootSignaturesAndConfirmation() throws {
        let vector = try vector()
        let input = try dictionary(vector["input"])
        let expected = try dictionary(vector["expected"])
        let initWire = hex(try string("pair_init_wire_hex", in: expected))
        let initValue = try Codec.decodeInit(initWire)

        XCTAssertFalse(Codec.productionEnabled)
        XCTAssertEqual(vector["production_enabled"] as? Bool, false)
        XCTAssertEqual(vector["profile_version"] as? String, Codec.profileIdentifier)
        XCTAssertEqual(initWire.count, Codec.initWireLength)
        XCTAssertEqual(
            (expected["pair_init_wire_len"] as? NSNumber)?.intValue,
            Codec.initWireLength
        )
        XCTAssertEqual(try Codec.encodeInit(initValue), initWire)
        try assertHex(try Codec.initSigningBytes(initValue), "pair_init_signing_bytes_hex", in: expected)
        try assertHex(try Codec.initHash(initValue), "pair_init_hash_hex", in: expected)
        try assertHex(try Codec.sessionID(initValue), "session_id_hex", in: expected)
        try assertHex(try Codec.transcriptHash(initValue), "transcript_hash_hex", in: expected)

        let root = try Codec.deriveProvisionalRoot(
            zX: hex(try string("z_x_hex", in: input)),
            zPQ: hex(try string("z_pq_hex", in: input)),
            pairInit: initValue
        )
        try assertHex(root, "provisional_k_root_hex", in: expected)

        let responseWire = hex(try string("pair_response_wire_hex", in: expected))
        let response = try Codec.decodeResponse(responseWire)
        XCTAssertEqual(responseWire.count, Codec.responseWireLength)
        XCTAssertEqual(
            (expected["pair_response_wire_len"] as? NSNumber)?.intValue,
            Codec.responseWireLength
        )
        XCTAssertEqual(try Codec.encodeResponse(response), responseWire)
        try assertHex(
            try Codec.responseSigningBytes(response),
            "pair_response_signing_bytes_hex",
            in: expected
        )
        try assertHex(
            try Codec.confirmationTag(root: root, initHash: try Codec.initHash(initValue)),
            "confirmation_tag_hex",
            in: expected
        )
        try Codec.verifyResponse(
            response,
            acceptedInit: initValue,
            root: root,
            nowMs: response.createdAtMs + 1
        )
    }

    func testSharedVectorVerifiesExactCertificatesPrekeyAndPairInitSignature() throws {
        let vector = try vector()
        let input = try dictionary(vector["input"])
        let expected = try dictionary(vector["expected"])
        let initValue = try Codec.decodeInit(hex(try string("pair_init_wire_hex", in: expected)))
        let trust = try trustContext(input: input)

        try assertHex(
            try Codec.deviceCertificateHash(trust.initiatorCertificate),
            "initiator_device_cert_hash_hex",
            in: expected
        )
        try assertHex(
            try Codec.deviceCertificateHash(trust.responderCertificate),
            "responder_device_cert_hash_hex",
            in: expected
        )
        try assertHex(
            try Codec.prekeyBundleHash(trust.responderPrekeyBundle),
            "responder_prekey_bundle_hash_hex",
            in: expected
        )
        try Codec.verifyInit(initValue, trust: trust, nowMs: initValue.createdAtMs + 1)
    }

    func testPairInitDecoderRejectsLengthHeaderAddressAndStructuralTampering() throws {
        let expected = try dictionary(try vector()["expected"])
        let wire = hex(try string("pair_init_wire_hex", in: expected))

        assertError(.invalidLength) { try Codec.decodeInit(Data(wire.dropLast())) }
        var appended = wire
        appended.append(0)
        assertError(.invalidLength) { try Codec.decodeInit(appended) }

        for (offset, error): (Int, Codec.PairInitError) in [
            (0, .invalidMagic),
            (8, .invalidVersion),
            (9, .invalidSuite),
            (10, .invalidRole),
            (11, .invalidProfile),
            (12, .invalidProfile),
        ] {
            var tampered = wire
            tampered[offset] ^= 0x01
            assertError(error) { try Codec.decodeInit(tampered) }
        }

        var uppercaseAddress = wire
        uppercaseAddress[36] = Character("R").asciiValue!
        assertError(.invalidAddress) { try Codec.decodeInit(uppercaseAddress) }

        var nonASCIIAddress = wire
        nonASCIIAddress[36] = 0xff
        assertError(.invalidAddress) { try Codec.decodeInit(nonASCIIAddress) }

        var zeroInitID = wire
        zeroInitID.replaceSubrange(124..<140, with: Data(repeating: 0, count: 16))
        assertError(.allZeroField) { try Codec.decodeInit(zeroInitID) }

        var zeroEphemeral = wire
        zeroEphemeral.replaceSubrange(236..<268, with: Data(repeating: 0, count: 32))
        assertError(.allZeroField) { try Codec.decodeInit(zeroEphemeral) }

        var zeroSignedPrekeyID = wire
        zeroSignedPrekeyID.replaceSubrange(428..<432, with: Data(repeating: 0, count: 4))
        assertError(.prekeyMismatch) { try Codec.decodeInit(zeroSignedPrekeyID) }

        var inconsistentOneTime = wire
        inconsistentOneTime.replaceSubrange(432..<436, with: Data(repeating: 0, count: 4))
        assertError(.invalidOneTimePrekey) { try Codec.decodeInit(inconsistentOneTime) }
    }

    func testTrustAndSignedTranscriptSubstitutionsFailClosed() throws {
        let vector = try vector()
        let input = try dictionary(vector["input"])
        let expected = try dictionary(vector["expected"])
        let wire = hex(try string("pair_init_wire_hex", in: expected))
        let initValue = try Codec.decodeInit(wire)
        let trust = try trustContext(input: input)
        let now = initValue.createdAtMs + 1

        let revoked = Codec.TrustContext(
            initiatorCertificate: trust.initiatorCertificate,
            responderCertificate: trust.responderCertificate,
            responderPrekeyBundle: trust.responderPrekeyBundle,
            responderRevoked: true
        )
        assertError(.revokedDevice) {
            try Codec.verifyInit(initValue, trust: revoked, nowMs: now)
        }

        var badCertificateSignature = trust.initiatorCertificate.signature
        badCertificateSignature[0] ^= 0x01
        let badCertificate = Codec.SignedDeviceCertificate(
            identityEd25519PublicKey: trust.initiatorCertificate.identityEd25519PublicKey,
            signingBytes: trust.initiatorCertificate.signingBytes,
            signature: badCertificateSignature
        )
        let badCertificateTrust = Codec.TrustContext(
            initiatorCertificate: badCertificate,
            responderCertificate: trust.responderCertificate,
            responderPrekeyBundle: trust.responderPrekeyBundle
        )
        assertError(.certificateMismatch) {
            try Codec.verifyInit(initValue, trust: badCertificateTrust, nowMs: now)
        }

        var badPrekeySignature = trust.responderPrekeyBundle.signature
        badPrekeySignature[0] ^= 0x01
        let badPrekeyTrust = Codec.TrustContext(
            initiatorCertificate: trust.initiatorCertificate,
            responderCertificate: trust.responderCertificate,
            responderPrekeyBundle: Codec.SignedPrekeyBundle(
                signingBytes: trust.responderPrekeyBundle.signingBytes,
                signature: badPrekeySignature
            )
        )
        assertError(.prekeyMismatch) {
            try Codec.verifyInit(initValue, trust: badPrekeyTrust, nowMs: now)
        }

        var swappedEndpoints = wire
        swappedEndpoints.replaceSubrange(
            36..<80,
            with: Data(initValue.responderAddress.utf8)
        )
        swappedEndpoints.replaceSubrange(
            80..<124,
            with: Data(initValue.initiatorAddress.utf8)
        )
        let swapped = try Codec.decodeInit(swappedEndpoints)
        assertError(.identityMismatch) {
            try Codec.verifyInit(swapped, trust: trust, nowMs: now)
        }

        var wrongCertificateDigest = wire
        wrongCertificateDigest[332] ^= 0x01
        let wrongCertificate = try Codec.decodeInit(wrongCertificateDigest)
        assertError(.certificateMismatch) {
            try Codec.verifyInit(wrongCertificate, trust: trust, nowMs: now)
        }

        var wrongPrekeyDigest = wire
        wrongPrekeyDigest[396] ^= 0x01
        let wrongPrekey = try Codec.decodeInit(wrongPrekeyDigest)
        assertError(.prekeyMismatch) {
            try Codec.verifyInit(wrongPrekey, trust: trust, nowMs: now)
        }

        var outsideTrustWindow = wire
        outsideTrustWindow.replaceSubrange(2708..<2716, with: Data(repeating: 0, count: 8))
        let outsideWindow = try Codec.decodeInit(outsideTrustWindow)
        assertError(.trustWindowMismatch) {
            try Codec.verifyInit(outsideWindow, trust: trust, nowMs: now)
        }

        var badPairInitSignature = wire
        badPairInitSignature[badPairInitSignature.count - 1] ^= 0x01
        let badSignature = try Codec.decodeInit(badPairInitSignature)
        assertError(.badSignature) {
            try Codec.verifyInit(badSignature, trust: trust, nowMs: now)
        }

        assertError(.notCurrentlyValid) {
            try Codec.verifyInit(
                initValue,
                trust: trust,
                nowMs: initValue.expiresAtMs
            )
        }
    }

    func testResponseDecoderAndVerificationRejectWrongBindingsRootSignatureAndTime() throws {
        let vector = try vector()
        let input = try dictionary(vector["input"])
        let expected = try dictionary(vector["expected"])
        let initValue = try Codec.decodeInit(hex(try string("pair_init_wire_hex", in: expected)))
        let wire = hex(try string("pair_response_wire_hex", in: expected))
        let response = try Codec.decodeResponse(wire)
        let root = try Codec.deriveProvisionalRoot(
            zX: hex(try string("z_x_hex", in: input)),
            zPQ: hex(try string("z_pq_hex", in: input)),
            pairInit: initValue
        )
        let now = response.createdAtMs + 1

        assertError(.invalidLength) { try Codec.decodeResponse(Data(wire.dropLast())) }
        var appended = wire
        appended.append(0)
        assertError(.invalidLength) { try Codec.decodeResponse(appended) }

        for (offset, error): (Int, Codec.PairInitError) in [
            (0, .invalidMagic),
            (8, .invalidVersion),
            (9, .invalidSuite),
            (10, .invalidRole),
            (11, .invalidProfile),
            (12, .invalidProfile),
        ] {
            var tampered = wire
            tampered[offset] ^= 0x01
            assertError(error) { try Codec.decodeResponse(tampered) }
        }

        var zeroTag = wire
        zeroTag.replaceSubrange(132..<164, with: Data(repeating: 0, count: 32))
        assertError(.allZeroField) { try Codec.decodeResponse(zeroTag) }

        var invalidInterval = wire
        invalidInterval.replaceSubrange(124..<132, with: wire.subdata(in: 116..<124))
        assertError(.invalidTime) { try Codec.decodeResponse(invalidInterval) }

        var wrongRoot = root
        wrongRoot[0] ^= 0x01
        assertError(.confirmationMismatch) {
            try Codec.verifyResponse(
                response,
                acceptedInit: initValue,
                root: wrongRoot,
                nowMs: now
            )
        }

        var wrongInitID = wire
        wrongInitID[36] ^= 0x01
        let unboundResponse = try Codec.decodeResponse(wrongInitID)
        assertError(.confirmationMismatch) {
            try Codec.verifyResponse(
                unboundResponse,
                acceptedInit: initValue,
                root: root,
                nowMs: now
            )
        }

        var wrongTag = wire
        wrongTag[132] ^= 0x01
        let mistagged = try Codec.decodeResponse(wrongTag)
        assertError(.confirmationMismatch) {
            try Codec.verifyResponse(
                mistagged,
                acceptedInit: initValue,
                root: root,
                nowMs: now
            )
        }

        var badSignatureWire = wire
        badSignatureWire[badSignatureWire.count - 1] ^= 0x01
        let badSignature = try Codec.decodeResponse(badSignatureWire)
        assertError(.badSignature) {
            try Codec.verifyResponse(
                badSignature,
                acceptedInit: initValue,
                root: root,
                nowMs: now
            )
        }

        assertError(.confirmationMismatch) {
            try Codec.verifyResponse(
                response,
                acceptedInit: initValue,
                root: root,
                nowMs: response.expiresAtMs
            )
        }
        assertError(.invalidSharedSecretLength) {
            try Codec.verifyResponse(
                response,
                acceptedInit: initValue,
                root: Data(root.dropLast()),
                nowMs: now
            )
        }
    }

    func testKDFRejectsWrongLengthsAndNonContributoryX25519() throws {
        let vector = try vector()
        let input = try dictionary(vector["input"])
        let expected = try dictionary(vector["expected"])
        let initValue = try Codec.decodeInit(hex(try string("pair_init_wire_hex", in: expected)))
        let zPQ = hex(try string("z_pq_hex", in: input))

        assertError(.invalidSharedSecretLength) {
            try Codec.deriveProvisionalRoot(
                zX: Data(repeating: 1, count: 31),
                zPQ: zPQ,
                pairInit: initValue
            )
        }
        assertError(.nonContributoryX25519) {
            try Codec.deriveProvisionalRoot(
                zX: Data(repeating: 0, count: 32),
                zPQ: zPQ,
                pairInit: initValue
            )
        }
    }
}
