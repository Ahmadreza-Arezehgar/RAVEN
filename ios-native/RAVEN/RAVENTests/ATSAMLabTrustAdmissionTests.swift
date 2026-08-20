//
//  ATSAMLabTrustAdmissionTests.swift
//  RAVENTests — lab BlockList + sticky revocation Keychain admission.
//

#if DEBUG

import Foundation
import XCTest
@testable import RAVEN

@MainActor
final class ATSAMLabTrustAdmissionTests: XCTestCase {

    private let labDefaultsKey = "raven.lab.test_a"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Must run (no XCTSkip): enable lab via UserDefaults when env/launch-arg absent.
        if ProcessInfo.processInfo.environment["RAVEN_LAB_TEST_A"] != "1",
           !ProcessInfo.processInfo.arguments.contains("-ravenLabTestA") {
            UserDefaults.standard.set(true, forKey: labDefaultsKey)
        }
        XCTAssertTrue(
            ATSAMEndpointDurableAdapters.labTestAEnabled,
            "labTestAEnabled must be true for ATSAMLabTrustAdmissionTests"
        )
        ATSAMLabTrustStoreDebugKeychain.reset()
    }

    override func tearDownWithError() throws {
        ATSAMLabTrustStoreDebugKeychain.reset()
        UserDefaults.standard.removeObject(forKey: labDefaultsKey)
        try super.tearDownWithError()
    }

    func testBlockPersistsAndUnblockClearsOnlyBlock() throws {
        let device = Data((0..<32).map { UInt8($0 ^ 0xA5) })
        let identity = Data((0..<32).map { UInt8($0 ^ 0x5A) })

        try ATSAMLabTrustStore.unblockPeer(deviceEd: device, identityPub: identity, noiseEd: device)
        XCTAssertFalse(
            ATSAMLabTrustStore.isAdmissionDenied(
                deviceEd: device,
                identityPub: identity,
                noiseEd: device
            )
        )

        try ATSAMLabTrustStore.blockPeer(deviceEd: device, identityPub: identity, noiseEd: device)
        XCTAssertTrue(
            ATSAMLabTrustStore.isAdmissionDenied(
                deviceEd: device,
                identityPub: identity,
                noiseEd: device
            )
        )
        XCTAssertFalse(ATSAMLabTrustStore.peerIsTrusted(deviceEd: device))

        try ATSAMLabTrustStore.recordRevocationDeny(deviceEd: device, identityPub: identity)
        try ATSAMLabTrustStore.unblockPeer(deviceEd: device, identityPub: identity, noiseEd: device)

        // Unblock must not clear sticky revocation.
        XCTAssertTrue(
            ATSAMLabTrustStore.isAdmissionDenied(
                deviceEd: device,
                identityPub: identity,
                noiseEd: nil
            )
        )
        XCTAssertFalse(ATSAMLabTrustStore.peerIsTrusted(deviceEd: device))
        XCTAssertFalse(ATSAMLabTrustStore.peerIsTrusted(identityPub: identity))
    }

    func testKeychainProbeErrorFailsClosedAsDenied() throws {
        let device = Data((0..<32).map { UInt8($0 ^ 0x11) })
        ATSAMLabTrustStoreDebugKeychain.forceAll(.error)
        XCTAssertTrue(
            ATSAMLabTrustStore.isAdmissionDenied(
                deviceEd: device,
                identityPub: nil,
                noiseEd: nil
            )
        )
        XCTAssertFalse(ATSAMLabTrustStore.peerIsTrusted(deviceEd: device))
    }

    func testKeychainAbsentIsNotDeniedWithoutMarkers() throws {
        let device = Data((0..<32).map { UInt8($0 ^ 0x22) })
        try ATSAMLabTrustStore.unblockPeer(deviceEd: device, identityPub: device, noiseEd: device)
        ATSAMLabTrustStoreDebugKeychain.forceAll(.absent)
        XCTAssertFalse(
            ATSAMLabTrustStore.isAdmissionDenied(
                deviceEd: device,
                identityPub: device,
                noiseEd: device
            )
        )
    }

    func testContactBookIsBlockedUsesAdmissionDeny() throws {
        let device = Data((0..<32).map { UInt8($0 ^ 0x33) })
        let book = RavenSecureLanLabTrustContactBook()
        try ATSAMLabTrustStore.unblockPeer(deviceEd: device, identityPub: device, noiseEd: device)
        XCTAssertFalse(
            book.isBlocked(deviceEdPub: device, userEdPub: device, noiseEdPub: device)
        )
        try ATSAMLabTrustStore.blockPeer(deviceEd: device)
        XCTAssertTrue(
            book.isBlocked(deviceEdPub: device, userEdPub: Data(count: 32), noiseEdPub: Data(count: 32))
        )
    }

    // MARK: - applyImportedRevocation

    func testApplyImportedRevocationValidStickyDenyAndUnblockPreserves() throws {
        let fixture = try loadValidRevocation001()
        try clearAdmissionMarkers(deviceEd: fixture.deviceEd, identityPub: fixture.identityEdPub)

        let rec = try ATSAMLabTrustStore.applyImportedRevocation(
            wire: fixture.wire,
            identityEdPub: fixture.identityEdPub
        )
        XCTAssertEqual(rec.deviceEdPub, fixture.deviceEd)
        XCTAssertTrue(
            ATSAMLabTrustStore.isAdmissionDenied(
                deviceEd: fixture.deviceEd,
                identityPub: fixture.identityEdPub,
                noiseEd: nil
            )
        )

        try ATSAMLabTrustStore.unblockPeer(
            deviceEd: fixture.deviceEd,
            identityPub: fixture.identityEdPub,
            noiseEd: nil
        )
        XCTAssertTrue(
            ATSAMLabTrustStore.isAdmissionDenied(
                deviceEd: fixture.deviceEd,
                identityPub: fixture.identityEdPub,
                noiseEd: nil
            ),
            "unblockPeer must not clear sticky revocation markers"
        )
    }

    func testApplyImportedRevocationWrongSignerRejectsWithoutMarkers() throws {
        let fixture = try loadValidRevocation001()
        try clearAdmissionMarkers(deviceEd: fixture.deviceEd, identityPub: fixture.identityEdPub)

        let wrongSigner = Data((0..<32).map { UInt8(($0 &+ 7) ^ 0xC3) })
        XCTAssertThrowsError(
            try ATSAMLabTrustStore.applyImportedRevocation(wire: fixture.wire, identityEdPub: wrongSigner)
        )
        assertNoAdmissionMarkers(deviceEd: fixture.deviceEd, identityPub: fixture.identityEdPub)
    }

    func testApplyImportedRevocationTamperedWireRejectsWithoutMarkers() throws {
        let fixture = try loadValidRevocation001()
        try clearAdmissionMarkers(deviceEd: fixture.deviceEd, identityPub: fixture.identityEdPub)

        var tampered = fixture.wire
        tampered[tampered.count / 2] ^= 0xFF
        XCTAssertThrowsError(
            try ATSAMLabTrustStore.applyImportedRevocation(
                wire: tampered,
                identityEdPub: fixture.identityEdPub
            )
        )
        assertNoAdmissionMarkers(deviceEd: fixture.deviceEd, identityPub: fixture.identityEdPub)
    }

    func testApplyImportedRevocationWrongIdentityRejectsWithoutMarkers() throws {
        let fixture = try loadValidRevocation001()
        try clearAdmissionMarkers(deviceEd: fixture.deviceEd, identityPub: fixture.identityEdPub)

        // Distinct identity key material (not the vector signer).
        let wrongIdentity = Data(hex: "1111111111111111111111111111111111111111111111111111111111111111")
        XCTAssertThrowsError(
            try ATSAMLabTrustStore.applyImportedRevocation(
                wire: fixture.wire,
                identityEdPub: wrongIdentity
            )
        )
        assertNoAdmissionMarkers(deviceEd: fixture.deviceEd, identityPub: fixture.identityEdPub)
        assertNoAdmissionMarkers(deviceEd: fixture.deviceEd, identityPub: wrongIdentity)
    }

    // MARK: - Helpers

    private struct ValidRevocation001 {
        let wire: Data
        let deviceEd: Data
        let identityEdPub: Data
    }

    private func loadValidRevocation001() throws -> ValidRevocation001 {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared-vectors/rvn1/device_revocation/valid_001.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "valid_001.json required")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root)) as? [String: Any]
        let inputs = try XCTUnwrap(json?["inputs"] as? [String: Any])
        let expected = try XCTUnwrap(json?["expected"] as? [String: Any])
        return ValidRevocation001(
            wire: Data(hex: try XCTUnwrap(expected["wire_hex"] as? String)),
            deviceEd: Data(hex: try XCTUnwrap(inputs["device_ed_pub_hex"] as? String)),
            identityEdPub: Data(hex: try XCTUnwrap(inputs["identity_ed_pub_hex"] as? String))
        )
    }

    private func clearAdmissionMarkers(deviceEd: Data, identityPub: Data) throws {
        try ATSAMLabTrustStore.unblockPeer(deviceEd: deviceEd, identityPub: identityPub, noiseEd: deviceEd)
        try ATSAMLabTrustStoreDebugKeychain.clearRevocationMarkers(
            deviceEd: deviceEd,
            identityPub: identityPub
        )
        ATSAMLabTrustStoreDebugKeychain.reset()
        assertNoAdmissionMarkers(deviceEd: deviceEd, identityPub: identityPub)
    }

    private func assertNoAdmissionMarkers(deviceEd: Data, identityPub: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            ATSAMLabTrustStore.isAdmissionDenied(
                deviceEd: deviceEd,
                identityPub: identityPub,
                noiseEd: nil
            ),
            "failed applyImportedRevocation must not create sticky revocation markers",
            file: file,
            line: line
        )
    }
}

private extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2))
        var result = Data(capacity: hex.count / 2)
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            result.append(UInt8(hex[cursor..<next], radix: 16)!)
            cursor = next
        }
        self = result
    }
}

#endif
