//
//  PendingFriendRequestQueue.swift
//  RAVEN
//
//  Round 24 (2026-05-16).
//
//  When the user scans a QR offline, they expect "the friend was
//  added" — but the server-side `/api/users/friend-request/{id}/send`
//  call needs internet. We can't drop the request; we'd silently lose
//  the friend pairing the user just initiated.
//
//  This queue persists pending friend-request sends in UserDefaults
//  (cheap; the number of pending requests is always small). The
//  `NetworkMonitor.networkStatusChanged` observer flushes the queue
//  the moment connectivity comes back.
//
//  Idempotency: the server side already de-duplicates friend
//  requests per (requester, recipient) pair. A retried send for an
//  already-accepted friend returns a benign 4xx that we treat as
//  success.

import Foundation
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Friend.QRQueue")

actor PendingFriendRequestQueue {
    static let shared = PendingFriendRequestQueue()

    private struct Entry: Codable {
        let recipientId: String
        let attemptedAt: Date
    }

    private let defaultsKey = "raven.friendRequest.pending.v1"
    private let defaults = UserDefaults.standard

    /// Holds the network-status-change observer so the actor's
    /// `flush()` fires when connectivity returns. The observer is
    /// retained for the lifetime of the singleton; no manual
    /// teardown needed because PendingFriendRequestQueue is a
    /// process-singleton.
    private var connectivityObserver: NSObjectProtocol?

    private init() {}

    /// Called once at app launch from `RAVENApp.task { … }` to wire
    /// the network observer. Idempotent.
    nonisolated func startObservingConnectivity() {
        Task { await self._installObserverIfNeeded() }
    }

    private func _installObserverIfNeeded() {
        guard connectivityObserver == nil else { return }
        connectivityObserver = NotificationCenter.default.addObserver(
            forName: .networkStatusChanged,
            object: nil,
            queue: nil
        ) { _ in
            // Drop into the actor's task isolation to flush. We
            // only flush when we've come BACK online — going
            // offline shouldn't trigger a flush attempt.
            Task {
                guard NetworkMonitor.shared.isOnline else { return }
                await PendingFriendRequestQueue.shared.flush()
            }
        }
        logger.notice("connectivity observer installed; queue will flush on next online event")
        // Best-effort: flush right now in case we're already online
        // at install time.
        let onlineNow = NetworkMonitor.shared.isOnline
        Task {
            if onlineNow {
                await self.flush()
            }
        }
    }

    /// Append a recipient. Called from the QR scanner when the
    /// scan succeeds but the network call can't go (offline) or
    /// fails transiently.
    func enqueue(recipientId: String) {
        guard !recipientId.isEmpty else { return }
        var current = loadCurrent()
        // Idempotent — don't queue the same recipient twice.
        guard !current.contains(where: { $0.recipientId == recipientId }) else { return }
        current.append(Entry(recipientId: recipientId, attemptedAt: Date()))
        save(current)
        logger.notice("enqueued offline friend-request for \(recipientId, privacy: .private); queue depth = \(current.count, privacy: .public)")
    }

    /// True iff a pending request for this recipient is waiting.
    func isPending(_ recipientId: String) -> Bool {
        loadCurrent().contains(where: { $0.recipientId == recipientId })
    }

    /// Walk the queue and try to send each entry. On 2xx OR a
    /// "already friends / duplicate" 4xx, the entry is dequeued.
    /// On a connectivity-shaped error, leave the entry for the
    /// next attempt.
    func flush() async {
        let entries = loadCurrent()
        guard !entries.isEmpty else { return }
        logger.notice("flushing \(entries.count, privacy: .public) pending friend-request(s)")

        var remaining: [Entry] = []
        for entry in entries {
            let delivered = await Self.attemptSend(recipientId: entry.recipientId)
            if !delivered {
                remaining.append(entry)
            }
        }
        save(remaining)
        if remaining.isEmpty {
            logger.notice("queue drained")
        } else {
            logger.notice("queue still has \(remaining.count, privacy: .public) item(s) — will retry on next network event")
        }
    }

    // MARK: - Storage

    private func loadCurrent() -> [Entry] {
        guard let raw = defaults.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([Entry].self, from: raw) else {
            return []
        }
        return list
    }

    private func save(_ list: [Entry]) {
        if list.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let raw = try? JSONEncoder().encode(list) {
            defaults.set(raw, forKey: defaultsKey)
        }
    }

    // MARK: - Network

    /// Returns true when the entry is considered DELIVERED (2xx OR
    /// a benign duplicate / already-friend 4xx). Returns false when
    /// the entry should be retried.
    private static func attemptSend(recipientId: String) async -> Bool {
        struct Empty: Encodable {}
        struct EmptyResp: Decodable {}
        do {
            let _: EmptyResp = try await NetworkService.shared.post(
                path: "/api/users/friend-request/\(recipientId)/send",
                body: Empty()
            )
            logger.notice("offline-queued friend-request for \(recipientId, privacy: .private) delivered")
            return true
        } catch let apiErr as APIError {
            switch apiErr {
            case .httpError(let code, _):
                // 409 / 422 / 400 typically mean "already friends"
                // or "request already pending" — treat as delivered.
                if (400..<500).contains(code) {
                    logger.notice("friend-request to \(recipientId, privacy: .private) returned \(code, privacy: .public) — treating as already-delivered.")
                    return true
                }
                return false
            case .unauthorized:
                // Token expired during flush — leave entry, next
                // login will refresh and re-attempt.
                return false
            default:
                return false
            }
        } catch {
            return false
        }
    }
}
