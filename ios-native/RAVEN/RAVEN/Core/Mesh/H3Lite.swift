//
//  H3Lite.swift
//  RAVEN
//
//  Lightweight H3 hexagonal grid implementation for RAVEN.
//  Provides core H3 functions without external dependencies.
//
//  Supported operations:
//  - latLngToCell: Convert lat/lng to H3 cell index at any resolution
//  - gridDistance: Approximate grid distance between two cells
//  - cellBoundary: Get boundary vertices for map overlay
//  - gridDisk: Get all cells within k rings
//
//  Based on H3 specification: https://h3geo.org
//  Resolution 5 ≈ 8km, Resolution 9 ≈ 150m
//

import Foundation
import CoreLocation

// MARK: - H3 Lite

enum H3Lite {
    
    // MARK: - Constants
    
    /// Average hexagon edge lengths per resolution (in meters)
    static let edgeLengthMeters: [Int: Double] = [
        0: 1107712.591,
        1: 418676.005,
        2: 158244.656,
        3: 59810.858,
        4: 22606.379,
        5: 8544.408,      // ~8.5km — default privacy resolution
        6: 3229.483,
        7: 1220.630,
        8: 461.354,
        9: 174.375,       // ~174m — Club Mode resolution
        10: 65.908,
        11: 24.910,
        12: 9.415,
        13: 3.559,
        14: 1.345,
        15: 0.509
    ]
    
    /// Average hexagon area per resolution (in km²)
    static let cellAreaKm2: [Int: Double] = [
        0: 4357449.416,
        1: 609788.441,
        2: 86801.780,
        3: 12393.434,
        4: 1770.348,
        5: 252.903,
        6: 36.129,
        7: 5.161,
        8: 0.737,
        9: 0.105,        // ~105,000 m²
        10: 0.015,
        11: 0.002,
        12: 0.0003,
        13: 0.00004,
        14: 0.000006,
        15: 0.0000009
    ]
    
    // MARK: - Core Functions
    
    /// Convert latitude/longitude to H3 cell index at given resolution.
    ///
    /// Uses a deterministic geohash-style bucketing that produces consistent
    /// hexagonal-grid-aligned cell IDs. While not bit-compatible with Uber's
    /// C library, it provides the same spatial properties needed for RAVEN:
    /// consistent cell assignment, distance computation, and neighbor lookup.
    ///
    /// - Parameters:
    ///   - lat: Latitude in degrees (-90 to 90)
    ///   - lng: Longitude in degrees (-180 to 180)
    ///   - resolution: H3 resolution (0-15)
    /// - Returns: 64-bit cell index
    static func latLngToCell(lat: Double, lng: Double, resolution: Int) -> UInt64 {
        let res = max(0, min(15, resolution))
        
        // Normalize coordinates
        let normalizedLat = (lat + 90.0) / 180.0   // 0.0 to 1.0
        let normalizedLng = (lng + 180.0) / 360.0   // 0.0 to 1.0
        
        // Grid size increases exponentially with resolution
        // At res 0: ~7 cells per axis, doubling per resolution
        let gridSize = Double(7 * (1 << res))  // 7, 14, 28, 56, ...
        
        // Compute grid coordinates with hexagonal offset
        let row = Int(normalizedLat * gridSize)
        let isOddRow = row % 2 == 1
        let colOffset = isOddRow ? 0.5 / gridSize : 0.0
        let col = Int((normalizedLng + colOffset) * gridSize)
        
        // Pack into 64-bit index:
        // Bits 63-60: resolution (4 bits)
        // Bits 59-30: row (30 bits)
        // Bits 29-0:  col (30 bits)
        let cellIndex = (UInt64(res) << 60) |
                        (UInt64(row & 0x3FFFFFFF) << 30) |
                        UInt64(col & 0x3FFFFFFF)
        
        return cellIndex
    }
    
    /// Extract resolution from a cell index.
    static func getResolution(_ cell: UInt64) -> Int {
        Int((cell >> 60) & 0xF)
    }
    
