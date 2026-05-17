//
//  LocationManager.swift
//  RAVEN
//
//  CoreLocation wrapper for Current and Live location sharing
//

import Foundation
import CoreLocation
import Combine

/// Manages location permissions and updates for location sharing feature.
/// Marked `@unchecked Sendable` because every state read/write is funneled
/// onto the main queue (see `DispatchQueue.main.async` blocks below) and
/// CLLocationManager itself is documented as main-thread-only.
final class LocationManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = LocationManager()
    
    private let manager = CLLocationManager()
    
    @Published var lastLocation: CLLocation?
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var isUpdatingLive = false
    
    // Live session tracking
    @Published var liveSessionId: String?
    @Published var liveExpiresAt: Date?
    
    private var locationContinuations: [CheckedContinuation<CLLocation, Error>] = []
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorization = manager.authorizationStatus
    }
    
    // MARK: - Permissions
    
    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }
    
    var hasLocationPermission: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }
    
    // MARK: - Current Location (One-shot)
    
    func getCurrentLocation() async throws -> CLLocation {
        guard hasLocationPermission else {
            throw LocationError.permissionDenied
        }
        
        // ✅ Bug 3 fix: Fast path — if OS has a recent location cached, return immediately
        // Avoids 10-15s satellite wait in indoor environments
        if let recentLoc = manager.location,
           Date().timeIntervalSince(recentLoc.timestamp) < 15 {
            #if DEBUG
            print("📍 [Location] Fast path: using cached location (age: \(Date().timeIntervalSince(recentLoc.timestamp))s)")
            #endif
            return recentLoc
        }
        
        // ✅ Bug 4 fix: Race the continuation against a 10-second timeout.
        // CLLocationManager may never call its delegate in GPS dead zones (indoors),
        // which would leave the continuation hanging forever and the UI frozen.
        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            // Task 1: Actual location request
            // ✅ Bug 3 fix: Wrap in withTaskCancellationHandler so that when the
            // task group cancels this child (timeout wins), the continuation is
            // properly resumed with CancellationError instead of leaking forever.
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        // CLLocationManager delegates on main queue; serialize access there
                        DispatchQueue.main.async {
                            // Cancel stale continuations to prevent double-send
                            let stale = self.locationContinuations
                            self.locationContinuations.removeAll()
                            for c in stale {
                                c.resume(throwing: CancellationError())
                            }
                            
                            self.locationContinuations.append(continuation)
                            self.manager.requestLocation()
                        }
                    }
                } onCancel: {
                    DispatchQueue.main.async {
                        let stale = self.locationContinuations
                        self.locationContinuations.removeAll()
                        for c in stale {
                            c.resume(throwing: CancellationError())
                        }
                    }
                }
            }
            
            // Task 2: Timeout guard (10 seconds)
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw LocationError.locationUnavailable
            }
            
            // Return whichever finishes first
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    // MARK: - Live Location
    
    func startLiveUpdates(duration: TimeInterval) -> String {
        let sessionId = UUID().uuidString
        liveSessionId = sessionId
        liveExpiresAt = Date().addingTimeInterval(duration)
        isUpdatingLive = true
        
        // FIX 8: Enable background location + prevent DB spam
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.distanceFilter = 15 // Only update if user moves 15+ meters
        
        manager.startUpdatingLocation()
        
        #if DEBUG
        print("📍 [Location] Started live session: \(sessionId), expires: \(liveExpiresAt!)")
        #endif
        
        // Auto-stop when expired
        Task {
            try? await Task.sleep(for: .seconds(duration))
            if liveSessionId == sessionId {
                stopLiveUpdates()
            }
        }
        
        return sessionId
    }
    
    func stopLiveUpdates() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        isUpdatingLive = false
        liveSessionId = nil
        liveExpiresAt = nil
        #if DEBUG
        print("📍 [Location] Live session stopped")
        #endif
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        #if DEBUG
        print("📍 [Location] Authorization changed: \(authorization.rawValue)")
        #endif
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        
        // Resume ALL pending continuations safely
        let continuations = locationContinuations
        locationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: location)
        }
        
        // For live updates, publish notification
        if isUpdatingLive {
            NotificationCenter.default.post(
                name: .liveLocationUpdated,
                object: nil,
                userInfo: ["location": location, "sessionId": liveSessionId ?? ""]
            )
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        #if DEBUG
        print("📍 [Location] Error: \(error)")
        #endif
        
        // Resume ALL pending continuations with error
        let continuations = locationContinuations
        locationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - Location Error

enum LocationError: Error, LocalizedError {
    case permissionDenied
    case locationUnavailable
    case sessionExpired
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location permission required"
        case .locationUnavailable:
            return "Unable to get location"
        case .sessionExpired:
            return "Live location session expired"
        }
    }
}

// MARK: - Location Payload (for message content)

struct LocationPayload: Codable {
    enum Kind: String, Codable {
        case current
        case live
    }
    
    let kind: Kind
    let lat: Double
    let lng: Double
    let accuracy: Double?
    let label: String?
    let timestamp: Date
    
    // Live-specific
    let sessionId: String?
    let expiresAt: Date?
    let heading: Double?
    let speed: Double?
    
    // Create current location payload
    static func current(from location: CLLocation, label: String? = nil) -> LocationPayload {
        LocationPayload(
            kind: .current,
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            label: label,
            timestamp: Date(),
            sessionId: nil,
            expiresAt: nil,
            heading: nil,
            speed: nil
        )
    }
    
    // Create live location payload
    static func live(from location: CLLocation, sessionId: String, expiresAt: Date) -> LocationPayload {
        LocationPayload(
            kind: .live,
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            label: nil,
            timestamp: Date(),
            sessionId: sessionId,
            expiresAt: expiresAt,
            heading: location.course >= 0 ? location.course : nil,
            speed: location.speed >= 0 ? location.speed : nil
        )
    }
    
    // Encode to JSON string for message content
    func toJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    // Decode from JSON string
    static func from(_ jsonString: String) -> LocationPayload? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocationPayload.self, from: data)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let liveLocationUpdated = Notification.Name("liveLocationUpdated")
}
