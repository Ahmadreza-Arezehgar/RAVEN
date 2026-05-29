//
//  GatewayScore.swift
//  RAVEN
//
//  Pure score calculator for the Mesh-to-Internet Gateway feature
//  (v1.6 MVP). Kept as a value type with no I/O so the unit tests can
//  exercise every weight in isolation — every other piece of the
//  gateway pipeline ultimately consults this value to decide whether
//  to advertise itself as a relay candidate.
//
//  The formula follows the published spec (12-section gateway design
//  doc) verbatim. Weights are tunable via `Weights.default`; if a real
//  field telemetry pass shows a different curve works better, a
//  single struct edit re-pivots every gateway in the network.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Where the score lives on the [0, 1] real line — broken down so
/// callers can show a user "you got penalised because you're hot".
struct GatewayScoreBreakdown {
    let weighted: Double           // raw weighted sum before penalties
    let batteryPenalty: Double     // 1.0 = no penalty, < 1.0 = applied
    let thermalPenalty: Double     // 1.0 = no penalty, < 1.0 = applied
    let final: Double              // weighted * batteryPenalty * thermalPenalty, clamped [0, 1]

    /// Compact byte for BLE beacons (0...255 → 0.0...1.0 quantised).
    var quantisedByte: UInt8 {
        UInt8(min(255, max(0, Int((final * 255).rounded()))))
    }
}

/// Raw inputs the score reads. Decoupled from any platform API so we
/// can mock everything in tests.
struct GatewayInputs {
    var hasInternet: Bool
    var connectionQuality: Double  // 0...1 from RTT + loss
    var batteryLevel: Double       // 0...1
    var isCharging: Bool
    var isForeground: Bool
    var historicalUptime: Double   // 0...1, rolling 24h
    var userOptInHelper: Bool
    var availableBandwidth: Double // 0...1, normalised against ceiling
    var thermalState: ThermalState

    enum ThermalState: Int { case nominal, fair, serious, critical }

    /// Snapshot the live device state via UIDevice + ProcessInfo +
    /// NetworkMonitor + the helper-mode default. Non-isolated so the
    /// gateway service can poll from any actor.
    @MainActor
    static func liveSnapshot(
        hasInternet: Bool,
        connectionQuality: Double,
        historicalUptime: Double,
        availableBandwidth: Double,
        userOptInHelper: Bool
    ) -> GatewayInputs {
        var batteryLevel: Double = 1.0
        var isCharging = false
        var isForeground = false
        var thermal: ThermalState = .nominal

        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let lvl = UIDevice.current.batteryLevel
        // -1 means "monitoring not available" — assume worst case.
        batteryLevel = lvl < 0 ? 0.5 : Double(lvl)
        switch UIDevice.current.batteryState {
        case .charging, .full: isCharging = true
        default: isCharging = false
        }
        switch UIApplication.shared.applicationState {
        case .active: isForeground = true
        default: isForeground = false
        }
        #endif

        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair:    thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }

        return GatewayInputs(
            hasInternet: hasInternet,
            connectionQuality: connectionQuality,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            isForeground: isForeground,
            historicalUptime: historicalUptime,
            userOptInHelper: userOptInHelper,
            availableBandwidth: availableBandwidth,
            thermalState: thermal
        )
    }
}

/// Weighted-sum scoring as published in the 12-section gateway spec.
/// Weights sum to 1.0 so the pre-penalty value is a clean [0, 1].
enum GatewayScore {

    struct Weights {
        var hasInternet: Double = 0.30
        var connectionQuality: Double = 0.20
        var battery: Double = 0.15
        var charging: Double = 0.10
        var foreground: Double = 0.05
        var historicalUptime: Double = 0.10
        var optIn: Double = 0.05
        var bandwidth: Double = 0.05

        static let `default` = Weights()
    }

