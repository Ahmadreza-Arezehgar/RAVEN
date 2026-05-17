import SwiftUI
import UserNotifications
import GoogleSignIn
#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

// 🍏 Mac-only command notifications — bridge the menu-bar shortcuts into
// SwiftUI views. iOS doesn't post these (no menu bar), so subscribers
// can listen without platform guards.
extension Notification.Name {
    static let ravenNewMessage = Notification.Name("ravenNewMessage")
    static let ravenOpenBackgroundMesh = Notification.Name("ravenOpenBackgroundMesh")
}


@main
struct RAVENApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appSettings = AppSettings.shared
    @State private var languageManager = AppLanguageManager.shared

    // ─────────────────────────────────────────────────────────────────
    // 🍏 Mac mesh-daemon mode
    // ─────────────────────────────────────────────────────────────────
    // When the LaunchAgent starts RAVEN with `--mesh-daemon`, we run a
    // headless WindowGroup that DOES NOT open a window — it just keeps
    // the BLE engine + WebSocket alive so the mesh stays bridged while
    // the user has the GUI app closed.
    //
    // On iOS / Catalyst foreground launches (no flag), this is `false`
    // and the normal UI scene runs.
    private static let isMeshDaemonMode: Bool = {
        #if targetEnvironment(macCatalyst)
        return CommandLine.arguments.contains("--mesh-daemon")
        #else
        return false
        #endif
    }()

    // ─────────────────────────────────────────────────────────────────
    // Root content
    // ─────────────────────────────────────────────────────────────────
    // Single-rooted view that the modifier chain in `body` attaches to.
    // Splitting the platform branches across `#if/#else` directly inside
    // the modifier chain breaks Swift's type inference (each branch
    // produces a different opaque `View`), so we resolve it here.
    @ViewBuilder
    private var rootContent: some View {
        #if targetEnvironment(macCatalyst)
        if Self.isMeshDaemonMode {
            // Headless daemon mode — keep BLE + WebSocket alive without
            // ever showing UI. A 1×1 Color.clear is enough to satisfy
            // WindowGroup; the LaunchAgent hides the dock icon via Info.plist.
            Color.clear.frame(width: 1, height: 1)
        } else {
            AuthGateView()
        }
        #else
        AuthGateView()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // Single-rooted view so the modifier chain below applies cleanly
            // on both platforms. The Catalyst branch handles daemon mode
            // (1×1 hidden window) and the post-auth shell dispatch lives
            // inside AuthGateView itself.
            rootContent
                .preferredColorScheme(appSettings.preferredColorScheme)
                .dynamicTypeSize(appSettings.dynamicTypeSize)  // Global text scaling
                .environment(\.layoutDirection, languageManager.layoutDirection)
                .environment(\.locale, languageManager.locale)
                .withToastSupport()
                .withAppLock()  // App Lock - requires auth when enabled
                // Background mesh onboarding moved to MainShellView (after login/setup complete)
                // Screenshot protection removed from root - will be applied per-view
                .handleDeepLinks()
                // 🍎 BUG FIX (2026-05-10): wire NSUserActivity handlers
                // for the activity types declared in Info.plist
                // (`INSendMessageIntent`, `INStartCallIntent`). Without
                // these, Siri-suggested message intents and Handoff
                // continuations are dropped and iOS 26 logs
                // "no handler registered" on every launch.
                .onContinueUserActivity("INSendMessageIntent") { activity in
                    // Forward to the router via the existing URL handler.
                    // Siri's INSendMessageIntent attaches the conversation
                    // identifier as `userInfo["conversationIdentifier"]`.
                    if let convo = activity.userInfo?["conversationIdentifier"] as? String,
                       let url = URL(string: "raven://room/\(convo)") {
                        DeepLinkRouter.shared.handleURL(url)
                    }
                }
                .onContinueUserActivity("INStartCallIntent") { _ in
                    // Calling is not implemented yet — log so we know
                    // when the activity arrives, but don't crash.
                    #if DEBUG
                    print("📞 [App] INStartCallIntent received — call feature not yet implemented")
                    #endif
                }
                // Universal links / Handoff fallback for unknown activity types
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        DeepLinkRouter.shared.handleURL(url)
                    }
                }
                .task {
                    // v1.6 self-tests — verify the new cryptographic
                    // surfaces still work end-to-end on this device.
                    // PASS/FAIL appears once per launch in the console;
                    // a regression in the cryptographic boundary surfaces
                    // immediately rather than at user-facing fail time.
                    #if DEBUG
                    KeyBackupService.runDebugSelfTest()
                    SealedSenderEnvelope.runDebugSelfTest()
                    await OPAQUEService.runDebugSelfTest()
                    await MeshGatewayService.runDebugSelfTest()
                    SecretKey.runDebugSelfTest()
                    DoubleAEAD.runDebugSelfTest()
                    IdentityRotationService.runDebugSelfTest()
                    #endif

                    // Identity rotation: bootstrap the 180-day timer
                    // and check on every launch whether we're due. The
                    // first launch records "now" as the baseline so a
                    // fresh install doesn't immediately rotate.
                    IdentityRotationService.shared.bootstrap()
                    _ = await IdentityRotationService.shared.rotateIfDue()

                    // Bootstrap the Mesh-to-Internet Gateway service.
                    // No-op until the user toggles Helper Mode on in
                    // Settings; the bootstrap call only registers
                    // observers + starts the score-tick timer.
                    MeshGatewayService.shared.bootstrap()

                    // 🖼️ Avatar disk cache: prune past 100 MB cap so
                    // long-running installs don't bloat. Cheap walk
                    // of `Documents/avatars/`. Not awaited — fire and
                    // forget; the actor serialises any concurrent
                    // image() reads against this.
                    Task { await AvatarCacheService.shared.prune() }

                    // Request push permissions on app start
                    let granted = await PushNotificationService.shared.requestAuthorization()
                    #if DEBUG
                    print("🔔 [App] Push authorization: \(granted ? "GRANTED" : "DENIED")")
                    #endif

                    // Retry sending stored token to server (in case previous attempt failed)
                    if granted {
                        await PushNotificationService.shared.retryTokenRegistration()
                    }

                    // 🆕 Multi-device: register / refresh this device in the
                    // server's linked-devices registry. Best-effort — swallows
                    // network failures; the user just won't see this device
                    // listed in Settings until next launch.
                    if AuthService.shared.isAuthenticated {
                        _ = await LinkedDevicesService.shared.heartbeat()

                        // 🔐 Upload our Ed25519 identity public key so the
                        // server can verify signatures we produce (currently
                        // used by the desktop QR-login flow — see
                        // `Features/QRCode/DesktopLoginApprovalView.swift`).
                        // Idempotent: server returns `unchanged` if the key
                        // matches what's already registered. Best-effort —
                        // a failure here just means the user can't approve
                        // a desktop login until the next launch.
                        if let pub = DeviceIdentityService.shared.publicKeyBase64 {
                            do {
                                let resp = try await NetworkService.shared.uploadIdentityKey(publicKeyBase64: pub)
                                #if DEBUG
                                print("🔐 [App] Identity key upload: \(resp.status)")
                                #endif
                            } catch {
                                #if DEBUG
                                print("⚠️ [App] Identity key upload failed: \(error.localizedDescription)")
                                #endif
                            }
                        }
                    }

                    // 🩻 MetricKit diagnostics — subscribes to Apple's daily
                    // batch of crash/hang/CPU/disk reports and forwards them
                    // to /api/diagnostics. No external SDK; on-device cost.
                    DiagnosticsService.shared.start()
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
        // 🍏 Mac-only window chrome: sane default size, content-min resizing,
        // unified glass title bar (macOS 26 convention). The modifiers are
        // gated so iOS still gets the original full-screen single-window UX.
        #if targetEnvironment(macCatalyst)
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            // Replace iOS-style "New" with a Mac-friendly "New Message" command
            CommandGroup(replacing: .newItem) {
                Button("New Message") {
                    NotificationCenter.default.post(name: .ravenNewMessage, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            // Sidebar navigation toggle (⌘\ — Mac convention)
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Background Mesh") {
                    NotificationCenter.default.post(name: .ravenOpenBackgroundMesh, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
        #endif
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
        let memoryCapacity = 100 * 1024 * 1024 // 100 MB — prevents image eviction during active use
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

        // 🔔 BUG FIX (2026-05-10): register for remote notifications
        // SYNCHRONOUSLY here, before `didFinishLaunching` returns.
        // The previous version did this from a `.task { ... }` on
        // the root WindowGroup — by the time we asked for the token,
        // iOS had already forwarded any cold-launch silent-push
        // payload, and on iOS 26 with provisional auth the first
        // foreground delivery was dropped. Calling
        // `registerForRemoteNotifications` here means
        // `didRegisterForRemoteNotificationsWithDeviceToken` fires
        // before the cold-launch push handlers run.
        // The user-facing `requestAuthorization()` prompt (the alert)
        // still happens later from the `.task {}` because it requires
        // user interaction and shouldn't block app launch.
        UIApplication.shared.registerForRemoteNotifications()
        
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
        // Database init stays async in a Task below. DatabaseService uses
        // ensureInitialized() which lazy-inits on first access, so BLE message
        // handlers will trigger DB init on their first write — no messages are lost.
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

                // 🔐 E2EE bootstrap — wires the pre-key bundle provider,
                // publishes our public bundle on first launch, and tops
                // up the server-side OPK pool. Idempotent + non-fatal:
                // failures only mean E2EE stays gated by its feature
                // flag (`E2EEMessageGateway.isEnabled`).
                Task.detached(priority: .utility) {
                    await E2EEBootstrap.shared.runIfNeeded()
                }
                
                #if !targetEnvironment(simulator)
                await MeshPostSyncWorker.shared.startMonitoring()
                #endif
                
                #if DEBUG
                print("📡 [App] Database & mesh sync ready ✅")
                #endif
                
                // 🚀 Pre-warm FeedStore cache — triggers eager SQLite read
                // so cached posts are in memory BEFORE FeedView appears.
                // This access creates the singleton which fires warmCacheOnStartup().
                await MainActor.run { _ = FeedStore.shared }
                #if DEBUG
                print("🚀 [App] FeedStore cache pre-warmed ✅")
                #endif
                
                // 🌐 Register mesh-native feature handlers (Echo, Club, Vault)
                await MainActor.run {
                    EchoService.shared.registerMeshHandlers()
                    ClubService.shared.registerMeshHandlers()
                    VaultService.shared.registerMeshHandlers()
                }
                // Restore active Club session if any
                await ClubService.shared.restoreActiveSession()
                #if DEBUG
                print("🌐 [App] Mesh feature handlers registered ✅")
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
        
        // ⚡ Warmup: Pre-establish TLS + TCP on the SHARED NetworkService session,
        // so the first real API call (auth check / feed fetch) skips the ~150-300ms
        // handshake. Fires immediately at launch — runs in parallel with the rest
        // of init since networking is I/O-bound. Best-effort.
        Task.detached(priority: .utility) {
            await NetworkService.shared.warmConnection()
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
    
    #if !targetEnvironment(macCatalyst)
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // BUG FIX (2026-05-10): the previous version awaited
        // `handlePushReceived` (which can do a full server sync, >30 s
        // on slow networks) BEFORE calling `completionHandler`. iOS
        // gives ~30 s for silent-push handlers to complete; if we go
        // over, the system records a non-completion against the bundle
        // id and starts throttling future silent pushes. Worse, if
        // `handlePushReceived` ever threw / hung, the completion
        // handler was never called at all.
        //
        // Now: report `.newData` immediately so iOS marks the silent
        // push as handled, then continue the heavy work in a separate
        // detached task that's free to run as long as it needs.
        completionHandler(.newData)
        let appState = application.applicationState
        Task.detached(priority: .userInitiated) {
            await PushNotificationService.shared.handlePushReceived(
                userInfo,
                appState: appState
            )
        }
    }
    #endif
    
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
        
        // ⚡ DUPLICATE FIX: Always suppress the system banner while the app
        // is in foreground. Our in-app `LiquidToastView` (driven by
        // NotificationPipeline) is the canonical foreground UX — showing
        // BOTH the iOS banner AND the in-app toast for the same message
        // produced two notifications for one event. Standard messenger
        // behaviour (WhatsApp, Telegram, Signal) is foreground-app =
        // in-app banner only. The system banner only fires when the app
        // is backgrounded / locked, where there's no in-app surface.
        // The badge is still updated here so the bell count stays correct.
        #if DEBUG
        print("🔔 [AppDelegate] Foreground push → suppressing system banner (in-app toast handles it)")
        #endif
        completionHandler([.badge])
    }
    
    // Notification tap handler (including lock screen action responses)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        
        #if DEBUG
        print("🔔 [AppDelegate] didReceive action: \(actionId)")
        #endif
        
        switch actionId {
        // ── Lock Screen Quick Reply ──
        case "REPLY":
            guard let textResponse = response as? UNTextInputNotificationResponse else {
                completionHandler()
                return
            }
            let replyText = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replyText.isEmpty else {
                completionHandler()
                return
            }
            
            // Determine destination: room_id for messages, post_id for comment replies
            let roomId = userInfo["room_id"] as? String ?? userInfo["chat_id"] as? String ?? userInfo["group_id"] as? String
            let senderId = userInfo["sender_id"] as? String
            let notifType = userInfo["type"] as? String
            
            Task {
                do {
                    if notifType == "comment" || notifType == "post_comment" {
                        // Comment reply — post a comment on the post
                        if let postId = userInfo["post_id"] as? String {
                            struct CommentBody: Encodable { let content: String }
                            struct CommentResp: Decodable { let id: String }
                            let _: CommentResp = try await NetworkService.shared.post(
                                path: "/api/posts/\(postId)/comment",
                                body: CommentBody(content: replyText)
                            )
                            #if DEBUG
                            print("✅ [LockScreen] Comment reply sent to post \(postId.prefix(8))")
                            #endif
                        }
                    } else if let roomId = roomId {
                        // Message reply — send via MessageService
                        // For groups, send to roomId (group ID); for 1:1, send to senderId
                        let isGroup = notifType == "group_message"
                        let destinationId = isGroup ? roomId : (senderId ?? roomId)
                        try await MessageService.shared.sendText(
                            to: destinationId,
                            text: replyText,
                            isGroup: isGroup
                        )
                        #if DEBUG
                        print("✅ [LockScreen] Quick reply sent to \(destinationId.prefix(8))")
                        #endif
                    }
                } catch {
                    #if DEBUG
                    print("❌ [LockScreen] Quick reply failed: \(error)")
                    #endif
                }
                completionHandler()
            }
            return
            
        // ── Accept Friend Request ──
        case "ACCEPT":
            let requestId = userInfo["requester_id"] as? String ?? userInfo["sender_id"] as? String ?? userInfo["request_id"] as? String
            guard let requestId = requestId else {
                completionHandler()
                return
            }
            Task {
                do {
                    struct EmptyBody: Encodable {}
                    let _: Empty = try await NetworkService.shared.post(
                        path: "/api/users/friend-request/\(requestId)/accept",
                        body: EmptyBody()
                    )
                    #if DEBUG
                    print("✅ [LockScreen] Friend request accepted: \(requestId.prefix(8))")
                    #endif
                } catch {
                    #if DEBUG
                    print("❌ [LockScreen] Accept friend request failed: \(error)")
                    #endif
                }
                completionHandler()
            }
            return
            
        // ── Decline Friend Request ──
        case "DECLINE":
            let requestId = userInfo["requester_id"] as? String ?? userInfo["sender_id"] as? String ?? userInfo["request_id"] as? String
            guard let requestId = requestId else {
                completionHandler()
                return
            }
            Task {
                do {
                    struct EmptyBody: Encodable {}
                    let _: Empty = try await NetworkService.shared.post(
                        path: "/api/users/friend-request/\(requestId)/decline",
                        body: EmptyBody()
                    )
                    #if DEBUG
                    print("✅ [LockScreen] Friend request declined: \(requestId.prefix(8))")
                    #endif
                } catch {
                    #if DEBUG
                    print("❌ [LockScreen] Decline friend request failed: \(error)")
                    #endif
                }
                completionHandler()
            }
            return
            
        // ── Mark as Read ──
        case "MARK_READ":
            Task {
                if let roomId = userInfo["room_id"] as? String ?? userInfo["chat_id"] as? String {
                    await PendingReadService.shared.enqueue(type: "message", targetId: roomId, isAll: false)
                }
                completionHandler()
            }
            return
            
        // ── View Post / Join Audio Room ──
        case "VIEW":
            Task { @MainActor in
                if let postId = userInfo["post_id"] as? String {
                    DeepLinkRouter.shared.route(to: .post(postId: postId))
                }
                completionHandler()
            }
            return

        case "JOIN":
            Task { @MainActor in
                if let roomId = userInfo["room_id"] as? String {
                    DeepLinkRouter.shared.route(to: .audioRoom(slug: roomId))
                }
                completionHandler()
            }
            return
            
        default:
            // Default tap (UNNotificationDefaultActionIdentifier) — navigate as before
            Task {
                await PushNotificationService.shared.handlePushTap(userInfo)
                completionHandler()
            }
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
            // ⚡ BUG 2 FIX: Only bridge to server when we have an EXPLICIT
            // non-group signal (`envelope.isGroup == false`). When the flag is
            // missing/nil — older client that didn't set it — the recipientId
            // could actually be an unsynced group. Bridging it as a 1:1 would
            // cause the server to reject (no such 1:1 thread) AND we'd never
            // limbo-store it for the later group sync. Skip the bridge in that
            // case; mesh relay continues to handle propagation.
            let canSafelyBridgeAs1to1 = (envelope.isGroup == false)
            if NetworkMonitor.shared.isOnline && canSafelyBridgeAs1to1 {
                #if DEBUG
                print("🌉 [BRIDGE] We're online! Forwarding mesh 1:1 message to server for recipient...")
                #endif
                await BLEMeshEngine.shared.bridgeMeshMessageToServer(envelope)
            } else if NetworkMonitor.shared.isOnline {
                #if DEBUG
                print("🚫 [BRIDGE] Skip server bridge — envelope.isGroup is \(envelope.isGroup.map(String.init) ?? "nil"); mesh relay only")
                #endif
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

        // 🔐 Per-group AES-GCM decryption — when the sender stamped a
        // groupKeyVersion, the text field is ciphertext. We pull the right
        // version of the group key from GroupKeyService and decrypt before
        // any further processing (DB write, conversation update, UI).
        if let version = envelope.groupKeyVersion,
           isGroupMessage,
           let cipher = envelope.text,
           !cipher.isEmpty {
            // 🔐 Forward-secrecy guard: if a peer is broadcasting under a
            // version newer than what we have cached locally, the server
            // must have rotated. Refresh our `latest` pointer so the very
            // next OUTGOING encrypt uses the new key (preventing us from
            // continuing to encrypt with a stale key that a kicked member
            // might still hold).
            await GroupKeyService.shared.ensureNotStale(
                groupId: envelope.recipientId, serverVersion: version
            )
            let plaintext = await GroupKeyService.shared.decrypt(
                cipher, groupId: envelope.recipientId, version: version
            )
            if let plaintext = plaintext {
                message.text = plaintext
            } else {
                #if DEBUG
                print("⚠️ [MESH] Could not decrypt group payload (\(envelope.recipientId.prefix(8)) v\(version)) — leaving ciphertext")
                #endif
            }
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
            // ⚡ BUG FIX 1: Pass isGroup hint so mesh-delivered group messages route to
            // groupId even if the local groups row hasn't synced yet. Without this,
            // a duplicate would appear once the group syncs and old messages
            // re-applied.
            try await conversationRepo.applyMessage(message, currentUserId: currentUserId, isGroup: isGroupMessage)
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
        // For groups: roomId = groupId (envelope.recipientId is authoritative).
        // For 1:1: roomId = senderId (peer's ID).
        // ⚡ BUG FIX 4: Don't fall back to senderId for groups — that would
        // route the toast/notification tap to the sender's 1:1 chat instead
        // of the group. envelope.recipientId is the groupId for group messages.
        let roomId = isGroupMessage ? envelope.recipientId : message.senderId
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
        
        // Type-aware preview ("📷 Photo", "🎤 Voice message · 12s",
        // file names with caption, etc.) Centralised so APNs +
        // mesh + in-app toasts all show consistent strings — see
        // MessagePreviewFormatter.swift for the type matrix.
        let safePreview = MessagePreviewFormatter.format(message: message)
        
        if appState == .active {
            // App is in foreground - show toast notification IF we
            // are the first delivery channel to see this message.
            //
            // 🔴 Bug fix (2026-05-09): the same message could arrive
            // via mesh AND server (or via APNs background → in-app
            // foreground when the user opens the app), producing two
            // in-app banners for one event. Centralised dedup uses
            // `NotificationDedupCache.claim(messageId:)` — the first
            // path to claim shows the banner, the others silently skip.
            let firstToShow = await NotificationDedupCache.shared.claim(messageId: message.id)
            guard firstToShow else {
                #if DEBUG
                print("📵 [Notif] Skipping mesh in-app toast for \(message.id.prefix(8)) — already shown")
                #endif
                return
            }
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
            // 🔁 Dedup with the APNs path. If the same message already
            // arrived via a server push and iOS displayed that alert,
            // we skip the mesh-side local notification — otherwise the
            // user gets two banners for one message (the original
            // user-reported bug).
            let firstToShow = await NotificationDedupCache.shared.claim(messageId: message.id)
            guard firstToShow else {
                #if DEBUG
                print("📵 [Notif] Skipping mesh local-notif for \(message.id.prefix(8)) — APNs already showed it")
                #endif
                return
            }

            // ALWAYS fire local notification for Mesh Messages to guarantee Lock Screen delivery
            let content = UNMutableNotificationContent()
            content.title = safeSenderName

            // 🔒 Privacy: Respect user's message preview setting (default: true)
            let showPreview = UserDefaults.standard.object(forKey: "messagePreview") as? Bool ?? true
            content.body = showPreview ? safePreview : "New Message"

            content.sound = .default
            content.threadIdentifier = roomId
            // 🔴 Bug fix (2026-05-09): mesh-delivered messages were
            // missing the lock-screen "Reply" action because we never
            // set `categoryIdentifier`. APNs-delivered messages had it
            // (server sets `aps.category = "MESSAGE"`), but for mesh we
            // construct the content locally and forgot the category.
            // Without it, iOS shows no action buttons on the lock screen
            // — smart reply silently does nothing.
            content.categoryIdentifier = "MESSAGE"
            // Pass the keys the REPLY handler in `didReceive` reads.
            // It looks at `room_id` / `chat_id` / `group_id` and
            // `sender_id` — so we use snake_case here too, matching
            // what the APNs server payload sends.
            content.userInfo = [
                "room_id": roomId,
                "chat_id": roomId,
                "type": isGroupMessage ? "group_message" : "message",
                "sender_id": message.senderId,
                "message_id": message.id
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
