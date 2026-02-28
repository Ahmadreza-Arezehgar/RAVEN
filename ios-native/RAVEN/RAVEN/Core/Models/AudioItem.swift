import Foundation

// MARK: - Audio Item (Voice playback data)
/// Represents a playable voice item — voice post, voice message, or comment.

struct AudioItem: Identifiable, Equatable {
    let id: String
    let voiceUrl: String
    let duration: Int              // seconds
    let waveform: [Float]?
    let senderName: String
    let senderAvatar: String?      // URL string
    let contentId: String?         // post/message id for transcript
    let contentType: String        // "post", "comment", "dm", "group"
    
    static func == (lhs: AudioItem, rhs: AudioItem) -> Bool {
        lhs.id == rhs.id
    }
}
