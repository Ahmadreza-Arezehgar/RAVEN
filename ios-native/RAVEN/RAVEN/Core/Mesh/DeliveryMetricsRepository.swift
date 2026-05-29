//
//  DeliveryMetricsRepository.swift
//  RAVEN
//
//  SQLite-backed historical delivery metrics for estimating
//  "average delivery time for your network" in the Delivery Detail Sheet.
//
//  Activated after 10+ delivered messages.
//

import Foundation

// MARK: - Delivery Metrics Repository

final class DeliveryMetricsRepository {
    static let shared = DeliveryMetricsRepository()
    
    /// Minimum delivered messages before showing average.
    static let activationThreshold = 10
    
    private let tableName = "delivery_metrics"
    
    private init() {
        Task { await createTable() }
    }
    
    // MARK: - Schema
    
    private func createTable() async {
        let sql = """
        CREATE TABLE IF NOT EXISTS \(tableName) (
            message_id TEXT PRIMARY KEY,
            sent_at REAL NOT NULL,
            delivered_at REAL,
            hop_count INTEGER DEFAULT 0,
            network_density TEXT DEFAULT 'medium'
        )
        """
        try? await DatabaseService.shared.execute(sql)
    }
    
    // MARK: - Record
    
    /// Record a message being sent.
    func recordSent(messageId: String, density: DeliveryPredictabilityService.NetworkDensity) async {
        let sql = """
        INSERT OR IGNORE INTO \(tableName) (message_id, sent_at, network_density)
        VALUES (?, ?, ?)
        """
        try? await DatabaseService.shared.execute(sql, params: [
            messageId,
            Date().timeIntervalSince1970,
            density.rawValue
        ])
    }
    
    /// Record a message being delivered.
    func recordDelivered(messageId: String, hopCount: Int) async {
        let sql = """
        UPDATE \(tableName)
        SET delivered_at = ?, hop_count = ?
        WHERE message_id = ?
        """
        try? await DatabaseService.shared.execute(sql, params: [
            Date().timeIntervalSince1970,
            hopCount,
            messageId
        ])
    }
    
    // MARK: - Query
    
    /// Average delivery latency for a given network density.
    /// Returns nil if fewer than `activationThreshold` delivered messages exist.
    func averageLatency(
        for density: DeliveryPredictabilityService.NetworkDensity? = nil
    ) async -> TimeInterval? {
        var sql = """
        SELECT AVG(delivered_at - sent_at) as avg_latency,
               COUNT(*) as total
        FROM \(tableName)
        WHERE delivered_at IS NOT NULL
        """
        var params: [Any] = []
        
        if let density = density {
            sql += " AND network_density = ?"
            params.append(density.rawValue)
        }
        
        guard let rows = try? await DatabaseService.shared.query(sql, params: params),
              let row = rows.first,
              let total = row["total"] as? Int64,
              total >= Int64(Self.activationThreshold),
              let avg = row["avg_latency"] as? Double else {
            return nil
        }
        
        return avg
    }
    
    /// Total number of delivered messages.
    func deliveredCount() async -> Int {
        let sql = "SELECT COUNT(*) as cnt FROM \(tableName) WHERE delivered_at IS NOT NULL"
        guard let rows = try? await DatabaseService.shared.query(sql),
              let row = rows.first,
              let count = row["cnt"] as? Int64 else {
            return 0
        }
        return Int(count)
    }
    
    /// Average hop count for delivered messages.
    func averageHopCount() async -> Double? {
        let sql = """
        SELECT AVG(hop_count) as avg_hops
        FROM \(tableName)
        WHERE delivered_at IS NOT NULL AND hop_count > 0
        """
        guard let rows = try? await DatabaseService.shared.query(sql),
              let row = rows.first,
              let avg = row["avg_hops"] as? Double else {
            return nil
        }
        return avg
    }
    
    /// Cleanup old metrics (keep last 30 days).
    func pruneOld() async {
        let cutoff = Date().addingTimeInterval(-86400 * 30).timeIntervalSince1970
        let sql = "DELETE FROM \(tableName) WHERE sent_at < ?"
        try? await DatabaseService.shared.execute(sql, params: [cutoff])
    }
}
