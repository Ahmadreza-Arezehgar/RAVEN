//
//  LocationPrivacyService.swift
//  RAVEN
//
//  Privacy-first location manager for geo-fenced messaging.
//
//  PRIVACY CONSTRAINTS (CRITICAL):
//  1. Default resolution is 5 (~8km). Higher resolutions (e.g. 9 for Club)
//     are only used on-demand and NEVER cached persistently.
//  2. Exact coordinates are NEVER stored, logged, or transmitted.
//  3. desiredAccuracy = kCLLocationAccuracyKilometer (saves battery + privacy)
//     EXCEPT in Club precision mode (kCLLocationAccuracyBest).
//  4. Only H3 cell index is cached — coordinate is discarded immediately.
//  5. Location only active when sending/receiving geo-fenced messages.
//  6. Explicit consent prompt on first use.
//

import Foundation
import CoreLocation

// MARK: - Location Precision Mode

/// Determines GPS accuracy for LocationPrivacyService.
/// Club Mode uses `.high` for ~150m H3 cells; all else uses `.standard` (8km).
enum LocationAccuracyMode {
    case standard   // kCLLocationAccuracyKilometer — geo-fencing, privacy
    case high       // kCLLocationAccuracyBest — Club Mode tracking
    
    var clAccuracy: CLLocationAccuracy {
        switch self {
        case .standard: return kCLLocationAccuracyKilometer
        case .high: return kCLLocationAccuracyBest
        }
    }
    
    var distanceFilter: CLLocationDistance {
        switch self {
        case .standard: return 1000  // 1km — coarse updates
        case .high: return 10        // 10m — fine updates for Club tracking
        }
    }
    
    var updateInterval: TimeInterval {
        switch self {
        case .standard: return 300   // 5 minutes
        case .high: return 5         // 5 seconds — matches Club ping cadence
        }
    }
}

// MARK: - Location Privacy Service

