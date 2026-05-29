//
//  NotificationDedupCache.swift
//  RAVEN
//
//  In-memory dedup window so the same chat message doesn't trigger
//  two simultaneous notifications when it arrives via APNs AND mesh
//  (or via APNs and a redundant locally-scheduled "safety net" copy).
//
//  How it works
//  ────────────
//  Whichever path fires first calls `claim(messageId:)`. That path
//  becomes responsible for showing the notification. Every later
//  path that calls `claim` for the same id within the TTL window
//  receives `false` and silently skips.
//
//  Why an actor + TTL instead of UNNotificationCenter dedup
//  ────────────────────────────────────────────────────────
//  iOS does dedup pending/delivered UNNotificationRequest with the
//  same identifier — but APNs alerts that arrive in the background
//  are shown by iOS *before* our app code runs (no identifier under
//  our control). The cache here lets us at least prevent the second,
//  locally-scheduled copy from also displaying.
//
//  TTL is 60 seconds: long enough that mesh + APNs in close
//  succession dedup, short enough that the cache never grows
//  unbounded across a long-running session.
//

import Foundation

actor NotificationDedupCache {
    static let shared = NotificationDedupCache()

    private var seen: [String: Date] = [:]
    /// Window during which a re-arrival of the same message id is
    /// considered a duplicate.
    private let ttl: TimeInterval = 60

    /// Reserve this message id for the current notification path.
    /// Returns `true` if the caller is the FIRST to claim it (and
    /// therefore should display the notification); `false` if a
    /// previous path already claimed within the TTL window (caller
    /// must skip).
    @discardableResult
    func claim(messageId: String) -> Bool {
        cleanup()
        if seen[messageId] != nil {
            return false
        }
        seen[messageId] = Date()
        return true
    }

    /// True if a recent claim exists for this id. Read-only — does
    /// NOT set the marker. Useful when a path wants to peek without
    /// committing.
    func isClaimed(messageId: String) -> Bool {
        cleanup()
        return seen[messageId] != nil
    }

    /// Drop the marker for a specific id — used when a path
    /// optimistically claimed but then aborted.
    func release(messageId: String) {
        seen.removeValue(forKey: messageId)
    }

    /// Drop entries past the TTL window. Called lazily on every
    /// touch so we never run a timer just to garbage-collect.
    private func cleanup() {
        let cutoff = Date().addingTimeInterval(-ttl)
        seen = seen.filter { $0.value > cutoff }
    }
}