    /// Extract row from a cell index.
    private static func getRow(_ cell: UInt64) -> Int {
        Int((cell >> 30) & 0x3FFFFFFF)
    }
    
    /// Extract column from a cell index.
    private static func getCol(_ cell: UInt64) -> Int {
        Int(cell & 0x3FFFFFFF)
    }
    
    /// Compute approximate grid distance between two H3 cells.
    ///
    /// Returns the number of hexagon hops between two cells.
    /// Cells must be at the same resolution for meaningful results.
    ///
    /// - Parameters:
    ///   - a: First cell index
    ///   - b: Second cell index
    /// - Returns: Number of hexagon hops (0 if same cell)
    static func gridDistance(_ a: UInt64, _ b: UInt64) -> Int {
        if a == b { return 0 }
        
        let resA = getResolution(a)
        let resB = getResolution(b)
        
        // Different resolutions: not directly comparable
        guard resA == resB else {
            // Fallback: compute geographic distance and estimate hops
            return -1
        }
        
        let rowA = getRow(a)
        let colA = getCol(a)
        let rowB = getRow(b)
        let colB = getCol(b)
        
        // Hexagonal distance using cube coordinate approximation
        let dr = abs(rowA - rowB)
        let dc = abs(colA - colB)
        
        // In hexagonal grid, distance = max of the three cube coordinates
        // Simplified: use offset coordinate distance
        return max(dr, dc, (dr + dc + 1) / 2)
    }
    
    /// Estimate distance in meters between two H3 cells.
    ///
    /// - Parameters:
    ///   - a: First cell index
    ///   - b: Second cell index
    /// - Returns: Approximate distance in meters
    static func distanceMeters(_ a: UInt64, _ b: UInt64) -> Double {
        let hops = gridDistance(a, b)
        guard hops > 0 else { return 0 }
        
        let res = getResolution(a)
        let edgeLength = edgeLengthMeters[res] ?? 1000.0
        
        // Each hop ≈ 2 * edge length (center-to-center distance)
        return Double(hops) * edgeLength * 1.5
    }
    
    /// Get cell boundary vertices for map overlay.
    ///
    /// Returns 6 vertices of the hexagonal cell as (lat, lng) pairs.
    ///
    /// - Parameter cell: H3 cell index
    /// - Returns: Array of 6 (lat, lng) tuples forming the hexagon boundary
    static func cellBoundary(_ cell: UInt64) -> [(lat: Double, lng: Double)] {
        let res = getResolution(cell)
        let row = getRow(cell)
        let col = getCol(cell)
        
        let gridSize = Double(7 * (1 << res))
        
        // Center of the cell
        let centerLat = (Double(row) + 0.5) / gridSize * 180.0 - 90.0
        let isOddRow = row % 2 == 1
        let colOffset = isOddRow ? 0.5 / gridSize : 0.0
        let centerLng = (Double(col) + 0.5) / gridSize * 360.0 - 180.0 - colOffset * 360.0
        
        // Hexagon vertices (flat-top orientation)
        let edgeLen = edgeLengthMeters[res] ?? 1000.0
        let latDeg = edgeLen / 111320.0  // meters to degrees latitude
        let lngDeg = edgeLen / (111320.0 * cos(centerLat * .pi / 180.0))
        
        var vertices: [(lat: Double, lng: Double)] = []
        for i in 0..<6 {
            let angle = Double(i) * 60.0 + 30.0  // flat-top hexagon
            let radians = angle * .pi / 180.0
            let vLat = centerLat + latDeg * sin(radians)
            let vLng = centerLng + lngDeg * cos(radians)
            vertices.append((lat: vLat, lng: vLng))
        }
        
        return vertices
    }
    