@MainActor
final class LocationPrivacyService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = LocationPrivacyService()
    
    private let locationManager = CLLocationManager()
    private var lastUpdate: Date?
    private var accuracyMode: LocationAccuracyMode = .standard
    
    /// Current H3 cell at default resolution (5 ≈ 8km) — the ONLY location data stored.
    /// Exact coordinates are discarded immediately after computing this.
    @Published private(set) var currentH3Cell: UInt64?
    
    /// Authorization status for UI display.
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    /// Whether the service is actively tracking location.
    @Published private(set) var isActive: Bool = false
    
    /// Whether this is the first time requesting location (for consent prompt).
    var needsInitialConsent: Bool {
        return authorizationStatus == .notDetermined
    }
    
    private override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
    }
    
    // MARK: - Public API
    
    /// Safe accessor for the raw CLLocation (coordinate only).
    /// Used by VaultService for proximity unlock with actual GPS precision.
    /// ⚠️ The CLLocation is NOT persisted, logged, or transmitted — only read transiently.
    var currentCLLocation: CLLocation? {
        locationManager.location
    }
    
    /// Start location tracking in standard mode (geo-fencing, ~8km).
    /// Uses kilometer accuracy (privacy + battery saving).
    func start() {
        startWithMode(.standard)
    }
    
    /// Start high-precision location tracking for Club Mode.
    /// Uses best accuracy + WiFi/GPS fusion + 10m distance filter.
    /// This gives ~10m accuracy (enough for H3 resolution 9 = ~150m cells).
    func startHighPrecision() {
        startWithMode(.high)
    }
    
    /// Core start implementation with configurable accuracy mode.
    private func startWithMode(_ mode: LocationAccuracyMode) {
        guard FeatureFlag.isGeoFencedEnabled else { return }
        
        accuracyMode = mode
        lastUpdate = nil  // Reset rate limit on mode change
        
        locationManager.desiredAccuracy = mode.clAccuracy
        locationManager.distanceFilter = mode.distanceFilter
        locationManager.allowsBackgroundLocationUpdates = false  // No background tracking
        locationManager.pausesLocationUpdatesAutomatically = (mode == .standard)
        // Enable WiFi + cellular + GPS fusion for best results
        locationManager.activityType = mode == .high ? .otherNavigation : .other
        
        switch authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
            isActive = true
        default:
            break
        }
        
        #if DEBUG
        let desc = mode == .high ? "BEST (Club)" : "kilometer"
        print("📍 [LocationPrivacy] Started (accuracy: \(desc), filter: \(mode.distanceFilter)m)")
        #endif
    }
    
    /// Stop location tracking.
    func stop() {
        locationManager.stopUpdatingLocation()
        isActive = false
        accuracyMode = .standard
        #if DEBUG
        print("📍 [LocationPrivacy] Stopped")
        #endif
    }
    
    /// Request a one-time location update for sending a geo-fenced message.
    /// Lighter than continuous tracking.
    func requestSingleUpdate() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            start()  // Will request permission first
            return
        }
        
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.requestLocation()
    }
    
    /// Get current H3 cell at a specific resolution.
    /// Used by Club Mode (resolution 9 ≈ 150m) and Proximity-Locked (variable).
    /// Returns nil if location is not available.
    ///
    /// - Parameter resolution: H3 resolution (0-15). Default privacy resolution is 5.
    /// - Returns: H3 cell index at the requested resolution, or nil.
    ///
    /// ⚠️ PRIVACY: This does NOT cache higher-resolution cells.
    /// The result is computed on-the-fly and discarded after use.
    func currentH3Cell(resolution: Int) -> UInt64? {
        guard let location = locationManager.location else { return nil }
        
        // Reject stale locations (>60s old) when in high-precision mode
        if accuracyMode == .high {
            let age = Date().timeIntervalSince(location.timestamp)
            if age > 60 {
                #if DEBUG
                print("📍 [LocationPrivacy] Rejecting stale location (age: \(Int(age))s)")
                #endif
                // Request a fresh update
                locationManager.requestLocation()
                return nil
            }
        }
        
        return GeoFence.latLngToCell(
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            resolution: resolution
        )
    }
    
    /// Get current H3 cell as a hex string at a specific resolution.
    func currentH3CellString(resolution: Int) -> String? {
        guard let cell = currentH3Cell(resolution: resolution) else { return nil }
        return H3Lite.cellToString(cell)
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            if isActive || currentH3Cell == nil {
                manager.startUpdatingLocation()
                isActive = true
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        // Rate limit updates (mode-adaptive)
        if let lastUpdate = lastUpdate, Date().timeIntervalSince(lastUpdate) < accuracyMode.updateInterval {
            return
        }
        
        // In high-precision mode, reject poor horizontal accuracy (>500m)
        if accuracyMode == .high && location.horizontalAccuracy > 500 {
            #if DEBUG
            print("📍 [LocationPrivacy] Discarding low-accuracy fix: \(Int(location.horizontalAccuracy))m")
            #endif
            return
        }
        
        // ⚠️ CRITICAL: Compute H3 index and DISCARD coordinate immediately
        let h3Index = GeoFence.latLngToCell(
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude
        )
        
        currentH3Cell = h3Index
        lastUpdate = Date()
        
        // ⚠️ coordinate is NOT stored, NOT logged, NOT transmitted
        
        #if DEBUG
        if accuracyMode == .high {
            print("📍 [LocationPrivacy] Updated H3 cell (Club mode, accuracy: \(Int(location.horizontalAccuracy))m)")
        } else {
            // In debug, only log the H3 cell — NEVER the coordinate
            print("📍 [LocationPrivacy] Updated H3 cell (privacy-safe)")
        }
        #endif
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        #if DEBUG
        print("📍 [LocationPrivacy] Location error: \(error.localizedDescription)")
        #endif
    }
}
