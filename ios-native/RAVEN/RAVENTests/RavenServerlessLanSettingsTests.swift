//
//  RavenServerlessLanSettingsTests.swift
//  RAVENTests — config validation + fingerprint (no secrets).
//

import XCTest
@testable import RAVEN

final class RavenServerlessLanSettingsTests: XCTestCase {

    func testAppHostRecognizesXCTestAndSuppressesExternalSideEffects() {
        XCTAssertTrue(ProcessInfo.processInfo.isRunningRavenTests)
        XCTAssertTrue(RavenRuntimePolicy.isXCTestHost)
        XCTAssertFalse(RavenRuntimePolicy.allowsExternalSideEffects)
    }

    func testRuntimeDetectorUsesEarlyInjectionEnvironmentWithoutLoadedXCTestClass() {
        let detector = RavenTestRuntimeDetector(
            environment: ["XCInjectBundleInto": "/tmp/RAVEN.app/RAVEN"],
            arguments: ["/tmp/RAVEN.app/RAVEN"],
            classLookup: { _ in nil }
        )

        XCTAssertTrue(detector.isRunningTests())
    }

    func testRuntimeDetectorDoesNotDisableProductionShapedLaunch() {
        let detector = RavenTestRuntimeDetector(
            environment: ["PATH": "/usr/bin"],
            arguments: ["/Applications/RAVEN.app/RAVEN"],
            classLookup: { _ in nil }
        )

        XCTAssertFalse(detector.isRunningTests())
    }

    func testAppStartupNeverReachedAnExternalSideEffectBoundary() async throws {
        // Give SwiftUI onAppear/.task and scene-activation callbacks a chance
        // to run. They must all stop before the HTTP/WebSocket/APNs boundary.
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual(
            RavenTestExternalSideEffectAudit.actualAttemptCount,
            0,
            "Unexpected XCTest external attempts: \(RavenTestExternalSideEffectAudit.actualAttemptLabels)"
        )
        XCTAssertEqual(
            RavenTestExternalSideEffectAudit.blockedRequestCount,
            0,
            "App startup reached the XCTest URLSession firewall instead of stopping at its service gate"
        )

        // Prove the backstop itself only after recording the clean startup
        // snapshot. Keeping both assertions in one test makes the result
        // independent of XCTest method randomization/order.
        let configuration = RavenRuntimePolicy.protectForXCTest(.ephemeral)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(
                from: URL(string: "https://example.invalid/raven-xctest-firewall")!
            )
            XCTFail("XCTest firewall unexpectedly allowed an external URLSession request")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSURLErrorDomain)
            XCTAssertEqual(nsError.code, URLError.dataNotAllowed.rawValue)
        }
        XCTAssertEqual(RavenTestExternalSideEffectAudit.blockedRequestCount, 1)
    }

    override func setUp() {
        super.setUp()
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        RavenServerlessLanConfig.clear()
    }

    override func tearDown() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(false)
        RavenServerlessLanConfig.clear()
        super.tearDown()
    }

    func testPubHexValidation() {
        XCTAssertFalse(RavenServerlessLanSettingsView.isValidPubHex(""))
        XCTAssertFalse(RavenServerlessLanSettingsView.isValidPubHex("abc"))
        XCTAssertFalse(RavenServerlessLanSettingsView.isValidPubHex(String(repeating: "g", count: 64)))
        let ok = String(repeating: "ab", count: 32)
        XCTAssertTrue(RavenServerlessLanSettingsView.isValidPubHex(ok))
        XCTAssertEqual(ok.count, 64)
    }

    func testFingerprintFromPubHexIsStableAndPublicOnly() {
        let pub = String(repeating: "11", count: 32)
        let fp1 = RavenServerlessLanSettingsView.fingerprint(ofPubHex: pub)
        let fp2 = RavenServerlessLanSettingsView.fingerprint(ofPubHex: pub)
        XCTAssertNotNil(fp1)
        XCTAssertEqual(fp1, fp2)
        XCTAssertFalse(fp1!.contains("seed"))
        // Never treat the raw 64-char pub as the fingerprint label.
        XCTAssertNotEqual(fp1, pub)
    }

    func testConfigRoundTripNoSecrets() {
        FeatureFlag.ravenEnvelopeV1.setEnabled(true)
        let pub = String(repeating: "22", count: 32)
        let cfg = RavenServerlessLanConfig(host: "192.168.1.10", port: 7420, peerPubHex: pub)
        cfg.save()
        let loaded = RavenServerlessLanConfig.stored
        XCTAssertEqual(loaded?.host, "192.168.1.10")
        XCTAssertEqual(loaded?.port, 7420)
        XCTAssertEqual(loaded?.peerPubHex, pub)
        RavenServerlessLanConfig.clear()
        XCTAssertNil(RavenServerlessLanConfig.stored)
    }

    func testInvalidPortOrShortPubNotStoredViaHelpers() {
        XCTAssertFalse(RavenServerlessLanSettingsView.isValidPubHex("aa"))
        // Empty host / zero port rejected by stored getter when keys incomplete.
        UserDefaults.standard.set("127.0.0.1", forKey: "raven.serverless.lan.host")
        UserDefaults.standard.set(0, forKey: "raven.serverless.lan.port")
        UserDefaults.standard.set(String(repeating: "33", count: 32), forKey: "raven.serverless.lan.peer_pub_hex")
        XCTAssertNil(RavenServerlessLanConfig.stored)
        RavenServerlessLanConfig.clear()
    }
}
