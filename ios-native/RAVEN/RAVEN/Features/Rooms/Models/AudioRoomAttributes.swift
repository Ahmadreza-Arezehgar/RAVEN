#if !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

/// Shared ActivityAttributes model for Audio Room Live Activity.
struct AudioRoomAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var listenersCount: Int
        var speakersCount: Int
        var isMuted: Bool
    }

    var roomId: String
    var roomTitle: String
}
#endif
