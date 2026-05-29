//
//  DeliveryStateService.swift
//  RAVEN
//
//  Per-message delivery state machine for the Delivery Confidence Indicator.
//  Tracks: Queued → In Transit → Delivered (or Stale/Failed)
//
//  States:
//  🔵 Queued     — message created, no relay ACK yet
//  🟡 In Transit — at least one relay ACK received
//  🟢 Delivered  — destination ACK received
//  🟠 Stale      — TTL > 50% elapsed, still not delivered
//  🔴 Failed     — TTL expired or unrecoverable error
//

import Foundation
import Combine
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Mesh.DeliveryState")

// MARK: - Mesh Confidence State

/// Delivery confidence state for mesh messages (distinct from TransportTypes.DeliveryState).
enum MeshConfidenceState: Equatable {
    case queued
    case inTransit(firstRelayAt: Date, hopsConfirmed: UInt8)
    case delivered(at: Date)
    case stale(since: Date)
    case failed(reason: ConfidenceFailureReason)
    
    /// Unique string key for animation identity.
    var stateKey: String {
        switch self {
        case .queued:     return "queued"
        case .inTransit:  return "inTransit"
        case .delivered:  return "delivered"
        case .stale:      return "stale"
        case .failed:     return "failed"
        }
    }
}

enum ConfidenceFailureReason: Equatable {
    case ttlExpired
    case noRoute
    case unknown
}

// MARK: - Delivery State Service

@MainActor
final class DeliveryStateService: ObservableObject {
    static let shared = DeliveryStateService()
    
    /// Per-message delivery state. Key = clientMessageId.
    @Published private(set) var states: [String: MeshConfidenceState] = [:]
    
    /// Message metadata for staleness checks. Key = clientMessageId.
    private var messageTimestamps: [String: (createdAt: Date, ttlSeconds: Int)] = [:]
    
    /// Staleness check timer.
    private var stalenessTimer: Timer?
    
    /// Maximum states to track (memory bound).
    private let maxTrackedMessages = 500
    
    private init() {
        startStalenessTimer()
    }
    
    // MARK: - State Transitions
    
    /// Called when a new message is sent.
    func onMessageSent(_ messageId: String, ttlSeconds: Int = 86400) {
        guard FeatureFlag.isDeliveryConfidenceEnabled else { return }
        
        // Evict oldest if at capacity
        if states.count >= maxTrackedMessages {
            evictOldest()
        }
        
        states[messageId] = .queued
        messageTimestamps[messageId] = (createdAt: Date(), ttlSeconds: ttlSeconds)

        logger.debug("\(messageId, privacy: .private) -> queued")
    }
    
    /// Called when we receive a relay receipt for a message we sent.
    func onRelayReceipt(_ receipt: RelayReceipt) {
        guard FeatureFlag.isDeliveryConfidenceEnabled else { return }
        
        let messageId = receipt.originalMessageId
        let currentState = states[messageId]
        
        switch currentState {
        case .queued:
            // First relay confirmation — transition to inTransit
            states[messageId] = .inTransit(
                firstRelayAt: Date(timeIntervalSince1970: receipt.receivedAt),
                hopsConfirmed: receipt.hopCount
            )
            logger.debug("\(messageId, privacy: .private) -> inTransit (hop=\(receipt.hopCount, privacy: .public))")

        case .inTransit(let firstRelayAt, let currentHops):
            // Update hop count if higher
            if receipt.hopCount > currentHops {
                states[messageId] = .inTransit(
                    firstRelayAt: firstRelayAt,
                    hopsConfirmed: receipt.hopCount
                )
            }
            
        case .stale:
            // Receipt arrived after stale — back to inTransit
            states[messageId] = .inTransit(
                firstRelayAt: Date(timeIntervalSince1970: receipt.receivedAt),
                hopsConfirmed: receipt.hopCount
            )
            logger.debug("\(messageId, privacy: .private) -> inTransit (recovered from stale)")
            
        default:
            break // delivered/failed — no change
        }
    }
    
    /// Called when destination ACK is received.
    func onDestinationACK(messageId: String) {
        guard FeatureFlag.isDeliveryConfidenceEnabled else { return }
        
        states[messageId] = .delivered(at: Date())

        logger.debug("\(messageId, privacy: .private) -> delivered")
    }
    
    /// Called when a message fails permanently.
    func onMessageFailed(messageId: String, reason: ConfidenceFailureReason = .unknown) {
        guard FeatureFlag.isDeliveryConfidenceEnabled else { return }
        
        states[messageId] = .failed(reason: reason)

        let reasonStr = String(describing: reason)
        logger.debug("\(messageId, privacy: .private) -> failed (\(reasonStr, privacy: .public))")
    }
    
    // MARK: - Query
    
    /// Get delivery state for a message, defaulting to nil if not tracked.
    func state(for messageId: String) -> MeshConfidenceState? {
        states[messageId]
    }
    
    /// Time since the message was sent, if tracked.
    func timeSinceSend(for messageId: String) -> TimeInterval? {
        guard let meta = messageTimestamps[messageId] else { return nil }
        return Date().timeIntervalSince(meta.createdAt)
    }
    
    /// Hop count for in-transit messages.
    func hopCount(for messageId: String) -> UInt8 {
        guard case .inTransit(_, let hops) = states[messageId] else { return 0 }
        return hops
    }
    
    // MARK: - Staleness Detection
    
    private func startStalenessTimer() {
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkStaleness()
            }
        }
    }
    
    private func checkStaleness() {
        let now = Date()
        
        for (messageId, state) in states {
            guard let meta = messageTimestamps[messageId] else { continue }
            
            let ttlRemaining = meta.ttlSeconds - Int(now.timeIntervalSince(meta.createdAt))
            let ttlHalf = meta.ttlSeconds / 2
            
            switch state {
            case .queued, .inTransit:
                if ttlRemaining <= 0 {
                    // TTL expired
                    states[messageId] = .failed(reason: .ttlExpired)
                } else if ttlRemaining < ttlHalf {
                    // Past half TTL — mark stale
                    if case .stale = state { continue } // already stale
                    states[messageId] = .stale(since: now)
                    logger.debug("\(messageId, privacy: .private) -> stale (TTL \(ttlRemaining, privacy: .public)s remaining)")
                }
                
            case .stale:
                if ttlRemaining <= 0 {
                    states[messageId] = .failed(reason: .ttlExpired)
                }
                
            default:
                break
            }
        }
    }
    
    // MARK: - Cleanup
    
    private func evictOldest() {
        // Remove oldest delivered/failed states first
        let sortedByAge = messageTimestamps.sorted { $0.value.createdAt < $1.value.createdAt }
        
        for (messageId, _) in sortedByAge.prefix(50) {
            if case .delivered = states[messageId] {
                states.removeValue(forKey: messageId)
                messageTimestamps.removeValue(forKey: messageId)
            } else if case .failed = states[messageId] {
                states.removeValue(forKey: messageId)
                messageTimestamps.removeValue(forKey: messageId)
            }
        }
    }
    
    /// Clear all delivery state (e.g., on logout).
    func clearAll() {
        states.removeAll()
        messageTimestamps.removeAll()
    }
}
