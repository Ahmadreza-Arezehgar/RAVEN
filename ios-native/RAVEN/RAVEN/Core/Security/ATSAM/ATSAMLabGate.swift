//
//  ATSAMLabGate.swift
//  RAVEN
//
//  Single source of truth for DEBUG Test A lab unlock.
//  Release compiles to false; no runtime override can enable production paths.
//

import Foundation

public enum ATSAMLabGate {

    /// CI documentation anchor: Release builds must always compile to disabled.
    public static var releaseBuildAlwaysDisabled: Bool { true }

    /// DEBUG lab unlock. Release always false (compile-time).
    public static var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["RAVEN_LAB_TEST_A"] == "1" { return true }
        if ProcessInfo.processInfo.arguments.contains("-ravenLabTestA") { return true }
        return UserDefaults.standard.bool(forKey: "raven.lab.test_a")
        #else
        return false
        #endif
    }

    #if !DEBUG
    /// Release CI probe: every production gate must compile fail-closed.
    public static var releaseProductionGatesDisabled: Bool {
        !isEnabled
            && !ATSAMPairInitV1.productionEnabled
            && !ATSAMEndpointTransactionV1.productionEnabled
            && !ATSAMIndexedSessionProfile.productionEnabled
            && !ATSAMEndpointDurableAdapters.labTestAEnabled
    }
    #endif
}
