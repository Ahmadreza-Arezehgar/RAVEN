//
//  ATSAMLabGateReleaseVerificationTests.swift
//  RAVENTests
//
//  Release-only proof that lab gates compile fail-closed (no @testable import).
//

import XCTest
import RAVEN

final class ATSAMLabGateReleaseVerificationTests: XCTestCase {

    func testReleaseProductionGatesCompileDisabled() {
        #if DEBUG
        XCTFail("Release-only verification must run under Release configuration")
        #else
        XCTAssertTrue(ATSAMLabGate.releaseBuildAlwaysDisabled)
        XCTAssertFalse(ATSAMLabGate.isEnabled)
        XCTAssertTrue(ATSAMLabGate.releaseProductionGatesDisabled)
        #endif
    }
}
