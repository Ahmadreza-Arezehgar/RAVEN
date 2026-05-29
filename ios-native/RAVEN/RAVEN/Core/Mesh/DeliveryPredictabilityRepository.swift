//
//  DeliveryPredictabilityRepository.swift
//  RAVEN
//
//  SQLite persistence for PRoPHET delivery predictability table.
//  Stores P(self, destination) values with encounter counts and timestamps.
//

import Foundation
import SQLCipher

/// Persistent storage for PRoPHET delivery predictability entries
actor DeliveryPredictabilityRepository {
    static let shared = DeliveryPredictabilityRepository()
    
    private let db = DatabaseService.shared
    
    // MARK: - Public API
    
    /// Load all P-table entries from SQLite
    func loadAll() async -> [(destinationId: String, probability: Double, lastUpdated: Date, encounterCount: Int)] {
        guard let rows = try? await db.query(
            "SELECT destination_id, probability, last_updated, encounter_count FROM delivery_predictability"
        ) else { return [] }
        
        var results: [(String, Double, Date, Int)] = []
        for row in rows {
            guard let destId = row["destination_id"] as? String,
                  let prob = row["probability"] as? Double,
                  let updatedStr = row["last_updated"] as? String else { continue }
            let encounterCount = (row["encounter_count"] as? Int64).map(Int.init) ?? 0
            let date = PerformanceConstants.iso8601.date(from: updatedStr) ?? Date()
            results.append((destId, prob, date, encounterCount))
        }
        return results
    }
    
    /// Upsert a single P-table entry
    func upsert(destinationId: String, probability: Double, encounterCount: Int) async {
        let now = PerformanceConstants.iso8601.string(from: Date())
        try? await db.execute(
            """
            INSERT INTO delivery_predictability (destination_id, probability, last_updated, encounter_count)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(destination_id) DO UPDATE SET
                probability = excluded.probability,
                last_updated = excluded.last_updated,
                encounter_count = excluded.encounter_count
            """,
            params: [destinationId, probability, now, encounterCount]
        )
    }
    
    /// Batch save entire P-table (replaces all entries)
    func saveAll(_ entries: [(destinationId: String, probability: Double, encounterCount: Int)]) async {
        for entry in entries {
            await upsert(
                destinationId: entry.destinationId,
                probability: entry.probability,
                encounterCount: entry.encounterCount
            )
        }
    }
    
    /// Remove entries with probability below threshold (cleanup)
    func pruneBelow(threshold: Double = 0.01) async {
        try? await db.execute(
            "DELETE FROM delivery_predictability WHERE probability < ?",
            params: [threshold]
        )
    }
    
    /// Remove a specific destination entry
    func remove(destinationId: String) async {
        try? await db.execute(
            "DELETE FROM delivery_predictability WHERE destination_id = ?",
            params: [destinationId]
        )
    }
    
    /// Count of entries in table
    func count() async -> Int {
        let rows = try? await db.query("SELECT COUNT(*) as cnt FROM delivery_predictability")
        return (rows?.first?["cnt"] as? Int64).map(Int.init) ?? 0
    }
    
    /// Clear entire table
    func clearAll() async {
        try? await db.execute("DELETE FROM delivery_predictability")
    }
    
    // MARK: - DDL
    
    static func tableCreationSQL() -> [String] {
        [
            """
            CREATE TABLE IF NOT EXISTS delivery_predictability (
                destination_id TEXT PRIMARY KEY,
                probability    REAL NOT NULL DEFAULT 0.0,
                last_updated   TEXT NOT NULL,
                encounter_count INTEGER NOT NULL DEFAULT 0
            )
            """
        ]
    }
}
