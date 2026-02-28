import Foundation
import UIKit

// MARK: - Realtime Engine (Central Hub)
// Primary transport: WebSocket (wss://). Fallback: HTTP polling at 30s.
@Observable
class RealtimeEngine {
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
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
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
    }
    
    private func onEnterForeground() {
        #if DEBUG
        print("[RealtimeEngine] Entering foreground")
        #endif
        CrashGuard.shared.log(.network, "RealtimeEngine: entering foreground")
        
        // Don't sync if not fully authenticated
        let auth = AuthService.shared
        guard auth.isAuthenticated,
              auth.isEmailVerified || auth.currentUser?.authMethod != .password,
              auth.currentUser?.username != nil else {
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
        guard connectionState == .disconnected else { return }
        
        let auth = AuthService.shared
        guard auth.isAuthenticated else { return }
        
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
            self.webSocketTask = Self.wsSession.webSocketTask(with: wsURL)
            self.webSocketTask?.resume()
            
            // Start receiving messages
            self.receiveWebSocketMessage()
            
            // Start ping/pong heartbeat to detect silent connection drops
            // (Cloud Run and similar LBs drop idle TCP after ~10-15 min)
            self.startPingTimer()
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
                self.webSocketTask?.sendPing { error in
                    if let error = error {
                        #if DEBUG
                        print("❌ [RealtimeEngine] WebSocket ping failed: \(error.localizedDescription)")
                        #endif
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
                    }
                }
                
                Task {
                    await ConversationStore.shared.handleIncomingMessages(messages)
                    // Update timestamp for incremental polling fallback
                    if let latest = messages.first {
                        self.lastInboxTimestamp = PerformanceConstants.iso8601.string(from: latest.timestamp)
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
        CrashGuard.shared.log(.network, "WS disconnected", metadata: [
            "reconnectAttempt": "\(wsReconnectAttempts)"
        ])
        
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
            let delay = min(Double(1 << self.wsReconnectAttempts), 30)  // 2s, 4s, 8s... max 30s
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
            
            // Update timestamp for next poll from latest message
            if let latestMessage = messages.first {
                lastInboxTimestamp = PerformanceConstants.iso8601.string(from: latestMessage.timestamp)
            }
            
            // Handle new messages
            if !messages.isEmpty {
                await ConversationStore.shared.handleIncomingMessages(messages)
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
            if AuthService.shared.isAuthenticated && AuthService.shared.isEmailVerified {
                Task { @MainActor in
                    DeepLinkRouter.shared.navigate(to: destination)
                }
            } else {
                DeepLinkRouter.shared.pendingDestination = destination
            }
        }
    }
    
    // MARK: - Toast Notification
    
    private func showToast(for payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }
        
        switch type {
        case "message":
            if let senderName = payload["sender_username"] as? String,
               let preview = payload["preview"] as? String,
               let roomId = payload["room_id"] as? String {
                // Don't show toast if user is already in this chat
                guard !DeepLinkRouter.shared.isInChat(roomId: roomId) else { return }
                let senderId = payload["sender_id"] as? String ?? ""
                Task { @MainActor in
                    let toast = ToastItem.message(
                        senderName: senderName,
                        preview: preview,
                        chatId: roomId,
                        senderId: senderId
                    )
                    NotificationPipeline.shared.enqueue(toast)
                }
            }
            
        case "friend_request":
            if let username = payload["requester_username"] as? String,
               let userId = payload["requester_id"] as? String {
                Task { @MainActor in
                    let toast = ToastItem.friendRequest(
                        fromName: username,
                        senderId: userId,
                        requestId: userId
                    )
                    NotificationPipeline.shared.enqueue(toast)
                }
            }
            
        default:
            break
        }
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
