import ActivityKit
import Foundation

/// Singleton lifecycle manager for Audio Room Live Activity.
/// Handles start (on join), throttled update (max every 5s), and end (on leave).
@MainActor
class AudioRoomActivityManager {
    static let shared = AudioRoomActivityManager()
    
    private var currentActivity: Activity<AudioRoomAttributes>?
    private var lastUpdate: Date = .distantPast
    private let throttleInterval: TimeInterval = 5
    
    private init() {}
    
    // MARK: - Start
    
    func startActivity(roomId: String, roomTitle: String, state: AudioRoomAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        // End any existing activity first
        endActivity()
        
        let attributes = AudioRoomAttributes(roomId: roomId, roomTitle: roomTitle)
        let content = ActivityContent(state: state, staleDate: nil)
        
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil  // local-only for now; add .token for server push later
            )
        } catch {
            #if DEBUG
            print("❌ Failed to start Live Activity: \(error)")
            #endif
        }
    }
    
    // MARK: - Update (throttled)
    
    func updateActivity(state: AudioRoomAttributes.ContentState) {
        guard let activity = currentActivity else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= throttleInterval else { return }
        lastUpdate = now
        
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            await activity.update(content)
        }
    }
    
    // MARK: - End
    
    func endActivity() {
        guard let activity = currentActivity else { return }
        
        let finalContent = ActivityContent(
            state: activity.content.state,
            staleDate: nil
        )
        Task {
            await activity.end(finalContent, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }
}
