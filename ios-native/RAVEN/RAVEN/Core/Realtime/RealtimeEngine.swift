import Foundation
import UIKit

// MARK: - Realtime Engine (Central Hub)
// Primary transport: WebSocket (wss://). Fallback: HTTP polling at 30s.
//
// Marked `@unchecked Sendable` so the polling timer's @Sendable callback can
// hold a weak reference. All state mutations happen via `@MainActor`-tagged
// methods (`startPolling`, `stopPolling`, `poll`), so the thread-safety
// contract is "main only" — the timer fires on the main runloop.
@Observable
class RealtimeEngine: @unchecked Sendable {
    static let shared = RealtimeEngine()
    
    enum ConnectionState: String {
        case disconnected
        case connecting
        case websocket   // WebSocket connected — real-time
        case polling     // Polling fallback — WebSocket unavailable
        case syncing
    }
    
    var connectionState: ConnectionState = .disconnected
    var lastSyncTime: Date?
    
    private var pollingTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var networkStatusObserver: NSObjectProtocol?
    /// Tracks the last seen online state so we only fire a sync on
    /// the actual offline→online transition (not on every probe tick).
    private var wasOnline: Bool = false
    /// Coalesces simultaneous reconnects (NWPath + probe both fire
    /// `networkStatusChanged`) so we don't kick off two parallel
    /// `syncNow()`s within milliseconds of each other.
    private var reconnectSyncInFlight: Bool = false
    private var lastInboxTimestamp: String?
    private var isPollingInFlight = false  // Prevent overlapping polls
    
