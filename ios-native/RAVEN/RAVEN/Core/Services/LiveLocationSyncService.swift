//
//  LiveLocationSyncService.swift
//  RAVEN
//
//  ✅ Bug 1 & 4 fix: Singleton service that manages live location sessions
//  independent of any View lifecycle. Sends ONE anchor message, then updates
//  the same message's coordinates instead of creating 720 new bubbles/hour.
//

import Foundation
import CoreLocation

@MainActor
final class LiveLocationSyncService: ObservableObject {
    static let shared = LiveLocationSyncService()
    
    // MARK: - Published State
    
    /// Currently active live location session (nil = no active session)
    @Published private(set) var activeSession: LiveSession?
    
    // MARK: - Private
    
    private var observer: NSObjectProtocol?
    private var expiryTask: Task<Void, Never>?
    
    struct LiveSession {
        let sessionId: String
        let anchorMessageId: String
        let roomId: String
        let expiresAt: Date
        let duration: TimeInterval
    }
    
    // MARK: - Start Live Location
    
    /// Start a live location session. Creates one anchor message and then
    /// updates coordinates in-place every 5 seconds.
    ///
    /// - Parameters:
    ///   - duration: How long the session lasts (e.g. 15 min, 1 hour)
    ///   - initialLocation: The first GPS fix
    ///   - messageStore: The store for the chat where the anchor bubble appears
    func start(
        duration: TimeInterval,
        initialLocation: CLLocation,
        messageStore: MessageStore
    ) async {
        // Stop any existing session first
        stop()
        
        // 1. Start GPS updates in LocationManager
        let sessionId = LocationManager.shared.startLiveUpdates(duration: duration)
        let expiresAt = Date().addingTimeInterval(duration)
        
        // 2. Create ONE anchor message (the only bubble the user sees)
        let anchorId = UUID().uuidString
        let payload = LocationPayload.live(
            from: initialLocation,
            sessionId: sessionId,
            expiresAt: expiresAt
        )
        
        try? await messageStore.sendLocation(payload, clientMessageId: anchorId)
        
        // 3. Save session
        let session = LiveSession(
            sessionId: sessionId,
            anchorMessageId: anchorId,
            roomId: messageStore.roomId,
            expiresAt: expiresAt,
            duration: duration
        )
        activeSession = session
        
        // 4. Subscribe to GPS updates — update anchor in-place instead of new messages
        var lastSentAt = Date()
        let minInterval: TimeInterval = 5
        
        observer = NotificationCenter.default.addObserver(
            forName: .liveLocationUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let location = notification.userInfo?["location"] as? CLLocation,
                  let sid = notification.userInfo?["sessionId"] as? String,
                  sid == sessionId else { return }

            // queue: .main guarantees we're already on the main thread, so
            // assumeIsolated lets us read MainActor state without an await.
            MainActor.assumeIsolated {
                guard let self = self,
                      self.activeSession?.sessionId == sessionId else { return }

                // Throttle
                let now = Date()
                guard now.timeIntervalSince(lastSentAt) >= minInterval else { return }
                lastSentAt = now

                // Check expiry
                guard expiresAt > now else { return }

                // ✅ Update the anchor message with new coordinates (same clientMessageId)
                let updatePayload = LocationPayload.live(
                    from: location, sessionId: sessionId, expiresAt: expiresAt
                )
                Task {
                    try? await messageStore.sendLocation(updatePayload, clientMessageId: anchorId)
                }
            }
        }
        
        // 5. Auto-stop when session expires
        expiryTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self.activeSession?.sessionId == sessionId {
                    self.stop()
                }
            }
        }
        
        #if DEBUG
        print("📍 [LiveLocationSync] Session started: \(sessionId), anchor: \(anchorId.prefix(8)), expires in \(Int(duration))s")
        #endif
    }
    
    // MARK: - Stop
    
    /// Stop the current live location session and clean up all resources.
    func stop() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
        
        expiryTask?.cancel()
        expiryTask = nil
        
        LocationManager.shared.stopLiveUpdates()
        
        let old = activeSession
        activeSession = nil
        
        #if DEBUG
        if let old = old {
            print("📍 [LiveLocationSync] Session stopped: \(old.sessionId)")
        }
        #endif
    }
    
    /// Check if a live session is active for a given room
    func isActive(forRoom roomId: String) -> Bool {
        guard let session = activeSession else { return false }
        return session.roomId == roomId && session.expiresAt > Date()
    }
}
