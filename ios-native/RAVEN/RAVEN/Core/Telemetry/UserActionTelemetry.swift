//
//  UserActionTelemetry.swift
//  RAVEN
//
//  🔴 ROUND 26 (2026-05-16) — added at user request.
//
//  "har dokmee ke user mizane app darja behesh reaction dashte
//   bashe ... va dar paszaminie toye server sabt beshe"
//   (every button the user taps should have a visible reaction AND
//   be logged on the server in the background)
//
//  Single call-site for the "I tapped a meaningful action button"
//  signal. Each call:
//    1. Fires a light haptic (so the user feels the tap landed,
//       even on buttons that have no visible state change yet).
//    2. Posts to `POST /api/events/action` as a fire-and-forget
//       background Task — failure is silent (network glitches or
//       sign-out mid-tap must NEVER break the UI flow).
//
//  Used by: block / report / follow / unfollow / accept /
//  decline / like / unlike / repost / unrepost / bookmark /
//  unbookmark / mute / unmute / pin / unpin / share / forward /
//  add-friend / remove-friend / send / cancel / approve / reject /
//  join / leave / kick / promote / demote — anywhere a user
//  intentionally taps to cause something to happen.
//
//  Not used for navigation taps (tapping a chat to open it) or
//  passive interactions (scrolling a feed). Those are tracked
//  via the existing `/events/view` + `/events/interaction` paths.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Canonical action vocabulary. Keep strings stable across releases —
/// they become server-side analytics keys. Add NEW cases instead of
/// renaming existing ones.
enum UserAction: String {
    // Social graph
    case follow                = "follow"
    case unfollow              = "unfollow"
    case block                 = "block"
    case unblock               = "unblock"
    case report                = "report"
    case mute                  = "mute"
    case unmute                = "unmute"

    // Friend requests
    case friendRequestSend     = "friend_request_send"
    case friendRequestAccept   = "friend_request_accept"
    case friendRequestDecline  = "friend_request_decline"
    case friendRequestCancel   = "friend_request_cancel"
    case friendRemove          = "friend_remove"

    // Post interactions
    case like                  = "like"
    case unlike                = "unlike"
    case repost                = "repost"
    case unrepost              = "unrepost"
    case bookmark              = "bookmark"
    case unbookmark            = "unbookmark"
    case commentSubmit         = "comment_submit"
    case commentDelete         = "comment_delete"
    case postShare             = "post_share"
    case postPin               = "post_pin"
    case postUnpin             = "post_unpin"
    case postHide              = "post_hide"
    case postEdit              = "post_edit"
    case postDelete            = "post_delete"

    // Messaging
    case messageSendText       = "message_send_text"
    case messageSendMedia      = "message_send_media"
    case messageSendAlbum      = "message_send_album"
    case messageSendVoice      = "message_send_voice"
    case messageDelete         = "message_delete"
    case messageEdit           = "message_edit"
    case messageForward        = "message_forward"
    case messagePin            = "message_pin"
    case messageReact          = "message_react"
    case messageReply          = "message_reply"

    // Conversation
    case chatOpen              = "chat_open"
    case chatArchive           = "chat_archive"
    case chatUnarchive         = "chat_unarchive"
    case chatDelete            = "chat_delete"
    case chatMute              = "chat_mute"
    case chatUnmute            = "chat_unmute"

    // Groups
    case groupCreate           = "group_create"
    case groupJoin             = "group_join"
    case groupLeave            = "group_leave"
    case groupInvite           = "group_invite"
    case groupKick             = "group_kick"
    case groupPromote          = "group_promote"
    case groupDemote           = "group_demote"

    // Auth / settings
    case signIn                = "sign_in"
    case signOut               = "sign_out"
    case settingsToggle        = "settings_toggle"
}

/// Discriminator for `target_id`. Optional — pass nil when the
/// action doesn't reference a specific target (e.g. signIn).
enum UserActionTarget: String {
    case post, user, comment, message, group, conversation, room, poll, story, channel
}

@MainActor
final class UserActionTelemetry {

    static let shared = UserActionTelemetry()

    /// Disable haptic feedback (used by tests + headless builds).
    var hapticsEnabled: Bool = true

