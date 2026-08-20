//
//  RavenSecureLanRlb1Tests.swift
//  RAVENTests
//
//  Cross-language KAT coverage for rvn1 LAN RLB1 offer wire.
//

import Foundation
import XCTest
@testable import RAVEN

final class RavenSecureLanRlb1Tests: XCTestCase {

    private func vectorsRoot() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared-vectors/rvn1/lan")
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private func loadVector(_ name: String) throws -> [String: Any] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1/lan not found")
        }
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
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

    private func rlb1Error(_ error: Error) -> RavenSecureLanRlb1Error? {
        error as? RavenSecureLanRlb1Error
    }

    // MARK: - Vector KAT

    func testRlb1Offer001ExactWireFromFixture() throws {
        let vector = try loadVector("rlb1_offer_001.json")
        let inputs = try dictionary(vector["inputs"])
        let expected = try dictionary(vector["expected"])

        let seed = hex(try XCTUnwrap(inputs["device_seed_hex"] as? String))
        let deviceID = try XCTUnwrap(inputs["device_id"] as? String)
        let epochMs = try XCTUnwrap(inputs["epoch_ms"] as? NSNumber).uint64Value

        let bundle = try RavenSecureLanRlb1V1.fixtureOfferBundle(
            deviceSeed: seed,
            deviceID: deviceID,
            epochMs: epochMs
        )
        let wire = try RavenSecureLanRlb1V1.encodeOffer(bundle)

        XCTAssertEqual(
            wire.map { String(format: "%02x", $0) }.joined(),
            try XCTUnwrap(expected["offer_wire_hex"] as? String)
        )
        XCTAssertEqual(wire.count, expected["offer_wire_len"] as? Int)
        XCTAssertEqual(expected["max_offer_wire"] as? Int, RavenSecureLanRlb1V1.maxOfferWire)
        XCTAssertLessThanOrEqual(wire.count, RavenSecureLanRlb1V1.maxOfferWire)
        XCTAssertTrue(RavenSecureLanRlb1V1.isRlb1(wire))
    }

    func testRlb1Offer001DecodeRoundtrip() throws {
        let vector = try loadVector("rlb1_offer_001.json")
        let expected = try dictionary(vector["expected"])
        let wire = hex(try XCTUnwrap(expected["offer_wire_hex"] as? String))

        let decoded = try RavenSecureLanRlb1V1.decodeOffer(wire)
        let reencoded = try RavenSecureLanRlb1V1.encodeOffer(decoded)

        XCTAssertEqual(reencoded, wire)
        XCTAssertEqual(decoded.cert.deviceID, "alice-lan-device-1")
        XCTAssertEqual(decoded.prekey.deviceID, "alice-lan-device-1")
        XCTAssertEqual(decoded.cert.userEdPub, decoded.prekey.identityEd25519Pub)
    }

    // MARK: - Size caps

    func testCombinedOfferCapRejectsOversize() throws {
        let vector = try loadVector("rlb1_offer_001.json")
        let reject = try dictionary(vector["reject_cases"])
        let capCase = try dictionary(reject["combined_cap_ge_65519"])

        let seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let now: UInt64 = 1_700_000_000_000
        let hugeID = String(repeating: "x", count: 60_000)

        let cert = try RavenSecureLanRlb1V1.issueDeviceCertificate(
            deviceSeed: seed,
            userEdPub: LanDeterministicEd25519.publicKey(seed: seed),
            deviceEdPub: LanDeterministicEd25519.publicKey(seed: seed),
            deviceXPub: Data(repeating: 0x61, count: 32),
            deviceID: hugeID,
            notBeforeMs: now - 60_000,
            notAfterMs: now + 86_400_000,
            capabilities: 0
        )
        let prekey = try RavenSecureLanRlb1V1.signPrekeyBundle(
            deviceSeed: seed,
            bundle: RavenSecureLanRlb1V1.LanPrekeyBundle(
                version: 1,
                identityEd25519Pub: Data(repeating: 0, count: 32),
                deviceID: hugeID,
                x25519Pub: Data(repeating: 0x61, count: 32),
                mlkem768EK: Data(repeating: 0x02, count: RavenSecureLanRlb1V1.mlkem768EKLen),
                signedPrekeyID: 1,
                oneTimePrekeyID: 0,
                oneTimeX25519Pub: nil,
                createdAtMs: now,
                expiresAtMs: now + 86_400_000,
                signature: Data(repeating: 0, count: 64)
            )
        )
        let oversizeBundle = RavenSecureLanRlb1V1.LanBundle(cert: cert, prekey: prekey)

        let certJSON = try RavenSecureLanRlb1V1.encodeCertJSON(cert)
        let prekeyJSON = try RavenSecureLanRlb1V1.encodePrekeyJSON(prekey)
        XCTAssertEqual(certJSON.count, capCase["cert_json_len"] as? Int)
        XCTAssertEqual(prekeyJSON.count, capCase["prekey_json_len"] as? Int)
        XCTAssertGreaterThan(
            RavenSecureLanRlb1V1.rlb1HeaderLen + certJSON.count + prekeyJSON.count,
            RavenSecureLanRlb1V1.maxOfferWire
        )

        XCTAssertThrowsError(try RavenSecureLanRlb1V1.encodeOffer(oversizeBundle)) { error in
            XCTAssertEqual(
                rlb1Error(error),
                .offerExceedsTransport
            )
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                capCase["encode_error"] as? String
            )
        }

        var wire = try RavenSecureLanRlb1V1.encodeOffer(
            try RavenSecureLanRlb1V1.fixtureOfferBundle(deviceSeed: seed)
        )
        wire.append(Data(repeating: 0, count: RavenSecureLanRlb1V1.maxOfferWire + 1 - wire.count))
        XCTAssertEqual(wire.count, capCase["offer_wire_len"] as? Int)
        XCTAssertEqual(wire.count, RavenSecureLanRlb1V1.maxOfferWire + 1)
        XCTAssertThrowsError(try RavenSecureLanRlb1V1.decodeOffer(wire)) { error in
            XCTAssertEqual(rlb1Error(error), .offerExceedsTransport)
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                capCase["decode_error"] as? String
            )
        }
    }

    // MARK: - Wire fail-closed

    func testRejectsBadMagicVersionKindAndTrailingBytes() throws {
        let vector = try loadVector("rlb1_offer_001.json")
        let expected = try dictionary(vector["expected"])
        var wire = hex(try XCTUnwrap(expected["offer_wire_hex"] as? String))

        var badMagic = wire
        badMagic[0] ^= 0xFF
        XCTAssertThrowsError(try RavenSecureLanRlb1V1.decodeOffer(badMagic)) { error in
            XCTAssertEqual(rlb1Error(error), .magic)
        }

        var badVersion = wire
        badVersion[4] = 0
        XCTAssertThrowsError(try RavenSecureLanRlb1V1.decodeOffer(badVersion)) { error in
            XCTAssertEqual(rlb1Error(error), .version)
        }

        var badKind = wire
        badKind[5] = 0
        XCTAssertThrowsError(try RavenSecureLanRlb1V1.decodeOffer(badKind)) { error in
            XCTAssertEqual(rlb1Error(error), .kind)
        }

        wire.append(0)
        XCTAssertThrowsError(try RavenSecureLanRlb1V1.decodeOffer(wire)) { error in
            XCTAssertEqual(rlb1Error(error), .trailingBytes)
        }
    }

    // MARK: - Identity bind

    func testRejectsIdentityMismatch() throws {
        let vector = try loadVector("rlb1_offer_001.json")
        let expected = try dictionary(vector["expected"])
        let wire = hex(try XCTUnwrap(expected["offer_wire_hex"] as? String))
        var bundle = try RavenSecureLanRlb1V1.decodeOffer(wire)

        bundle.prekey.identityEd25519Pub = Data(repeating: 0xAB, count: 32)
        XCTAssertThrowsError(try RavenSecureLanRlb1V1.requireIdentityBound(bundle)) { error in
            XCTAssertEqual(rlb1Error(error), .identityMismatch)
        }

        bundle = try RavenSecureLanRlb1V1.decodeOffer(wire)
        bundle.cert.deviceID = "other-device"
        XCTAssertThrowsError(try RavenSecureLanRlb1V1.requireIdentityBound(bundle)) { error in
            XCTAssertEqual(rlb1Error(error), .deviceIDMismatch)
        }

        var tamperedCert = bundle.cert
        tamperedCert.deviceID = "mismatch-device"
        let mismatched = RavenSecureLanRlb1V1.LanBundle(cert: tamperedCert, prekey: bundle.prekey)
        let tamperedWire = try RavenSecureLanRlb1V1.encodeOffer(mismatched)
        XCTAssertThrowsError(try RavenSecureLanRlb1V1.decodeOffer(tamperedWire)) { error in
            XCTAssertEqual(rlb1Error(error), .deviceIDMismatch)
        }
    }
}
