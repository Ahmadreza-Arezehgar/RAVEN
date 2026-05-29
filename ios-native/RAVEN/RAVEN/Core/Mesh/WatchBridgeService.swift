// WatchBridgeService.swift
//
// iPhone-side adapter that lets a paired Apple Watch participate in
// the RAVEN mesh through WatchConnectivity (`WCSession`).
//
// Why this exists: Apple Watch can't act as a BLE peripheral for
// 3rd-party apps (verified — Apple Developer Forums #89263). The only
// practical way the Watch joins the mesh is by relaying through its
// paired iPhone:
//
//   Watch      ──WCSession──▶  iPhone  ──BLE / MPC / server──▶  Recipient
//
// What this service does:
//
//   Inbound (Watch → iPhone), keyed by the payload's `kind`:
//     • compose-dm          → MessageRouter.send (text reply)
//     • voice-reply         → file transfer arrives via didReceive(file:);
//                             we post `ravenWatchVoiceReplyArrived` and the
//                             media/voice pipeline picks it up.
//     • react               → posts `ravenWatchReact`
//     • post-toggle-like    → posts `ravenWatchPostToggleLike`
//     • post-comment        → posts `ravenWatchPostComment`
//     • mark-read           → posts `ravenWatchMarkRead`
//     • room-membership     → posts `ravenWatchRoomMembership`
//     • room-ptt            → posts `ravenWatchRoomPTT`
//     • subscribe-thread    → posts `ravenWatchSubscribeThread` (the chat
//                             store responds by calling
//                             pushThreadSnapshot below)
//     • request-snapshot    → posts `ravenWatchRequestSnapshot`
//     • open                → posts `ravenWatchOpen` (deep-link)
//
//   Outbound (iPhone → Watch):
//     • pushApplicationContext  → state snapshot (inbox/feed/rooms/notifs)
//     • notifyWatchOfMessage    → incoming-DM haptic
//     • pushThreadSnapshot      → full history for a subscribed thread
//     • pushThreadAppend        → one new message in a subscribed thread
//     • pushPostUpdate          → like/comment counter change
//     • pushDeliveryReceipt     → a mesh-pending send finally landed
//
// Notes:
//   • The "Watch app target doesn't exist yet" comment in v1 is no
//     longer true — see `/Users/ahmd/hybrid_messenger/RAVEN-WatchApp/`.
//     The two sides talk over the API surface defined here.
//   • Cellular Watch (Series 4+) standalone path — when the iPhone is
//     unreachable but the Watch has cellular, the Watch hits the REST
//     API directly. That path bypasses this service.

import Foundation
import WatchConnectivity
import CryptoKit
import os

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "Mesh.WatchBridge")

// MARK: - Notification names

extension Notification.Name {
    /// Watch → iPhone intents. Subscribers are the corresponding domain
    /// services (reactions, posts feed, rooms, chat store).
    static let ravenWatchReact              = Notification.Name("raven.watch.react")
    static let ravenWatchPostToggleLike     = Notification.Name("raven.watch.postToggleLike")
    static let ravenWatchPostComment        = Notification.Name("raven.watch.postComment")
    static let ravenWatchMarkRead           = Notification.Name("raven.watch.markRead")
    static let ravenWatchRoomMembership     = Notification.Name("raven.watch.roomMembership")
    static let ravenWatchRoomPTT            = Notification.Name("raven.watch.roomPTT")
    static let ravenWatchSubscribeThread    = Notification.Name("raven.watch.subscribeThread")
    static let ravenWatchRequestSnapshot    = Notification.Name("raven.watch.requestSnapshot")
    static let ravenWatchOpen               = Notification.Name("raven.watch.open")
    static let ravenWatchVoiceReplyArrived  = Notification.Name("raven.watch.voiceReplyArrived")
}

@MainActor
final class WatchBridgeService: NSObject {
    static let shared = WatchBridgeService()

    /// True when the Watch counterpart is reachable (paired + app
    /// installed + foreground or recently backgrounded). Outbound
    /// `sendMessage` requires this; `updateApplicationContext` and
    /// `transferUserInfo` queue regardless.
    private(set) var isReachable: Bool = false
    private(set) var isCompanionInstalled: Bool = false

    private let session: WCSession?

    private override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    // MARK: - Lifecycle

    /// Activate `WCSession`. Idempotent.
    func start() {
        guard let session else { return }
        if session.delegate !== self {
            session.delegate = self
        }
        if session.activationState == .notActivated {
            session.activate()
        }
    }

