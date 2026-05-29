import Foundation

/// Payload for the `contactCard` message type — a postcard-style share of
/// another Raven user's profile (avatar + display name + @username + QR
/// deep link). Embedded as JSON in `ChatMessage.text` so we can ride the
/// existing text/cipher pipeline without a new attachment column.
///
/// The receiving client renders this with `ContactCardMessageView`. The QR
/// payload is a stable `https://raven-messager.com/u/<username>` deep link
/// so receivers can scan it with the system camera, and `DeepLinkRouter`
/// can route it inside the app.
struct ContactSharePayload: Codable {
    let userId: String
    let username: String
    let displayName: String
    let avatarUrl: String?

    /// Computed QR / deep-link target for this contact. Receivers render a
    /// QR code over this string; tapping the card also opens the URL.
    var profileURL: URL? {
        URL(string: "https://raven-messager.com/u/\(username)")
    }

    /// Build a payload from a `GroupFriendInfo` (the friend type used by
    /// the attachment-sheet Friends list and Group member picker).
    init(from friend: GroupFriendInfo) {
        self.userId = friend.id
        self.username = friend.username
        self.displayName = friend.safeDisplayName
        self.avatarUrl = friend.avatarUrl
    }

    init(userId: String, username: String, displayName: String, avatarUrl: String?) {
        self.userId = userId
        self.username = username
        self.displayName = displayName
        self.avatarUrl = avatarUrl
    }

    static func decode(from jsonString: String) -> ContactSharePayload? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ContactSharePayload.self, from: data)
    }

    func encode() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Cheap shape probe — true when the string *looks* like a contact-
    /// card payload, without paying for full JSON decode. Used by reply
    /// previews / inbox rows / pinned banners so a card message stored
    /// as `.text` (older clients, server round-trip that dropped the
    /// type column) doesn't leak its raw JSON body into the UI.
    static func looksLikeContactCard(_ s: String?) -> Bool {
        guard let s, s.hasPrefix("{") else { return false }
        return s.contains("\"displayName\"")
            && s.contains("\"username\"")
            && s.contains("\"userId\"")
    }
}
