//
//  ATSAMMlKem768IncrementalLabTests.swift
//  RAVENTests — lab-only ML-KEM-768 incremental encapsulation fixture coverage.
//
//  Always-on (no Rust FFI link):
//    xcodebuild test -project RAVEN.xcodeproj -scheme RAVEN \
//      -destination 'platform=iOS Simulator,name=RAVEN-iPhone-15' \
//      -only-testing:RAVENTests/ATSAMMlKem768IncrementalLabTests
//  Optional linked FFI gate:
//    ./node/scripts/ios_mlkem768_incremental_lab_gate.sh
//

#if DEBUG

import CryptoKit
import Foundation
import XCTest

final class ATSAMMlKem768IncrementalLabTests: XCTestCase {

    func testFixtureSchemaAndAllFieldLengths() throws {
        let fixture = try loadFixture()
        let lab = ATSAMMlKem768IncrementalLab.self

        XCTAssertEqual(fixture.vectorID, "mlkem768_incremental_encaps_001")
        XCTAssertTrue(fixture.labOnly)
        XCTAssertEqual(fixture.material.seed.count, lab.seedLength)
        XCTAssertEqual(fixture.material.coins.count, lab.coinsLength)
        XCTAssertEqual(fixture.material.dk.count, lab.dkLength)
        XCTAssertEqual(fixture.material.header.count, lab.headerLength)
        XCTAssertEqual(fixture.material.ekVector.count, lab.ekVectorLength)
        XCTAssertEqual(fixture.material.encapsState.count, lab.encapsStateLength)
        XCTAssertEqual(fixture.material.ct1.count, lab.ct1Length)
        XCTAssertEqual(fixture.material.ct2.count, lab.ct2Length)
        XCTAssertEqual(fixture.material.sharedSecret.count, lab.sharedSecretLength)
    }

    func testSecretWipeClearsSecretBuffers() throws {
        var material = try loadFixture().material
        XCTAssertFalse(material.dk.allSatisfy { $0 == 0 })
        XCTAssertFalse(material.sharedSecret.allSatisfy { $0 == 0 })
        material.wipeSecrets()
        XCTAssertTrue(material.dk.allSatisfy { $0 == 0 })
        XCTAssertTrue(material.coins.allSatisfy { $0 == 0 })
        XCTAssertTrue(material.seed.allSatisfy { $0 == 0 })
        XCTAssertTrue(material.encapsState.allSatisfy { $0 == 0 })
        XCTAssertTrue(material.sharedSecret.allSatisfy { $0 == 0 })
    }

