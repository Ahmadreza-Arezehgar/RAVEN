//
//  VideoTimestampStub.swift
//  RAVEN
//
//  Stub for the YouTube-style "chapter" parser used by `FeedVideoPlayer`.
//  The real parser scans a post's body for `0:42 — Chapter title` lines
//  and emits jump points; it was bundled with the Phase-4 WIP and got
//  reverted out. The player still references the types, so we keep
//  them around as no-op shapes — the chapter rail just renders empty.
//

import Foundation

struct VideoTimestamp: Identifiable, Hashable {
    let id = UUID()
    /// Stable string token used by the player to compare "is this the
    /// active chapter" without identity-based equality. Defaults to
    /// the id's UUID string when not set explicitly.
    let token: String
    let seconds: Double
    let label: String

    init(seconds: Double, label: String, token: String? = nil) {
        self.seconds = seconds
        self.label = label
        self.token = token ?? UUID().uuidString
    }
}

enum VideoTimestampParser {
    /// Parse video chapter timestamps from a post's body. Stub returns
    /// an empty array, so the player skips drawing the chapter rail.
    static func extract(from text: String) -> [VideoTimestamp] {
        []
    }
}

// `ravenVideoSetPlaybackRate` is declared in `FeedVideoPlayer.swift`
// (now back in the build); only the subtitle notification name lives
// here.
extension Notification.Name {
    static let ravenVideoSetSubtitle = Notification.Name("ravenVideoSetSubtitle")
}
