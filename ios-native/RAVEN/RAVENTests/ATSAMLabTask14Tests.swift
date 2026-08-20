//
//  ATSAMLabTask14Tests.swift
//  RAVENTests — Task 14: device-pub bootstrap, foreground listen, checklist.
//

#if DEBUG

import CryptoKit
import Foundation
import XCTest
@testable import RAVEN

@MainActor
final class ATSAMLabTask14Tests: XCTestCase {

    private let userDefaultsKey = "raven.lab.test_a"
    private let checklistRelative = "node/scripts/ios_lan_lab_checklist.md"

    override func setUp() async throws {
        try await super.setUp()
        try? ATSAMLabTrustStore.removeImportedPeerCertsForTesting()
        RavenSecureLanLabListenerController.shared.stopLabListen()
        RavenSecureLanLabListenerController.shared.setForegroundForTesting(true)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        RavenSecureLanLabListenerController.shared.stopLabListen()
        RavenSecureLanLabListenerController.shared.setForegroundForTesting(true)
        try? ATSAMLabTrustStore.removeImportedPeerCertsForTesting()
        try await super.tearDown()
    }

    private func withLabEnabled(_ body: () throws -> Void) throws {
        let envEnabled = ProcessInfo.processInfo.environment["RAVEN_LAB_TEST_A"] == "1"
        let launchArgEnabled = ProcessInfo.processInfo.arguments.contains("-ravenLabTestA")
        if envEnabled || launchArgEnabled {
            try body()
            return
        }
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }
        XCTAssertTrue(ATSAMLabGate.isEnabled)
        try body()
    }

    private func samplePeerCertJSON(
        userSeed: UInt8,
        deviceSeed: UInt8
    ) throws -> String {
        let userEd = Data(repeating: userSeed, count: 32)
        let deviceEd = Data(repeating: deviceSeed, count: 32)
        let deviceX = Data(repeating: 0xAA, count: 32)
        let sig = Data(repeating: 0xBB, count: 64)
        let dto = ATSAMLabTrustStore.LabCertJSON(
            device_ed_pub: deviceEd.ravenHex,
            device_x_pub: deviceX.ravenHex,
            device_id: "lab-test-peer",
            not_before_ms: 1,
            not_after_ms: 9_999_999_999_999,
            capabilities: 0,
            signature: sig.ravenHex,
            user_ed_pub: userEd.ravenHex
        )
        let data = try JSONEncoder().encode(dto)
        return String(decoding: data, as: UTF8.self)
    }

    func testImportPeerCertJSONStoresDeviceEdPubForExpectedBind() throws {
        try withLabEnabled {
            let json = try samplePeerCertJSON(userSeed: 0x01, deviceSeed: 0x02)
            try ATSAMLabTrustStore.importPeerCertJSON(json)

            let userEd = Data(repeating: 0x01, count: 32)
            let deviceEd = Data(repeating: 0x02, count: 32)
            XCTAssertTrue(ATSAMLabTrustStore.peerIsTrusted(deviceEd: deviceEd))
            XCTAssertTrue(ATSAMLabTrustStore.peerIsTrusted(identityPub: userEd))
            XCTAssertEqual(try ATSAMLabTrustStore.peerDeviceEdPub(forIdentityPub: userEd), deviceEd)

            let book = RavenSecureLanLabTrustContactBook()
            XCTAssertTrue(book.isLocalContact(deviceEdPub: deviceEd, userEdPub: userEd))
            XCTAssertFalse(
                book.isLocalContact(
                    deviceEdPub: Data(repeating: 0xFF, count: 32),
                    userEdPub: Data(repeating: 0xFE, count: 32)
                )
            )
        }
    }

    func testRemoveImportedPeerClearsContactTrust() throws {
        try withLabEnabled {
            let json = try samplePeerCertJSON(userSeed: 0x03, deviceSeed: 0x04)
            try ATSAMLabTrustStore.importPeerCertJSON(json)
            let deviceEd = Data(repeating: 0x04, count: 32)
            XCTAssertTrue(ATSAMLabTrustStore.peerIsTrusted(deviceEd: deviceEd))
            try ATSAMLabTrustStore.removeImportedPeer(deviceEd: deviceEd)
            XCTAssertFalse(ATSAMLabTrustStore.peerIsTrusted(deviceEd: deviceEd))
        }
    }

    func testLabGateClosedRefusesSecureListen() throws {
        UserDefaults.standard.set(false, forKey: userDefaultsKey)
        let envEnabled = ProcessInfo.processInfo.environment["RAVEN_LAB_TEST_A"] == "1"
        let launchArgEnabled = ProcessInfo.processInfo.arguments.contains("-ravenLabTestA")
        if envEnabled || launchArgEnabled {
            throw XCTSkip("Cannot isolate lab-gate-closed while env/launch arg unlock is active")
        }

        RavenSecureLanLabListenerController.shared.stopLabListen()
        XCTAssertFalse(ATSAMLabGate.isEnabled)

        XCTAssertThrowsError(
            try RavenSecureLanTransportV1.configureLabListenIfEnabled(port: 17421)
        ) { error in
            XCTAssertEqual(error as? RavenSecureLanListenError, .labGateClosed)
        }
        XCTAssertFalse(RavenSecureLanLabListenerController.shared.isListening)
    }

    func testForegroundStopOnBackgroundSimulation() throws {
        try withLabEnabled {
            RavenSecureLanLabListenerController.shared.stopLabListen()
            RavenSecureLanLabListenerController.shared.setForegroundForTesting(true)
            let port: UInt16 = UInt16(48_000 + Int.random(in: 0..<999))
            try RavenSecureLanTransportV1.configureLabListenIfEnabled(port: port)
            XCTAssertTrue(RavenSecureLanLabListenerController.shared.isListening)

            RavenSecureLanLabListenerController.shared.setForegroundForTesting(false)
            XCTAssertFalse(RavenSecureLanLabListenerController.shared.isListening)
            XCTAssertFalse(RavenSecureLanLabListenerController.shared.isForeground)

            RavenSecureLanLabListenerController.shared.setForegroundForTesting(true)
            XCTAssertTrue(RavenSecureLanLabListenerController.shared.isListening)
        }
    }

    func testChecklistFileExistsWithRequiredSections() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checklist = repoRoot.appendingPathComponent(checklistRelative)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: checklist.path),
            "Missing checklist at \(checklist.path)"
        )
        let text = try String(contentsOf: checklist, encoding: .utf8)
        XCTAssertTrue(text.contains("contacts.json"), "checklist must mention contacts.json")
        XCTAssertTrue(text.contains("device_ed_pub") || text.contains("device Ed25519"), "§6.3.1 device pub note")
        XCTAssertTrue(text.contains("RAVEN_LAB_TEST_A") || text.contains("-ravenLabTestA"), "lab unlock reminder")
        XCTAssertTrue(text.contains("foreground"), "foreground-only listener note")
        XCTAssertTrue(text.contains("PairInit"), "manual PairInit step")
        XCTAssertTrue(text.contains("Delete contact") || text.contains("Remove peer"), "delete contact step")
    }
}

#endif
