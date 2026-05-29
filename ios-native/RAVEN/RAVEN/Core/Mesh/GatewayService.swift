//
//  GatewayService.swift
//  RAVEN
//
//  Gateway management for Multi-hop Internet Bridging.
//  Online devices can bridge messages to the server on behalf of offline peers.
//
//  Key principles:
//  - Blind bridging: gateway CANNOT read message content (E2EE)
//  - Rate limited: 20 msg/min, 1MB/min, 5 msg/peer
//  - Opt-in only: user must explicitly enable gateway mode
//  - Wi-Fi + battery > 30% required
//

import Foundation
import UIKit

// MARK: - Gateway Service

@MainActor
final class GatewayService: ObservableObject {
    static let shared = GatewayService()
    
    /// Whether this device is actively serving as a gateway.
    @Published private(set) var isActive: Bool = false
    
    /// Gateway stats for today.
    @Published private(set) var todayStats = GatewayStats()
    
    // MARK: - Rate Limiter
    
    private var messageLog: [(peerId: String, timestamp: Date, size: Int)] = []
    
    struct RateLimits {
        static let maxMessagesPerMinute = 20
        static let maxBytesPerMinute = 1_048_576  // 1MB
        static let maxMessagesPerPeer = 5
        static let windowSeconds: TimeInterval = 60
    }
    
    // MARK: - Lifecycle
    
    private init() {
        loadStats()
    }
    
    /// Refresh gateway active status based on current conditions.
    func refresh() {
        guard FeatureFlag.isInternetBridgeEnabled else {
            isActive = false
            return
        }
        
        let userEnabled = UserDefaults.standard.bool(forKey: "raven.gateway_enabled")
        let isOnline = NetworkMonitor.shared.isOnline
        let batteryOK = UIDevice.current.batteryLevel < 0 || UIDevice.current.batteryLevel > 0.30
        
        isActive = userEnabled && isOnline && batteryOK
        
        #if DEBUG
        print("🌐 [Gateway] Status: active=\(isActive) | userEnabled=\(userEnabled) | online=\(isOnline) | battery=\(batteryOK)")
        #endif
    }
    
    // MARK: - Rate Limiting
    
    /// Check if a bridge request from a peer is allowed.
    func isAllowed(from peerId: String, payloadSize: Int) -> Bool {
        cleanupExpiredEntries()
        
        let now = Date()
        let recentMessages = messageLog.filter {
            now.timeIntervalSince($0.timestamp) < RateLimits.windowSeconds
        }
        
        // Global rate: messages per minute
        if recentMessages.count >= RateLimits.maxMessagesPerMinute {
            #if DEBUG
            print("🌐 [Gateway] Rate limited: global msg limit (\(recentMessages.count)/\(RateLimits.maxMessagesPerMinute))")
            #endif
            return false
        }
        
        // Global rate: bytes per minute
        let totalBytes = recentMessages.reduce(0) { $0 + $1.size }
        if totalBytes + payloadSize > RateLimits.maxBytesPerMinute {
            #if DEBUG
            print("🌐 [Gateway] Rate limited: byte limit (\(totalBytes)/\(RateLimits.maxBytesPerMinute))")
            #endif
            return false
        }
        
        // Per-peer rate: messages per window
        let peerMessages = recentMessages.filter { $0.peerId == peerId }
        if peerMessages.count >= RateLimits.maxMessagesPerPeer {
            #if DEBUG
            print("🌐 [Gateway] Rate limited: per-peer limit for \(peerId.prefix(8))")
            #endif
            return false
        }
        
        return true
    }
    
    /// Record a bridge request (after successful forwarding).
    func recordRequest(from peerId: String, payloadSize: Int) {
        messageLog.append((peerId: peerId, timestamp: Date(), size: payloadSize))
        
        // Update daily stats
        todayStats.messagesRelayed += 1
        todayStats.bytesRelayed += payloadSize
        todayStats.uniqueUsersHelped.insert(peerId)
        saveStats()
    }
    
