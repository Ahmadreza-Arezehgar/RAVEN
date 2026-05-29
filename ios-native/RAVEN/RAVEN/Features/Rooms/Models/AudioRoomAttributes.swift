#if !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

/// Shared ActivityAttributes model for Audio Room Live Activity.
///
/// `roomId` is the canonical UUID; `shareSlug` is the short
/// deep-link-friendly identifier. The widget extension reads
/// `shareSlug` to build the `raven://room/{slug}` URL that brings
/// the user back into the room when they tap the Dynamic Island or
/// the lock-screen banner. Optional because legacy rooms created
/// before slug generation don't have one — in that case the widget
/// falls back to opening the app without deep-linking.
struct AudioRoomAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var listenersCount: Int
        var speakersCount: Int
        var isMuted: Bool
    }

    var roomId: String
    var roomTitle: String
    var shareSlug: String?
}
#endif