    private init() {}

    // MARK: - Public API

    /// Record a user-driven button press.
    ///
    /// - Parameters:
    ///   - action:     Canonical action (see `UserAction`). Use the
    ///                 raw-string overload for one-offs you don't
    ///                 want to register in the enum.
    ///   - targetId:   Optional id of the thing the action targets.
    ///                 Post id for `like`, user id for `block`, etc.
    ///   - targetType: Optional type discriminator for `targetId`.
    ///   - metadata:   Optional JSON-serialisable dictionary. Use
    ///                 sparingly; bigger payloads cost more to ship.
    func record(
        _ action: UserAction,
        targetId: String? = nil,
        targetType: UserActionTarget? = nil,
        metadata: [String: Any]? = nil
    ) {
        record(
            action: action.rawValue,
            targetId: targetId,
            targetType: targetType?.rawValue,
            metadata: metadata
        )
    }

    /// Raw-string overload for actions that don't have an enum case
    /// yet. Prefer the typed `record(_:)` whenever possible so the
    /// vocabulary stays grep-able.
    func record(
        action: String,
        targetId: String? = nil,
        targetType: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        // Haptic feedback — runs synchronously on the main actor
        // so the tap feels "landed" even before the network call
        // even queues. Cheap (~1ms) and safe on every device.
        fireHaptic()

        // Background fire-and-forget. Cancellation / network
        // failure / unauthenticated state all silently no-op —
        // telemetry MUST NEVER block or break the user's UI.
        Task.detached(priority: .background) {
            await Self.postToServer(
                action: action,
                targetId: targetId,
                targetType: targetType,
                metadata: metadata
            )
        }
    }

    // MARK: - Internals

    private func fireHaptic() {
        guard hapticsEnabled else { return }
        #if canImport(UIKit)
        // Light selection-style impact — the same haptic every
        // navigation tap uses, so action buttons feel consistent
        // with the rest of the chrome. Callers that already fire
        // their own success/medium impact don't double-up because
        // `selectionChanged` is the lightest of the three.
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
        #endif
    }

    private static func postToServer(
        action: String,
        targetId: String?,
        targetType: String?,
        metadata: [String: Any]?
    ) async {
        // Skip when the user isn't signed in — no point sending
        // anonymous events through the auth-required endpoint.
        let pair = await KeychainService.shared.getToken()
        guard let pair, !pair.token.isEmpty else { return }

        struct ActionBody: Encodable {
            let action: String
            let target_id: String?
            let target_type: String?
            let metadata: [String: AnyEncodable]?
            let client: String
        }
        var metaWrapped: [String: AnyEncodable]? = nil
        if let metadata, !metadata.isEmpty {
            metaWrapped = metadata.mapValues { AnyEncodable($0) }
        }

        let body = ActionBody(
            action: action,
            target_id: targetId,
            target_type: targetType,
            metadata: metaWrapped,
            client: "ios"
        )

        struct EmptyResponse: Decodable {}
        do {
            let _: EmptyResponse = try await NetworkService.shared.post(
                path: "/api/events/action",
                body: body
            )
        } catch {
            // Silent — telemetry must NEVER produce user-visible
            // errors. Debug log only.
            #if DEBUG
            print("ℹ️ [UserActionTelemetry] silent failure for \(action): \(error)")
            #endif
        }
    }
}

// MARK: - AnyEncodable
/// Tiny type-erased Encodable wrapper so we can ship heterogeneous
/// metadata dictionaries through JSONEncoder without forcing every
/// call site to define a typed Codable struct.
private struct AnyEncodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String:  try c.encode(v)
        case let v as Int:     try c.encode(v)
        case let v as Double:  try c.encode(v)
        case let v as Bool:    try c.encode(v)
        case let v as [String]: try c.encode(v)
        case let v as [Int]:   try c.encode(v)
        case let v as [String: Any]:
            try c.encode(v.mapValues { AnyEncodable($0) })
        case Optional<Any>.none:
            try c.encodeNil()
        default:
            // Fall back to the string description for anything
            // exotic — keeps the JSON valid without forcing the
            // call site to think about encoding.
            try c.encode(String(describing: value))
        }
    }
}