    // MARK: - Gateway Scoring
    
    /// Score a peer as a potential gateway (0.0 - 1.0).
    /// Higher = better gateway candidate.
    func gatewayScore(
        internetStrength: Double,   // 0-1, Wi-Fi = 1.0, cellular = 0.5
        batteryLevel: Double,       // 0-1
        reputation: Double = 1.0    // 0-1, based on past successful bridges
    ) -> Double {
        let w_internet = 0.5
        let w_battery = 0.3
        let w_reputation = 0.2
        
        return (internetStrength * w_internet) +
               (batteryLevel * w_battery) +
               (reputation * w_reputation)
    }
    
    // MARK: - Bridge Request
    
    /// Forward a blind bridge request to the server.
    /// Gateway CANNOT read the content — only the encrypted blob.
    func bridgeToServer(
        encryptedPayload: Data,
        forMessageId: String,
        fromPeerId: String
    ) async -> Bool {
        guard isActive else { return false }
        guard isAllowed(from: fromPeerId, payloadSize: encryptedPayload.count) else { return false }
        
        do {
            // POST blind payload to bridge endpoint
            let _: EmptyResponse = try await NetworkService.shared.post(
                path: "/api/messages/bridge",
                body: BridgeRequest(
                    messageId: forMessageId,
                    encryptedPayload: encryptedPayload.base64EncodedString()
                ),
                idempotencyKey: "bridge-\(forMessageId)"
            )
            
            recordRequest(from: fromPeerId, payloadSize: encryptedPayload.count)
            
            #if DEBUG
            print("🌐 [Gateway] Successfully bridged \(forMessageId.prefix(8)) for \(fromPeerId.prefix(8))")
            #endif
            return true
            
        } catch {
            #if DEBUG
            print("🌐 [Gateway] Bridge failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }
    
    // MARK: - Private
    
    private func cleanupExpiredEntries() {
        let cutoff = Date().addingTimeInterval(-RateLimits.windowSeconds * 2)
        messageLog.removeAll { $0.timestamp < cutoff }
    }
    
    // MARK: - Stats Persistence
    
    private let statsKey = "raven.gateway_stats"
    private let statsDateKey = "raven.gateway_stats_date"
    
    private func loadStats() {
        let today = Calendar.current.startOfDay(for: Date())
        let storedDate = UserDefaults.standard.object(forKey: statsDateKey) as? Date ?? .distantPast
        
        if Calendar.current.startOfDay(for: storedDate) == today {
            let messages = UserDefaults.standard.integer(forKey: "\(statsKey).messages")
            let bytes = UserDefaults.standard.integer(forKey: "\(statsKey).bytes")
            todayStats = GatewayStats(messagesRelayed: messages, bytesRelayed: bytes)
        } else {
            todayStats = GatewayStats()
            saveStats()
        }
    }
    
    private func saveStats() {
        let today = Calendar.current.startOfDay(for: Date())
        UserDefaults.standard.set(today, forKey: statsDateKey)
        UserDefaults.standard.set(todayStats.messagesRelayed, forKey: "\(statsKey).messages")
        UserDefaults.standard.set(todayStats.bytesRelayed, forKey: "\(statsKey).bytes")
    }
}

// MARK: - Gateway Stats

struct GatewayStats {
    var messagesRelayed: Int = 0
    var bytesRelayed: Int = 0
    var uniqueUsersHelped: Set<String> = []
    
    var bytesRelayedFormatted: String {
        if bytesRelayed < 1024 {
            return "\(bytesRelayed) B"
        } else if bytesRelayed < 1_048_576 {
            return "\(bytesRelayed / 1024) KB"
        } else {
            return String(format: "%.1f MB", Double(bytesRelayed) / 1_048_576)
        }
    }
}

// MARK: - Bridge Request Model

struct BridgeRequest: Codable {
    let messageId: String
    let encryptedPayload: String  // Base64 encoded E2E encrypted data
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case encryptedPayload = "encrypted_payload"
    }
}