    func testFixtureHeaderIsRhoThenSHA3OfVectorAndRho() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("CryptoKit SHA3_256 requires iOS/macOS 26+")
        }
        let material = try loadFixture().material
        let rho = Data(material.header.prefix(32))
        var hashInput = material.ekVector
        hashInput.append(rho)

        var expectedHeader = rho
        expectedHeader.append(Data(SHA3_256.hash(data: hashInput)))

        XCTAssertEqual(material.header, expectedHeader)
    }

    func testValidatorRejectsWrongLength() throws {
        var material = try loadFixture().material
        material.ekVector.removeLast()

        XCTAssertThrowsError(try ATSAMMlKem768IncrementalLab.validate(material)) { error in
            XCTAssertEqual(
                error as? ATSAMMlKem768IncrementalLab.ValidationError,
                .invalidLength(
                    field: "ek_vector_hex",
                    expected: ATSAMMlKem768IncrementalLab.ekVectorLength,
                    actual: ATSAMMlKem768IncrementalLab.ekVectorLength - 1
                )
            )
        }
    }

    func testValidatorRejectsBadHeaderHash() throws {
        try requireSHA3()
        var material = try loadFixture().material
        material.header[material.header.index(before: material.header.endIndex)] ^= 0x01

        XCTAssertThrowsError(try ATSAMMlKem768IncrementalLab.validate(material)) { error in
            XCTAssertEqual(
                error as? ATSAMMlKem768IncrementalLab.ValidationError,
                .headerHashMismatch
            )
        }
    }

    #if RAVEN_MLKEM768_INCREMENTAL_FFI

    func testFFIExportedLengthConstantsMatchHeader() throws {
        ATSAMMlKem768IncrementalLab.assertExportedLengthConstants()
        XCTAssertEqual(ATSAMMlKem768IncrementalLab.seedLength, 64)
        XCTAssertEqual(ATSAMMlKem768IncrementalLab.dkLength, 2_400)
        XCTAssertEqual(ATSAMMlKem768IncrementalLab.sharedSecretLength, 32)
    }

    func testFFIEncapsulatesAndDecapsulatesFixture() throws {
        var material = try loadFixture().material
        defer { material.wipeSecrets() }

        var keyPair = try ATSAMMlKem768IncrementalLab.keygenSplit(seed: material.seed)
        defer { keyPair.wipeSecrets() }
        XCTAssertEqual(keyPair.dk, material.dk)
        XCTAssertEqual(keyPair.header, material.header)
        XCTAssertEqual(keyPair.ekVector, material.ekVector)
        try ATSAMMlKem768IncrementalLab.validateSplit(
            header: keyPair.header,
            ekVector: keyPair.ekVector
        )

        var first = try ATSAMMlKem768IncrementalLab.encaps1(
            header: keyPair.header,
            coins: material.coins
        )
        defer { first.wipeSecrets() }
        XCTAssertEqual(first.state, material.encapsState)
        XCTAssertEqual(first.ct1, material.ct1)
        XCTAssertEqual(first.sharedSecret, material.sharedSecret)

        var ct2 = try ATSAMMlKem768IncrementalLab.encaps2(
            state: first.state,
            header: keyPair.header,
            ekVector: keyPair.ekVector
        )
        defer { ATSAMMlKem768IncrementalLab.wipe(&ct2) }
        XCTAssertEqual(ct2, material.ct2)

        var decapsulated = try ATSAMMlKem768IncrementalLab.decaps(
            dk: keyPair.dk,
            ct1: first.ct1,
            ct2: ct2
        )
        defer { ATSAMMlKem768IncrementalLab.wipe(&decapsulated) }
        XCTAssertEqual(decapsulated, material.sharedSecret)
    }

    func testFFIEncaps2RejectsTamperedVector() throws {
        var material = try loadFixture().material
        defer { material.wipeSecrets() }
        var tamperedVector = material.ekVector
        tamperedVector[0] ^= 0x01

        XCTAssertThrowsError(
            try ATSAMMlKem768IncrementalLab.encaps2(
                state: material.encapsState,
                header: material.header,
                ekVector: tamperedVector
            )
        ) { error in
            XCTAssertEqual(
                error as? ATSAMMlKem768IncrementalLab.FFIError,
                .operationFailed(name: "encaps2", status: 2)
            )
        }
    }

    func testFFITamperedCiphertextUsesImplicitRejectionSecret() throws {
        var material = try loadFixture().material
        defer { material.wipeSecrets() }
        var tamperedCT2 = material.ct2
        tamperedCT2[0] ^= 0x01

        var rejectedSecret = try ATSAMMlKem768IncrementalLab.decaps(
            dk: material.dk,
            ct1: material.ct1,
            ct2: tamperedCT2
        )
        defer { ATSAMMlKem768IncrementalLab.wipe(&rejectedSecret) }
        XCTAssertNotEqual(rejectedSecret, material.sharedSecret)
    }

    #else

    func testFFIPathRequiresExplicitLabLink() throws {
        throw XCTSkip(
            "Build and link raven-mlkem768-incremental-ffi with "
                + "RAVEN_MLKEM768_INCREMENTAL_FFI; run the lab gate script"
        )
    }

    #endif

    private func requireSHA3() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("CryptoKit SHA3_256 requires iOS/macOS 26+")
        }
    }

    private func loadFixture() throws -> LoadedFixture {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1 not found — open monorepo checkout")
        }
        let url = root.appendingPathComponent(
            "atsam/mlkem768_incremental_encaps_001.json"
        )
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        func dataField(_ name: String) throws -> Data {
            let value = try XCTUnwrap(object[name] as? String, "missing \(name)")
            return try decodeHex(value, field: name)
        }

        return LoadedFixture(
            vectorID: try XCTUnwrap(object["vector_id"] as? String),
            labOnly: try XCTUnwrap(object["lab_only"] as? Bool),
            material: ATSAMMlKem768IncrementalLab.Material(
                seed: try dataField("seed_hex"),
                coins: try dataField("coins_hex"),
                dk: try dataField("dk_hex"),
                header: try dataField("header_hex"),
                ekVector: try dataField("ek_vector_hex"),
                encapsState: try dataField("encaps_state_hex"),
                ct1: try dataField("ct1_hex"),
                ct2: try dataField("ct2_hex"),
                sharedSecret: try dataField("ss_hex")
            )
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

private struct LoadedFixture {
    let vectorID: String
    let labOnly: Bool
    let material: ATSAMMlKem768IncrementalLab.Material
}

private enum FixtureError: Error {
    case invalidHex(String)
}

#endif
