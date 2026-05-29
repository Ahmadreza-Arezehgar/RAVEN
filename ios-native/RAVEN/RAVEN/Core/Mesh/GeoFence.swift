//
//  GeoFence.swift
//  RAVEN
//
//  Geo-fence data model for location-restricted message delivery.
//  Uses H3 hexagonal grid (resolution 5, ~8km) for privacy-safe area specification.
//
//  Privacy constraints:
//  - Resolution hardcoded to 5 (~8km hexagons) — NEVER use higher resolution
//  - Exact coordinates are NEVER stored or transmitted
//  - Only H3 cell index is used (coarse location)
//

import Foundation

// MARK: - Geo Fence

struct GeoFence: Codable, Equatable {
    /// Center H3 cell at resolution 5 (~8km hexagon)
    let h3Cell: UInt64
    
    /// Radius in cells (0 = just center, 1 = center + 6 neighbors, etc.)
    /// Maximum 5 (~40km total coverage)
    let radiusInCells: UInt8
    
    /// If true, only deliver inside the fence. If false, prefer but don't require.
    let deliverOnlyInside: Bool
    
    // MARK: - Constants
    
    /// H3 resolution — HARDCODED. Never change. ~8km hexagon at res 5.
    static let resolution: Int = 5
    
    /// Maximum radius in cells (~40km)
    static let maxRadius: UInt8 = 5
    
    // MARK: - Coding Keys (short for BLE)
    
    enum CodingKeys: String, CodingKey {
        case h3Cell = "h3"
        case radiusInCells = "r"
        case deliverOnlyInside = "s"  // "strict"
    }
    
    // MARK: - Query
    
    /// Check if another H3 cell falls within this geo-fence.
    /// Uses grid distance (number of hexagon hops between cells).
    func contains(_ otherCell: UInt64) -> Bool {
        let distance = GeoFence.gridDistance(h3Cell, otherCell)
        return distance <= Int(radiusInCells)
    }
    
    /// Check if a cell is near this fence (within fence + buffer).
    /// Used for relay decisions — relay if within range + 2 cells.
    func isNearby(_ otherCell: UInt64, buffer: Int = 2) -> Bool {
        let distance = GeoFence.gridDistance(h3Cell, otherCell)
        return distance <= Int(radiusInCells) + buffer
    }
    
    /// Human-readable radius description.
    var radiusDescription: String {
        let km = (Int(radiusInCells) * 2 + 1) * 8  // Approximate km
        return "~\(km) km"
    }
    
    // MARK: - H3 Grid Operations (via H3Lite)
    
    /// Compute grid distance between two H3 cells.
    /// Returns the number of hexagon hops between cells.
    static func gridDistance(_ a: UInt64, _ b: UInt64) -> Int {
        H3Lite.gridDistance(a, b)
    }
    
    /// Convert lat/lng to H3 cell index at the default resolution (5 ≈ 8km).
    static func latLngToCell(lat: Double, lng: Double) -> UInt64 {
        H3Lite.latLngToCell(lat: lat, lng: lng, resolution: Self.resolution)
    }
    
    /// Convert lat/lng to H3 cell index at a specific resolution.
    /// Use for features requiring different granularity:
    ///   - Resolution 5 (~8km): default privacy-safe
    ///   - Resolution 9 (~150m): Club Mode
    static func latLngToCell(lat: Double, lng: Double, resolution: Int) -> UInt64 {
        H3Lite.latLngToCell(lat: lat, lng: lng, resolution: resolution)
    }
    
    /// Get cell boundary vertices for map overlay.
    /// Returns 6 (lat, lng) pairs forming the hexagon.
    static func cellBoundary(_ cell: UInt64) -> [(lat: Double, lng: Double)] {
        H3Lite.cellBoundary(cell)
    }
    
    /// Get all cells within k rings of origin.
    static func gridDisk(origin: UInt64, k: Int) -> [UInt64] {
        H3Lite.gridDisk(origin: origin, k: k)
    }
    
    /// Estimate distance in meters between two cells.
    static func distanceMeters(_ a: UInt64, _ b: UInt64) -> Double {
        H3Lite.distanceMeters(a, b)
    }
}

// MARK: - Validation

extension GeoFence {
    /// Validate that this fence has reasonable parameters.
    var isValid: Bool {
        return h3Cell != 0 && radiusInCells <= Self.maxRadius
    }
}
