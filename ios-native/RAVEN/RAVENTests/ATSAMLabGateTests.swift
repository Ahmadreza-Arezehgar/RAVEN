//
//  ATSAMLabGateTests.swift
//  RAVENTests
//
//  Single-source-of-truth coverage for DEBUG lab unlock (Test A).
//

import XCTest
@testable import RAVEN

final class ATSAMLabGateTests: XCTestCase {

    private let userDefaultsKey = "raven.lab.test_a"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        super.tearDown()
    }

    func testReleaseBuildAlwaysDisabledIsTrue() {
        XCTAssertTrue(ATSAMLabGate.releaseBuildAlwaysDisabled)
    }

    func testReleaseConfigurationIsFailClosed() throws {
        #if DEBUG
        throw XCTSkip("Release-only LabGate fail-closed verification")
        #else
        XCTAssertFalse(ATSAMLabGate.isEnabled)
        XCTAssertFalse(ATSAMPairInitV1.productionEnabled)
        XCTAssertFalse(ATSAMEndpointTransactionV1.productionEnabled)
        XCTAssertFalse(ATSAMIndexedSessionProfile.productionEnabled)
        XCTAssertFalse(ATSAMEndpointDurableAdapters.labTestAEnabled)
        #endif
    }

    func testWrappersMatchLabGateInDebug() {
        #if DEBUG
        let gate = ATSAMLabGate.isEnabled
        XCTAssertEqual(ATSAMPairInitV1.productionEnabled, gate)
        XCTAssertEqual(ATSAMEndpointTransactionV1.productionEnabled, gate)
        XCTAssertEqual(ATSAMIndexedSessionProfile.productionEnabled, gate)
        XCTAssertEqual(ATSAMEndpointDurableAdapters.labTestAEnabled, gate)
        #else
        XCTAssertFalse(ATSAMPairInitV1.productionEnabled)
        XCTAssertFalse(ATSAMEndpointTransactionV1.productionEnabled)
        XCTAssertFalse(ATSAMIndexedSessionProfile.productionEnabled)
        XCTAssertFalse(ATSAMEndpointDurableAdapters.labTestAEnabled)
        #endif
    }

    func testIsEnabledFalseWhenAllUnlockSourcesOff() throws {
        UserDefaults.standard.set(false, forKey: userDefaultsKey)

        let envEnabled = ProcessInfo.processInfo.environment["RAVEN_LAB_TEST_A"] == "1"
        let launchArgEnabled = ProcessInfo.processInfo.arguments.contains("-ravenLabTestA")

        if envEnabled || launchArgEnabled {
            throw XCTSkip("Test host has RAVEN_LAB_TEST_A or -ravenLabTestA; cannot isolate defaults-only path")
        }

        XCTAssertFalse(ATSAMLabGate.isEnabled)
    }

    func testUserDefaultsKeyEnablesLabGate() throws {
        let envEnabled = ProcessInfo.processInfo.environment["RAVEN_LAB_TEST_A"] == "1"
        let launchArgEnabled = ProcessInfo.processInfo.arguments.contains("-ravenLabTestA")

        if envEnabled || launchArgEnabled {
            throw XCTSkip("Test host already has lab unlock via env/launch arg")
        }

        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        XCTAssertTrue(ATSAMLabGate.isEnabled)
        XCTAssertTrue(ATSAMEndpointDurableAdapters.labTestAEnabled)
    }

    func testEnvironmentVariableEnablesLabGate() throws {
        guard ProcessInfo.processInfo.environment["RAVEN_LAB_TEST_A"] == "1" else {
            throw XCTSkip("RAVEN_LAB_TEST_A=1 not set in test host environment")
        }
        UserDefaults.standard.set(false, forKey: userDefaultsKey)
        XCTAssertTrue(ATSAMLabGate.isEnabled)
    }

    func testLaunchArgumentEnablesLabGate() throws {
        guard ProcessInfo.processInfo.arguments.contains("-ravenLabTestA") else {
            throw XCTSkip("-ravenLabTestA not present in test host launch arguments")
        }
        UserDefaults.standard.set(false, forKey: userDefaultsKey)
        XCTAssertTrue(ATSAMLabGate.isEnabled)
    }
}
