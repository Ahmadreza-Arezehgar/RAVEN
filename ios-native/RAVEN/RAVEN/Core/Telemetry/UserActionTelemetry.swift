//
//  UserActionTelemetry.swift
//  RAVEN
//
//  Messenger-product boundary: this compatibility shim provides local
//  tactile feedback only. It MUST NOT upload taps, contact/conversation
//  identifiers, metadata, or engagement events to a Raven server.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Local messaging actions that still use the compatibility feedback shim.
enum UserAction: String {
    case block                 = "block"
    case unblock               = "unblock"
    case report                = "report"
    case chatMute              = "chat_mute"
    case chatUnmute            = "chat_unmute"
}

/// Discriminator for `target_id`. Optional — pass nil when the
/// action doesn't reference a specific target (e.g. signIn).
enum UserActionTarget: String {
    case user, group, conversation
}

@MainActor
final class UserActionTelemetry {

    static let shared = UserActionTelemetry()

    /// Disable haptic feedback (used by tests + headless builds).
    var hapticsEnabled: Bool = true

    private init() {}

    // MARK: - Public API

    /// Provide local feedback for an intentional messaging action. Parameters
    /// remain for source compatibility but are deliberately never persisted or
    /// transmitted.
    func record(
        _ action: UserAction,
        targetId: String? = nil,
        targetType: UserActionTarget? = nil,
        metadata: [String: Any]? = nil
    ) {
        _ = action
        _ = targetId
        _ = targetType
        _ = metadata
        fireHaptic()
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

}
