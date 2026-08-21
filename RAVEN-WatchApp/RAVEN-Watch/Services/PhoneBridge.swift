// PhoneBridge.swift
//
// Watch-side counterpart to `ios-native/RAVEN/RAVEN/Core/Mesh/WatchBridgeService.swift`.
// All traffic between this watchOS app and its paired iPhone goes
// through here.
//
// Three WCSession channels in use, each chosen for what it guarantees:
//
//   • `updateApplicationContext(_:)`
//       Latest-state-only snapshot. The phone calls it on every change
//       to chat list / feed / rooms / notifications. We get the freshest
//       version on next wake; older contexts are silently discarded by
//       the OS. Source of truth for everything we render.
//
//   • `sendMessage(_:replyHandler:errorHandler:)`
//       Real-time, both apps reachable. Used for compose → "sent" UI
//       flip so the user gets immediate feedback when both sides are
//       awake. Falls back to `transferUserInfo` if the phone isn't
//       reachable.
//
//   • `transferUserInfo(_:)`
//       Queued, persistent, ordered. Used for user intent that *must*
//       reach the phone eventually — replies, reactions, marked-as-read
//       — even if the user lowered their wrist or the phone is asleep.
//
//   • `transferFile(_:metadata:)`
//       Voice replies. The Watch records to a temp .m4a and ships the
//       file; the phone re-encodes / uploads as a regular voice message.
//
// Apple Watch *cannot* directly join the BLE mesh (CoreBluetooth
// peripheral mode is unavailable to 3rd-party watchOS apps — verified
// Apple Developer Forum thread #89263). The mesh shows up on the Watch
// only via the iPhone's relay. If the user has a Series 4+ cellular
// Watch and the iPhone is genuinely unreachable, the standalone
// `RemoteAPI.swift` fallback kicks in for online sends.

import Foundation
import WatchConnectivity
import CryptoKit

@MainActor
final class PhoneBridge: NSObject, ObservableObject {
    static let shared = PhoneBridge()

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var isCompanionInstalled: Bool = false
    @Published private(set) var lastError: String?

    private let session: WCSession?

    private override init() {
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard let session else { return }
        if session.delegate !== self {
            session.delegate = self
        }
        if session.activationState == .notActivated {
            session.activate()
        }
    }

    // MARK: - Compose (Watch → iPhone)

    /// Send a text reply. Returns true when the phone acknowledged
    /// receipt within the reply window; the UI uses this to flip the
    /// composer to "sent". On false, the message is still queued via
    /// `transferUserInfo` so the phone picks it up when it next wakes.
    @discardableResult
    func sendCompose(recipientId: String, roomId: String?, text: String) async -> Bool {
        let payload: [String: Any] = [
            "kind": "compose-dm",
            "clientMessageId": UUID().uuidString,
            "recipientId": recipientId,
            "roomId": roomId ?? "",
            "text": text,
        ]
        return await deliver(payload)
    }

    /// Toggle a reaction emoji on a message. The phone resolves the
    /// current reaction state and posts the appropriate `add` /
    /// `remove` to the server's reactions endpoint.
    @discardableResult
    func toggleReaction(messageId: String, roomId: String, emoji: String) async -> Bool {
        let payload: [String: Any] = [
            "kind": "react",
            "messageId": messageId,
            "roomId": roomId,
            "emoji": emoji,
        ]
        return await deliver(payload)
    }

    /// Mark a thread as read up to a given timestamp.
    @discardableResult
    func markRead(roomId: String, upTo: Date) async -> Bool {
        let payload: [String: Any] = [
            "kind": "mark-read",
            "roomId": roomId,
            "upTo": upTo.timeIntervalSince1970,
        ]
        return await deliver(payload)
    }

    /// Ship a recorded voice clip. The Watch records locally with
    /// AVAudioRecorder, then hands the file URL here; we attach the
    /// destination chat metadata so the phone knows where to send it.
    ///
    /// 🔴 ROUND 71 phase 3 — seal the voice clip with the shared
    /// WatchAuthKeyStore symmetric key BEFORE handing the file to
    /// WCSession.transferFile. Pre-fix the Watch sent the m4a as
    /// plaintext; iPhone-side WatchBridgeService had a round-70
    /// `decryptSealedVoiceReply` decrypt path that was dead code
    /// because the Watch never marked its envelopes `sealed=v1`.
    /// The plaintext leg meant the audio sat on the iPhone's
    /// `Library/Caches/` briefly + flowed through the cleartext
    /// branch with only a DEBUG warning.
    func sendVoiceReply(fileURL: URL, recipientId: String, roomId: String?) {
        guard let session, session.activationState == .activated else { return }
        let clientMessageId = UUID().uuidString

        Task {
            let sealedURL: URL?
            if let key = await WatchAuthKeyStore.shared.readKey() {
                sealedURL = Self.sealVoiceFile(plaintextURL: fileURL, key: key)
            } else {
                sealedURL = nil
            }

            var meta: [String: Any] = [
                "kind": "voice-reply",
                "recipientId": recipientId,
                "roomId": roomId ?? "",
                "clientMessageId": clientMessageId,
            ]

            let urlToShip: URL
            if let sealedURL {
                meta["sealed"] = "v1"
                urlToShip = sealedURL
            } else {
                // Key not yet provisioned (first install before the
                // iPhone has shipped its first applicationContext) —
                // fall back to plaintext so the user-visible action
                // still works. The iPhone logs a warning and the
                // window is small (resolves on next iPhone activation).
                urlToShip = fileURL
            }

            session.transferFile(urlToShip, metadata: meta)
        }
    }

