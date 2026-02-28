// RAVEN - Location Service
// Handles location services for nearby features

import Foundation
import CoreLocation
import Combine
import UIKit

/// Handles location services for nearby features
@MainActor
class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()
    
    @Published var currentLocation: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isAuthorized = false
    
    /// True if user has denied permission and needs to go to Settings
    var shouldShowSettingsPrompt: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }
    
    /// True if permission hasn't been requested yet
    var isNotDetermined: Bool {
        authorizationStatus == .notDetermined
    }
    
    private let locationManager = CLLocationManager()
    
    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = locationManager.authorizationStatus
        updateAuthState()
    }
    
    // MARK: - Permission
    
    /// Request location permission - call this when user taps "Enable" button
    func requestPermission() {
        guard !shouldShowSettingsPrompt else {
            openSettings()
            return
        }
        locationManager.requestWhenInUseAuthorization()
    }
    
    func requestAlwaysPermission() {
        locationManager.requestAlwaysAuthorization()
    }
    
    /// Open app settings - use when permission is denied
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
    
    private func updateAuthState() {
        let wasAuthorized = isAuthorized
        isAuthorized = authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        
        // Auto-start location updates when permission is newly granted
        if isAuthorized && !wasAuthorized {
            startUpdating()
        }
    }
    
    // MARK: - Location
    
    func startUpdating() {
        guard isAuthorized else {
            requestPermission()
            return
        }
        locationManager.startUpdatingLocation()
    }
    
    func stopUpdating() {
        locationManager.stopUpdatingLocation()
    }
    
    func requestOnce() {
        guard isAuthorized else {
            requestPermission()
            return
        }
        locationManager.requestLocation()
    }
    
    // MARK: - Geohash
    
    /// Generate geohash for current location (for nearby discovery)
    func currentGeohash(precision: Int = 6) -> String? {
        guard let location = currentLocation else { return nil }
        return geohash(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, precision: precision)
    }
    
    /// Generate geohash from coordinates
    func geohash(latitude: Double, longitude: Double, precision: Int = 6) -> String {
        var isEven = true
        var bit = 0
        var currentCharIndex = 0
        var hash = ""
        
        var minLat = -90.0, maxLat = 90.0
        var minLon = -180.0, maxLon = 180.0
        
        let base32 = "0123456789bcdefghjkmnpqrstuvwxyz"
        
        while hash.count < precision {
            if isEven {
                let mid = (minLon + maxLon) / 2
                if longitude >= mid {
                    currentCharIndex |= (1 << (4 - bit))
                    minLon = mid
                } else {
                    maxLon = mid
                }
            } else {
                let mid = (minLat + maxLat) / 2
                if latitude >= mid {
                    currentCharIndex |= (1 << (4 - bit))
                    minLat = mid
                } else {
                    maxLat = mid
                }
            }
            isEven.toggle()
            
            if bit < 4 {
                bit += 1
            } else {
                let charIndex = base32.index(base32.startIndex, offsetBy: currentCharIndex)
                hash.append(base32[charIndex])
                bit = 0
                currentCharIndex = 0
            }
        }
        
        return hash
    }
    
    /// Get nearby geohashes (including neighbors)
    func nearbyGeohashes(precision: Int = 5) -> [String] {
        guard let center = currentGeohash(precision: precision) else { return [] }
        return getNeighbors(of: center) + [center]
    }
    
    private func getNeighbors(of hash: String) -> [String] {
        // Simplified - returns the hash itself for now
        // Full implementation would calculate 8 neighboring geohashes
        return []
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            currentLocation = locations.last
        }
    }
    
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            updateAuthState()
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ [Location] Error: \(error.localizedDescription)")
    }
}
