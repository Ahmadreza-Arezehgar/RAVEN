//
//  DeliveryPredictabilityService.swift
//  RAVEN
//
//  PRoPHET (Probabilistic Routing Protocol using History of Encounters and Transitivity)
//
//  Math:
//    On encounter with B:  P(self, B)  += (1 - P(self, B)) × P_ENCOUNTER
//    Aging (lazy, on read): P(self, X) *= GAMMA ^ (elapsed / timeUnit)
//    Transitivity:          P(self, C) += (1 - P(self, C)) × P(self, B) × P(B, C) × BETA
//    Forward decision:      P(peer, D) >  P(self, D) × FORWARD_THRESHOLD
//
//  Privacy: Peer IDs are HMAC-hashed before storage to prevent social graph extraction.
//  Security: Transitivity updates are trust-capped and rate-limited.
//

import Foundation
import CryptoKit

/// PRoPHET routing service for smart mesh forwarding decisions
actor DeliveryPredictabilityService {
    static let shared = DeliveryPredictabilityService()
    
    // MARK: - PRoPHET Constants
    
    private let pEncounter: Double = 0.75
    private let gamma: Double = 0.98
    private let beta: Double = 0.25
    private let timeUnitSeconds: Double = 300
    private let forwardThreshold: Double = 1.2
    private let pruneThreshold: Double = 0.01
    private let maxTableSize: Int = 500
    /// Max retention: prune entries untouched for 30 days
    private let maxRetentionSeconds: TimeInterval = 86400 * 30
    
    // MARK: - Feature Flag (Shadow Mode)
    
    /// When true, PRoPHET logs decisions but does NOT change routing behavior.
    /// Set to false after validating with real-world divergence data.
    var shadowMode: Bool = true
    
    // MARK: - P-Table
    
    struct PEntry {
        var storedValue: Double   // Value at lastUpdated time
        var lastUpdated: Date
        var encounterCount: Int
    }
    
    /// Our own P-table: destinationHash → PEntry
    private var pTable: [String: PEntry] = [:]
    
    /// Peer P-tables received during encounters: peerHash → [destHash: probability]
    private var peerTables: [String: (table: [String: Double], receivedAt: Date)] = [:]
    
    /// Rate limit: last transitivity update time per peer
    private var lastTransitivityUpdate: [String: Date] = [:]
    
    private var isLoaded = false
    
    /// HMAC key for hashing peer IDs before storage (privacy)
    private var hmacKey: SymmetricKey?
    
    // MARK: - Lazy Aging (compute on read, no batch writes)
    
    /// Current aged P-value — computed on read, never written eagerly
    private func currentValue(_ entry: PEntry, now: Date = Date()) -> Double {
        let elapsed = now.timeIntervalSince(entry.lastUpdated)
        guard elapsed > 0 else { return entry.storedValue }
        let timeUnits = elapsed / timeUnitSeconds
        return entry.storedValue * pow(gamma, timeUnits)
    }
    
    // MARK: - Privacy: HMAC Hashing
    
    private func getHMACKey() -> SymmetricKey {
        if let key = hmacKey { return key }
        // Derive from device identity — same device always produces same hashes
        let seed = DeviceIdentityService.shared.fingerprint ?? "raven-prophet-default"
        let key = SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
        hmacKey = key
        return key
    }
    
    /// Hash a peer/destination ID for privacy-safe storage
    private func hashId(_ id: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(id.utf8),
            using: getHMACKey()
        )
        return Data(mac).prefix(16).base64EncodedString()
    }
    
    // MARK: - Initialization
    
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        
        let entries = await DeliveryPredictabilityRepository.shared.loadAll()
        for entry in entries {
            pTable[entry.destinationId] = PEntry(
                storedValue: entry.probability,
                lastUpdated: entry.lastUpdated,
                encounterCount: entry.encounterCount
            )
        }
        
        isLoaded = true
        #if DEBUG
        print("📊 [PRoPHET] Loaded \(pTable.count) P-table entries (shadow=\(shadowMode))")
        #endif
    }
    
    // MARK: - Encounter Recording
    
    func recordEncounter(with peerId: String) async {
        await loadIfNeeded()
        let hashed = hashId(peerId)
        let now = Date()
        
        let current = pTable[hashed].map { currentValue($0, now: now) } ?? 0.0
        let updated = current + (1.0 - current) * pEncounter
        
        pTable[hashed] = PEntry(
            storedValue: min(updated, 1.0),
            lastUpdated: now,
            encounterCount: (pTable[hashed]?.encounterCount ?? 0) + 1
        )
        
        #if DEBUG
        print("📊 [PRoPHET] Encounter \(peerId.prefix(8)): P = \(String(format: "%.3f", current)) → \(String(format: "%.3f", updated))")
        #endif
        
        await DeliveryPredictabilityRepository.shared.upsert(
            destinationId: hashed,
            probability: min(updated, 1.0),
            encounterCount: pTable[hashed]?.encounterCount ?? 1
        )
    }
    
    // MARK: - Transitivity (with defenses)
    
    /// Update our P-table from peer's table.
    /// Defenses: trust-capping, rate limiting, stale rejection, clamping.
    func updateTransitivity(peerTable: [String: Double], peerId: String, peerTableAge: TimeInterval = 0) async {
        await loadIfNeeded()
        let hashedPeer = hashId(peerId)
        let now = Date()
        
        // Defense 1: Reject stale tables (> 24h old)
        guard peerTableAge < 86400 else {
            #if DEBUG
            print("📊 [PRoPHET] Rejected stale table from \(peerId.prefix(8)) (age: \(Int(peerTableAge))s)")
            #endif
            return
        }
        
        // Defense 2: Rate limit — max one update per peer per hour
        if let lastUpdate = lastTransitivityUpdate[hashedPeer],
           now.timeIntervalSince(lastUpdate) < 3600 {
            return
        }
        lastTransitivityUpdate[hashedPeer] = now
        
        // Defense 3: Trust cap — influence bounded by our direct encounter history
        let pSelfPeer = currentValue(pTable[hashedPeer] ?? PEntry(storedValue: 0, lastUpdated: now, encounterCount: 0), now: now)
        let peerTrust = min(pSelfPeer, 0.8)
        guard peerTrust > pruneThreshold else { return }
        
        // Store peer's table for forwarding decisions
        peerTables[hashedPeer] = (table: peerTable, receivedAt: now)
        
        var updatedCount = 0
        let myId = DeviceIdentityService.shared.fingerprint ?? ""
        
        for (destId, pPeerDest) in peerTable {
            guard destId != peerId, destId != myId else { continue }
            let hashedDest = hashId(destId)
            
            // Defense 4: Clamp peer's claimed P
            let clampedP = min(max(pPeerDest, 0), 1.0)
            guard clampedP.isFinite else { continue } // Reject NaN/Infinity
            
            let currentP = pTable[hashedDest].map { currentValue($0, now: now) } ?? 0.0
            let increment = (1.0 - currentP) * peerTrust * clampedP * beta
            
            guard increment > 0.005 else { continue }
            
            pTable[hashedDest] = PEntry(
                storedValue: min(currentP + increment, 1.0),
                lastUpdated: now,
                encounterCount: pTable[hashedDest]?.encounterCount ?? 0
            )
            updatedCount += 1
        }
        
        #if DEBUG
        if updatedCount > 0 {
            print("📊 [PRoPHET] Transitivity from \(peerId.prefix(8)): updated \(updatedCount) (trust=\(String(format: "%.2f", peerTrust)))")
        }
        #endif
    }
    
    // MARK: - Forwarding Decision
    
    /// Should we forward a message for `destination` to peer `peerId`?
    /// In shadow mode, always returns true but logs the decision.
    func shouldForward(to peerId: String, destination: String, sprayCounter: Int = 0) async -> Bool {
        await loadIfNeeded()
        let now = Date()
        
        if peerId == destination { return true }
        
        let hashedDest = hashId(destination)
        let hashedPeer = hashId(peerId)
        let inSprayPhase = sprayCounter > 1
        
        let myP = pTable[hashedDest].map { currentValue($0, now: now) } ?? 0.0
        
        // Get peer's P for destination from their exchanged table, or estimate from encounter frequency
        let peerP: Double
        if let peerData = peerTables[hashedPeer],
           now.timeIntervalSince(peerData.receivedAt) < 86400,
           let p = peerData.table[destination] {
            peerP = p
        } else {
            // No peer table — use our P for the peer as a proxy (encounter frequency)
            peerP = pTable[hashedPeer].map { currentValue($0, now: now) } ?? 0.0
        }
        
        // Unknown both → default to forward (safe)
        if myP < pruneThreshold && peerP < pruneThreshold { return true }
        
        let prophetDecision: Bool
        if inSprayPhase {
            // Permissive during spray: forward unless peer is clearly worse
            prophetDecision = peerP >= myP * 0.5
        } else {
            // Strict during wait: only relinquish to significantly better carrier
            prophetDecision = peerP > myP * forwardThreshold
        }
        
        // Shadow mode: log divergence but don't change behavior
        if shadowMode {
            #if DEBUG
            if !prophetDecision {
                print("📊 [PRoPHET-SHADOW] Would suppress → \(peerId.prefix(8)) for \(destination.prefix(8)) | myP=\(String(format: "%.3f", myP)) peerP=\(String(format: "%.3f", peerP)) spray=\(sprayCounter)")
            }
            #endif
            return true // Always forward in shadow mode
        }
        
        return prophetDecision
    }
    
    // MARK: - Query
    
    func probability(for destination: String) async -> Double {
        await loadIfNeeded()
        let hashed = hashId(destination)
        guard let entry = pTable[hashed] else { return 0 }
        return currentValue(entry)
    }
    
    func encounterCount(for peerId: String) async -> Int {
        await loadIfNeeded()
        return pTable[hashId(peerId)]?.encounterCount ?? 0
    }
    
    /// Compact summary for exchange with peers (unhashed IDs for interop)
    func getTableSummary() async -> [String: Double] {
        await loadIfNeeded()
        let now = Date()
        var summary: [String: Double] = [:]
        for (key, entry) in pTable {
            let p = currentValue(entry, now: now)
            if p > pruneThreshold { summary[key] = p }
        }
        return summary
    }
    
    func getTableSummaryData() async -> Data? {
        let summary = await getTableSummary()
        guard !summary.isEmpty else { return nil }
        return try? JSONEncoder().encode(summary)
    }
    
    // MARK: - Periodic Cleanup (lightweight — lazy aging means no mass updates)
    
    func pruneForgotten() async {
        await loadIfNeeded()
        let now = Date()
        var pruned = 0
        
        pTable = pTable.filter { _, entry in
            let p = currentValue(entry, now: now)
            let age = now.timeIntervalSince(entry.lastUpdated)
            let keep = p > pruneThreshold && age < maxRetentionSeconds
            if !keep { pruned += 1 }
            return keep
        }
        
        // Enforce size limit
        if pTable.count > maxTableSize {
            let sorted = pTable.sorted { currentValue($0.value, now: now) < currentValue($1.value, now: now) }
            let toRemove = pTable.count - maxTableSize
            for i in 0..<toRemove {
                pTable.removeValue(forKey: sorted[i].key)
                pruned += 1
            }
        }
        
        // Prune stale peer tables
        peerTables = peerTables.filter { now.timeIntervalSince($0.value.receivedAt) < 86400 }
        
        #if DEBUG
        if pruned > 0 {
            print("📊 [PRoPHET] Pruned \(pruned) entries, remaining=\(pTable.count)")
        }
        #endif
    }
    
    // MARK: - Persistence
    
    func save() async {
        guard isLoaded else { return }
        let now = Date()
        let entries = pTable.map { (destId, entry) in
            (destinationId: destId, probability: currentValue(entry, now: now), encounterCount: entry.encounterCount)
        }
        await DeliveryPredictabilityRepository.shared.saveAll(entries)
        await DeliveryPredictabilityRepository.shared.pruneBelow(threshold: pruneThreshold)
    }
    
    /// Clear all routing memory (privacy: user-triggered reset)
    func resetAll() async {
        pTable.removeAll()
        peerTables.removeAll()
        lastTransitivityUpdate.removeAll()
        await DeliveryPredictabilityRepository.shared.clearAll()
        #if DEBUG
        print("📊 [PRoPHET] All routing memory cleared")
        #endif
    }
    
    func getStats() async -> (entryCount: Int, avgProbability: Double, maxProbability: Double, shadowMode: Bool) {
        await loadIfNeeded()
        let now = Date()
        guard !pTable.isEmpty else { return (0, 0, 0, shadowMode) }
        let probs = pTable.values.map { currentValue($0, now: now) }
        return (pTable.count, probs.reduce(0, +) / Double(probs.count), probs.max() ?? 0, shadowMode)
    }
    
    // MARK: - Encounter Statistics (for Adaptive Spray)
    
    /// Network density classification based on encounter history.
    enum NetworkDensity: String, Codable {
        case verySparse  // 0-2 peers in 24h
        case sparse      // 3-10 peers, none recently
        case moderate    // 3-10 peers with recent activity
        case medium      // 11-30 peers
        case dense       // 31+ peers
    }
    
    /// Returns unique peer counts from the P-table for time windows.
    /// Uses existing PRoPHET encounter data instead of a separate log.
    func encounterStats() async -> (uniquePeersLast24h: Int, uniquePeersLastHour: Int) {
        await loadIfNeeded()
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-86400)
        let oneHourAgo = now.addingTimeInterval(-3600)
        
        var last24h = 0
        var lastHour = 0
        
        for (_, entry) in pTable {
            // Only count entries that have actual encounters (not just transitivity)
            guard entry.encounterCount > 0 else { continue }
            
            if entry.lastUpdated > oneDayAgo {
                last24h += 1
            }
            if entry.lastUpdated > oneHourAgo {
                lastHour += 1
            }
        }
        
        return (last24h, lastHour)
    }
    
    /// Classify current network density from encounter stats.
    func networkDensity() async -> NetworkDensity {
        let stats = await encounterStats()
        
        switch (stats.uniquePeersLast24h, stats.uniquePeersLastHour) {
        case (0...2, _):
            return .verySparse
        case (3...10, 0):
            return .sparse
        case (3...10, 1...):
            return .moderate
        case (11...30, _):
            return .medium
        case (31..., _):
            return .dense
        default:
            return .medium
        }
    }
}
