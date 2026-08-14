//
//  PresenceService.swift
//  RAVEN
//
//  Presence API for hybrid routing decisions
//

import Foundation
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Mesh.Presence")

/// Response from presence check
struct PresenceResponse: Codable {
    let online: Bool
    let hasInternet: Bool
    let lastSeenAt: String?
    let mutualRoomCount: Int?  // For trust indicators
    
    // Server returns camelCase directly, no mapping needed
}

/// Manages presence status for hybrid routing
class PresenceService {
    static let shared = PresenceService()
    
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 30  // Every 30 seconds
    
    // MARK: - Public API
    
    /// Check if recipient is online and has internet
    /// Returns default (offline) if check fails
    func checkPresence(_ userId: String) async -> PresenceResponse {
        guard RavenRuntimePolicy.allowsExternalSideEffects else {
            return PresenceResponse(online: false, hasInternet: false, lastSeenAt: nil, mutualRoomCount: nil)
        }
        do {
            let response: PresenceResponse = try await NetworkService.shared.get(
                path: "/api/presence/\(userId)"
            )
            logger.debug("User \(userId, privacy: .private): online=\(response.online, privacy: .public), hasInternet=\(response.hasInternet, privacy: .public)")
            return response
        } catch {
            logger.debug("Failed to check \(userId, privacy: .private): \(error.localizedDescription, privacy: .public)")
            // Default to offline - will trigger mesh fallback
            return PresenceResponse(
                online: false,
                hasInternet: false,
                lastSeenAt: nil,
                mutualRoomCount: nil
            )
        }
    }
    
    /// Start sending heartbeats to server
    func startHeartbeat() {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        guard heartbeatTimer == nil else { return }
        
        // Send immediately
        Task { await sendHeartbeat() }
        
        // Then periodically
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { await self?.sendHeartbeat() }
        }
        
        #if DEBUG
        print("💓 [Presence] Heartbeat started (every \(Int(heartbeatInterval))s)")
        #endif
    }
    
    /// Stop heartbeats (app going to background)
    func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        
        // Notify server we're going offline
        Task { await goOffline() }
        
        #if DEBUG
        print("💓 [Presence] Heartbeat stopped")
        #endif
    }
    
    // MARK: - Private
    
    private func sendHeartbeat() async {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        do {
            let _: [String: String] = try await NetworkService.shared.post(
                path: "/api/presence/heartbeat",
                body: HeartbeatRequest(hasInternet: NetworkMonitor.shared.isOnline)
            )
        } catch {
            // Silently fail - not critical
        }
    }
    
    private func goOffline() async {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        do {
            let _: [String: String] = try await NetworkService.shared.post(
                path: "/api/presence/offline",
                body: EmptyBody()
            )
        } catch {
            // Silently fail
        }
    }
}

// MARK: - Request Bodies

private struct HeartbeatRequest: Codable {
    let hasInternet: Bool
    
    enum CodingKeys: String, CodingKey {
        case hasInternet = "has_internet"
    }
}

private struct EmptyBody: Codable {}
