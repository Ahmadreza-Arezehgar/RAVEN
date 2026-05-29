//
//  MuleService.swift
//  RAVEN
//
//  Core logic for Intent-based Data Mules.
//  Handles intent verification, message selection for mules,
//  intent registry management, and abuse resistance.
//

import Foundation
import CryptoKit

// MARK: - Mule Service

@MainActor
final class MuleService: ObservableObject {
    static let shared = MuleService()
    
    /// Our active travel intent (nil if none).
    @Published private(set) var activeIntent: TravelIntent?
    
    /// Stats for current travel.
    @Published private(set) var stats = MuleStats()
    
    /// Reputation tracker for peers.
    private var peerReputation: [String: Double] = [:]  // userIdHashed → score (0-1)
    
    private init() {
        loadActiveIntent()
    }
    
    // MARK: - Intent Management
    
    /// Announce a new travel intent.
    func announceTravel(_ intent: TravelIntent) {
        guard FeatureFlag.isDataMulesEnabled else { return }
        
        // Max 1 active per user
        activeIntent = intent
        stats = MuleStats()
        
        // Persist
        saveActiveIntent()
        UserDefaults.standard.set(true, forKey: "raven.has_active_travel_intent")
        
        #if DEBUG
        print("🚗 [Mule] Announced travel: \(intent.intentId.prefix(8))")
        #endif
    }
    
    /// Cancel the active travel intent.
    func cancelTravel() {
        activeIntent = nil
        stats = MuleStats()
        UserDefaults.standard.set(false, forKey: "raven.has_active_travel_intent")
        clearActiveIntent()
        
        #if DEBUG
        print("🚗 [Mule] Travel cancelled")
        #endif
    }
    
    // MARK: - Intent Verification
    
    /// Verify a travel intent from a peer.
    /// Returns true if the intent is valid and trustworthy.
    func verifyIntent(_ intent: TravelIntent) -> IntentVerificationResult {
        // 1. Signature check
        guard intent.isSignatureValid() else {
            return .rejected(reason: .invalidSignature)
        }
        
        // 2. Date check: not expired, reasonable departure window
        guard !intent.isExpired else {
            return .rejected(reason: .expired)
        }
        
        let now = Date()
        guard intent.departureTime > now.addingTimeInterval(-TravelIntent.broadcastLeadTime) else {
            return .rejected(reason: .departurePassed)
        }
        
        // 3. Duration check: reasonable (not more than 48h)
        guard intent.estimatedDuration > 0 && intent.estimatedDuration <= TravelIntent.maxDuration else {
            return .rejected(reason: .unreasonableDuration)
        }
        
        // 4. Rate limit: max 1 intent per user (already enforced client-side)
        
        // 5. Reputation check
        let reputation = peerReputation[intent.userIdHashed] ?? 0.5  // Default neutral
        if reputation < 0.1 {
            return .rejected(reason: .lowReputation)
        }
        
        return .accepted(reputationScore: reputation)
    }
    
    // MARK: - Message Selection
    
    /// Select messages from relay queue that should be loaded onto a mule.
    /// Uses geo-scoring to prioritize messages headed toward the mule's destination.
    func selectMessagesForMule(
        intent: TravelIntent,
        relayQueue: [MeshEnvelope]
    ) -> [MeshEnvelope] {
        guard FeatureFlag.isDataMulesEnabled else { return [] }
        
        var selected: [MeshEnvelope] = []
        var budgetBytes = intent.capacityMB * 1_048_576  // Convert MB to bytes
        
        // Score and sort messages by relevance to the mule's route
        let scored = relayQueue.compactMap { envelope -> (envelope: MeshEnvelope, score: Double)? in
            let score = geoScore(envelope: envelope, intent: intent)
            guard score > 0 else { return nil }
            return (envelope, score)
        }
        .sorted { $0.score > $1.score }
        
        // Select messages within budget
        for (envelope, score) in scored {
            // Estimate payload size (rough: ~200 bytes per message)
            let estimatedSize = 200
            guard budgetBytes >= estimatedSize else { break }
            
            selected.append(envelope)
            budgetBytes -= estimatedSize
            
            #if DEBUG
            print("🚗 [Mule] Selected \(envelope.clientMessageId.prefix(8)) (score=\(String(format: "%.2f", score)))")
            #endif
        }
        
        return selected
    }
    
    /// Compute geo-relevance score for a message relative to a travel intent.
    private func geoScore(envelope: MeshEnvelope, intent: TravelIntent) -> Double {
        // If message has a geo-fence, check if destination overlaps with travel route
        if let fence = envelope.geoFence {
            // Check if the message's target area is along the mule's route
            let distFromOrigin = GeoFence.gridDistance(fence.h3Cell, intent.fromRegion)
            let distFromDest = GeoFence.gridDistance(fence.h3Cell, intent.toRegion)
            
            // Score based on proximity to route
            let maxRelevantDistance = 10  // cells
            let minDist = min(distFromOrigin, distFromDest)
            
            if minDist <= maxRelevantDistance {
                return 1.0 - (Double(minDist) / Double(maxRelevantDistance))
            }
            return 0  // Not relevant to this route
        }
        
        // No geo-fence — use PRoPHET predictability as proxy
        // Messages without geo-fence get a lower base score
        let ttlRemaining = max(0, envelope.ttlSeconds - Int(Date().timeIntervalSince1970 - envelope.timestamp))
        let urgencyScore = 1.0 - (Double(ttlRemaining) / Double(envelope.ttlSeconds))
        
        return urgencyScore * 0.3  // Low weight for non-geo messages
    }
    
    // MARK: - Reputation
    
    /// Update peer reputation after a mule encounter.
    func updateReputation(userIdHashed: String, success: Bool) {
        let current = peerReputation[userIdHashed] ?? 0.5
        let delta: Double = success ? 0.05 : -0.15  // Penalize failure harder
        peerReputation[userIdHashed] = max(0, min(1, current + delta))
    }
    
    // MARK: - Persistence
    
    private let intentKey = "raven.active_travel_intent"
    
    private func loadActiveIntent() {
        guard let data = UserDefaults.standard.data(forKey: intentKey),
              let intent = try? JSONDecoder().decode(TravelIntent.self, from: data),
              !intent.isExpired else {
            activeIntent = nil
            return
        }
        activeIntent = intent
    }
    
    private func saveActiveIntent() {
        guard let intent = activeIntent,
              let data = try? JSONEncoder().encode(intent) else {
            clearActiveIntent()
            return
        }
        UserDefaults.standard.set(data, forKey: intentKey)
    }
    
    private func clearActiveIntent() {
        UserDefaults.standard.removeObject(forKey: intentKey)
    }
}

// MARK: - Mule Stats

struct MuleStats {
    var messagesCarried: Int = 0
    var messagesDelivered: Int = 0
    var usersHelped: Int = 0
}

// MARK: - Intent Verification Result

enum IntentVerificationResult {
    case accepted(reputationScore: Double)
    case rejected(reason: IntentRejectionReason)
    
    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

enum IntentRejectionReason: String {
    case invalidSignature = "Invalid signature"
    case expired = "Intent expired"
    case departurePassed = "Departure time passed"
    case unreasonableDuration = "Unreasonable duration"
    case lowReputation = "Low reputation"
}