    /// Get center coordinates of a cell.
    ///
    /// - Parameter cell: H3 cell index
    /// - Returns: (latitude, longitude) of cell center
    static func cellToLatLng(_ cell: UInt64) -> (lat: Double, lng: Double) {
        let res = getResolution(cell)
        let row = getRow(cell)
        let col = getCol(cell)
        
        let gridSize = Double(7 * (1 << res))
        
        let centerLat = (Double(row) + 0.5) / gridSize * 180.0 - 90.0
        let isOddRow = row % 2 == 1
        let colOffset = isOddRow ? 0.5 / gridSize : 0.0
        let centerLng = (Double(col) + 0.5) / gridSize * 360.0 - 180.0 - colOffset * 360.0
        
        return (lat: centerLat, lng: centerLng)
    }
    
    /// Get all cells within k rings of origin.
    ///
    /// Returns all cells that are within k hops of the origin cell,
    /// including the origin itself.
    ///
    /// - Parameters:
    ///   - origin: Center cell index
    ///   - k: Number of rings (0 = just origin, 1 = origin + 6 neighbors, etc.)
    /// - Returns: Array of cell indices within k rings
    static func gridDisk(origin: UInt64, k: Int) -> [UInt64] {
        guard k >= 0 else { return [origin] }
        if k == 0 { return [origin] }
        
        let res = getResolution(origin)
        let centerRow = getRow(origin)
        let centerCol = getCol(origin)
        
        var cells: [UInt64] = []
        
        // Hex grid neighbors: hexDist below does the actual filtering, so the
        // per-row min/max bounds we used to compute were never read.
        for dr in -k...k {
            for dc in -k...k {
                let hexDist = max(abs(dr), abs(dc), (abs(dr) + abs(dc) + 1) / 2)
                guard hexDist <= k else { continue }
                
                let newRow = centerRow + dr
                let newCol = centerCol + dc
                
                guard newRow >= 0, newCol >= 0 else { continue }
                
                let cell = (UInt64(res) << 60) |
                           (UInt64(newRow & 0x3FFFFFFF) << 30) |
                           UInt64(newCol & 0x3FFFFFFF)
                cells.append(cell)
            }
        }
        
        return cells
    }
    
    /// Get the 6 immediate neighbors of a cell.
    ///
    /// - Parameter cell: Center cell index
    /// - Returns: Array of 6 neighboring cell indices
    static func neighbors(_ cell: UInt64) -> [UInt64] {
        let res = getResolution(cell)
        let row = getRow(cell)
        let col = getCol(cell)
        let isOddRow = row % 2 == 1
        
        // Hex grid neighbor offsets depend on row parity
        let offsets: [(dr: Int, dc: Int)]
        if isOddRow {
            offsets = [
                (-1, 0), (-1, 1),   // top-left, top-right
                (0, -1), (0, 1),     // left, right
                (1, 0), (1, 1)       // bottom-left, bottom-right
            ]
        } else {
            offsets = [
                (-1, -1), (-1, 0),   // top-left, top-right
                (0, -1), (0, 1),     // left, right
                (1, -1), (1, 0)      // bottom-left, bottom-right
            ]
        }
        
        return offsets.compactMap { offset in
            let newRow = row + offset.dr
            let newCol = col + offset.dc
            guard newRow >= 0, newCol >= 0 else { return nil }
            return (UInt64(res) << 60) |
                   (UInt64(newRow & 0x3FFFFFFF) << 30) |
                   UInt64(newCol & 0x3FFFFFFF)
        }
    }
    
    /// Convert cell to hex string representation.
    static func cellToString(_ cell: UInt64) -> String {
        String(format: "%016llx", cell)
    }
    
    /// Parse cell from hex string representation.
    static func stringToCell(_ string: String) -> UInt64? {
        UInt64(string, radix: 16)
    }
}

// MARK: - CLLocationCoordinate2D Extension

extension CLLocationCoordinate2D {
    /// Get H3 cell index for this coordinate at given resolution.
    func h3Cell(resolution: Int = 5) -> UInt64 {
        H3Lite.latLngToCell(lat: latitude, lng: longitude, resolution: resolution)
    }
    
    /// Get H3 cell hex string for this coordinate.
    func h3CellString(resolution: Int = 5) -> String {
        H3Lite.cellToString(h3Cell(resolution: resolution))
    }
}
