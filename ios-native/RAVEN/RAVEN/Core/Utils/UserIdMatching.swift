//
//  UserIdMatching.swift
//  RAVEN
//
//  Single source of truth for "is this id mine?" comparisons.
//
//  Why this exists
//  ───────────────
//  PostgreSQL stores UUIDs in canonical lowercase ("ab12-…"); Swift's
//  `UUID().uuidString` produces uppercase ("AB12-…"); different
//  server endpoints have historically echoed user_id with different
//  casing. The result was a class of subtle bugs where a check like
//  `message.senderId == AuthService.shared.currentUser?.id`
//  evaluated `false` for the user's OWN messages — bubbles still
//  rendered correctly because some sites lowercased while others
//  did not, but the unread-count badge happily counted the user's
//  own sends as "from peer" (the visible report:  the floating
//  scroll-to-bottom button suddenly showing "3 new" right after
//  the user pressed Send).
//
//  Use these helpers everywhere instead of raw `==` on a senderId
//  pair. They normalise and compare in one place; if the canonical
//  form ever changes again, only this file needs to change.
//

import Foundation

/// Compare two user-id strings (or any opaque ids) in a way that
/// tolerates incidental casing/whitespace differences. Two nil/empty
/// values are considered NOT equal — a missing id never matches
/// anything, including another missing id.
@inline(__always)
func userIdsMatch(_ a: String?, _ b: String?) -> Bool {
    guard let a = a?.trimmingCharacters(in: .whitespaces),
          let b = b?.trimmingCharacters(in: .whitespaces),
          !a.isEmpty, !b.isEmpty else {
        return false
    }
    return a.caseInsensitiveCompare(b) == .orderedSame
}

/// Convenience: "is this senderId mine?". Reads the local
/// keychain-saved user id via AuthService and matches in
/// canonical form.
@MainActor
@inline(__always)
func senderIsMe(_ senderId: String?) -> Bool {
    return userIdsMatch(senderId, AuthService.shared.currentUser?.id)
}
