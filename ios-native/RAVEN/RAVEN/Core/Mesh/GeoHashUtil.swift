//
//  GeoHashUtil.swift
//  RAVEN
//
//  Privacy-preserving GeoHash encoder for mesh routing.
//  Converts GPS coordinates to a coarse grid cell (~39×19 km at precision 4)
//  so the server can geo-fence message delivery without ever seeing exact location.
//

import Foundation
import CoreLocation

/// تبدیل مختصات به رشته GeoHash برای حفظ حریم خصوصی در مسیریابی سرور
struct GeoHashUtil {
    private static let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")
    
    /// Encode latitude/longitude to a GeoHash string.
    /// - Parameters:
    ///   - latitude: Latitude in degrees (-90…90)
    ///   - longitude: Longitude in degrees (-180…180)
    ///   - precision: Number of characters (4 ≈ city-level, ~39×19 km)
    /// - Returns: GeoHash string of the requested precision
    static func encode(latitude: Double, longitude: Double, precision: Int = 4) -> String {
        var isEven = true
        var lat = (-90.0, 90.0)
        var lon = (-180.0, 180.0)
        var bit = 0
        var ch = 0
        var geohash = ""
        
        while geohash.count < precision {
            if isEven {
                let mid = (lon.0 + lon.1) / 2
                if longitude > mid {
                    ch |= (1 << (4 - bit))
                    lon.0 = mid
                } else {
                    lon.1 = mid
                }
            } else {
                let mid = (lat.0 + lat.1) / 2
                if latitude > mid {
                    ch |= (1 << (4 - bit))
                    lat.0 = mid
                } else {
                    lat.1 = mid
                }
            }
            isEven.toggle()
            if bit < 4 {
                bit += 1
            } else {
                geohash.append(base32[ch])
                bit = 0
                ch = 0
            }
        }
        return geohash
    }
}