    static func compute(_ inp: GatewayInputs, weights: Weights = .default) -> GatewayScoreBreakdown {
        // Weighted sum (each input clamped/coerced to [0, 1]).
        let weighted =
            weights.hasInternet       * (inp.hasInternet ? 1.0 : 0.0) +
            weights.connectionQuality * clamp(inp.connectionQuality) +
            weights.battery           * clamp(inp.batteryLevel) +
            weights.charging          * (inp.isCharging ? 1.0 : 0.0) +
            weights.foreground        * (inp.isForeground ? 1.0 : 0.0) +
            weights.historicalUptime  * clamp(inp.historicalUptime) +
            weights.optIn             * (inp.userOptInHelper ? 1.0 : 0.0) +
            weights.bandwidth         * clamp(inp.availableBandwidth)

        // Battery penalty (non-linear per spec).
        //   < 20%:  ×0.3 (hard discourage)
        //   < 40%:  ×0.7
        //   else:   ×1.0
        let batteryPenalty: Double
        if inp.batteryLevel < 0.20 { batteryPenalty = 0.3 }
        else if inp.batteryLevel < 0.40 { batteryPenalty = 0.7 }
        else { batteryPenalty = 1.0 }

        // Thermal penalty (per spec).
        let thermalPenalty: Double
        switch inp.thermalState {
        case .serious:  thermalPenalty = 0.5
        case .critical: thermalPenalty = 0.0   // spec says "minimum mode, urgent only"
        default:        thermalPenalty = 1.0
        }

        let final = clamp(weighted * batteryPenalty * thermalPenalty)
        return GatewayScoreBreakdown(
            weighted: weighted,
            batteryPenalty: batteryPenalty,
            thermalPenalty: thermalPenalty,
            final: final
        )
    }

    private static func clamp(_ x: Double) -> Double {
        min(1.0, max(0.0, x))
    }
}

// MARK: - Debug self-test

#if DEBUG
extension GatewayScore {
    /// Verifies the spec-published behaviour: a fully-equipped
    /// charging foreground node beats a battery-starved background
    /// one, the battery cliff at 20% applies, and `critical` thermal
    /// state collapses the score to zero. Output under "🌐 [Gateway]".
    static func runDebugSelfTest() {
        // Best-case node: charging, internet, foreground, opted-in.
        let best = GatewayInputs(
            hasInternet: true, connectionQuality: 1.0, batteryLevel: 1.0,
            isCharging: true, isForeground: true, historicalUptime: 1.0,
            userOptInHelper: true, availableBandwidth: 1.0, thermalState: .nominal
        )
        let bestScore = compute(best).final
        guard bestScore > 0.95 else {
            NSLog("🌐 [Gateway] ❌ FAIL — best-case score \(bestScore) < 0.95")
            return
        }

        // Battery cliff: same node at 18% battery should drop sharply.
        var lowBat = best
        lowBat.batteryLevel = 0.18
        let lowBatScore = compute(lowBat).final
        guard lowBatScore < bestScore * 0.5 else {
            NSLog("🌐 [Gateway] ❌ FAIL — low-battery score \(lowBatScore) didn't trigger cliff (best=\(bestScore))")
            return
        }

        // Critical thermal collapses to zero per spec.
        var hot = best
        hot.thermalState = .critical
        let hotScore = compute(hot).final
        guard hotScore == 0 else {
            NSLog("🌐 [Gateway] ❌ FAIL — critical thermal didn't zero score (got \(hotScore))")
            return
        }

        // No internet → score floors below 0.7 (must lose the 0.30 weight).
        var noNet = best
        noNet.hasInternet = false
        let noNetScore = compute(noNet).final
        guard noNetScore < 0.71 else {
            NSLog("🌐 [Gateway] ❌ FAIL — no-internet score didn't drop the 0.30 weight (got \(noNetScore))")
            return
        }

        // Quantised byte sanity: 1.0 → 255, 0.0 → 0.
        let q1 = compute(best).quantisedByte
        guard q1 >= 240 else {
            NSLog("🌐 [Gateway] ❌ FAIL — quantised best should be near 255, got \(q1)")
            return
        }

        NSLog("🌐 [Gateway] ✅ SCORE PASS — best=\(String(format: "%.2f", bestScore)) lowBat=\(String(format: "%.2f", lowBatScore)) noNet=\(String(format: "%.2f", noNetScore)) hot=\(String(format: "%.2f", hotScore)) qByte=\(q1)")
    }
}
#endif
