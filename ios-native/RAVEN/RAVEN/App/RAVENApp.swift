import SwiftUI
import UserNotifications
import GoogleSignIn
import BackgroundTasks

@main
struct RAVENApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appSettings = AppSettings.shared
    @State private var languageManager = AppLanguageManager.shared
    
    var body: some Scene {
        WindowGroup {
            AuthGateView()
                .preferredColorScheme(appSettings.preferredColorScheme)
                .dynamicTypeSize(appSettings.dynamicTypeSize)  // Global text scaling
                .environment(\.layoutDirection, languageManager.layoutDirection)
                .environment(\.locale, languageManager.locale)
                .withToastSupport()
                .withAppLock()  // App Lock - requires auth when enabled
                // Background mesh onboarding moved to MainShellView (after login/setup complete)
                // Screenshot protection removed from root - will be applied per-view
                .handleDeepLinks()
                .task {
                    // Request push permissions on app start
                    let granted = await PushNotificationService.shared.requestAuthorization()
                    #if DEBUG
                    print("🔔 [App] Push authorization: \(granted ? "GRANTED" : "DENIED")")
                    #endif
                    
                    // Retry sending stored token to server (in case previous attempt failed)
                    if granted {
                        await PushNotificationService.shared.retryTokenRegistration()
                    }
                }
                .onOpenURL { url in
                    // Handle raven://room/{slug} deep links
                    DeepLinkRouter.shared.handleURL(url)
                }
                // 🚀 Cold Start Deep Link: After user authenticates, fire any pending deep link
                .onChange(of: AuthService.shared.isAuthenticated) { _, isAuthenticated in
                    if isAuthenticated {
                        if let pending = DeepLinkRouter.shared.pendingDestination {
                            DeepLinkRouter.shared.pendingDestination = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                DeepLinkRouter.shared.navigate(to: pending)
                            }
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                CrashGuard.shared.log(.lifecycle, "App became active (foreground)")
                
                // Start presence heartbeat when app becomes active
                PresenceService.shared.startHeartbeat()
                
                // Restart delivery job runner (stopped during background)
                DeliveryJobRunner.shared.start()
                
                // End background tasks when returning to foreground
                BackgroundMeshManager.shared.endAllBackgroundTasks()
                
                // Ensure BLE is running
                #if !targetEnvironment(simulator)
                if !BLEMeshEngine.shared.isScanning {
                    BLEMeshEngine.shared.start()
                }
                BLEMeshEngine.shared.setBackgroundBridgeMode(enabled: false)
                #endif
                
            case .inactive:
                CrashGuard.shared.log(.lifecycle, "App became inactive")
                
            case .background:
                CrashGuard.shared.log(.lifecycle, "App entered background")
                
                // Stop heartbeat and notify server when going background
                PresenceService.shared.stopHeartbeat()
                
                // Stop the 5-second delivery job timer to avoid CPU/energy kills.
                // Background delivery is handled by BLE event-driven drainPendingFromDB.
                DeliveryJobRunner.shared.stop()
                
                // Schedule background tasks
                BackgroundMeshManager.shared.scheduleBackgroundRefresh()
                BackgroundMeshManager.shared.scheduleBackgroundProcessing()
                BackgroundMeshManager.shared.startBackgroundLocationAnchor()
                
                #if !targetEnvironment(simulator)
                BLEMeshEngine.shared.setBackgroundBridgeMode(enabled: true)
                #endif
                
                // Mark clean transition to background (not a crash)
                CrashGuard.shared.markCleanExit()
                
                #if DEBUG
                print("📱 [App] Entered background - scheduled background tasks")
                #endif
                
            default:
                break
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Configure URLCache for offline image viewing (500 MB disk space)
        let memoryCapacity = 50 * 1024 * 1024 // 50 MB
        let diskCapacity = 500 * 1024 * 1024 // 500 MB
        URLCache.shared = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: "raven_media_cache")

        // 🛡️ CrashGuard — MUST be first to detect crashes from previous session
        CrashGuard.shared.start()
        
        // 💎 RevenueCat — Configure subscription service early
        SubscriptionService.shared.configure()
        
        #if DEBUG
        print("🚀 [App] ═══════════════════════════════════════")
        print("🚀 [App] RAVEN Starting...")
        print("🚀 [App] ═══════════════════════════════════════")
        #endif
        
        // 1. Setup background mesh manager FIRST
        BackgroundMeshManager.shared.setup()
        
        // 2. Handle launch options (check if launched from background)
        BackgroundMeshManager.shared.handleLaunchOptions(launchOptions)
        
        // Setup push notification delegate
        UNUserNotificationCenter.current().delegate = self
        
        // Start DTN Mesh infrastructure (Server-first, Mesh-fallback)
        NetworkMonitor.shared.start()
        // PendingSyncManager removed — OutboxManager handles this
        
        // Log launch reason
        if launchOptions == nil {
            #if DEBUG
            print("🚀 [App] Normal launch (user tapped icon)")
            #endif
        } else {
            #if DEBUG
            print("🚀 [App] Background launch with options: \(launchOptions?.keys.description ?? "nil")")
            #endif
        }
        
        #if DEBUG
        print("🌐 [App] Network & Mesh monitoring started")
        #endif
        
        // 🔴 CRITICAL FIX: BLE MUST be initialized SYNCHRONOUSLY before
        // didFinishLaunchingWithOptions returns. Apple's CoreBluetooth State
        // Restoration contract requires CBCentralManager to be created on the
        // main thread during launch. If BLE init is async (inside Task), iOS
        // sees that the app failed to handle the BLE event, kills it, re-wakes
        // it, and repeats — hundreds of times per second — freezing the device.
        //
        // Database init stays async in a Task below. DatabaseService already
        // guards with `guard db != nil` so BLE message handlers gracefully
        // drop messages until the DB is ready (they'll sync later).
        #if !targetEnvironment(simulator)
        BLEMeshEngine.shared.start()
        
        if application.applicationState == .background {
            BLEMeshEngine.shared.setBackgroundBridgeMode(enabled: true)
            BackgroundMeshManager.shared.startBackgroundLocationAnchor()
            #if DEBUG
            print("📡 [App] Background launch detected - BLE bridge profile enabled")
            #endif
        } else {
            BLEMeshEngine.shared.setBackgroundBridgeMode(enabled: false)
        }
        
        BLEMeshEngine.shared.onMessageReceived = { envelope in
            Task { await Self.handleMeshMessage(envelope) }
        }
        BLEMeshEngine.shared.onACKReceived = { ack in
            Task { await Self.handleMeshACK(ack) }
        }
        BLEMeshEngine.shared.onMeshPostReceived = { envelope in
            Task { await MeshPostService.shared.handleIncoming(envelope) }
        }
        
        #if DEBUG
        print("📡 [App] Bluetooth Mesh started synchronously ✅")
        #endif
        #endif
        
        // Database & identity init (async — safe to run after BLE is up)
        Task {
            do {
                try await DatabaseService.shared.initialize()
                try await FriendDeviceRepository.shared.createTableIfNeeded()
                try await DeviceIdentityService.shared.initialize()
                try await ConversationRepository.shared.deduplicateByPeerId()
                try await ConversationRepository.shared.normalizeRoomIdsToPeerId()
                
                #if DEBUG
                print("🔐 [App] Device identity initialized: \(DeviceIdentityService.shared.fingerprint ?? "generating...")")
                #endif
                
                #if !targetEnvironment(simulator)
                await MeshPostSyncWorker.shared.startMonitoring()
                #endif
                
                #if DEBUG
                print("📡 [App] Database & mesh sync ready ✅")
                #endif
            } catch {
                #if DEBUG
                print("🚨 [App] Critical Initialization Error: \(error)")
                #endif
                // DB failure is non-fatal for BLE — messages will be dropped
                // gracefully and synced when DB becomes available.
            }
        }
        
        // Check if launched from push
        if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Task {
                await PushNotificationService.shared.handlePushTap(userInfo)
            }
        }
        
        // ✅ Warmup: Light health check to warm up network connection (fire and forget)
        // Token warmup removed - getToken() now caches automatically on first read
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 500_000_000)  // Delay 500ms to not compete with launch
            do {
                guard let url = AppConfig.apiURL(path: "/health") else { return }
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    #if DEBUG
                    print("🌐 [App] Network warmup complete")
                    #endif
                }
            } catch {
                #if DEBUG
                print("⚠️ [App] Network warmup failed (not critical): \(error.localizedDescription)")
                #endif
            }
        }
        
        return true
    }
    
    // MARK: - URL Callback (Google Sign-In)
    
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        // Handle Google Sign-In callback
        if GIDSignIn.sharedInstance.handle(url) {
            #if DEBUG
            print("🔵 [App] Google Sign-In handled URL callback")
            #endif
            return true
        }
        
        // Handle deep links
        DeepLinkRouter.shared.handleURL(url)
        return true
    }
    
    // MARK: - Remote Notifications
    
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenHex = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        #if DEBUG
        print("📱 [AppDelegate] didRegisterForRemoteNotifications — token: \(tokenHex.prefix(16))... (\(tokenHex.count) chars)")
        #endif
        Task {
            await PushNotificationService.shared.handleDeviceToken(deviceToken)
        }
    }
    
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("📱 [AppDelegate] ❌ didFailToRegisterForRemoteNotifications: \(error.localizedDescription)")
        #endif
        Task {
            await PushNotificationService.shared.handleRegistrationError(error)
        }
    }
    
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            await PushNotificationService.shared.handlePushReceived(
                userInfo,
                appState: application.applicationState
            )
            completionHandler(.newData)
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    // Foreground notification display
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        #if DEBUG
        print("🔔 [AppDelegate] willPresent notification: \(userInfo)")
        #endif
        
        Task {
            await PushNotificationService.shared.handlePushReceived(
                userInfo,
                appState: .active
            )
        }
        
        // Show system banner + sound in foreground, UNLESS user is currently
        // viewing the exact chat this notification is about.
        // This ensures notifications still appear when the app is open but
        // the user is on a different screen (e.g. feed, settings, another chat).
        let incomingChatId = userInfo["room_id"] as? String ?? userInfo["chat_id"] as? String ?? userInfo["group_id"] as? String
        
        if let chatId = incomingChatId, DeepLinkRouter.shared.isInChat(roomId: chatId) {
            // User IS in this chat — suppress system notification, in-app toast handles it
            #if DEBUG
            print("🔔 [AppDelegate] Suppressing banner (user is in chat \(chatId.prefix(8)))")
            #endif
            completionHandler([])
        } else {
            // User is NOT in this chat — show system banner + sound
            #if DEBUG
            print("🔔 [AppDelegate] Showing system banner + sound")
            #endif
            completionHandler([.banner, .sound, .badge])
        }
    }
    
    // Notification tap handler
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        
        Task {
            await PushNotificationService.shared.handlePushTap(userInfo)
            completionHandler()
        }
    }
    
    // MARK: - Mesh Message Handler
    
    static func handleMeshMessage(_ envelope: MeshEnvelope) async {
        #if DEBUG
        print("📥 [App] Processing mesh message: \(envelope.clientMessageId.prefix(8))")
        #endif
        
        // Check if message is for us
        let myId = await KeychainService.shared.getUserId()
        
        // DEBUG: Log the comparison
        #if DEBUG
        print("🔍 [MESH DEBUG] myId: \(myId ?? "nil")")
        print("🔍 [MESH DEBUG] envelope.recipientId: \(envelope.recipientId)")
        print("🔍 [MESH DEBUG] Match: \(envelope.recipientId == myId)")
        #endif
        
        guard let myId = myId, !myId.isEmpty else {
            #if DEBUG
            print("❌ [App] Cannot process mesh message - userId not loaded from Keychain!")
            #endif
            return
        }
        
        // Check if this is a group message (recipientId = groupId in groups table)
        // Bug 2 fix: Also use envelope.isGroup flag as fallback for groups not yet synced locally
        let groupRepo = GroupRepository()
        let knownGroup = try? await groupRepo.get(groupId: envelope.recipientId)
        let isGroupMessage = knownGroup != nil || (envelope.isGroup == true)
        
        guard envelope.recipientId == myId || isGroupMessage else {
            #if DEBUG
            print("📦 [App] Message not for us (recipient: \(envelope.recipientId.prefix(8)), me: \(myId.prefix(8))) - forwarding...")
            #endif
            
            // BRIDGE: If we're online, forward to SERVER for the recipient
            // This is the key "offline sender → online bridge → server → online recipient" path
            if NetworkMonitor.shared.isOnline {
                #if DEBUG
                print("🌉 [BRIDGE] We're online! Forwarding mesh message to server for recipient...")
                #endif
                await BLEMeshEngine.shared.bridgeMeshMessageToServer(envelope)
            }
            
            // NOTE: Mesh relay is handled by BLEMeshEngine.processVerifiedEnvelope
            // Do NOT re-forward here — that causes double forwarding / amplification
            return
        }
        
        // Bug 2 fix: Group message for a group we don't know about yet → limbo
        if isGroupMessage && knownGroup == nil {
            #if DEBUG
            print("📦 [App] Group \(envelope.recipientId.prefix(8)) not in local DB — storing in limbo for later sync")
            #endif
            await PendingGroupMessageRepository.shared.store(envelope)
            return
        }
        
        #if DEBUG
        print("✅ [App] Message IS for us! Converting to ChatMessage...")
        print("🔍 [MESH RECEIVE DEBUG] ════════════════════════════")
        print("🔍 [MESH RECEIVE DEBUG] envelope.roomId: \(envelope.roomId)")
        print("🔍 [MESH RECEIVE DEBUG] envelope.senderId: \(envelope.senderId)")
        print("🔍 [MESH RECEIVE DEBUG] envelope.recipientId: \(envelope.recipientId)")
        print("🔍 [MESH RECEIVE DEBUG] envelope.senderName: \(envelope.senderName)")
        #endif
        
        // Convert envelope to ChatMessage
        // IMPORTANT: roomId depends on message type:
        // - Group: roomId = group ID (= envelope.recipientId)
        // - 1:1: roomId = peer ID (= sender for receiver)
        var message = ChatMessage.fromMeshEnvelope(envelope, authority: .mesh)
        if isGroupMessage {
            message.roomId = envelope.recipientId  // Group: roomId = group ID
        } else if message.roomId == myId {
            message.roomId = envelope.senderId     // 1:1: roomId = peer ID
        }
        
        #if DEBUG
        print("🔍 [MESH RECEIVE DEBUG] FINAL message.roomId: \(message.roomId ?? "nil")")
        print("🔍 [MESH RECEIVE DEBUG] ════════════════════════════")
        #endif
        
        // Save to database
        let messageRepo = MessageRepository.shared
        let conversationRepo = ConversationRepository.shared
        
        // Check for duplicate using MeshACKHandler (in-memory cache)
        if await MeshACKHandler.shared.isDuplicate(message.id) {
            #if DEBUG
            print("⚠️ [App] Duplicate mesh message (ACK cache) - sending ACK only")
            #endif
            // Still send ACK even for duplicates (to confirm receipt)
            await MeshACKHandler.shared.sendDeliveryACK(for: message.id, toSenderId: message.senderId)
            return
        }
        
        // Also check DB for duplicates (belt and suspenders)
        guard !(await messageRepo.exists(clientMessageId: message.id)) else {
            #if DEBUG
            print("⚠️ [App] Duplicate mesh message (DB) - sending ACK only")
            #endif
            await MeshACKHandler.shared.sendDeliveryACK(for: message.id, toSenderId: message.senderId)
            return
        }
        
        // Insert message
        try? await messageRepo.upsert(message)
        #if DEBUG
        print("📥 [MESH] ✅ Message inserted to DB: \(message.id.prefix(8))")
        #endif
        
        // Update conversation directly (don't use handleIncomingMessage as it has duplicate check)
        let currentUserId = await KeychainService.shared.getUserId() ?? ""
        do {
            try await conversationRepo.applyMessage(message, currentUserId: currentUserId)
            #if DEBUG
            print("📥 [MESH] ✅ Conversation updated for roomId=\(message.roomId?.prefix(8) ?? "nil")")
            #endif
        } catch {
            #if DEBUG
            print("📥 [MESH] ❌ applyMessage FAILED: \(error)")
            #endif
        }
        
        // Reload conversations UI
        #if DEBUG
        print("📥 [MESH] Reloading conversation list...")
        #endif
        await ConversationStore.shared.loadFromDB()
        let convCount = await MainActor.run { ConversationStore.shared.conversations.count }
        #if DEBUG
        print("📥 [MESH] ✅ Conversations reloaded: \(convCount) total")
        #endif
        
        // Notify MessageStore to reload if chat is open
        // roomId = senderId (peer's ID) for correct conversation
        let roomId = isGroupMessage ? (message.roomId ?? message.senderId) : message.senderId
        await MainActor.run {
            NotificationCenter.default.post(
                name: MessageStore.meshMessageReceivedNotification,
                object: nil,
                userInfo: ["roomId": roomId]
            )
        }
        
        // Show notification — local notification if backgrounded, in-app banner if foregrounded
        let appState = await MainActor.run { UIApplication.shared.applicationState }
        
        // --- CENTRALIZED NAME & PREVIEW RESOLUTION ---
        let resolvedName = await MainActor.run { () -> String? in
            if let conv = ConversationStore.shared.conversations.first(where: { $0.roomId == roomId }) {
                return conv.isGroup ? (conv.groupName ?? conv.peer.displayName) : conv.peer.displayName
            }
            return nil
        }
        
        var safeSenderName = message.senderName
        if safeSenderName.looksEncrypted || safeSenderName.isEmpty {
            safeSenderName = resolvedName ?? "New Message"
        } else if isGroupMessage {
            let gName = resolvedName ?? "Group"
            safeSenderName = "\(safeSenderName) in \(gName)"
        }
        
        var safePreview = message.text ?? "💬 Mesh message"
        if safePreview.looksEncrypted {
            switch message.type {
            case .image: safePreview = "📷 Photo"
            case .video: safePreview = "🎥 Video"
            case .videoNote: safePreview = "📹 Video note"
            case .ephemeralPhoto: safePreview = "📸 Snap Photo"
            case .voice: safePreview = "🎤 Voice message"
            case .file: safePreview = "📄 File"
            case .location: safePreview = "📍 Location"
            case .postShare: safePreview = "🔄 Shared post"
            case .system: safePreview = "🔔 Notification"
            default: safePreview = "🔒 Secure message"
            }
        }
        
        if appState == .active {
            // App is in foreground - show toast notification
            await MainActor.run {
                let toast = ToastItem.message(
                    senderName: safeSenderName,
                    preview: safePreview,
                    avatarURL: nil,
                    chatId: roomId,
                    senderId: message.senderId,
                    isGroup: isGroupMessage
                )
                NotificationPipeline.shared.enqueue(toast)
            }
        } else {
            // ALWAYS fire local notification for Mesh Messages to guarantee Lock Screen delivery
            let content = UNMutableNotificationContent()
            content.title = safeSenderName
            
            // 🔒 Privacy: Respect user's message preview setting (default: true)
            let showPreview = UserDefaults.standard.object(forKey: "messagePreview") as? Bool ?? true
            content.body = showPreview ? safePreview : "New Message"
            
            content.sound = .default
            content.threadIdentifier = roomId
            content.userInfo = [
                "roomId": roomId,
                "type": "mesh_message",
                "senderId": message.senderId
            ]
            
            // Use message.id so if APNs also sends a push with apns-collapse-id = message.id, iOS merges them
            let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
        
        // Bug 4 fix: ALWAYS send ACK, even for group messages.
        // ACK is point-to-point to the original sender only — it does NOT flood the network.
        // Without ACK, the sender's DeliveryJobRunner retries broadcasting for days (TTL),
        // causing a "broadcast storm" that drains battery and congests BLE.
        let ack = MeshACKEnvelope(
            originalMessageId: message.id,
            senderId: currentUserId,
            recipientId: message.senderId,
            status: .delivered,
            pathUsed: "mesh",
            originDeviceId: DeviceIdentityService.shared.fingerprint ?? ""
        )
        await BLEMeshEngine.shared.sendACK(ack)
        
        // BRIDGE: If we're online, forward mesh message to server for the recipient
        // This allows offline users to reach online users through a bridge device
        if NetworkMonitor.shared.isOnline && envelope.needsForwarding {
            await BLEMeshEngine.shared.forwardMeshMessageToServer(message)
        }
        
        #if DEBUG
        print("🎉 [App] Mesh message processed, ACK sent!")
        #endif
    }
    
    // MARK: - App Termination
    
    func applicationWillTerminate(_ application: UIApplication) {
        CrashGuard.shared.log(.lifecycle, "App terminating (willTerminate)")
        CrashGuard.shared.markCleanExit()
    }
    
    // MARK: - Handle Mesh ACK (Delivery/Read Receipt)
    
    static func handleMeshACK(_ ack: MeshACKEnvelope) async {
        // Verify this ACK is for me
        let myId = await KeychainService.shared.getUserId() ?? ""
        guard ack.recipientId == myId else {
            #if DEBUG
            print("⚠️ [App] ACK not for me - ignoring")
            #endif
            return
        }
        
        #if DEBUG
        print("📨 [App] Processing ACK for message \(ack.originalMessageId.prefix(8)) - status: \(ack.status.rawValue)")
        #endif
        
        // Update message status in database
        let newStatus: MessageStatus = ack.status == .read ? .read : .delivered
        
        // ⚡️ FIX: Prevent out-of-order BLE ACKs from downgrading read to delivered
        if newStatus == .delivered {
            let rows = try? await DatabaseService.shared.query("SELECT status FROM messages WHERE client_message_id = ? LIMIT 1", params: [ack.originalMessageId])
            if let currentStatusStr = rows?.first?["status"] as? String, currentStatusStr == "read" {
                #if DEBUG
                print("⚡️ [App] Skipping delivered ACK — message already read")
                #endif
                return
            }
        }
        
        try? await MessageRepository.shared.updateStatus(
            clientMessageId: ack.originalMessageId,
            status: newStatus
        )
        
        // Bug 4 fix: Stop relay for BOTH delivered AND read ACKs.
        // Previously only .delivered stopped broadcast — .read ACKs were ignored,
        // causing messages to broadcast for up to 24h (TTL) and draining battery.
        if ack.status == .delivered || ack.status == .read {
            let msgRows = try? await DatabaseService.shared.query(
                "SELECT room_id FROM messages WHERE client_message_id = ? LIMIT 1",
                params: [ack.originalMessageId]
            )
            let ackRoomId = msgRows?.first?["room_id"] as? String
            // Bug 4 fix: Stop delivery job for ALL messages (including groups).
            // For groups, a single ACK proves the message entered the mesh successfully.
            // This breaks the infinite retry loop that was draining battery.
            await BLEMeshEngine.shared.broadcastStop(ack.originalMessageId)
            try? await DeliveryJobRepository.shared.markStopped(messageId: ack.originalMessageId)
        }
        
        // Notify UI to refresh
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("MeshACKReceived"),
                object: nil,
                userInfo: ["messageId": ack.originalMessageId, "status": newStatus.rawValue]
            )
        }
        
        // Canonical delivery should be recorded on server.
        if ack.status == .delivered {
            let deliveredVia = ack.pathUsed ?? "mesh"
            let ackIdempotencyKey = "ack-\(ack.originalMessageId)-\(ack.senderId)"
            
            if NetworkMonitor.shared.isOnline {
                do {
                    let response: AckDeliveredResponse = try await NetworkService.shared.post(
                        path: "/api/messages/ack-delivered",
                        body: AckDeliveredRequest(
                            messageId: ack.originalMessageId,
                            deliveredVia: deliveredVia,
                            pathUsed: deliveredVia
                        ),
                        idempotencyKey: ackIdempotencyKey
                    )
                    
                    if response.stopMesh {
                        await BLEMeshEngine.shared.handleStop(ack.originalMessageId)
                        try? await DeliveryJobRepository.shared.markStopped(messageId: ack.originalMessageId)
                    }
                    
                    // In case this ACK was queued while offline, remove it.
                    try? await PendingACKRepository.shared.remove(clientMessageId: ack.originalMessageId)
                } catch {
                    // Offline-first: queue ACK and sync on reconnect.
                    try? await PendingACKRepository.shared.add(
                        clientMessageId: ack.originalMessageId,
                        deliveredVia: deliveredVia,
                        pathUsed: deliveredVia,
                        idempotencyKey: ackIdempotencyKey
                    )
                    #if DEBUG
                    print("⚠️ [App] Failed to sync mesh ACK to server, queued for retry: \(error)")
                    #endif
                }
            } else {
                try? await PendingACKRepository.shared.add(
                    clientMessageId: ack.originalMessageId,
                    deliveredVia: deliveredVia,
                    pathUsed: deliveredVia,
                    idempotencyKey: ackIdempotencyKey
                )
                #if DEBUG
                print("📥 [App] Offline - queued mesh ACK for server sync")
                #endif
            }
        }
        
        #if DEBUG
        print("✅ [App] Message \(ack.originalMessageId.prefix(8)) marked as \(newStatus.rawValue)")
        #endif
    }
}
