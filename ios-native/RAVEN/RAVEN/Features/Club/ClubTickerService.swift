//
//  ClubTickerService.swift
//  RAVEN
//
//  Adaptive location ping timer for Club Mode.
//  Broadcasts H3 cell (resolution 9 ≈ 150m) at adaptive intervals:
//  - 15s default (active movement)
//  - 30s when stationary
//  - 60s when low battery (<20%)
//
//  Supports three location source strategies:
//  - meshOnly:      BLE mesh broadcast only (fully offline)
//  - internetOnly:  HTTP relay to club members via server
//  - hybrid:        Internet primary, mesh fallback (best reliability)
//

import Foundation
import UIKit

// MARK: - Club Ticker Service

@MainActor
final class ClubTickerService: ObservableObject {
    static let shared = ClubTickerService()
    
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastPingAt: Date?
    @Published private(set) var lastDeliveryMethod: String = ""  // "mesh" / "internet" / "both"
    
    private var timer: Timer?
    private var activeClub: Club?
    private var lastH3Cell: UInt64?
    
    // Adaptive intervals
    private let activeInterval: TimeInterval = 15
    private let stationaryInterval: TimeInterval = 30
    private let lowBatteryInterval: TimeInterval = 60
    
    private init() {}
    
    // MARK: - Public API
    
    /// Start pinging for a club.
    func start(for club: Club) {
        stop()
        activeClub = club
        isRunning = true
        
        // Start high-precision location tracking (GPS + WiFi fusion)
        LocationPrivacyService.shared.startHighPrecision()
        
        // Schedule first ping immediately
        Task {
            await sendPing()
        }
        
        // Schedule recurring pings
        scheduleNextPing()
        
        #if DEBUG
        print("🐦 [ClubTicker] Started for club: \(club.name) | source: \(club.locationSource.label)")
        #endif
    }
    
    /// Stop pinging.
    func stop() {
        timer?.invalidate()
        timer = nil
        activeClub = nil
        isRunning = false
        lastH3Cell = nil
        lastDeliveryMethod = ""
        
        // Revert to standard accuracy when Club stops
        LocationPrivacyService.shared.stop()
        
        #if DEBUG
        print("🐦 [ClubTicker] Stopped")
        #endif
    }
    
    // MARK: - Private
    