    // WebSocket
    /// Dedicated session for WebSocket — NOT URLSession.shared.
    /// URLSession.shared may block WebSocket on cellular/constrained networks.
    /// NOTE: Must be static or nonisolated(unsafe) to avoid @Observable
    /// wrapping it with @ObservationTracked (which doesn't support lazy).
    private static let wsSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = true
        return URLSession(
            configuration: RavenRuntimePolicy.protectForXCTest(config),
            delegate: nil,
            delegateQueue: nil
        )
    }()
    private var webSocketTask: URLSessionWebSocketTask?
    private var wsReconnectAttempts = 0
    private let maxWsReconnectAttempts = 10
    private var wsReconnectTimer: Timer?
    private var wsPingTimer: Timer?
    private var isWebSocketConnected = false
    
    // Polling intervals — used ONLY as fallback when WebSocket fails
    private let foregroundInterval: TimeInterval = 30  // 30 seconds (was 10s with polling-only)
    private let backgroundInterval: TimeInterval = 60  // 60 seconds in background
    
    private init() {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        setupLifecycleObservers()
    }
    
    // MARK: - Lifecycle Observers
    
    private func setupLifecycleObservers() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onEnterForeground()
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onEnterBackground()
        }

        // 🟢 ROUND 73 (2026-05-24) — full inbox sync on network restore.
        //
        // USER REPORT: "vaghty ke app be internet vaskl mishe bayad
        // tamam message haro toye hafeze save kone va download kone
        // ke message ha hamishe bashan" — when the app reconnects
        // to internet, it should download and persist all messages
        // so they're always available.
        //
        // BEFORE: sync only fired on app start + foreground.
        // Mid-session offline→online transitions (Wi-Fi handoff,
        // tunnel exit, airplane mode toggle) did NOT trigger a
        // catch-up sync. Anything pushed by the server while we
        // were offline waited until the next periodic 30s poll
        // (or the user backgrounded + foregrounded the app to
        // force one), which felt like "messages are missing".
        //
        // FIX: subscribe to `.networkStatusChanged` and run
        // `syncNow()` exactly once per offline→online edge. The
        // `wasOnline` cache prevents re-firing on every server-
        // probe tick (which also posts the notification when
        // `serverReachable` flips). The `reconnectSyncInFlight`
        // gate coalesces races between NWPath and probe.
        networkStatusObserver = NotificationCenter.default.addObserver(
            forName: .networkStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onNetworkStatusChanged()
        }
        // Prime the wasOnline cache so the FIRST observation doesn't
        // count as an offline→online edge (we sync on start() anyway).
        wasOnline = NetworkMonitor.shared.isOnline
    }

    /// Called whenever NetworkMonitor posts `.networkStatusChanged`
    /// (NWPath transition OR backend-probe success/failure flip).
    /// Fires `syncNow()` only on the actual offline→online edge.
    private func onNetworkStatusChanged() {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        let nowOnline = NetworkMonitor.shared.isOnline
        let prevOnline = wasOnline
        wasOnline = nowOnline

        // Only act on the offline→online transition. The other
        // observers (OutboxManager, GroupService, etc.) handle the
        // online→offline edge separately.
        guard nowOnline, !prevOnline else { return }

        // Guard against duplicate sync kickoffs from coalesced
        // notifications (NWPath fires once, the first probe success
        // can fire again ~immediately).
        guard !reconnectSyncInFlight else {
            #if DEBUG
            print("🔁 [RealtimeEngine] Network restored — sync already in flight; coalescing")
            #endif
            return
        }
        reconnectSyncInFlight = true

        #if DEBUG
        print("🌐 [RealtimeEngine] Network RESTORED — triggering full sync")
        #endif

        // Don't sync if not fully authenticated — same readiness check
        // that `onEnterForeground` uses.
        let auth = AuthService.shared
        let isReady = MainActor.assumeIsolated {
            auth.isAuthenticated &&
            (auth.isEmailVerified || auth.currentUser?.authMethod != .password) &&
            auth.currentUser?.username != nil
        }
        guard isReady else {
            #if DEBUG
            print("⚠️ [RealtimeEngine] Network restored but user not fully verified — skipping sync")
            #endif
            reconnectSyncInFlight = false
            return
        }

        // Reconnect WebSocket immediately so push channel is live
        // alongside the catch-up sync.
        Task { @MainActor in
            connectWebSocketOrPoll()
        }

        // Heavy sync on a background task so the main thread stays
        // responsive. `syncNow()` already does the right thing:
        //   1. ConversationStore.fetchConversations(forceFull:false)
        //   2. pollInbox() — incremental fetch with `since=` cursor
        //   3. NotificationsService.pollNotifications()
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.syncNow()
            await MainActor.run { self?.reconnectSyncInFlight = false }
        }
    }
    
    private func onEnterForeground() {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        #if DEBUG
        print("[RealtimeEngine] Entering foreground")
        #endif
        CrashGuard.shared.log(.network, "RealtimeEngine: entering foreground")

        // Don't sync if not fully authenticated.
        // `setupLifecycleObservers` registers this with `queue: .main`,
        // so the closure is guaranteed to fire on the main thread —
        // `assumeIsolated` lets the compiler honour the AuthService
        // MainActor isolation without forcing an `async` rewrite.
        let auth = AuthService.shared
        let isReady = MainActor.assumeIsolated {
            auth.isAuthenticated &&
            (auth.isEmailVerified || auth.currentUser?.authMethod != .password) &&
            auth.currentUser?.username != nil
        }
        guard isReady else {
            #if DEBUG
            print("⚠️ [RealtimeEngine] Skipping foreground sync - user not fully verified")
            #endif
            return
        }
        
        // 🟢 Connect WebSocket first (lightweight) so it isn't queued behind heavy sync
        Task { @MainActor in
            connectWebSocketOrPoll()
        }
        
        // 🟢 Sync in background so it doesn't block the feed or socket
        Task.detached(priority: .background) { [weak self] in
            await self?.syncNow()
        }
    }
    
    private func onEnterBackground() {
        #if DEBUG
        print("[RealtimeEngine] Entering background")
        #endif
        CrashGuard.shared.log(.network, "RealtimeEngine: entering background — disconnecting WS")
        
        // Disconnect WebSocket in background (iOS will kill it anyway)
        disconnectWebSocket()
        
        Task { @MainActor in
            stopPolling()
        }
    }
    
    // MARK: - Start/Stop
    
    func start() {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        guard connectionState == .disconnected else { return }

        let auth = AuthService.shared
        // AuthService is MainActor-isolated; `start()` is invoked from
        // the auth bootstrap path on main — assumeIsolated to avoid an
        // async cascade through every caller of start().
        guard MainActor.assumeIsolated({ auth.isAuthenticated }) else { return }
        
        connectionState = .connecting
        _ = OutboxManager.shared
        
        // 🚀 تسک اول: لود کردن دیتابیس در بکگراند
        let dbTask = Task {
            try? await DatabaseService.shared.initialize()
            await ConversationStore.shared.loadFromDB()
        }
        
        // 🚀 تسک دوم: اتصال فوری به وب‌سوکت (همزمان با لود دیتابیس)
        Task { @MainActor in
            guard auth.isEmailVerified || auth.currentUser?.authMethod != .password,
                  auth.currentUser?.username != nil else {
                connectionState = .polling
                return
            }
            
            // بلافاصله و بدون چک کردن isOnline استارت می‌زنیم
            // تا باگ سیستم عامل iOS در تاخیر تشخیص نتورک را دور بزنیم
            connectWebSocketOrPoll()
            
            // برای سینک کردن سنگین، منتظر می‌مانیم تا دیتابیس کاملا لود شود
            _ = await dbTask.result
            
            if NetworkMonitor.shared.isOnline {
                Task.detached(priority: .background) { [weak self] in
                    await self?.syncNow()
                }
            }
        }
    }
    
    func stop() {
        #if DEBUG
        print("[RealtimeEngine] Stopping...")
        #endif
        disconnectWebSocket()
        Task { @MainActor in
            stopPolling()
        }
        connectionState = .disconnected
    }
    
    // MARK: - WebSocket Transport
    
    /// Attempt WebSocket connection. Falls back to polling if it fails.
    @MainActor
    private func connectWebSocketOrPoll() {
        // Try WebSocket first
        connectWebSocket()
        
        // Also start polling as a safety net (it'll be stopped if WS connects)
        startPolling(interval: foregroundInterval)
    }
    
    private func connectWebSocket() {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        disconnectWebSocket()
        
        Task {
            guard var components = URLComponents(string: AppConfig.apiBaseURL) else {
                #if DEBUG
                print("⚠️ [RealtimeEngine] No base URL for WebSocket")
                #endif
                return
            }
            
            // Build WebSocket URL: wss://server/ws/inbox
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            components.path = "/ws/inbox"
            
            // Add auth token as query parameter
            if let tokenInfo = await KeychainService.shared.getToken() {
                components.queryItems = [URLQueryItem(name: "token", value: tokenInfo.token)]
            }
            
            guard let wsURL = components.url else {
                #if DEBUG
                print("⚠️ [RealtimeEngine] Failed to construct WebSocket URL")
                #endif
                return
            }
            
            #if DEBUG
            print("[RealtimeEngine] 🔌 Connecting WebSocket to \(wsURL.host ?? "unknown")...")
            #endif
            CrashGuard.shared.log(.network, "WS connecting", metadata: ["host": wsURL.host ?? "unknown"])
            
            // 🟢 Use dedicated session with cellular flags (NOT URLSession.shared which fails on cellular)
            guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
            self.webSocketTask = Self.wsSession.webSocketTask(with: wsURL)
            RavenTestExternalSideEffectAudit.recordActual(.webSocket)
            self.webSocketTask?.resume()

            // BUG FIX (2026-05-14, supersedes 2026-05-10): the previous
            // fix reset `wsReconnectAttempts` straight after `.resume()`
            // — but `.resume()` is asynchronous and returns BEFORE the
            // WS handshake actually succeeds. If the handshake then
            // failed (server 401, immediate POSIX 57, etc.) we'd enter
            // the disconnect path with the counter at 0 and reconnect
            // 2 seconds later. Repeat → infinite 2-second reconnect
            // loop that never trips `maxWsReconnectAttempts`. Worse,
            // every loop slammed the server with a fresh handshake.
            //
            // The fix: do NOT reset here. The counter is now reset
            // ONLY when a payload actually arrives (see
            // `processWebSocketData`, ~line 383) AND in the first
            // sendPing success below — both are real proof the
            // handshake completed end-to-end. The "stuck on payload
            // decode" worry from the original comment is covered by
            // the ping-success reset, which happens within ~30 s of
            // a real handshake regardless of message traffic.

            // Start receiving messages
            self.receiveWebSocketMessage()

            // Start ping/pong heartbeat to detect silent connection drops
            // (Cloud Run and similar LBs drop idle TCP after ~10-15 min)
            self.startPingTimer()

            // Immediate one-shot ping to confirm handshake succeeded.
            // On success → reset reconnect counter (real proof the WS
            // is alive). On failure → handleWebSocketDisconnect runs
            // through the ping timer's own failure path.
            self.webSocketTask?.sendPing { [weak self] error in
                guard let self = self, error == nil else { return }
                Task { @MainActor in
                    self.wsReconnectAttempts = 0
                    #if DEBUG
                    print("[RealtimeEngine] ✅ WS handshake confirmed (initial ping ack) — backoff reset")
                    #endif
                }
            }
        }
    }
    
    /// Sends a ping every 30 seconds to keep the WebSocket alive and detect half-open connections.
    /// Must schedule on main RunLoop — Swift Concurrency threads have no active RunLoop,
    /// so Timer.scheduledTimer silently never fires on them.
    private func startPingTimer() {
        wsPingTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.wsPingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // BUG FIX (2026-05-10): capture the current
                // webSocketTask into a local *before* sending the ping,
                // and confirm it's still the active task in the ping
                // completion handler before triggering disconnect
                // handling. The previous version read `self.webSocketTask`
                // at ping-fire time, then read it again in the
                // completion handler — `disconnectWebSocket` running on
                // main between those reads would nil the property and
                // the ping completion (URLSession background queue)
                // would call `handleWebSocketDisconnect` AGAIN, spawning
                // a parallel reconnect timer alongside the one
                // `disconnectWebSocket` already kicked. Identity check
                // mirrors the pattern in `receiveWebSocketMessage`
                // (line ~277).
                guard let task = self.webSocketTask else { return }
                task.sendPing { [weak self] error in
                    if let error = error {
                        #if DEBUG
                        print("❌ [RealtimeEngine] WebSocket ping failed: \(error.localizedDescription)")
                        #endif
                        // Only act if WE are still the live task. If
                        // disconnectWebSocket already ran, it's already
                        // handling reconnect — don't double-trigger.
                        guard let self = self,
                              self.webSocketTask === task else { return }
                        self.handleWebSocketDisconnect()
                    }
                }
            }
        }
    }
    
    private func receiveWebSocketMessage() {
        guard let currentTask = webSocketTask else { return }
        currentTask.receive { [weak self] result in
            guard let self = self else { return }
            
            // Fix: Ignore errors from cancelled/stale sockets
            guard self.webSocketTask === currentTask else { return }
            
            switch result {
            case .success(let message):
                self.handleWebSocketMessage(message)
                // Continue listening
                self.receiveWebSocketMessage()
                
            case .failure(let error):
                let nsError = error as NSError
                let isTimeout = nsError.domain == NSURLErrorDomain && (nsError.code == NSURLErrorTimedOut || nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorNotConnectedToInternet)
                let isNotConnected = nsError.domain == NSPOSIXErrorDomain && nsError.code == 57
                
                // Suppress noisy timeout/disconnect errors that happen during background transitions
                if isTimeout || isNotConnected || nsError.code == -1001 {
                    #if DEBUG
                    print("⚠️ [RealtimeEngine] WebSocket closed (\(isNotConnected ? "not connected" : "timeout")) — will reconnect when active")
                    #endif
                } else {
                    CrashGuard.shared.log(.network, "WS receive error", metadata: [
                        "domain": nsError.domain,
                        "code": "\(nsError.code)",
                        "desc": error.localizedDescription
                    ])
                    #if DEBUG
                    print("❌ [RealtimeEngine] WebSocket receive error: \(error.localizedDescription)")
                    #endif
                }
                self.handleWebSocketDisconnect()
            }
        }
    }
    
    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }
            processWebSocketData(data)

        case .data(let data):
            processWebSocketData(data)

        @unknown default:
            break
        }
    }
    
    private func processWebSocketData(_ data: Data) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            // Custom strategy: handle both "2026-02-15T12:34:56Z" and "2026-02-15T12:34:56.789Z"
            // Swift's built-in .iso8601 does NOT parse fractional seconds.
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)
                
                // Try with fractional seconds first (most common from servers)
                if let date = PerformanceConstants.iso8601Fractional.date(from: dateString) { return date }
                
                // Fallback: standard ISO8601 without fractional seconds
                if let date = PerformanceConstants.iso8601.date(from: dateString) { return date }
                
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot parse date: \(dateString)")
            }
            // ✅ Bug 6 fix: Decode each message individually so one corrupted entry
            // doesn't block the entire batch. Without this, a bad message causes an
            // infinite retry loop (lastInboxTimestamp never advances).
            let safeMessages = try decoder.decode([SafeDecodable<ChatMessage>].self, from: data)
            let messages = safeMessages.compactMap(\.value)
            
            #if DEBUG
            let dropped = safeMessages.count - messages.count
            if dropped > 0 {
                print("⚠️ [RealtimeEngine] Dropped \(dropped)/\(safeMessages.count) malformed messages")
            }
            #endif
            
            if !messages.isEmpty {
                // Mark as connected via WebSocket
                if !isWebSocketConnected {
                    isWebSocketConnected = true
                    wsReconnectAttempts = 0
                    Task { @MainActor in
                        self.connectionState = .websocket
                        self.stopPolling()  // No need for polling when WebSocket is live
                        CrashGuard.shared.log(.network, "WS connected — polling stopped")
                        #if DEBUG
                        print("[RealtimeEngine] ✅ WebSocket connected — polling stopped")
                        #endif
                        // Drain any bridge envelopes the server queued for us
                        // while we were offline. The Mac native edition does
                        // the same on connect; iOS used to skip this step,
                        // which is why bridged messages never appeared even
                        // after the upload chain was fixed.
                        Task { await MeshBridgeReceiver.shared.drainPendingBridges() }
                    }
                }
                
                Task {
                    await ConversationStore.shared.handleIncomingMessages(messages)
                    // Update timestamp for incremental polling fallback.
                    // Use MAX timestamp (not `.first`) — see fix in `pollInbox`.
                    if let latest = messages.map(\.timestamp).max() {
                        self.lastInboxTimestamp = PerformanceConstants.iso8601.string(from: latest)
                    }
                }
            }
        } catch {
            // Try to decode as a WebSocket event (e.g. message_seen)
            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)
                    if let date = PerformanceConstants.iso8601Fractional.date(from: dateString) { return date }
                    if let date = PerformanceConstants.iso8601.date(from: dateString) { return date }
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot parse date: \(dateString)")
                }
                
                // (Audio-room realtime events removed in the messenger pivot.)

                // Chat sidecar events (fan out via NotificationCenter so
                // the open ChatView / MessageStore / reaction store can
                // react without each one parsing the WS frame). All three
                // share the same /ws/inbox channel.
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let typeStr = json["type"] as? String {
                    switch typeStr {
                    case "message_edited":
                        // 🔴 ROUND 19 — hacker-audit Server F3 / Bridge F5.
                        // The WS-pushed edit used to deliver
                        // attacker-controlled `content` straight into
                        // the bubble. We now hop to a Task that
                        // unseals the envelope before posting the
                        // NotificationCenter event the chat surface
                        // consumes. If the server's WS payload
                        // doesn't carry a `sender_id`, the unseal
                        // returns nil for sealed envelopes (no key
                        // resolvable) and we fall back to the raw
                        // content marker — the per-bubble badge will
                        // surface "sealedButFailed" so the user sees
                        // the suspicious render.
                        let messageId = json["message_id"] as? String ?? ""
                        let rawContent = json["content"] as? String ?? ""
                        let senderId = json["sender_id"] as? String
                        // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) —
                        // Swift 6 strict-concurrency: `let` capture
                        // instead of `var` so the cross-actor Task
                        // doesn't trip the "captured var in
                        // concurrently-executing code" diagnostic.
                        // Compute the optional once via a closure
                        // (`PerformanceConstants.iso8601*` are
                        // thread-safe) so the resulting value is
                        // immutable across the capture boundary.
                        let editedAt: Date? = {
                            guard let ts = json["edited_at"] as? String else { return nil }
                            return PerformanceConstants.iso8601Fractional.date(from: ts)
                                ?? PerformanceConstants.iso8601.date(from: ts)
                        }()
                        Task {
                            // 🔴 ROUND 71 phase 3 follow-up — compute
                            // `unsealedText` as a `let` so the Task
                            // body holds no mutable captured state.
                            let unsealedText: String
                            if rawContent.isEmpty {
                                unsealedText = rawContent
                            } else if let unsealed = await MessageContentSealer.unseal(
                                encoded: rawContent,
                                senderUserId: senderId,
                                senderAgreementPubKey: nil,
                                msgId: messageId
                            ) {
                                unsealedText = unsealed.plaintext
                                switch unsealed.reason {
                                case .noiseTransport, .atsamHybrid:
                                    await MessageEncryptionStatusStore.shared
                                        .record(.sealed, for: messageId)
                                case .explicitPlaintext:
                                    await MessageEncryptionStatusStore.shared
                                        .record(.plaintextExplicit, for: messageId)
                                case .legacy:
                                    await MessageEncryptionStatusStore.shared
                                        .record(.plaintextLegacy, for: messageId)
                                case .decryptFailed:
                                    await MessageEncryptionStatusStore.shared
                                        .record(.sealedButFailed, for: messageId)
                                case .noSenderKey:
                                    break
                                }
                            } else {
                                // nil = garbage / unparseable.
                                unsealedText = ""
                                await MessageEncryptionStatusStore.shared
                                    .record(.sealedButFailed, for: messageId)
                            }
                            await MainActor.run {
                                var info: [String: Any] = [:]
                                info["messageId"] = messageId
                                info["content"] = unsealedText
                                if let editedAt = editedAt { info["editedAt"] = editedAt }
                                NotificationCenter.default.post(
                                    name: Notification.Name("MessageEditedRemote"),
                                    object: nil,
                                    userInfo: info
                                )
                            }
                        }
                        return

                    case "message_reaction":
                        Task { @MainActor in
                            NotificationCenter.default.post(
                                name: Notification.Name("MessageReactionUpdated"),
                                object: nil,
                                userInfo: [
                                    "messageId": json["message_id"] as? String ?? "",
                                    "reactions": json["reactions"] as? [[String: Any]] ?? [],
                                ]
                            )
                        }
                        return

                    case "typing":
                        Task { @MainActor in
                            NotificationCenter.default.post(
                                name: Notification.Name("ChatTypingUpdated"),
                                object: nil,
                                userInfo: [
                                    "roomId": json["room_id"] as? String ?? "",
                                    "byUserId": json["by_user_id"] as? String ?? "",
                                    "byUsername": json["by_username"] as? String ?? "",
                                    "isTyping": json["is_typing"] as? Bool ?? false,
                                    "isGroup": json["is_group"] as? Bool ?? false,
                                ]
                            )
                        }
                        return

                    case "message_pinned":
                        Task { @MainActor in
                            var info: [String: Any] = [:]
                            info["messageId"] = json["message_id"] as? String ?? ""
                            info["isGroup"] = json["is_group"] as? Bool ?? false
                            info["pinned"] = json["pinned"] as? Bool ?? false
                            info["pinnedByUserId"] = json["pinned_by_user_id"] as? String ?? ""
                            if let ts = json["pinned_at"] as? String,
                               let date = PerformanceConstants.iso8601Fractional.date(from: ts)
                                    ?? PerformanceConstants.iso8601.date(from: ts) {
                                info["pinnedAt"] = date
                            }
                            NotificationCenter.default.post(
                                name: Notification.Name("MessagePinnedUpdated"),
                                object: nil,
                                userInfo: info
                            )
                        }
                        return

                    case "bridge_envelope", "bridge.envelope":
                        // Server pushes a bridge envelope inline (the
                        // 1:1 fan-out from `/api/mesh/bridge-envelope`).
                        // Hand to MeshBridgeReceiver, which dedups and
                        // runs the local decrypt + verify.
                        if let envB64 = json["envelope_b64"] as? String,
                           let key = json["idempotency_key"] as? String {
                            Task { @MainActor in
                                await MeshBridgeReceiver.shared.ingest(
                                    envelopeB64: envB64,
                                    idempotencyKey: key,
                                    bridgedAt: Date()
                                )
                            }
                        }
                        return

                    case "added_to_group":
                        // 🟦 ROUND 47 (2026-05-17) — server-pushed group
                        // lifecycle event. Materialize the group locally
                        // AND re-broadcast it over mesh so BLE-only
                        // neighbours can also see the new group.
                        //
                        // Payload shape (set by server/routers/groups.py
                        // POST handler):
                        //   {
                        //     "type": "added_to_group",
                        //     "group_id": "...",
                        //     "group_name": "...",
                        //     "added_by": "...",
                        //     "added_by_id": "...",
                        //     "group": {
                        //       "id", "name", "avatar_url", "description",
                        //       "created_by", "creator_username",
                        //       "created_at", "member_count",
                        //       "members": [{user_id, username, ...}]
                        //     }
                        //   }
                        Task {
                            await Self.handleAddedToGroupWS(json: json)
                        }
                        return

                    default:
                        break
                    }
                }

                let event = try decoder.decode(MessageSeenEvent.self, from: data)
                if event.type == "message_seen" {
                    Task {
                        try? await ReadReceiptRepository.shared.markSeen(
                            messageId: event.messageId,
                            userId: event.seenByUserId,
                            username: event.seenByUsername,
                            avatarUrl: event.seenByAvatarUrl,
                            seenAt: event.seenAt
                        )
                        // Notify UI to refresh seen-by data
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: NSNotification.Name("MessageSeenUpdated"),
                                object: nil,
                                userInfo: ["messageId": event.messageId, "chatId": event.chatId]
                            )
                        }
                        #if DEBUG
                        print("👁 [RealtimeEngine] Seen event: \(event.seenByUsername) saw \(event.messageId.prefix(8))")
                        #endif
                    }
                }
            } catch {
                // Could be a ping/pong, control frame, or different message format
                #if DEBUG
                print("[RealtimeEngine] WebSocket non-message data: \(String(data: data, encoding: .utf8) ?? "binary")")
                #endif
            }
        }
    }
    
    private func handleWebSocketDisconnect() {
        guard webSocketTask != nil else { return } // Prevent double-execution

        isWebSocketConnected = false
        webSocketTask = nil

        // BUG FIX (2026-05-14): only log to CrashGuard on noteworthy
        // disconnects, not every single one. The previous version
        // wrote a CrashGuard entry on EVERY drop — with the broken
        // reconnect-counter (Bug 1) producing an infinite 2-second
        // reconnect loop, this saturated iOS's os_log buffer and
        // produced the "Logging Error: Failed to receive N log
        // messages" diagnostic. Log on the first attempt (so we have
        // a breadcrumb) and on the final attempt (so the polling
        // fallback is recorded), but stay quiet for the middle
        // attempts which are routine retry traffic.
        let attempt = wsReconnectAttempts
        if attempt == 0 || attempt >= maxWsReconnectAttempts - 1 {
            CrashGuard.shared.log(.network, "WS disconnected", metadata: [
                "reconnectAttempt": "\(attempt)"
            ])
        }

        // ⚡ FIX: All UI state checks moved into a single @MainActor task.
        // Previously used DispatchQueue.main.sync which deadlocks when called
        // from URLSessionWebSocketTask's background thread (0x8badf00d crash).
        Task { @MainActor in
            if self.connectionState == .websocket {
                self.connectionState = .polling
            }

            // Don't attempt reconnect if app is in background — iOS will throttle and timeout
            guard UIApplication.shared.applicationState == .active else {
                #if DEBUG
                print("⚠️ [RealtimeEngine] App is backgrounded — skipping WebSocket reconnect")
                #endif
                self.startPolling(interval: self.foregroundInterval)
                return
            }

            // Reconnect with exponential backoff
            guard self.wsReconnectAttempts < self.maxWsReconnectAttempts else {
                #if DEBUG
                print("⚠️ [RealtimeEngine] Max WebSocket reconnect attempts reached — staying on polling")
                #endif
                self.startPolling(interval: self.foregroundInterval)
                return
            }
            
            self.wsReconnectAttempts += 1
            // Cap the shift count so `1 << n` can't UB on `n >= 63`.
            // 2^5 = 32s already exceeds the 30s ceiling below.
            let safeShift = min(self.wsReconnectAttempts, 5)
            let delay = min(Double(1 << safeShift), 30)  // 2s, 4s, 8s... max 30s
            #if DEBUG
            print("[RealtimeEngine] 🔄 WebSocket reconnect attempt \(self.wsReconnectAttempts) in \(delay)s")
            #endif
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self,
                      UIApplication.shared.applicationState == .active,
                      self.connectionState != .disconnected else { return }
                self.connectWebSocket()
            }
            
            // Ensure polling is running as fallback during reconnection
            if self.pollingTimer == nil {
                self.startPolling(interval: self.foregroundInterval)
            }
        }
    }
    
    private func disconnectWebSocket() {
        wsPingTimer?.invalidate()
        wsPingTimer = nil
        wsReconnectTimer?.invalidate()
        wsReconnectTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isWebSocketConnected = false
    }
    
    // MARK: - Polling (Fallback)
    
    @MainActor
    private func startPolling(interval: TimeInterval) {
        stopPolling()
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                await self?.poll()
            }
        }
        
        #if DEBUG
        print("[RealtimeEngine] Started polling every \(interval)s (fallback)")
        #endif
    }
    
    @MainActor
    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    private func poll() async {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        guard connectionState == .polling || connectionState == .websocket else { return }
        
        // Skip polling when WebSocket is live
        guard !isWebSocketConnected else { return }
        
        // Skip polling when offline
        guard NetworkMonitor.shared.isOnline else {
            return  // offline
        }
        
        // Poll inbox (incremental)
        await pollInbox()
        
        // Poll notifications (friend requests, etc.)
        await NotificationsService.shared.pollNotifications()
    }
    
    // MARK: - Sync Now (Force refresh)
    
    func syncNow() async {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        #if DEBUG
        print("[RealtimeEngine] Syncing now...")
        #endif
        connectionState = .syncing
        
        // Full conversations refresh
        await ConversationStore.shared.fetchConversations(forceFull: false)
        
        // Poll inbox for new messages
        await pollInbox()
        
        // Poll notifications (friend requests, etc.)
        await NotificationsService.shared.pollNotifications()
        
        lastSyncTime = Date()
        connectionState = isWebSocketConnected ? .websocket : .polling
    }
    
    // Rate-limit backoff: skip polls until this date
    private var rateLimitBackoffUntil: Date?
    
    private func pollInbox() async {
        // Prevent concurrent polls from stacking up
        guard !isPollingInFlight else {
            return  // already polling
        }
        
        // Respect rate-limit backoff
        if let backoff = rateLimitBackoffUntil, Date() < backoff {
            return  // still in backoff window
        }
        rateLimitBackoffUntil = nil
        
        isPollingInFlight = true
        defer { isPollingInFlight = false }
        
        do {
            var queryItems: [URLQueryItem] = []
            
            if let since = lastInboxTimestamp {
                queryItems.append(URLQueryItem(name: "since", value: since))
            }
            
            // API returns array directly, not wrapped in a response object
            let messages: [ChatMessage] = try await NetworkService.shared.get(
                path: "/api/messages/inbox",
                queryItems: queryItems.isEmpty ? nil : queryItems
            )
            
            // BUG FIX (2026-05-10): use the genuine MAX timestamp, not
            // `messages.first`. The previous code assumed the server
            // returned newest-first; if the server ever returned
            // oldest-first or paginated mid-window, the cursor either
            // re-fetched the same page indefinitely OR silently skipped
            // messages between page boundary and now. `max(by:)` is
            // order-independent.
            if let latest = messages.map(\.timestamp).max() {
                lastInboxTimestamp = PerformanceConstants.iso8601.string(from: latest)
            }
            
            // 🔴 ROUND 19 — hacker-audit Server F3 CRITICAL.
            // 🔴 ROUND 21 — hacker-audit Bridge F1 follow-up.
            //
            // Two layers of receive-side decrypt:
            //   1. If `groupKeyVersion` is set, the body is the
            //      AES-GCM ciphertext that the bridge node refused
            //      to decrypt (round 21 fix). We run it through
            //      `GroupKeyService.decrypt` using the version
            //      index the server pass-through preserved.
            //   2. Otherwise (1:1 path, or legacy bridges), we run
            //      it through `MessageContentSealer.unseal`.
            //
            // Either way, garbage payloads land as empty + tagged
            // `sealedButFailed` so the bubble surfaces the warning
            // instead of rendering attacker bytes.
            var unsealedMessages: [ChatMessage] = []
            unsealedMessages.reserveCapacity(messages.count)
            for var m in messages {
                if let wire = m.text, !wire.isEmpty {
                    if let version = m.groupKeyVersion,
                       let roomId = m.roomId, !roomId.isEmpty {
                        // Group ciphertext path (Bridge F1).
                        if let plain = await GroupKeyService.shared.decrypt(
                            wire, groupId: roomId, version: version
                        ) {
                            m.text = plain
                            await MessageEncryptionStatusStore.shared
                                .record(.sealed, for: m.id)
                        } else {
                            // 🔒 Decrypt failed — substitute the SAME
                            // placeholder every other receive path uses
                            // (ConversationStore.handleIncomingMessages,
                            // MessageStore, RAVENApp group path) instead
                            // of an empty body that renders a blank
                            // bubble. handleIncomingMessages' own
                            // placeholder logic is gated behind a
                            // `!wire.isEmpty` check, so an empty string
                            // here would slip through unsubstituted.
                            m.text = "🔒 [Encrypted message — could not decrypt]"
                            await MessageEncryptionStatusStore.shared
                                .record(.sealedButFailed, for: m.id)
                        }
                    } else if let result = await MessageContentSealer.unseal(
                        encoded: wire,
                        senderUserId: m.senderId,
                        senderAgreementPubKey: nil,
                        msgId: m.id
                    ) {
                        m.text = result.plaintext
                        switch result.reason {
                        case .noiseTransport, .atsamHybrid:
                            await MessageEncryptionStatusStore.shared
                                .record(.sealed, for: m.id)
                        case .explicitPlaintext:
                            await MessageEncryptionStatusStore.shared
                                .record(.plaintextExplicit, for: m.id)
                        case .legacy:
                            await MessageEncryptionStatusStore.shared
                                .record(.plaintextLegacy, for: m.id)
                        case .decryptFailed:
                            // `result.plaintext` is "" on a decrypt
                            // failure — substitute the canonical
                            // placeholder so the bubble isn't blank.
                            m.text = "🔒 [Encrypted message — could not decrypt]"
                            await MessageEncryptionStatusStore.shared
                                .record(.sealedButFailed, for: m.id)
                        case .noSenderKey:
                            // Sealed body but no key resolvable — also
                            // "" plaintext. Same placeholder so we never
                            // render an empty bubble.
                            m.text = "🔒 [Encrypted message — could not decrypt]"
                        }
                    } else {
                        // Server returned garbage / non-Base64.
                        // Don't render attacker bytes — show the same
                        // placeholder the rest of the receive paths use
                        // rather than an empty body.
                        m.text = "🔒 [Encrypted message — could not decrypt]"
                        await MessageEncryptionStatusStore.shared
                            .record(.sealedButFailed, for: m.id)
                    }
                }
                unsealedMessages.append(m)
            }

            // Handle new messages
            if !unsealedMessages.isEmpty {
                await ConversationStore.shared.handleIncomingMessages(unsealedMessages)
            }
            
        } catch let apiError as APIError {
            switch apiError {
            case .rateLimited(let retryAfter):
                // Back off for the server-specified duration (or 60s default)
                let delay = TimeInterval(retryAfter ?? 60)
                rateLimitBackoffUntil = Date().addingTimeInterval(delay)
                #if DEBUG
                print("⏳ [RealtimeEngine] Poll inbox rate-limited — backing off \(Int(delay))s")
                #endif
            default:
                #if DEBUG
                print("❌ [RealtimeEngine] Poll inbox failed: \(apiError)")
                #endif
            }
        } catch let decodingError as DecodingError {
            #if DEBUG
            print("❌ [RealtimeEngine] DECODE ERROR:")
            #endif
            switch decodingError {
            case .keyNotFound(let key, let context):
                #if DEBUG
                print("   Key not found: '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue })")
                #endif
            case .typeMismatch(let type, let context):
                #if DEBUG
                print("   Type mismatch: expected \(type) at path: \(context.codingPath.map { $0.stringValue })")
                #endif
            case .valueNotFound(let type, let context):
                #if DEBUG
                print("   Value not found: \(type) at path: \(context.codingPath.map { $0.stringValue })")
                #endif
            case .dataCorrupted(let context):
                #if DEBUG
                print("   Data corrupted: \(context.debugDescription)")
                #endif
            @unknown default:
                #if DEBUG
                print("   Unknown decoding error: \(decodingError)")
                #endif
            }
        } catch {
            CrashGuard.shared.log(.error, "Poll inbox failed", metadata: [
                "error": error.localizedDescription
            ])
            #if DEBUG
            print("❌ [RealtimeEngine] Poll inbox failed: \(error)")
            #endif
        }
    }
    
    // MARK: - Handle Push Notification
    
    func handlePushNotification(_ payload: [String: Any]) {
        Task {
            // Immediate sync
            await syncNow()
            
            // Show toast if app is active
            await MainActor.run {
                if UIApplication.shared.applicationState == .active {
                    showToast(for: payload)
                }
            }
        }
    }
    
    func handlePushTap(_ payload: [String: Any]) {
        // Sync first
        Task {
            await syncNow()
        }
        
        // Navigate to chat based on payload
        guard let type = payload["type"] as? String else { return }
        
        var destination: DeepLinkRouter.Destination?
        switch type {
        case "message":
            if let roomId = payload["room_id"] as? String {
                destination = .chat(roomId: roomId)
            }
        case "friend_request":
            destination = .friendRequests
        case "security":
            destination = .security
        default:
            break
        }
        
        if let destination = destination {
            // AuthService is @MainActor; `handlePushTap` is invoked from
            // UNUserNotificationCenter delegate callbacks which iOS
            // dispatches on main, so assumeIsolated is safe.
            let isReady = MainActor.assumeIsolated {
                AuthService.shared.isAuthenticated && AuthService.shared.isEmailVerified
            }
            if isReady {
                Task { @MainActor in
                    DeepLinkRouter.shared.navigate(to: destination)
                }
            } else {
                DeepLinkRouter.shared.pendingDestination = destination
            }
        }
    }
    
    // MARK: - Toast Notification

    /// 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — annotated
    /// `@MainActor` so the body can directly touch
    /// `ConversationStore.shared` / `NotificationPipeline.shared`
    /// (both main-actor isolated). Pre-fix the function was
    /// nonisolated which compiled under Swift 5 but became a
    /// hard error under Swift 6 strict-concurrency. Only caller
    /// (`handlePushNotification`) already wraps the invocation
    /// in `MainActor.run`, so the annotation has no runtime cost.
    @MainActor
    private func showToast(for payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }

        // The realtime channel is a private-messaging carrier. Legacy social
        // events must not be converted into UI or engagement notifications.
        let messagingEventTypes: Set<String> = [
            "message", "group_message", "dm_message", "friend_request",
            "added_to_group", "group_invite", "vault_access",
            "security_alert", "security",
        ]
        guard messagingEventTypes.contains(type) else { return }

        // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — name lookup
        // is shared by every toast case below so the banner ALWAYS
        // gets a display name. Tries `sender_username` first (modern
        // path), then `sender_name`, then aps.alert.title (APNs
        // foreground payload), then the conversation peer cache,
        // then "Someone" as last resort. Pre-fix the message case
        // hard-required `sender_username` and silently dropped the
        // whole toast when missing — the "empty banner" user
        // complaint.
        let resolveSenderName: (String?) -> String = { fallbackRoomId in
            if let s = payload["sender_username"] as? String, !s.isEmpty, !s.looksEncrypted {
                return s
            }
            if let s = payload["sender_name"] as? String, !s.isEmpty, !s.looksEncrypted {
                return s
            }
            if let aps = payload["aps"] as? [String: Any],
               let alert = aps["alert"] as? [String: Any],
               let title = alert["title"] as? String, !title.isEmpty {
                return title
            }
            if let roomId = fallbackRoomId,
               let conv = ConversationStore.shared.conversations.first(where: { $0.roomId == roomId }) {
                return conv.isGroup ? (conv.groupName ?? conv.peer.displayName) : conv.peer.displayName
            }
            return "Someone"
        }
        let resolveAvatarURL: () -> URL? = {
            let raw = (payload["sender_avatar"] as? String)
                ?? (payload["sender_avatar_url"] as? String)
                ?? (payload["avatar_url"] as? String)
                ?? (payload["sender_avatar_path"] as? String)
                ?? (payload["requester_avatar"] as? String)
            guard let raw, !raw.isEmpty else { return nil }
            return AppConfig.mediaURL(from: raw)
        }

        switch type {
        case "message", "group_message", "dm_message":
            // 🔴 ROUND 71 phase 3 — accept the message even when
            // sender_username is missing. Resolves to peer-cache
            // display name or "Someone"; preview falls through
            // MessagePreviewFormatter which always returns at least
            // a type-aware label ("📷 Photo", "🎤 Voice", etc.).
            let roomId = (payload["room_id"] as? String) ?? (payload["sender_id"] as? String) ?? ""
            if !roomId.isEmpty {
                let senderName = resolveSenderName(roomId)
                // 🔴 Bug fix (2026-05-15): the WS toast path was
                // dropping the body to whatever the server's `preview`
                // string contained — for images/voice/video that's
                // empty or just a filename, so the in-app banner
                // showed only the sender's name. Run the metadata
                // through `MessagePreviewFormatter` so we land on
                // "📷 Photo", "🎤 Voice (0:12)", etc., the same way
                // the APNs path does (PushNotificationService:633).
                let rawPreview = payload["preview"] as? String
                let messageType = (payload["message_type"] as? String)
                    ?? (payload["type"] as? String)
                let durationRaw = payload["audio_duration_seconds"]
                    ?? payload["voice_duration"]
                    ?? payload["duration"]
                let audioDuration: Int? = {
                    if let i = durationRaw as? Int { return i }
                    if let d = durationRaw as? Double { return Int(d) }
                    if let s = durationRaw as? String { return Int(s) }
                    return nil
                }()
                let fileName = (payload["file_name"] as? String)
                    ?? (payload["attachment_name"] as? String)
                let preview = MessagePreviewFormatter.format(
                    messageType: messageType,
                    body: rawPreview,
                    audioDurationSeconds: audioDuration,
                    fileName: fileName
                )

                // (2026-05-15 — round 7) Don't show toast if user is
                // already in this chat. The strict `roomId == current`
                // check covers groups perfectly, but DM payloads have
                // historically used a few different `room_id` formats
                // (peer user-id alone vs. canonical room-id). Belt-
                // and-braces: also suppress when the sender id matches
                // the active chat's peer id, so a self-notification
                // can never sneak through a format mismatch.
                let senderId = payload["sender_id"] as? String ?? ""
                let activeRoom = DeepLinkRouter.shared.currentChatRoomId
                if activeRoom == roomId || (activeRoom != nil && activeRoom == senderId) {
                    return
                }
                let messageId = (payload["message_id"] as? String)
                    ?? (payload["client_message_id"] as? String)
                    ?? (payload["id"] as? String)
                Task { @MainActor in
                    // 🔴 Bug fix (2026-05-09): WS may deliver the same
                    // message that APNs or mesh already surfaced.
                    // Centralised dedup via NotificationDedupCache.
                    if let mid = messageId, !mid.isEmpty {
                        let firstToShow = await NotificationDedupCache.shared.claim(messageId: mid)
                        guard firstToShow else {
                            #if DEBUG
                            print("📵 [Notif] Skipping WS in-app toast for \(mid.prefix(8)) — already shown")
                            #endif
                            return
                        }
                    }
                    // (2026-05-15 — round 6) Surface the sender's
                    // avatar in the in-app toast — the user reported
                    // banners arrived without one. Server payload may
                    // carry the URL under several keys depending on
                    // which microservice produced the push, so we
                    // try them in order.
                    let avatarRaw = (payload["sender_avatar"] as? String)
                        ?? (payload["sender_avatar_url"] as? String)
                        ?? (payload["avatar_url"] as? String)
                        ?? (payload["sender_avatar_path"] as? String)
                    let avatarURL: URL? = {
                        guard let raw = avatarRaw, !raw.isEmpty else { return nil }
                        return AppConfig.mediaURL(from: raw)
                    }()
                    let isGroupChat = (payload["is_group"] as? Bool) ?? false
                    // 🔴 ROUND 71 phase 3 follow-up #4 (2026-05-24) —
                    // pass group name + messageId + server
                    // notification id through to the toast so the
                    // banner can render "<sender> · <group>" and
                    // the tap handler can mark the correct row
                    // read on the server. Group name resolution
                    // mirrors the message-store path: try payload
                    // fields first, fall back to ConversationStore
                    // by roomId.
                    let groupNameFromPayload =
                        (payload["group_name"] as? String)
                            ?? (payload["groupName"] as? String)
                    let resolvedGroupName: String? = {
                        if let g = groupNameFromPayload, !g.isEmpty { return g }
                        if isGroupChat,
                           let conv = ConversationStore.shared.conversations.first(where: { $0.roomId == roomId }),
                           let g = conv.groupName, !g.isEmpty {
                            return g
                        }
                        return nil
                    }()
                    let serverNotifId = (payload["notification_id"] as? String)
                        ?? (payload["notif_id"] as? String)
                    let toast = ToastItem.message(
                        senderName: senderName,
                        preview: preview,
                        avatarURL: avatarURL,
                        chatId: roomId,
                        senderId: senderId,
                        isGroup: isGroupChat,
                        groupName: resolvedGroupName,
                        serverNotificationId: serverNotifId,
                        messageId: messageId
                    )
                    NotificationPipeline.shared.enqueue(toast)
                }
            }
            
        case "friend_request":
            // 🔴 ROUND 71 phase 3 — accept/decline-correct toast.
            //   Pre-fix this branch passed `userId` as `requestId`,
            //   so the accept/decline buttons on the toast and on
            //   the notification row hit `/api/users/friend-request/
            //   {userId}/accept` — which 404s because the path
            //   expects the friend-request ROW id, not the
            //   requester's user id. Avatar was also dropped on
            //   the floor; the toast rendered initials only even
            //   when the server had a URL.
            //
            //   New behavior: pull `request_id` + `requester_avatar`
            //   from the payload (server sends both since R71 p3),
            //   fall back to the prior shape for back-compat with
            //   older servers. Also enqueue an unread-count bump so
            //   the badge reflects the new pending request without
            //   waiting for the next /api/notifications poll.
            if let username = payload["requester_username"] as? String,
               let userId = payload["requester_id"] as? String {
                let requestId = (payload["request_id"] as? String) ?? userId
                let avatarRaw = payload["requester_avatar"] as? String
                let avatarURL: URL? = {
                    guard let raw = avatarRaw, !raw.isEmpty else { return nil }
                    return AppConfig.mediaURL(from: raw)
                }()
                Task { @MainActor in
                    let toast = ToastItem.friendRequest(
                        fromName: username,
                        avatarURL: avatarURL,
                        senderId: userId,
                        requestId: requestId
                    )
                    NotificationPipeline.shared.enqueue(toast)
                    // Friend requests are NEVER auto-cleared by the
                    // poll-side mark-all-read sweep; bump the badge
                    // so the bell flashes right away.
                    NotificationPipeline.shared.unreadCount += 1
                    // 🟢 ROUND 75 (2026-05-24) — broadcast a refresh
                    // signal so NotificationsListView re-fetches
                    // /api/notifications immediately (otherwise the
                    // user opens the bell and sees an empty list
                    // until the 30s polling cycle). Cheap, idempotent,
                    // posted only on actual WS arrival.
                    NotificationCenter.default.post(
                        name: Notification.Name("FriendRequestWSReceived"),
                        object: nil
                    )
                }
            }
            
        case "added_to_group", "group_invite":
            let inviter = resolveSenderName(nil)
            let groupName = (payload["group_name"] as? String) ?? "a group"
            let groupId = (payload["group_id"] as? String) ?? (payload["room_id"] as? String) ?? ""
            Task { @MainActor in
                NotificationPipeline.shared.enqueue(ToastItem.groupInvite(
                    groupName: groupName,
                    inviterName: inviter,
                    avatarURL: resolveAvatarURL(),
                    groupId: groupId
                ))
            }

        case "vault_access":
            let viewer = resolveSenderName(nil)
            Task { @MainActor in
                NotificationPipeline.shared.enqueue(ToastItem.security(
                    title: "🔓 Vault opened",
                    message: "\(viewer) viewed your vault attachment"
                ))
            }

        case "security_alert", "security":
            let title = (payload["title"] as? String) ?? "Security Alert"
            let body = (payload["preview"] as? String) ?? (payload["body"] as? String) ?? "New activity detected"
            Task { @MainActor in
                NotificationPipeline.shared.enqueue(ToastItem.security(title: title, message: body))
            }

        default:
            #if DEBUG
            print("🍞 [RealtimeEngine] showToast — no banner case for type='\(type)' (add to switch if user-facing)")
            #endif
            break
        }
    }

    // MARK: - Added-to-Group WebSocket Handler (Round 47)
    //
    // 🟦 ROUND 47 (2026-05-17) — group lifecycle WS push.
    //
    // When the server-side `POST /api/groups` handler creates a group,
    // it now WS-pushes `{type: "added_to_group", group: {...}}` to every
    // online member. iOS materializes the group locally AND re-broadcasts
    // it via mesh so any BLE-only neighbours of the receiver also see it.
    //
    // This is the "instant" path. The bridge-downlink-based path serves
    // as a periodic safety net (every ~15s poll) — both converge to the
    // same `GroupRepository.upsert` + `MeshGroupBroadcaster.broadcastCreate`
    // call, and both are idempotent.
    static func handleAddedToGroupWS(json: [String: Any]) async {
        guard let groupDict = json["group"] as? [String: Any],
              let groupId = groupDict["id"] as? String,
              !groupId.isEmpty else {
            // Without the inline `group` payload we'd need a follow-up
            // /api/groups/{id} fetch. Older server builds (pre-R47) didn't
            // include it — degrade gracefully by triggering a fetchMyGroups
            // so the user at least sees the group eventually.
            #if DEBUG
            print("🟦 [WS] added_to_group missing inline group payload — falling back to fetchMyGroups()")
            #endif
            _ = try? await GroupService.shared.fetchMyGroups()
            return
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        func parseDate(_ s: String?) -> Date {
            guard let s = s, !s.isEmpty else { return Date() }
            return iso.date(from: s) ?? isoNoFrac.date(from: s) ?? Date()
        }

        let name = (groupDict["name"] as? String) ?? "Group"
        let avatarUrl = groupDict["avatar_url"] as? String
        let description = groupDict["description"] as? String
        let createdBy = (groupDict["created_by"] as? String) ?? ""
        let creatorUsername = groupDict["creator_username"] as? String
        let createdAt = parseDate(groupDict["created_at"] as? String)
        let memberCount = (groupDict["member_count"] as? Int) ?? 0

        let memberDicts = (groupDict["members"] as? [[String: Any]]) ?? []
        let members: [GroupMember] = memberDicts.compactMap { md in
            guard let uid = md["user_id"] as? String, !uid.isEmpty else { return nil }
            return GroupMember(
                userId: uid,
                username: (md["username"] as? String) ?? "",
                avatarUrl: md["avatar_url"] as? String,
                role: (md["role"] as? String) ?? "member",
                joinedAt: parseDate(md["joined_at"] as? String)
            )
        }

        let group = ChatGroup(
            id: groupId,
            name: name,
            avatarUrl: avatarUrl,
            description: description,
            createdBy: createdBy,
            creatorUsername: creatorUsername,
            createdAt: createdAt,
            memberCount: memberCount > 0 ? memberCount : members.count,
            members: members,
            syncStatus: .synced
        )

        // 1. Materialize locally (SQL UPSERT — safe to re-run).
        do {
            try await GroupRepository().upsert(group)
            try? await ConversationRepository.shared.createGroupConversation(group: group)
            // Promote any limbo messages for this group_id — those are
            // chat messages that arrived BEFORE we knew about the group
            // (mesh out-of-order). Promote re-runs the full receive path.
            let parked = await PendingGroupMessageRepository.shared.promoteMessages(forGroup: group.id)
            for env in parked {
                await AppDelegate.handleMeshMessage(env)
            }
            await ConversationStore.shared.loadFromDB()
            #if DEBUG
            print("🟦 [WS] added_to_group ✅ materialized group \(group.id.prefix(8)) name='\(group.name)' members=\(members.count) promoted=\(parked.count)")
            #endif
        } catch {
            #if DEBUG
            print("🟦 [WS] added_to_group ❌ GroupRepository.upsert failed: \(error.localizedDescription)")
            #endif
        }

        // 2. Re-broadcast over mesh for BLE-only neighbours that aren't
        // online and so can't be reached via the server-side WS push.
        //
        // 🔴 ROUND 40 (2026-05-19) — mesh-amplification fix.
        //
        // PREVIOUSLY: every `added_to_group` WS event fired an
        // unconditional `MeshGroupBroadcaster.broadcastCreate(group)`.
        // A compromised or TLS-stripped WS could spam this event 1k
        // times in a second and the client would dutifully blast 1k
        // group-create envelopes onto BLE — saturating every nearby
        // neighbour's radio and battery. A misbehaving server (bug,
        // not malice) had the same effect.
        //
        // FIX: per-process sliding-window dedup keyed on group.id.
        // Once we've broadcast a group-create for a given groupId we
        // skip subsequent broadcasts for 5 minutes. The local
        // `GroupRepository.upsert` above is already idempotent, so
        // missing a mesh re-broadcast costs us nothing — BLE-only
        // peers will see the group on the next legitimate event for
        // it (rename, member add, etc.) or via a friend's hop.
        if await Self.shouldBroadcastGroupCreate(groupId: group.id) {
            await MeshGroupBroadcaster.broadcastCreate(group)
            // 🟢 ROUND 74 (2026-05-24) — also broadcast the group's
            // AES-GCM key so BLE-only members can decrypt. We just
            // got added to this group via WS, which means the server
            // already minted v1; `prefetchAndBroadcast` will fetch
            // it (cached or live), and on a fresh fetch ALSO mesh-
            // broadcast it to neighbours. Same 5-min dedup applies
            // to the group_create broadcast; the key broadcast is
            // idempotent at the receiver (same key+version is a no-
            // op), so re-broadcasting on every added_to_group is
            // safe — duplicate keys are deduped at ingest time.
            Task { await GroupKeyService.shared.prefetchAndBroadcast(groupId: group.id) }
        } else {
            #if DEBUG
            print("🟦 [WS] added_to_group mesh-rebroadcast suppressed (within 5-min window) for \(group.id.prefix(8))")
            #endif
        }
    }

    // Per-process dedup cache for `added_to_group` mesh re-broadcast.
    // Keyed on groupId → timestamp of last broadcast. 5-min TTL.
    //
    // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — moved from a
    // bare `NSLock().lock()/.unlock()` pair to an actor so we don't
    // call NSLock's blocking lock/unlock from an `async` function.
    // Swift 6 strict-concurrency marks NSLock's lock/unlock as
    // unavailable in async contexts (they can deadlock if the
    // continuation hops to another thread holding the lock). An
    // actor gives us the same mutual-exclusion guarantee with no
    // blocking and async-safe scoping.
    private actor BroadcastDedup {
        private var lastBroadcastByGroup: [String: Date] = [:]
        private let ttl: TimeInterval

        init(ttl: TimeInterval) { self.ttl = ttl }

        func shouldBroadcast(groupId: String) -> Bool {
            let now = Date()
            // GC stale entries so the dict doesn't grow unbounded.
            lastBroadcastByGroup = lastBroadcastByGroup.filter { now.timeIntervalSince($0.value) < ttl }
            if let last = lastBroadcastByGroup[groupId],
               now.timeIntervalSince(last) < ttl {
                return false
            }
            lastBroadcastByGroup[groupId] = now
            return true
        }
    }

    private static let broadcastDedup = BroadcastDedup(ttl: 5 * 60)

    private static func shouldBroadcastGroupCreate(groupId: String) async -> Bool {
        await broadcastDedup.shouldBroadcast(groupId: groupId)
    }
}

// MARK: - Safe Array Decoder (Bug 6 fix)

/// Wrapper that catches per-element decode failures in arrays.
/// Usage: `decode([SafeDecodable<T>].self, ...)` + `.compactMap(\.value)`
/// If one element in the array has corrupt data, only that element is skipped.
struct SafeDecodable<T: Decodable>: Decodable {
    let value: T?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}
