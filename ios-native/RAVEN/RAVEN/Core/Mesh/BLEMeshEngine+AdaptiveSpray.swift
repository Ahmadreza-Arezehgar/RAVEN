//
//  BLEMeshEngine+AdaptiveSpray.swift
//  RAVEN
//
//  Adaptive Spray Count — dynamically adjusts the spray budget based on
//  network density derived from PRoPHET encounter history.
//
//  In dense networks (concerts, events): fewer sprays → saves battery
//  In sparse networks (rural areas): more sprays → improves delivery
//
//  SECURITY: Spray count is set ONLY at message creation by the sender.
//  Relay nodes NEVER modify spray counts — that would be an attack vector.
//  The adaptive value must never exceed MeshCryptoService.protocolMaxSprayCounter (50).
//

import Foundation

// MARK: - Adaptive Spray Count

extension BLEMeshEngine {
    
    /// Compute adaptive spray count based on current network density.
    /// Called only during initial message creation — never during relay.
    ///
    /// - Returns: Spray count clamped to protocol max (50).
    func adaptiveSprayCount() async -> Int {
        guard FeatureFlag.isAdaptiveSprayEnabled else {
            // Feature disabled — use static budget
            return PremiumLimits.meshSprayBudget
        }
        
        // RAVEN+ users get the full premium budget regardless of density
        if PremiumLimits.isPremium {
            return PremiumLimits.meshSprayBudget
        }
        
        let density = await DeliveryPredictabilityService.shared.networkDensity()
        let base = Self.baseSprayCount(for: density)
        
        let clamped = min(base, MeshCryptoService.protocolMaxSprayCounter)
        
        #if DEBUG
        let stats = await DeliveryPredictabilityService.shared.encounterStats()
        print("📡 [AdaptiveSpray] Density: \(density.rawValue) | Base: \(base) | Final: \(clamped) | Peers 24h: \(stats.uniquePeersLast24h) 1h: \(stats.uniquePeersLastHour)")
        #endif
        
        return clamped
    }
    
    /// Base spray count derived from network density classification.
    private static func baseSprayCount(
        for density: DeliveryPredictabilityService.NetworkDensity
    ) -> Int {
        switch density {
        case .verySparse: return 12   // Aggressive — few peers, maximize chance
        case .sparse:     return 10   // Historical sparse, no recent activity
        case .moderate:   return 7    // Some peers active
        case .medium:     return 5    // Default (matches original hardcode)
        case .dense:      return 3    // Conservative — many peers, save battery
        }
    }
    
    /// Spray adaptation info for debug panel display.
    func sprayAdaptationInfo() async -> SprayAdaptationInfo {
        let density = await DeliveryPredictabilityService.shared.networkDensity()
        let stats = await DeliveryPredictabilityService.shared.encounterStats()
        let currentSpray = await adaptiveSprayCount()
        let base = Self.baseSprayCount(for: density)
        
        return SprayAdaptationInfo(
            density: density,
            baseSpray: base,
            currentSpray: currentSpray,
            uniquePeers24h: stats.uniquePeersLast24h,
            uniquePeers1h: stats.uniquePeersLastHour,
            isAdaptiveEnabled: FeatureFlag.isAdaptiveSprayEnabled,
            isPremiumOverride: PremiumLimits.isPremium
        )
    }
}

// MARK: - Debug Info Model

/// Display model for the spray adaptation debug panel.
struct SprayAdaptationInfo {
    let density: DeliveryPredictabilityService.NetworkDensity
    let baseSpray: Int
    let currentSpray: Int
    let uniquePeers24h: Int
    let uniquePeers1h: Int
    let isAdaptiveEnabled: Bool
    let isPremiumOverride: Bool
    
    var densityLabel: String {
        switch density {
        case .verySparse: return "Very Sparse"
        case .sparse:     return "Sparse"
        case .moderate:   return "Moderate"
        case .medium:     return "Medium"
        case .dense:      return "Dense"
        }
    }
}