    /// Encrypt the m4a payload at `plaintextURL` with `key` and write
    /// the AES-GCM combined ciphertext (nonce ‖ ct ‖ tag) to a tmp
    /// file in this Watch app's caches directory. Returns the tmp
    /// URL on success; nil on any failure. Caller is responsible for
    /// removing the file after WCSession completes the transfer
    /// (WCSession copies the file's bytes into its own staging
    /// directory before transferFile() returns, so it's safe to
    /// delete the tmp afterwards).
    private static func sealVoiceFile(plaintextURL: URL, key: SymmetricKey) -> URL? {
        guard let plain = try? Data(contentsOf: plaintextURL, options: .mappedIfSafe) else {
            return nil
        }
        do {
            let sealedBox = try AES.GCM.seal(plain, using: key)
            guard let combined = sealedBox.combined else { return nil }
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).m4a.sealed")
            try combined.write(to: dst, options: [.atomic, .completeFileProtection])
            return dst
        } catch {
            return nil
        }
    }

    /// Watch tells the phone to push a fresh full snapshot. Used on cold
    /// app launch and when the user pulls-to-refresh in the inbox.
    @discardableResult
    func requestSnapshot() async -> Bool {
        let payload: [String: Any] = ["kind": "request-snapshot"]
        return await deliver(payload)
    }

    /// Subscribe / unsubscribe to a specific thread so the phone knows
    /// to push appends and a full message history. Called from the
    /// `ChatView.task` when a thread becomes visible.
    @discardableResult
    func subscribeThread(roomId: String) async -> Bool {
        let payload: [String: Any] = [
            "kind": "subscribe-thread",
            "roomId": roomId,
        ]
        return await deliver(payload)
    }

    // MARK: - Internal delivery

    /// `sendMessage` when reachable (real-time), `transferUserInfo`
    /// otherwise (queued, persistent). The boolean return reflects
    /// real-time delivery only — userInfo always succeeds locally.
    func deliver(_ payload: [String: Any]) async -> Bool {
        guard let session, session.activationState == .activated else { return false }

        if session.isReachable {
            return await withCheckedContinuation { cont in
                session.sendMessage(payload, replyHandler: { _ in
                    cont.resume(returning: true)
                }, errorHandler: { [weak self] error in
                    Task { @MainActor in self?.lastError = error.localizedDescription }
                    session.transferUserInfo(payload)
                    cont.resume(returning: false)
                })
            }
        } else {
            session.transferUserInfo(payload)
            return false
        }
    }
}

// MARK: - WCSessionDelegate

extension PhoneBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = (activationState == .activated && session.isReachable)
        let installed = (activationState == .activated && session.isCompanionAppInstalled)
        Task { @MainActor in
            self.isReachable = reachable
            self.isCompanionInstalled = installed
            if let error {
                self.lastError = error.localizedDescription
            }
            // Ask the phone for a fresh snapshot now that we're up.
            _ = await self.requestSnapshot()
        }
    }

    #if os(iOS)
    // Required by WCSessionDelegate on iOS only (not watchOS). Present so the
    // watch target still satisfies the protocol when its sources are compiled
    // under the iOS SDK (e.g. an embedded-watch build via -sdk iphonesimulator).
    // No-ops; never invoked on watchOS.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable && session.activationState == .activated
        }
    }

    /// Phone called `updateApplicationContext` with a fresh snapshot.
    /// This is the primary state-sync path.
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        // 🔴 ROUND 26 — hacker-audit MESH-HIGH-3.
        //   Intercept the auth-wrap key the iPhone ships down with
        //   `WatchBridgeService.publishAuthWrapKey()`. Cache it
        //   immediately in the Watch Keychain so `RemoteAPI.token`
        //   can decrypt the App Group's `raven.auth.token.enc`
        //   blob on the next call. The rest of the application
        //   context still flows to `WatchStore.applyApplicationContext`.
        if let keyB64 = applicationContext["raven.watch.auth-wrap-key.v1"] as? String,
           let keyData = Data(base64Encoded: keyB64) {
            Task.detached(priority: .utility) {
                _ = await WatchAuthKeyStore.shared.install(keyData)
            }
        }
        Task { @MainActor in
            WatchStore.shared.applyApplicationContext(applicationContext)
        }
    }

    /// Phone sent a real-time message — typically an "incoming-dm"
    /// haptic prompt or a "thread-snapshot" with full message history
    /// for a chat the user just opened.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            WatchStore.shared.applyMessage(message)
        }
    }

    /// Queued payload arrived while we were asleep.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            WatchStore.shared.applyMessage(userInfo)
        }
    }
}