    // MARK: - Outbound (iPhone → Watch)

    /// Push the full state snapshot. The Watch overwrites its local
    /// snapshot on every call — WCSession only keeps the most recent
    /// context, so older contexts are silently dropped.
    ///
    /// Callers should rate-limit this to once per ~250ms to avoid
    /// hammering the Watch.
    func pushApplicationContext(_ context: [String: Any]) {
        guard let session = session,
              session.activationState == .activated,
              session.isPaired
        else { return }
        do {
            try session.updateApplicationContext(context)
        } catch {
            logger.debug("[watch] context push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Push an inbound DM preview to the Watch. Called from the chat
    /// ingest path — the Watch shows a haptic + notification.
    func notifyWatchOfMessage(senderName: String, preview: String, messageId: String) {
        let payload: [String: Any] = [
            "kind": "incoming-dm",
            "senderName": senderName,
            "preview": preview,
            "messageId": messageId,
            "timestamp": Date().timeIntervalSince1970,
        ]
        sendOrQueue(payload)
    }

    /// Push a full thread history to the Watch in response to a
    /// `subscribe-thread`. `messages` is an array of the slim
    /// MessagePreview dicts the Watch's WatchModels.swift decodes.
    func pushThreadSnapshot(roomId: String, messages: [[String: Any]]) {
        let payload: [String: Any] = [
            "kind": "thread-snapshot",
            "roomId": roomId,
            "messages": messages,
        ]
        sendOrQueue(payload)
    }

    /// Append a single new message to a subscribed thread.
    func pushThreadAppend(roomId: String, message: [String: Any]) {
        let payload: [String: Any] = [
            "kind": "thread-append",
            "roomId": roomId,
            "message": message,
        ]
        sendOrQueue(payload)
    }

    /// Notify the Watch that a post's counters changed (like, comment).
    func pushPostUpdate(postId: String, likeCount: Int?, commentCount: Int?, likedByMe: Bool?) {
        var payload: [String: Any] = [
            "kind": "post-update",
            "postId": postId,
        ]
        if let likeCount     { payload["likeCount"] = likeCount }
        if let commentCount  { payload["commentCount"] = commentCount }
        if let likedByMe     { payload["likedByMe"] = likedByMe }
        sendOrQueue(payload)
    }

    /// Tell the Watch a previously-mesh-pending message has landed.
    /// Used so the inbox can drop the orange "mesh routing…" badge.
    func pushDeliveryReceipt(messageId: String) {
        sendOrQueue([
            "kind": "delivery-receipt",
            "messageId": messageId,
        ])
    }

    /// 🔴 ROUND 26 — hacker-audit MESH-HIGH-3.
    ///
    /// Ship the per-install auth-token wrap key to the paired Watch.
    /// The Watch caches it in its own Keychain and uses it to decrypt
    /// `raven.auth.token.enc` from the App Group file (see the
    /// matching `WatchAuthKeyStore.swift` on the Watch target).
    ///
    /// Call this on every session activation AND whenever the auth
    /// token rotates (because a fresh install / restore might be
    /// joining the pair). Idempotent — the Watch will overwrite its
    /// cached key with the latest version on every receive.
    ///
    /// Key is sent over WCSession's `updateApplicationContext` so it
    /// (a) survives Watch sleep, (b) is replayed automatically when
    /// the Watch app launches, and (c) only lives inside iOS-managed
    /// transport that's encrypted between paired devices.
    func publishAuthWrapKey() {
        guard let session = session,
              session.activationState == .activated,
              session.isPaired
        else { return }
        Task.detached(priority: .utility) {
            guard let keyBytes = await WatchAuthKeyStore.shared.rawKeyBytes() else {
                return
            }
            let payload: [String: Any] = [
                "raven.watch.auth-wrap-key.v1": keyBytes.base64EncodedString()
            ]
            do {
                try session.updateApplicationContext(payload)
            } catch {
                // Best-effort — the Watch falls back to the legacy
                // plaintext token until the key arrives.
            }
        }
    }

    /// Send-or-queue helper. `sendMessage` if reachable, else
    /// `transferUserInfo` so the payload arrives on next wake.
    private func sendOrQueue(_ payload: [String: Any]) {
        guard let session = session,
              session.activationState == .activated,
              session.isPaired
        else { return }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // Real-time delivery missed the window; fall through
                // to the queued path so the Watch sees it on wake.
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    // MARK: - Inbound (Watch → iPhone)

    /// Dispatch by `kind`. Compose flows through `MessageRouter`
    /// directly (since we already have that wired and tested);
    /// everything else fans out via NotificationCenter so the
    /// corresponding services can subscribe without us needing tight
    /// coupling here.
    private func handleInbound(_ payload: [String: Any]) {
        let kind = (payload["kind"] as? String) ?? "compose-dm"
        switch kind {
        case "compose-dm":
            handleWatchCompose(payload)
        case "react":
            NotificationCenter.default.post(
                name: .ravenWatchReact, object: nil, userInfo: payload
            )
        case "post-toggle-like":
            NotificationCenter.default.post(
                name: .ravenWatchPostToggleLike, object: nil, userInfo: payload
            )
        case "post-comment":
            NotificationCenter.default.post(
                name: .ravenWatchPostComment, object: nil, userInfo: payload
            )
        case "mark-read":
            NotificationCenter.default.post(
                name: .ravenWatchMarkRead, object: nil, userInfo: payload
            )
        case "room-membership":
            NotificationCenter.default.post(
                name: .ravenWatchRoomMembership, object: nil, userInfo: payload
            )
        case "room-ptt":
            NotificationCenter.default.post(
                name: .ravenWatchRoomPTT, object: nil, userInfo: payload
            )
        case "subscribe-thread":
            NotificationCenter.default.post(
                name: .ravenWatchSubscribeThread, object: nil, userInfo: payload
            )
        case "request-snapshot":
            NotificationCenter.default.post(
                name: .ravenWatchRequestSnapshot, object: nil
            )
        case "open":
            NotificationCenter.default.post(
                name: .ravenWatchOpen, object: nil, userInfo: payload
            )
        default:
            logger.debug("[watch] unknown kind=\(kind, privacy: .public)")
        }
    }

    /// The Watch sent us a text compose request. Validate, then hand off
    /// to `MessageRouter` so the same outbox + dual-path send logic runs
    /// as for a phone-side compose. Returns silently on malformed
    /// payloads (the Watch app is the source of truth; we don't crash
    /// on bad input).
    private func handleWatchCompose(_ payload: [String: Any]) {
        guard let recipientId = payload["recipientId"] as? String,
              let text = payload["text"] as? String,
              !text.isEmpty
        else { return }
        let clientMessageId = (payload["clientMessageId"] as? String) ?? UUID().uuidString
        let roomId = payload["roomId"] as? String

        Task {
            do {
                try await MessageRouter.shared.send(
                    to: recipientId,
                    text: text,
                    clientMessageId: clientMessageId,
                    roomId: roomId
                )
                logger.debug("[watch] composed -> \(recipientId, privacy: .private) (mid=\(clientMessageId, privacy: .private))")
            } catch {
                logger.debug("[watch] compose-send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Voice clip arrived from the Watch via `transferFile`. We just
    /// repost the local file URL — the media/voice pipeline owns the
    /// upload + envelope wrapping so we don't reach into that here.
    ///
    /// 🔴 ROUND 70 (2026-05-23) — hacker-audit WATCH-CRIT-1.
    /// PREVIOUSLY the Watch shipped raw `.m4a` plaintext through
    /// `WCSession.transferFile` and this handler reposted the file
    /// URL straight into the voice pipeline. The transit was
    /// Apple-managed-TLS but the bytes landed in the iPhone's
    /// tmp/ as plaintext `.m4a` — a brief forensic-attached
    /// window between landing and upload allowed exfil.
    ///
    /// FIX: if the file is AES-GCM-sealed (Watch wraps with the
    /// shared App-Group wrap key before transferFile, see
    /// `WatchAuthKeyStore.wrappedTransferKey()`), decrypt
    /// in-place to a `.completeFileProtection` tmp file and pass
    /// THAT URL forward instead of the plaintext one. Then unlink
    /// the original WCSession-delivered file immediately. The
    /// `metadata["sealed"] = "v1"` marker tells us whether the
    /// Watch sender opted into the new protected path; legacy
    /// (pre-round-70) Watch senders that ship plaintext still
    /// work but log a warning.
    private func handleVoiceReply(file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let isSealed = (metadata["sealed"] as? String) == "v1"
        let sourceURL = file.fileURL
        let recipientId = metadata["recipientId"] ?? ""
        let roomId = metadata["roomId"] ?? ""
        let clientMessageId = metadata["clientMessageId"] ?? UUID().uuidString

        if isSealed {
            // Async decrypt into a complete-protection tmp file.
            Task { @MainActor in
                let deliveredURL: URL? = await Self.decryptSealedVoiceReply(at: sourceURL)
                if let dst = deliveredURL {
                    let info: [String: Any] = [
                        "fileURL": dst,
                        "recipientId": recipientId,
                        "roomId": roomId,
                        "clientMessageId": clientMessageId,
                    ]
                    NotificationCenter.default.post(
                        name: .ravenWatchVoiceReplyArrived,
                        object: nil,
                        userInfo: info
                    )
                }
            }
            return
        }

        // Legacy plaintext path. Log and pass through.
        #if DEBUG
        print("⚠️ [WatchBridge] received UNSEALED voice reply from Watch — Watch app is pre-round-70 (plaintext on iPhone disk briefly). Update both ends to ship sealed.")
        #endif
        let info: [String: Any] = [
            "fileURL": sourceURL,
            "recipientId": recipientId,
            "roomId": roomId,
            "clientMessageId": clientMessageId,
        ]
        NotificationCenter.default.post(
            name: .ravenWatchVoiceReplyArrived,
            object: nil,
            userInfo: info
        )
    }

    /// 🔴 ROUND 70 — decrypt a Watch-sent sealed voice reply.
    /// Returns the URL of a `.completeFileProtection` tmp file
    /// containing the plaintext m4a, or nil on any failure.
    /// Caller is responsible for unlinking after consumption.
    private static func decryptSealedVoiceReply(at source: URL) async -> URL? {
        guard let cipher = try? Data(contentsOf: source, options: .mappedIfSafe) else {
            #if DEBUG
            print("⚠️ [WatchBridge] could not read sealed voice file")
            #endif
            return nil
        }
        guard let keyData = await WatchAuthKeyStore.shared.rawKeyBytes() else {
            #if DEBUG
            print("⚠️ [WatchBridge] sealed voice reply received but no transfer key available — dropping")
            #endif
            try? FileManager.default.removeItem(at: source)
            return nil
        }
        let key = SymmetricKey(data: keyData)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: cipher)
            let plain = try AES.GCM.open(sealedBox, using: key)
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).m4a")
            try plain.write(to: dst, options: [.atomic, .completeFileProtection])
            try? FileManager.default.removeItem(at: source)
            return dst
        } catch {
            #if DEBUG
            print("⚠️ [WatchBridge] failed to decrypt sealed voice reply: \(error.localizedDescription)")
            #endif
            try? FileManager.default.removeItem(at: source)
            return nil
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchBridgeService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            let reachable = (activationState == .activated && session.isReachable && session.isPaired)
            self.isReachable = reachable
            self.isCompanionInstalled = (activationState == .activated && session.isWatchAppInstalled)
            if let error {
                logger.debug("[watch] activation error: \(error.localizedDescription, privacy: .public)")
            } else {
                let paired = session.isPaired
                let installed = session.isWatchAppInstalled
                logger.debug("[watch] activation state=\(activationState.rawValue, privacy: .public) reachable=\(reachable, privacy: .public) paired=\(paired, privacy: .public) installed=\(installed, privacy: .public)")
                // 🔴 ROUND 26 — hacker-audit MESH-HIGH-3: ship the
                //   per-install auth-wrap key to the paired Watch as
                //   soon as the session is up. Watch caches in its
                //   own Keychain and uses it to decrypt the App
                //   Group token blob.
                if activationState == .activated && paired && installed {
                    self.publishAuthWrapKey()
                }
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // iOS requires us to re-activate after deactivation (typically
        // when the user pairs a new Watch). The delegate fires on a
        // background queue, so the WCSession call is safe to make from
        // the same context.
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable && session.isPaired && session.activationState == .activated
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isCompanionInstalled = session.isWatchAppInstalled && session.activationState == .activated
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.handleInbound(message)
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // Reply variant — Watch wants confirmation. We acknowledge
        // immediately so the Watch UI can flip to "sent"; the actual
        // delivery happens asynchronously through the dispatch path.
        Task { @MainActor in
            self.handleInbound(message)
        }
        replyHandler(["accepted": true])
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            self.handleInbound(userInfo)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Task { @MainActor in
            self.handleVoiceReply(file: file)
        }
    }
}