    private func scheduleNextPing() {
        timer?.invalidate()
        
        let interval = currentInterval()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.sendPing()
            }
        }
    }
    
    /// Determine ping interval based on movement and battery state.
    private func currentInterval() -> TimeInterval {
        // Low battery check
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel > 0 && batteryLevel < 0.2 {
            return lowBatteryInterval
        }
        
        // Stationary check: if H3 cell hasn't changed since last ping
        let currentCell = LocationPrivacyService.shared.currentH3Cell(resolution: 9)
        if let current = currentCell, let last = lastH3Cell, current == last {
            return stationaryInterval
        }
        
        return activeInterval
    }
    
    private func sendPing() async {
        guard let club = activeClub else { return }

        guard let userId = await KeychainService.shared.getUserId(), !userId.isEmpty,
              let displayName = currentDisplayName() else {
            #if DEBUG
            print("🐦 [ClubTicker] Skipping ping — user identity not ready")
            #endif
            return
        }

        // Get current H3 cell at resolution 9 (~150m)
        guard let h3Cell = LocationPrivacyService.shared.currentH3Cell(resolution: 9) else {
            #if DEBUG
            print("🐦 [ClubTicker] No location available for ping")
            #endif
            return
        }

        // Update last known cell for stationary detection
        lastH3Cell = h3Cell
        
        // Get precise coordinates for 'exact' mode
        let location = LocationPrivacyService.shared.currentCLLocation
        let isExact = club.locationPrecision == .exact
        let preciseLat = isExact ? location?.coordinate.latitude : nil
        let preciseLng = isExact ? location?.coordinate.longitude : nil

        // Update our own member record locally (with precise coords if available)
        do {
            try await ClubRepository.shared.updateMemberLocation(
                clubId: club.id,
                userId: userId,
                h3Cell: h3Cell,
                preciseLat: preciseLat,
                preciseLng: preciseLng
            )
        } catch {
            #if DEBUG
            print("🐦 [ClubTicker] updateMemberLocation failed: \(error)")
            #endif
        }

        // Build payload
        let batteryLevel = Int(max(0, UIDevice.current.batteryLevel) * 100)
        let payload = ClubPingPayload(
            clubId: club.id,
            userId: userId,
            displayName: displayName,
            h3Cell: h3Cell,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            batteryLevel: batteryLevel,
            preciseLat: preciseLat,
            preciseLng: preciseLng
        )

        // Deliver based on location source strategy
        switch club.locationSource {
        case .meshOnly:
            await broadcastViaMesh(payload: payload, userId: userId)
            lastDeliveryMethod = "mesh"
            
        case .internetOnly:
            let success = await sendViaInternet(payload: payload)
            if !success {
                #if DEBUG
                print("🐦 [ClubTicker] Internet delivery failed — no fallback (internet-only mode)")
                #endif
            }
            lastDeliveryMethod = success ? "internet" : "failed"
            
        case .hybrid:
            // Internet primary, mesh fallback
            let internetOk = await sendViaInternet(payload: payload)
            if internetOk {
                lastDeliveryMethod = "internet"
            } else {
                // Fallback to mesh
                await broadcastViaMesh(payload: payload, userId: userId)
                lastDeliveryMethod = "mesh (fallback)"
            }
            // Always also broadcast on mesh for nearby devices
            await broadcastViaMesh(payload: payload, userId: userId)
            if internetOk {
                lastDeliveryMethod = "both"
            }
        }
        
        lastPingAt = Date()
        
        #if DEBUG
        let cellStr = H3Lite.cellToString(h3Cell)
        print("🐦 [ClubTicker] Ping sent | cell=\(cellStr.prefix(8)) | via=\(lastDeliveryMethod) | interval=\(currentInterval())s")
        #endif
    }
    
    // MARK: - Delivery Methods
    
    /// Broadcast location ping via BLE mesh (offline / peer-to-peer).
    private func broadcastViaMesh(payload: ClubPingPayload, userId: String) async {
        var frame = MeshMessageFrame(
            kind: .clubPing,
            payload: payload,
            senderId: userId,
            messageId: "fp-\(UUID().uuidString)",
            hopLimit: 3,      // Club pings are local — 3 hops max
            sprayCounter: 10,  // Modest spray for frequent pings
            ttlSeconds: 60     // Very short TTL — stale pings are useless
        )
        frame.sign()

        if let data = frame.toData() {
            await BLEMeshEngine.shared.broadcastPostData(data)
        }
    }
    
    /// Send location ping via internet (HTTP POST to server relay).
    /// Server fans out the ping to all club members via WebSocket/push.
    /// Returns true if successful.
    private func sendViaInternet(payload: ClubPingPayload) async -> Bool {
        struct ClubPingRequest: Encodable {
            let clubId: String
            let userId: String
            let displayName: String
            let h3Cell: String      // Hex string for server compatibility
            let timestamp: Int64
            let batteryLevel: Int
        }
        
        let request = ClubPingRequest(
            clubId: payload.clubId,
            userId: payload.userId,
            displayName: payload.displayName,
            h3Cell: H3Lite.cellToString(payload.h3Cell),
            timestamp: payload.timestamp,
            batteryLevel: payload.batteryLevel
        )
        
        do {
            struct EmptyResponse: Decodable {}
            let _: EmptyResponse = try await NetworkService.shared.post(
                path: "/api/clubs/ping",
                body: request
            )
            return true
        } catch {
            #if DEBUG
            print("🐦 [ClubTicker] Internet ping failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }
    
    /// Look up the user's display name from AuthService, returning nil
    /// instead of broadcasting a placeholder like "Unknown".
    ///
    /// FIX: Was reading from UserDefaults key "currentUsername" which is never
    /// written anywhere. Now reads from AuthService.
    private func currentDisplayName() -> String? {
        guard let user = AuthService.shared.currentUser else { return nil }
        guard let name = user.firstName ?? user.username else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
