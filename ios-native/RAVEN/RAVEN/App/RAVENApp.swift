import SwiftUI
import UserNotifications
import GoogleSignIn
import CryptoKit
import os
#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

fileprivate let logger = Logger(subsystem: "app.raven.ios", category: "App")

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
                // Round 13 (2026-05-16) — hacker-audit S8: cover
                // the window with a branded splash whenever the
                // scene leaves .active so the iOS app-switcher
                // snapshot (saved to disk + included in encrypted
                // backups) never captures chat content, vault
                // documents, or recovery codes.
                .snapshotProtected()
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

                    // Round 24 — drain any QR friend-requests the
                    // user queued while offline. Hooks
                    // .networkStatusChanged so the actor's flush()
                    // fires the moment connectivity returns; if
                    // we're online at install time it also flushes
                    // immediately.
                    PendingFriendRequestQueue.shared.startObservingConnectivity()

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

                        // 🔴 v1.8 — App Attest device enrolment. Silent,
                        // best-effort, runs once; no-ops when already
                        // enrolled or unsupported (Simulator / old devices).
                        AppAttestService.shared.enrolIfNeeded()
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
                        // 🔴 v1.8 — App Attest enrolment on fresh login.
                        AppAttestService.shared.enrolIfNeeded()
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

    /// Round 16 (audit N8): validate that a server-supplied
    /// identifier is a well-formed UUID before letting it through
    /// to an authenticated mutation. Stops a spoofed APNs payload
    /// from smuggling a path-traversal or SQL fragment into a
    /// `/api/users/friend-request/{id}/accept`-style URL.
    static func isValidUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

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

        // 🔴 ROUND 70 (2026-05-23) — hacker-audit BACKUP-CRIT-1.
        // Launch-time prune of any vault-decrypted plaintext / video-
        // compression / multipart-upload tmp files left over from a
        // previous run that crashed or was killed before its `defer
        // { removeItem }` could fire. The VaultPayloadResolver writes
        // decrypted plaintext to `tmp/<uuid>_<stem>.<ext>` with
        // `.completeFileProtection` — but those files persist across
        // app restarts. A forensic attacker with a snapshot of the
        // device filesystem (or someone who briefly gets the unlocked
        // device) can recover them until iOS's own opportunistic
        // tmp/ GC runs.
        Self.pruneTemporaryDirectory()

        // 🔴 ROUND 70 (2026-05-23) — hacker-audit BACKUP-CRIT-2.
        // PeerKeyDirectory pinned identity keys + the entire peer-
        // userId social graph live in `UserDefaults.standard`, which
        // serializes to `Library/Preferences/<bundle>.plist` with
        // the default protection class. iCloud / iTunes backups of
        // a locked device exposed every pinned X25519 + Ed25519
        // identity key + the full set of userIds the device has
        // ever messaged. Fix: set `.complete` protection on the
        // preferences plist itself so a locked-device backup carries
        // an unreadable blob there.
        Self.hardenPreferencesPlistProtection()

        // 🔬 Crypto end-to-end self-test (DEBUG only).
        //
        // Runs the FULL stack — raw Noise IK handshake, two-store
        // session handoff, and the sealer wire format — against
        // a fresh ephemeral identity pair, then logs one line:
        //   "L1(raw-noise)=PASS | L2(two-store)=PASS | L3(sealer-wire)=PASS"
        //
        // If any layer reports FAIL we have a kernel bug independent
        // of cross-device staleness; if all three PASS the
        // user-reported decrypt loop has to be deployment/state asymmetry
        // (FriendDeviceRepository stale pin, etc.) rather than a
        // crypto kernel regression.  Either way, the test runs in
        // ~milliseconds and the log line is grep-able after launch.
        #if DEBUG
        NoiseSessionStore.runEndToEndSelfTest()
        #endif

        // 🟥 ROUND 33 (2026-05-17) — auto-publish the device's
        // ATSAM bundle so peers can fetch our X25519 agreement
        // key from `/api/atsam/prekey/{userId}`.  Before this
        // round nobody published unless they manually visited a
        // hidden Settings screen, so:
        //   • All text messages silently degraded to RVNP1
        //     plaintext on the wire (E2EE was effectively off).
        //   • Vault sends bounced with "Vault couldn't get the
        //     recipient's encryption key" because the receiver
        //     bundle came back HTTP 404.
        //
        // Fire-and-forget on a detached Task so launch isn't
        // blocked on the network round-trip; idempotent + throttled
        // inside `autoPublishIfNeeded`.  The 2 s delay gives
        // DeviceIdentityService time to async-load its keys from
        // the Keychain so we don't fire before `agreementPublicKeyData`
        // is populated (would skip-and-give-up otherwise).
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await ATSAMPrekeyService.autoPublishIfNeeded()
            // Belt-and-suspenders: retry once more after 30 s so a
            // slow Keychain unlock / cold-launch login flow has a
            // second chance to land the publish.  The throttle
            // inside `autoPublishIfNeeded` makes this a no-op once
            // the first call succeeded.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await ATSAMPrekeyService.autoPublishIfNeeded()
        }

        // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — eager-touch
        // GroupService so its init-time NetworkMonitor observer is
        // wired BEFORE the first networkStatusChanged event fires.
        //
        // Without this, the observer would only attach the first
        // time some screen touches `GroupService.shared` (e.g. open
        // the inbox, open the member picker). If the user toggled
        // airplane mode before any such screen had been opened,
        // pending offline-created groups never auto-reconciled and
        // group send failed with 404 ("Group not found") because
        // the server still didn't know the local UUID.
        //
        // Touching `.shared` here forces `init()` which installs
        // the observer (see GroupService.setupNetworkObserver) +
        // also drains anything queued from a previous session.
        _ = GroupService.shared
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard NetworkMonitor.shared.isOnline else { return }
            await GroupService.shared.syncPendingGroups()
        }

        // 🟥 ROUND 40 (2026-05-17) — pre-warm the friends cache.
        //
        // User report: "friend list bayad be sorat offline lad
        // beshe vaghty ke internet nist" — friend list should load
        // offline when there's no internet.
        //
        // Without this round, the friends list was only fetched
        // the FIRST TIME the user opened NewChatView / member
        // picker WHILE ONLINE.  If the user went offline before
        // ever opening that picker, the cache was empty and they
        // saw "You're offline. Connect to the internet to load
        // your friends list" — even though their friends had been
        // available on the server moments earlier.
        //
        // Fix: kick off a friends fetch from app launch (when we
        // have a chance of being online).  `GroupService.fetchFriends`
        // writes to UserDefaults (`raven_friends_cache`) on
        // success, so the next time the user opens NewChatView,
        // even offline, the cache is hot.  Fire-and-forget on a
        // detached Task; silently swallows offline-at-launch.  3 s
        // delay rides out the cold-launch network bring-up.
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard NetworkMonitor.shared.isOnline else {
                NSLog("👫 [FriendsCache] skipped pre-warm — offline at launch.")
                return
            }
            do {
                let friends = try await GroupService.shared.fetchFriends()
                NSLog("👫 [FriendsCache] pre-warmed %d friends at app launch.", friends.count)
            } catch {
                NSLog("👫 [FriendsCache] pre-warm failed: %@ — cache stays as-is.", error.localizedDescription)
            }
        }

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

                logger.debug("Device identity initialized: \(DeviceIdentityService.shared.fingerprint ?? "generating...", privacy: .private)")

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
    
    // MARK: - Quick Actions (home-screen long-press shortcuts)
    //
    // (2026-05-15 — round 7) iOS surfaces the four shortcuts declared
    // in `Info.plist`'s `UIApplicationShortcutItems` when the user
    // long-presses the app icon. We route each one through the same
    // `DeepLinkRouter` paths the in-app navigation uses, so the
    // tap from the home screen lands the user on exactly the same
    // screen as the equivalent in-app flow.
    //
    // Cold start (`launchOptions[.shortcutItem]`) is forwarded by
    // SceneKit through this hook too, so we don't need a separate
    // launch-options branch.
    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let handled = handleShortcut(shortcutItem)
        completionHandler(handled)
    }

    @discardableResult
    fileprivate func handleShortcut(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        // Soft impact gives the user tactile confirmation that the
        // long-press → tap registered. Mirrors what Maps / Notes do.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        switch shortcutItem.type {
        case "app.raven.shortcut.newMessage":
            // Open the inbox tab and surface the New Chat composer.
            DeepLinkRouter.shared.navigate(to: .newMessage)
            return true
        case "app.raven.shortcut.newPost":
            DeepLinkRouter.shared.navigate(to: .newPost)
            return true
        case "app.raven.shortcut.search":
            DeepLinkRouter.shared.navigate(to: .search)
            return true
        case "app.raven.shortcut.voiceNote":
            DeepLinkRouter.shared.navigate(to: .voiceNote)
            return true
        default:
            #if DEBUG
            print("[Shortcut] Unknown shortcut: \(shortcutItem.type)")
            #endif
            return false
        }
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

        // (2026-05-15 — round 8) Share Extension hand-off. The
        // extension writes its manifest into the App Group container
        // and opens `raven://share/v1?source=extension` to wake the
        // host app. Read the manifest, drop the user into the
        // recipient picker via a NotificationCenter signal — the
        // chat surface picks it up the same way it handles deep
        // links.
        if url.scheme == "raven" && url.host == "share" {
            handleSharedPayload()
            return true
        }

        // Handle deep links
        DeepLinkRouter.shared.handleURL(url)
        return true
    }

    /// Drains the App Group container the Share Extension wrote and
    /// fans the manifest out via NotificationCenter. The chat surface
    /// listens for `.ravenShareIncoming` and presents the recipient
    /// picker (same picker the in-app forward flow already uses).
    ///
    /// Round 14 (2026-05-16) — hacker-audit finding N4 hardening:
    /// the App Group container is technically writable by any process
    /// holding the `group.app.raven.shared` entitlement. On a
    /// non-jailbroken iOS Apple only grants App Group ownership to
    /// the registered team, so a third-party app cannot legitimately
    /// claim this group — but we still defend in depth:
    ///
    ///   1. **Schema strict-validation** — reject any manifest that
    ///      doesn't carry `version: 1` and the expected key set.
    ///      A queued malicious dictionary from an older or future
    ///      attacker payload fails fast.
    ///   2. **Freshness window** — reject payloads whose
    ///      `createdAt` is more than 30 s old. An attacker who
    ///      writes a manifest hours earlier (waiting for the user
    ///      to eventually open the URL) is locked out.
    ///   3. **Path containment** — every `path` in the manifest
    ///      must resolve inside the App Group container. A
    ///      malicious manifest pointing at `~/Library` or `/etc` is
    ///      rejected.
    ///   4. **One-time consumption** — the payload is removed
    ///      before broadcast (already done), so a second open of
    ///      the deep-link is a no-op.
    ///
    /// RESIDUAL GAP (deferred to round 15): the only way to
    /// fully bind the manifest write to the URL open is a shared
    /// Keychain HMAC — both targets sign with a key only they can
    /// read. That needs `keychain-access-groups` entitlements on
    /// both targets and a re-provisioning round.
    fileprivate func handleSharedPayload() {
        let appGroup = "group.app.raven.shared"
        let key = "raven.pendingShare.v1"
        guard let defaults = UserDefaults(suiteName: appGroup),
              let payload = defaults.dictionary(forKey: key) else {
            #if DEBUG
            print("[Share] No pending payload in App Group container.")
            #endif
            return
        }
        // Always clear the payload immediately — even if validation
        // fails — so a malformed entry can't accumulate or be re-
        // tried on subsequent opens.
        defaults.removeObject(forKey: key)
        defaults.synchronize()

        // 1. Schema check: required keys + expected version.
        guard let version = payload["version"] as? Int, version == 1 else {
            #if DEBUG
            print("⚠️ [Share] manifest version missing/unsupported — rejected.")
            #endif
            return
        }
        guard let createdAt = payload["createdAt"] as? TimeInterval else {
            #if DEBUG
            print("⚠️ [Share] manifest missing createdAt — rejected.")
            #endif
            return
        }

        // 2. Freshness window — 30 seconds is more than enough for
        // the Share Extension → openURL round-trip even on cold
        // launches. Anything older is suspect.
        let age = Date().timeIntervalSince1970 - createdAt
        if age < -2 || age > 30 {
            #if DEBUG
            print("⚠️ [Share] manifest age \(age)s outside freshness window — rejected.")
            #endif
            return
        }

        // 3. Path containment — every file path must resolve inside
        // the App Group container. The Share Extension always writes
        // to `<group>/PendingShare/`, so any path that doesn't
        // canonicalise into that prefix is foreign.
        if let containerBase = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        )?.standardizedFileURL.path,
           let items = payload["items"] as? [[String: String]] {
            for item in items {
                if let p = item["path"] {
                    let standardized = URL(fileURLWithPath: p).standardizedFileURL.path
                    if !standardized.hasPrefix(containerBase) {
                        #if DEBUG
                        print("⚠️ [Share] manifest item path escapes container (\(standardized)) — rejected.")
                        #endif
                        return
                    }
                }
            }
        }

        NotificationCenter.default.post(
            name: .ravenShareIncoming,
            object: nil,
            userInfo: payload
        )
        #if DEBUG
        let count = (payload["items"] as? [[String: String]])?.count ?? 0
        print("[Share] Drained \(count) item(s) from App Group; broadcasting .ravenShareIncoming.")
        #endif
    }
    
    // MARK: - Remote Notifications
    
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenHex = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        logger.debug("didRegisterForRemoteNotifications — token: \(tokenHex, privacy: .private) (\(tokenHex.count, privacy: .public) chars)")
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
            let rawId = userInfo["requester_id"] as? String ?? userInfo["sender_id"] as? String ?? userInfo["request_id"] as? String
            // Round 16 (audit N8): the push `userInfo` is server-
            // supplied and ultimately attacker-influenceable (spoofed
            // APNs, MITM during dev environment, etc.). Refuse to
            // invoke an authenticated mutation if the id is anything
            // other than a well-formed UUID. Stops a malicious push
            // that smuggles a path-traversal or SQL fragment into
            // the URL.
            guard let requestId = rawId, Self.isValidUUID(requestId) else {
                #if DEBUG
                print("⚠️ [LockScreen] ACCEPT rejected: missing/malformed request id.")
                #endif
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
            let rawId = userInfo["requester_id"] as? String ?? userInfo["sender_id"] as? String ?? userInfo["request_id"] as? String
            guard let requestId = rawId, Self.isValidUUID(requestId) else {
                #if DEBUG
                print("⚠️ [LockScreen] DECLINE rejected: missing/malformed request id.")
                #endif
                completionHandler()
                return
            }
            Task {
                do {
                    struct EmptyBody: Encodable {}
                    // 🟢 ROUND 75 (2026-05-24) — endpoint is `/reject`, not
                    // `/decline`. Lock-screen UNNotification action would
                    // 404 silently with the old path.
                    let _: Empty = try await NetworkService.shared.post(
                        path: "/api/users/friend-request/\(requestId)/reject",
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
        logger.debug("MESH myId=\(myId ?? "nil", privacy: .private) recipient=\(envelope.recipientId, privacy: .private) match=\(envelope.recipientId == myId, privacy: .public)")

        guard let myId = myId, !myId.isEmpty else {
            logger.debug("Cannot process mesh message - userId not loaded from Keychain!")
            return
        }

        // 🟦 ROUND 46 (2026-05-17) — group lifecycle event interception.
        //
        // BEFORE the normal "is this for me?" + recipient routing gate,
        // peek at `payloadKind`. If this envelope carries a group
        // lifecycle event (group_create / group_update / ...) we route
        // it to the dedicated `handleGroupSyncMeshMessage` handler,
        // which materializes the group locally + promotes any messages
        // parked in `PendingGroupMessageRepository`. We then RETURN —
        // the chat-message processing path below would otherwise try
        // to render the JSON payload as a system chat bubble.
        //
        // The diagnostic prologue here covers ALL incoming envelopes
        // so the debug log shows the discriminator for every receive.
        if let kind = envelope.payloadKind, !kind.isEmpty {
            #if DEBUG
            print("""
            🟦 [MESH-RX] payload.type=\(kind) message_id=\(envelope.clientMessageId.prefix(12)) \
            conversation_id=\(envelope.recipientId.prefix(8)) \
            conversation_type=\(envelope.isGroup == true ? "group" : "direct") \
            group_id=\(envelope.recipientId.prefix(8)) sender_id=\(envelope.senderId.prefix(8)) \
            receiver_id=\(myId.prefix(8))
            """)
            #endif
            if kind == "group_create" {
                await handleGroupSyncMeshMessage(envelope, myId: myId)
                return
            } else if kind == "friend_request" {
                // 🟦 ROUND 50 (2026-05-17) — offline mesh friend-add.
                await handleFriendRequestMeshMessage(envelope, myId: myId)
                return
            } else if kind == "group_key" {
                // 🟢 ROUND 74 (2026-05-24) — mesh group-key distribution.
                await handleGroupKeyMeshMessage(envelope, myId: myId)
                return
            } else if kind == "group_key_atsam" {
                // 🔐 ROUND 75 (2026-05-24) — per-recipient ATSAM-wrapped
                // group_key. Only the intended recipient can decrypt;
                // other peers in BLE range see opaque ciphertext.
                await handleGroupKeyATSAMMeshMessage(envelope, myId: myId)
                return
            } else {
                #if DEBUG
                print("🟦 [MESH-RX] Unknown payloadKind=\(kind) — ignoring envelope (forward-compat).")
                #endif
                return
            }
        }

        // Check if this is a group message (recipientId = groupId in groups table)
        // Bug 2 fix: Also use envelope.isGroup flag as fallback for groups not yet synced locally
        //
        // 🟢 ROUND 73 (2026-05-24) — third detector: `groupKeyVersion`
        // presence. The wire-side `groupKeyVersion` is set ONLY when the
        // body is AES-GCM-ciphertext under a per-group symmetric key —
        // 1:1 messages never set it (they use Double-Ratchet/ATSAM).
        // Without this, a legacy / older-client sender that emits a
        // group envelope without `envelope.isGroup=true` AND whose
        // receiver hasn't synced the group locally (`knownGroup==nil`)
        // got mis-classified as 1:1 → bridged as 1:1 to a group_id →
        // server 404 → local UI shows nothing. With this detector, the
        // receive pipeline correctly routes through the limbo +
        // group-decrypt branch and the bubble eventually renders once
        // the group syncs.
        let groupRepo = GroupRepository()
        let knownGroup = try? await groupRepo.get(groupId: envelope.recipientId)
        let isGroupMessage = knownGroup != nil
                          || (envelope.isGroup == true)
                          || (envelope.groupKeyVersion != nil)

        // 🟦 ROUND 46 (2026-05-17) — diagnostic for ALL chat-path mesh
        // receives. The user asked us to surface the routing decision
        // every time a payload arrives so they can confirm group
        // messages are landing in the right thread. Mirrors the
        // payload-kind prologue above for non-lifecycle traffic.
        #if DEBUG
        let knownGroupBeforeReceive = (knownGroup != nil)
        let displayThreadId: String = {
            if isGroupMessage { return envelope.recipientId }                 // groups
            if envelope.recipientId == myId { return envelope.senderId }      // 1:1 inbound
            return envelope.recipientId                                       // 1:1 outbound echo / relay
        }()
        print("""
        🟦 [MESH-RX] payload.type=message message_id=\(envelope.clientMessageId.prefix(12)) \
        conversation_id=\(envelope.recipientId.prefix(8)) \
        conversation_type=\(isGroupMessage ? "group" : "direct") \
        group_id=\(isGroupMessage ? envelope.recipientId.prefix(8) : "—") \
        sender_id=\(envelope.senderId.prefix(8)) receiver_id=\(myId.prefix(8)) \
        known_group_before_receive=\(knownGroupBeforeReceive) display_thread_id=\(displayThreadId.prefix(8))
        """)
        #endif

        // 🔴 ROUND 26 — legacy-peer detector.
        // Envelopes carrying `protocolVersion < 17` (or the default-16
        // back-compat value when the field is absent) come from a
        // RAVEN build that doesn't have the round-21+ sealer or the
        // round-26 transcript / mediaSealed bindings. Flag the sender
        // in `PeerProtocolCapabilityStore` so the chat surface drops
        // the orange "Older RAVEN" capsule banner. 1:1 only —
        // groups would need per-MEMBER tracking to distinguish which
        // member is downlevel; out of scope for this round.
        if !isGroupMessage,
           envelope.senderId != myId,
           envelope.protocolVersion < 17,
           !envelope.senderId.isEmpty {
            await PeerProtocolCapabilityStore.shared
                .record(.legacyClient, for: envelope.senderId)
        }
        
        guard envelope.recipientId == myId || isGroupMessage else {
            logger.debug("Message not for us (recipient: \(envelope.recipientId, privacy: .private), me: \(myId, privacy: .private)) - forwarding...")
            
            // BRIDGE: If we're online, forward to SERVER for the recipient
            // This is the key "offline sender → online bridge → server → online recipient" path
            // ⚡ BUG 2 FIX: Only bridge to server when we have an EXPLICIT
            // non-group signal (`envelope.isGroup == false`). When the flag is
            // missing/nil — older client that didn't set it — the recipientId
            // could actually be an unsynced group. Bridging it as a 1:1 would
            // cause the server to reject (no such 1:1 thread) AND we'd never
            // limbo-store it for the later group sync. Skip the bridge in that
            // case; mesh relay continues to handle propagation.
            //
            // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — the strict
            // gate above silently dropped every envelope with
            // `isGroup == nil`, which is the dominant cause of "bridge
            // never delivers in production" (mesh-relay only is hit-or-
            // miss when the offline recipient is one hop too far). The
            // gate broadens: treat `isGroup == nil` as 1:1 UNLESS we
            // actually know the recipient is a group (`knownGroup !=
            // nil`). Unknown-group envelopes still fall through to the
            // limbo path at line ~1197 because that branch keeps
            // `knownGroup == nil` semantics.
            let isExplicitGroup = (envelope.isGroup == true)
            let isKnownGroup = (knownGroup != nil)
            // 🟢 ROUND 72 (2026-05-24) — bridge stability: allow group
            // bridging from relayers.
            //
            // Previous gate ONLY bridged 1:1 envelopes (`canSafelyBridgeAs1to1`).
            // Explicit-group envelopes (`isGroup == true`) hit the "else if
            // isOnline" SKIP branch — meaning when a BLE-only sender's
            // group message hopped to an online relayer, the relayer
            // would NOT upload it to the server. The server-side fan-out
            // never ran, so internet-only group members never received
            // the message. The relayer's mesh re-broadcast was the only
            // delivery path, which is fragile in a sparse BLE cluster.
            //
            // Fix: also bridge group envelopes. The bridge function
            // (`bridgeMeshMessageToServer`) already supports groups via
            // `isGroup=true` + `groupId` in the request (server routes
            // through `_bridge_group_message` and fans out to every
            // member's WS push). Server idempotency on `client_message_id`
            // absorbs duplicate uploads when multiple relayers bridge
            // the same envelope.
            //
            // For UNKNOWN groups (`knownGroup == nil` but `isGroup ==
            // true`), still bridge — the server-side handler either
            // recognises the group_id (if it was created online) and
            // routes correctly, or 404s (offline-only group with
            // `local_*` id). The 404 is handled by the bridge's own
            // proxy-create branch when the bridger is a member; if
            // they're not, the 404 falls back gracefully and mesh
            // relay continues to propagate.
            let canSafelyBridgeAs1to1 = !isExplicitGroup && !isKnownGroup
            let canBridgeAsGroup = isExplicitGroup || isKnownGroup
            let canBridge = canSafelyBridgeAs1to1 || canBridgeAsGroup
            let isOnline = NetworkMonitor.shared.isOnline
            #if DEBUG
            print("🔍 [BRIDGE-GATE] mid=\(envelope.clientMessageId.prefix(8)) isOnline=\(isOnline) isGroup=\(envelope.isGroup.map(String.init) ?? "nil") knownGroup=\(isKnownGroup) canBridge1to1=\(canSafelyBridgeAs1to1) canBridgeGroup=\(canBridgeAsGroup) recipient=\(envelope.recipientId.prefix(8))")
            #endif
            if isOnline && canSafelyBridgeAs1to1 {
                #if DEBUG
                print("🌉 [BRIDGE] We're online! Forwarding mesh 1:1 message to server for recipient...")
                #endif
                let bridgeOK = await BLEMeshEngine.shared.bridgeMeshMessageToServer(envelope)
                #if DEBUG
                print("🌉 [BRIDGE-RESULT] mid=\(envelope.clientMessageId.prefix(8)) success=\(bridgeOK)")
                #endif
            } else if isOnline && canBridgeAsGroup {
                // 🟢 ROUND 72 — group bridge path. Ensure `isGroup=true`
                // is set on the envelope copy we hand to the bridge so
                // the server routes through `_bridge_group_message`
                // (otherwise it would default to 1:1 and the group
                // members fan-out never fires).
                var groupEnv = envelope
                groupEnv.isGroup = true
                #if DEBUG
                print("🌉 [BRIDGE] We're online! Forwarding mesh GROUP message to server for group \(envelope.recipientId.prefix(8))…")
                #endif
                let bridgeOK = await BLEMeshEngine.shared.bridgeMeshMessageToServer(groupEnv)
                #if DEBUG
                print("🌉 [BRIDGE-RESULT-GROUP] mid=\(envelope.clientMessageId.prefix(8)) success=\(bridgeOK)")
                #endif
            } else if isOnline {
                #if DEBUG
                print("🚫 [BRIDGE] Skip server bridge — gate prevented (isGroup=\(envelope.isGroup.map(String.init) ?? "nil"), canBridge=\(canBridge)); mesh relay only")
                #endif
            } else {
                #if DEBUG
                print("🚫 [BRIDGE] Skip server bridge — offline. Mesh relay continues.")
                #endif
            }

            // NOTE: Mesh relay is handled by BLEMeshEngine.processVerifiedEnvelope
            // Do NOT re-forward here — that causes double forwarding / amplification
            return
        }
        
        // Bug 2 fix: Group message for a group we don't know about yet → limbo
        if isGroupMessage && knownGroup == nil {
            logger.debug("Group \(envelope.recipientId, privacy: .private) not in local DB — storing in limbo for later sync")
            await PendingGroupMessageRepository.shared.store(envelope)

            // 🟢 ROUND 72 (2026-05-24) — bridge stability: if online,
            // ALSO upload to the server even though we can't display
            // locally yet. Rationale: an online recipient who lost
            // local group state (logout / fresh install / pre-sync)
            // still has the duty to propagate. The server fan-out
            // will then push to every OTHER member (1-hop) via WS
            // and APNs, so the group doesn't go silent just because
            // this one relayer hasn't reconciled state. Fire-and-
            // forget so the local limbo write doesn't get blocked
            // on a network round-trip.
            if NetworkMonitor.shared.isOnline {
                var groupEnv = envelope
                groupEnv.isGroup = true
                Task.detached(priority: .utility) {
                    let ok = await BLEMeshEngine.shared.bridgeMeshMessageToServer(groupEnv)
                    #if DEBUG
                    print("🌉 [BRIDGE-LIMBO] mid=\(envelope.clientMessageId.prefix(8)) groupId=\(envelope.recipientId.prefix(8)) success=\(ok)")
                    #endif
                }
            }
            return
        }

        logger.debug("Message IS for us. roomId=\(envelope.roomId, privacy: .private) senderId=\(envelope.senderId, privacy: .private) recipientId=\(envelope.recipientId, privacy: .private) senderName=\(envelope.senderName, privacy: .private)")

        // 🔴 ROUND 26 — hacker-audit Mesh F1 (CRITICAL).
        // Unseal the attachment metadata BEFORE we materialize a
        // ChatMessage. The seal helper re-populates the six legacy
        // fields (mediaUrl/thumbnailUrl/fileName/mimeType/fileSize/
        // audioDuration) on the envelope in place; the downstream
        // `fromMeshEnvelope` reads them as if they'd arrived in
        // cleartext (which is how pre-round-26 senders shipped them).
        var envelope = envelope

        // 🔴 ROUND 70 — strict-strip handshake. A round-70+ sender
        // sets senderId/recipientId to "" when the receiver is
        // confirmed `.modernATSAM` AND ships only the hashed tokens.
        // Resolve the real userIds via MeshIdentityResolver before
        // any downstream code reads `envelope.senderId`. If we can't
        // resolve (cold contact, hash never observed), fall back to
        // the empty string — the downstream contact-directory lookup
        // already handles unknown senders by showing a senderId
        // prefix, which is correct behaviour.
        if envelope.senderId.isEmpty, let hash = envelope.senderIdHash, !hash.isEmpty {
            if let resolved = await MeshIdentityResolver.shared.resolve(hash: hash) {
                envelope = MeshEnvelope(
                    protocolVersion: envelope.protocolVersion,
                    clientMessageId: envelope.clientMessageId,
                    roomId: envelope.roomId,
                    senderId: resolved,
                    senderName: envelope.senderName,
                    recipientId: envelope.recipientId,
                    type: envelope.type,
                    text: envelope.text,
                    timestamp: envelope.timestamp,
                    sprayCounter: envelope.sprayCounter,
                    hopCount: envelope.hopCount,
                    hopLimit: envelope.hopLimit,
                    routePath: envelope.routePath,
                    originDeviceId: envelope.originDeviceId,
                    needsForwarding: envelope.needsForwarding
                )
                envelope.senderIdHash = hash
                envelope.recipientIdHash = nil
                envelope.ttlSeconds = PremiumLimits.meshTTLSeconds
            }
        }
        if envelope.recipientId.isEmpty, let hash = envelope.recipientIdHash, !hash.isEmpty {
            if let resolved = await MeshIdentityResolver.shared.resolve(hash: hash) {
                // We rebuilt above if both were empty; recipientId
                // can still be empty after that. Re-stamp via a
                // fresh init.
                let prev = envelope
                envelope = MeshEnvelope(
                    protocolVersion: prev.protocolVersion,
                    clientMessageId: prev.clientMessageId,
                    roomId: prev.roomId,
                    senderId: prev.senderId,
                    senderName: prev.senderName,
                    recipientId: resolved,
                    type: prev.type,
                    text: prev.text,
                    timestamp: prev.timestamp,
                    sprayCounter: prev.sprayCounter,
                    hopCount: prev.hopCount,
                    hopLimit: prev.hopLimit,
                    routePath: prev.routePath,
                    originDeviceId: prev.originDeviceId,
                    needsForwarding: prev.needsForwarding
                )
                envelope.senderIdHash = prev.senderIdHash
                envelope.recipientIdHash = hash
                envelope.ttlSeconds = PremiumLimits.meshTTLSeconds
            }
        }

        await MeshMediaSealer.unseal(envelope: &envelope, myUserId: myId)

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
                logger.debug("Could not decrypt group payload (\(envelope.recipientId, privacy: .private) v\(version, privacy: .public)) — leaving ciphertext")
            }
        } else if !isGroupMessage, let wire = envelope.text, !wire.isEmpty {
            // 🔴 ROUND 19 — hacker-audit Mesh F2. The 1:1 mesh
            // path now runs through the sealer — both engaging the
            // round-17 replay window AND the round-13 AAD binding
            // (sender/recipient/msgId). Before this fix, the mesh
            // receive path lifted `envelope.text` straight into
            // the bubble — so a malicious relay could:
            //   • replay a captured frame after the sender's Noise
            //     re-key,
            //   • render attacker-injected text as if the sender
            //     authored it.
            let unsealed = await MessageContentSealer.unseal(
                encoded: wire,
                senderUserId: envelope.senderId,
                recipientUserId: myId,
                senderAgreementPubKey: nil,
                msgId: envelope.clientMessageId
            )
            #if DEBUG
            let wirePrefix20 = String(wire.prefix(20))
            if let u = unsealed {
                print("🔍 [Mesh.unseal] mid=\(envelope.clientMessageId.prefix(8)) sender=\(envelope.senderId.prefix(8)) wirePrefix='\(wirePrefix20)' wireLen=\(wire.count) → plaintext.count=\(u.plaintext.count) reason=\(u.reason) plaintextPrefix='\(u.plaintext.prefix(20))'")
            } else {
                print("🔍 [Mesh.unseal] mid=\(envelope.clientMessageId.prefix(8)) sender=\(envelope.senderId.prefix(8)) wirePrefix='\(wirePrefix20)' wireLen=\(wire.count) → nil (unknown magic / bad b64)")
            }
            #endif
            if let unsealed = unsealed {
                // 🔴 ROUND 71 phase 3 follow-up (2026-05-24) —
                //   placeholder when decrypt failed/no sender key.
                //   Same fix as MessageStore.swift — for
                //   `.decryptFailed` / `.noSenderKey` the unsealer
                //   returns `plaintext = ""` and the bubble rendered
                //   empty. Surface a clear placeholder so the user
                //   knows the message arrived but couldn't be
                //   decrypted (typically a bridged message from a
                //   sender with whom we have no Noise session).
                switch unsealed.reason {
                case .decryptFailed where unsealed.plaintext.isEmpty:
                    message.text = "🔒 Sealed message — couldn't decrypt"
                case .noSenderKey where unsealed.plaintext.isEmpty:
                    message.text = "🔒 Sealed message — sender key unknown"
                default:
                    message.text = unsealed.plaintext
                }
                // Mirror the verdict so the per-bubble lock badge
                // works on mesh deliveries too.
                //
                // 🔴 ROUND 26 — also feed
                // `PeerProtocolCapabilityStore` so the "Older RAVEN"
                // capsule banner clears as soon as we successfully
                // unseal a sealed mesh frame from this peer (= they
                // updated the app), and surfaces when a peer is
                // shipping RVNP1 / legacy bytes over BLE too.
                switch unsealed.reason {
                case .noiseTransport, .atsamHybrid:
                    await MessageEncryptionStatusStore.shared
                        .record(.sealed, for: envelope.clientMessageId)
                    await PeerProtocolCapabilityStore.shared
                        .record(.modernATSAM, for: envelope.senderId)
                case .explicitPlaintext:
                    await MessageEncryptionStatusStore.shared
                        .record(.plaintextExplicit, for: envelope.clientMessageId)
                    await PeerProtocolCapabilityStore.shared
                        .record(.legacyClient, for: envelope.senderId)
                case .legacy:
                    await MessageEncryptionStatusStore.shared
                        .record(.plaintextLegacy, for: envelope.clientMessageId)
                    await PeerProtocolCapabilityStore.shared
                        .record(.legacyClient, for: envelope.senderId)
                case .decryptFailed:
                    await MessageEncryptionStatusStore.shared
                        .record(.sealedButFailed, for: envelope.clientMessageId)
                    // 🔴 ROUND 26 (2026-05-17) — v2 of auto re-handshake.
                    //   v1 used `agreementKey` (sync cache) — if the
                    //   prekey wasn't cached, the if-let block was
                    //   skipped and NO eviction happened. User
                    //   reported decrypt failures continuing even
                    //   after multiple outbound sends.
                    //
                    //   v2 fixes:
                    //   (a) Use `ensureAgreementKey` which falls
                    //       back to the server prekey-bundle fetch
                    //       when the cache is empty.
                    //   (b) Evict BOTH the sender's peerPID (so our
                    //       send-side knows to handshake again) AND
                    //       any stale entries by trying both
                    //       common peerID derivations.
                    //   (c) Best-effort: actively send a stub
                    //       message to the sender right now via
                    //       MessageRouter so the handshake1 fires
                    //       immediately rather than waiting for
                    //       the user's next typed message.
                    let resolvedKey = await PeerKeyDirectory.shared.ensureAgreementKey(for: envelope.senderId)
                    if let pubKey = resolvedKey {
                        let peerPID = Data(SHA256.hash(data: pubKey).prefix(16))
                        await MainActor.run {
                            NoiseSessionStore.shared.evict(peerID: peerPID)
                        }
                        #if DEBUG
                        print("🔄 [Mesh] decrypt-failed for sender \(envelope.senderId.prefix(8)) — evicted local Noise peerPID \(peerPID.prefix(4).map { String(format: "%02x", $0) }.joined()).")
                        #endif
                        // 🔴 ROUND 26 (2026-05-17) — v3 of auto re-handshake.
                        //   v2 ONLY evicted our local session. Problem:
                        //   sender's session was still cached, so they
                        //   kept sealing with the stale key and every
                        //   subsequent message kept failing forever.
                        //   The receiver's eviction is necessary but
                        //   not sufficient — without an inbound
                        //   handshake1 the sender's session is sticky.
                        //
                        //   v3: also ACTIVELY broadcast a handshake1
                        //   frame to the sender. They process it via
                        //   `NoiseSessionStore.processInboundHandshake1`
                        //   which OVERWRITES their existing transport
                        //   entry (line 148-149). Both sides converge
                        //   on a fresh shared session within one
                        //   round-trip, no user action required.
                        await BLEMeshEngine.shared.triggerRehandshake(withSenderUserId: envelope.senderId)
                    } else {
                        #if DEBUG
                        print("⚠️ [Mesh] decrypt-failed for sender \(envelope.senderId.prefix(8)) — no prekey on file, can't compute peerPID; bridge-via-server may recover.")
                        #endif
                    }
                case .noSenderKey:
                    break
                }
            } else {
                // Unseal returned nil — could be either:
                //   (a) genuine garbage / attacker-injected bytes
                //   (b) a v1.6 peer who shipped raw plaintext with
                //       no magic header (because their build lands
                //       pre-round-10).
                //
                // 🔴 ROUND 26 — bridge interop with v1.6.
                // If we ALREADY know this sender is on a legacy
                // build (PeerProtocolCapabilityStore flagged them
                // legacyClient — either from a prior plaintext
                // packet they sent us OR from our own send-side
                // fallback when we couldn't establish a Noise
                // session with them), surface the wire bytes as
                // legacy text with the lock-broken badge instead
                // of showing "[unreadable]". This is the rescue
                // path that makes v1.6 → v1.7 mesh actually
                // legible. We DO NOT do this for unknown peers
                // because that would re-open audit C3 (a server /
                // relay injecting attacker bytes into bubbles).
                let level = await PeerProtocolCapabilityStore.shared.level(for: envelope.senderId)
                // 🔴 ROUND 26 (2026-05-17) — empty-bubble bug fix.
                //   The MESH-CRIT-1 fix split legacy detection into
                //   `.legacyClient` (peer-confirmed) vs `.suspectedLegacy`
                //   (local sealer-fallback only). The rescue check
                //   above ONLY accepted `.legacyClient`, so any peer
                //   that hit local fallback (very common during first
                //   contact / Noise session warm-up) was marked
                //   `.suspectedLegacy` and their messages rendered as
                //   EMPTY bubbles — user-reported screenshot showed
                //   3 messages each with just "Received via Direct
                //   Mesh" badge + timestamp, no body.
                //
                //   Both `.legacyClient` and `.suspectedLegacy` are
                //   signals that the sender ISN'T on a modern Noise
                //   session with us. In both cases the wire is
                //   likely raw plaintext (or RVNP1 — already handled
                //   above by the unseal magic branch). Rescue the
                //   wire bytes as legacy text either way. The
                //   security gain of MESH-CRIT-1 (no auto-downgrade
                //   on SEND) is preserved — this is only the
                //   RECEIVE-side render fallback.
                if (level == .legacyClient || level == .suspectedLegacy) && FeatureFlag.legacyPlaintextRender.isEnabled {
                    let legacy = MessageContentSealer.unsealLegacyText(wire)
                    message.text = legacy.plaintext
                    await MessageEncryptionStatusStore.shared
                        .record(.plaintextLegacy, for: envelope.clientMessageId)
                    #if DEBUG
                    print("📡 [App] Mesh recv: \(level == .legacyClient ? "legacy" : "suspected-legacy") peer \(envelope.senderId.prefix(8)) — rescued as plaintext.")
                    #endif
                } else {
                    // 🟥 ROUND 30 (2026-05-17) — asymmetric-legacy bug fix.
                    //
                    // Bug from user-supplied log:
                    //   Sender's PeerProtocolCapabilityStore had the
                    //   recipient flagged as `.legacyClient` (e.g. after
                    //   one earlier plaintext-fallback round), so the
                    //   sender's MessageRouter line ~360 shipped the
                    //   payload as RAW PLAINTEXT (no RVNS1 / RVNP1
                    //   magic) under the "we know peer is legacy"
                    //   downgrade branch.
                    //   But the RECEIVER had recently been reset
                    //   (simulator reinstall wiped PPCS state), so the
                    //   capability store level for the sender came back
                    //   `.unknown`.  The strict rescue check above
                    //   accepted only `.legacyClient` / `.suspectedLegacy`,
                    //   so `.unknown` fell through, text was set to "",
                    //   and the user got the "🔒 [Encrypted message —
                    //   could not decrypt]" placeholder on a perfectly
                    //   readable plaintext message.
                    //
                    //   Visible in the log as:
                    //     🔍 [Mesh.unseal] wirePrefix='Hghg' wireLen=4 → nil
                    //     🚨 [Mesh.lastResort] PLACEHOLDER SET … wire was 'Hghg'
                    //
                    // Fix: by the time we reach this branch, the
                    // mesh envelope has ALREADY been authenticated
                    // upstream (signature verified in
                    // MeshCryptoService.verifySignature before
                    // processVerifiedEnvelope is even called).  So
                    // the wire bytes are KNOWN to come from the
                    // claimed sender — audit-C3 (server-injected
                    // bytes) doesn't apply on the mesh path.  Accept
                    // valid-UTF-8 short wires as legacy plaintext
                    // and proactively flag the sender as
                    // `.suspectedLegacy` so the next message renders
                    // through the explicit rescue path above.
                    // 🔴 AUDIT 2026-05-29 (#95 / H8.F1) — gate the raw-plaintext
                    // render behind a default-OFF flag and, critically, do NOT
                    // auto-promote the sender to .suspectedLegacy. The previous
                    // code rendered any valid-UTF-8 wire from an .unknown peer as
                    // plaintext and pinned that peer to legacy forever — a durable
                    // confidentiality-downgrade primitive. Default is now the
                    // secure placeholder in the else branch.
                    if FeatureFlag.legacyPlaintextRender.isEnabled,
                       !wire.isEmpty,
                       wire.count <= 16 * 1024,
                       Data(wire.utf8).count == wire.utf8.count,
                       let _ = String(data: Data(wire.utf8), encoding: .utf8) {
                        message.text = wire
                        await MessageEncryptionStatusStore.shared
                            .record(.plaintextLegacy, for: envelope.clientMessageId)
                        #if DEBUG
                        print("📡 [App] Mesh recv (legacy render, flag ON): unknown-level peer \(envelope.senderId.prefix(8)) raw plaintext (\(wire.count) chars) — NOT pinning to legacy.")
                        #endif
                    } else {
                        // Genuinely garbage bytes → strict behaviour.
                        message.text = ""
                        await MessageEncryptionStatusStore.shared
                            .record(.sealedButFailed, for: envelope.clientMessageId)
                    }
                }
            }

            // 🔴 ROUND 26 (2026-05-17) — last-resort placeholder.
            //   If ALL the above paths produced an empty text
            //   (decryptFailed because Noise session was lost on
            //   one side, noSenderKey because we never had the
            //   sender's prekey bundle, unknown peer with garbage
            //   bytes, etc.) replace the empty bubble with a
            //   visible "[Encrypted message — could not decrypt]"
            //   placeholder. Empty bubbles look like a UI bug to
            //   the user and they keep tapping/scrolling trying
            //   to understand what happened. A clear placeholder
            //   tells them the message arrived but couldn't be
            //   read — actionable signal to re-pair or update.
            if (message.text ?? "").isEmpty {
                #if DEBUG
                print("🚨 [Mesh.lastResort] PLACEHOLDER SET for mid=\(message.id.prefix(8)) sender=\(envelope.senderId.prefix(8)) — wire was '\((envelope.text ?? "").prefix(20))' wireLen=\((envelope.text ?? "").count) groupKeyVersion=\(envelope.groupKeyVersion.map(String.init) ?? "nil")")
                #endif
                message.text = "🔒 [Encrypted message — could not decrypt]"
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
            // Already durably persisted — safe to record as seen and ACK.
            await MeshACKHandler.shared.markAsSeen(message.id)
            await MeshACKHandler.shared.sendDeliveryACK(for: message.id, toSenderId: message.senderId)
            return
        }

        // Insert message. If the insert FAILS we must NOT mark the ID as seen
        // and must NOT ACK — returning without either lets the sender re-spray
        // so the message isn't silently lost (the dedup cache previously burned
        // the ID for 7 days even when the insert failed).
        do {
            try await messageRepo.upsert(message)
        } catch {
            logger.error("[MESH] upsert FAILED for \(message.id, privacy: .private) — not ACKing so sender retries: \(error.localizedDescription, privacy: .public)")
            return
        }
        #if DEBUG
        print("📥 [MESH] ✅ Message inserted to DB: \(message.id.prefix(8))")
        #endif

        // Durably persisted — now it's safe to record as seen for dedup.
        await MeshACKHandler.shared.markAsSeen(message.id)

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
            // Message row is already persisted (not lost — chat open / next
            // loadFromDB surfaces it); only the inbox preview/sort update failed.
            // Log in release so this isn't silently swallowed.
            logger.error("[MESH] applyMessage FAILED for \(message.id, privacy: .private): \(error.localizedDescription, privacy: .public)")
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
        // 🔴 Bug fix (2026-05-16): the in-app toast for mesh
        // deliveries used to pass `avatarURL: nil` so every
        // banner appeared as a hollow capsule with a generic
        // initials placeholder — the user couldn't tell who
        // it was from. Resolve the sender's avatar from the
        // same ConversationStore lookup we already do for the
        // display name and pass it through to the toast.
        let resolved: (name: String?, avatar: String?) = await MainActor.run {
            if let conv = ConversationStore.shared.conversations.first(where: { $0.roomId == roomId }) {
                let n = conv.isGroup ? (conv.groupName ?? conv.peer.displayName) : conv.peer.displayName
                return (n, conv.peer.avatarPath)
            }
            return (nil, nil)
        }
        let resolvedName = resolved.name
        let resolvedAvatar = resolved.avatar

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
            // 🔴 ROUND 71 phase 3 follow-up #4 (2026-05-24) —
            // resolve group name + carry messageId so the toast can
            // render "<sender> · <group>" and cross-channel dedup
            // (WS + APNs + mesh) collapses correctly. The previous
            // `safeSenderName = "<sender> in <gName>"` concatenation
            // (built in lines just above) shoved the group name
            // into the title field — looked OK alone but doubled up
            // with the new title composer. Compute pure sender +
            // groupName separately.
            // 🔴 ROUND 71 phase 3 follow-up #4 (2026-05-24) —
            // resolve the sender's display name. For group messages
            // where `fromMeshEnvelope` cleared the wire-side
            // senderName, fall back to a local group-member lookup
            // by senderId.
            let toastSenderName: String
            if !message.senderName.isEmpty, !message.senderName.looksEncrypted {
                toastSenderName = message.senderName
            } else if !isGroupMessage {
                toastSenderName = resolvedName ?? "New Message"
            } else {
                let groupRepo = GroupRepository()
                let group = try? await groupRepo.get(groupId: envelope.recipientId)
                if let members = group?.members,
                   let m = members.first(where: { $0.userId == envelope.senderId }),
                   !m.username.isEmpty {
                    toastSenderName = m.username
                } else {
                    toastSenderName = "Member"
                }
            }
            let toastGroupName: String? = {
                guard isGroupMessage else { return nil }
                if let conv = ConversationStore.shared.conversations.first(where: { $0.roomId == roomId }),
                   let g = conv.groupName, !g.isEmpty {
                    return g
                }
                return resolvedName
            }()
            await MainActor.run {
                let toast = ToastItem.message(
                    senderName: toastSenderName,
                    preview: safePreview,
                    avatarURL: AppConfig.mediaURL(from: resolvedAvatar),
                    chatId: roomId,
                    senderId: message.senderId,
                    isGroup: isGroupMessage,
                    groupName: toastGroupName,
                    serverNotificationId: nil,
                    messageId: message.id
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
        //
        // 🟥 CRITICAL FIX (2026-05-17) — recipient & placeholder guards.
        //
        // BUG (from user-supplied log trace, msg F22BDF29...):
        // we received a 1:1 mesh message addressed TO us, failed to
        // decrypt (stale Noise session), set `message.text` to the
        // "🔒 [Encrypted message — could not decrypt]" placeholder,
        // then bridged THAT placeholder string to the server as if it
        // were the real message content. The server stored the
        // placeholder + downlinked it to other devices in our account.
        //
        // Two guards now:
        //   (1) `envelope.recipientId == myId` — we ARE the final
        //       recipient. The message has reached its destination;
        //       bridging onward serves no purpose AND would let the
        //       server see our decrypted plaintext (E2EE violation in
        //       the bridge code path).  Pure relays — handled earlier
        //       at line 983 — already bridge correctly for offline
        //       recipients.
        //   (2) Placeholder-text guard — even when bridging is
        //       legitimate (e.g. a group message we decrypted via
        //       group key but envelope.needsForwarding is set), never
        //       ship the "could not decrypt" placeholder. It is local
        //       UI text, not a real message.
        let isRecipient = envelope.recipientId == myId
        let textIsPlaceholder = (message.text ?? "").hasPrefix("🔒 [Encrypted message")
        if NetworkMonitor.shared.isOnline
            && envelope.needsForwarding
            && !isRecipient
            && !textIsPlaceholder {
            await BLEMeshEngine.shared.forwardMeshMessageToServer(message)
        } else if textIsPlaceholder {
            #if DEBUG
            print("🚫 [BRIDGE] Refusing to bridge placeholder text for \(message.id.prefix(8)) — would corrupt server-side conversation.")
            #endif
        }
        
        #if DEBUG
        print("🎉 [App] Mesh message processed, ACK sent!")
        #endif
    }

    // MARK: - Mesh Group Sync Handler (Round 46)
    //
    // 🟦 ROUND 46 (2026-05-17) — group lifecycle propagation.
    //
    // Materialize a `ChatGroup` from a mesh `group_create` envelope so
    // BLE-only devices can join group conversations without ever
    // hitting the server. Also promotes any messages parked in
    // `PendingGroupMessageRepository` for the same group_id — those
    // are the chat messages that arrived on this device BEFORE the
    // create event (which can happen because mesh-sprayed envelopes
    // do not guarantee FIFO order across hops).
    //
    // Self-validation rule: we only persist the group locally if our
    // own userId appears in the payload's members list. Otherwise we
    // log + return so the broadcast still relays through us (mesh
    // spray relay is handled separately by `BLEMeshEngine
    // .processValidatedEnvelope`) but we don't materialize a group
    // we're not in.
    static func handleGroupSyncMeshMessage(_ envelope: MeshEnvelope, myId: String) async {
        guard let payload = GroupSyncPayload.decode(from: envelope.text) else {
            #if DEBUG
            print("🟦 [GroupSync] DROP — could not decode GroupSyncPayload from mesh envelope mid=\(envelope.clientMessageId.prefix(8))")
            #endif
            return
        }

        // 🔴 ROUND 70 (2026-05-23) — hacker-audit GROUP-CREATE-CRIT-1.
        //
        // PREVIOUSLY this handler self-validated only against the
        // ATTACKER-SUPPLIED `payload.members` list: "are we a
        // member?" was answered by scanning attacker bytes. A rogue
        // mesh peer could broadcast a forged group_create with the
        // victim in `members` and `createdBy = anyone`, and the
        // receiver materialized the fake group + began routing chat
        // bubbles targeted at that group_id straight into the
        // victim's inbox. Combined with the server-bridge group
        // membership gap (also fixed in round 70), an attacker could
        // turn the victim into a relay-receiver for any forged
        // group conversation.
        //
        // PARTIAL FIX (round 70 phase 1): require `envelope.senderId`
        // to equal `payload.createdBy`. The envelope signature
        // verification at the BLE/mesh ingress layer already proves
        // the SIGNER controls its identity key, and (post-round-70-
        // FriendReq-fix) the receiver no longer auto-pins
        // attacker-claimed identity keys, so the signer's identity
        // is bound to a real userId only when we already had a
        // pinned identity for that userId. This is enough to reject
        // group_create envelopes where the claimed creator is not
        // also the on-wire signer.
        //
        // FUTURE (phase 2): add an Ed25519 signature field directly
        // on `GroupSyncPayload` covering (groupId, createdBy,
        // memberCount, createdAt) so receivers can verify against a
        // pinned creator identity without relying on the envelope
        // signature transitively. Tracked as ROUND-71.
        // 🔴 ROUND 71 phase 3 follow-up #8 (2026-05-24) — relay relax.
        //
        // PROBLEM (user-reported 2026-05-24):
        //   "alan device A ke faghat connectivity be bluetooth dare
        //    na ozv group shode na payam haro migire"
        //   ≈ device A (BLE-only) doesn't get added to the group
        //   and doesn't receive its messages.
        //
        // ROOT CAUSE: the round-70 check above required
        // `envelope.senderId == payload.createdBy`. That works when
        // the CREATOR is directly broadcasting (the original mesh
        // path), but BREAKS the relay scenario the user is in:
        //   - X (online) creates a group with A (BLE-only) and B
        //     (online + BLE-peer of A) as members.
        //   - X's mesh doesn't reach A (out of range).
        //   - B receives WS `added_to_group` from server, then
        //     calls `MeshGroupBroadcaster.broadcastCreate(group)`.
        //     The broadcaster sets `envelope.senderId = B.userId`
        //     (not X), but `payload.createdBy = X`.
        //   - A receives B's mesh broadcast, applies the strict
        //     check → REJECT → never materializes the group.
        //
        // FIX: accept the broadcast when EITHER:
        //   (a) envelope.senderId == payload.createdBy  (creator's
        //       own broadcast, original round-70 case), OR
        //   (b) envelope.senderId is a current member listed in
        //       payload.members (a legitimate group member relaying
        //       the lifecycle event to BLE-only neighbours).
        //
        // 🛡️ SECURITY: the round-70 attack required forging a
        // group_create that named the victim as a member. Under
        // the new check, the relayer still has to be in the same
        // payload.members list — a non-member relay still gets
        // rejected. The signature path remains intact (BLE ingress
        // verifies the envelope's outer Ed25519 signature against
        // signer's identity key), and `payload.members` self-
        // validation below still gates whether WE materialize the
        // group locally (we only persist if our userId is a member).
        // 🟢 ROUND 74 (2026-05-24) — resolve stripped senderId before
        // the relay gate.
        //
        // USER REPORT: "Device A (BLE-only) NA OZV GROUP SHODE" —
        // A never joins the group, despite C broadcasting group_create.
        //
        // ROOT CAUSE (agent 3 finding #3): modernATSAM strict-strip
        // sets `envelope.senderId = ""` and only ships the hashed
        // sender. The relay-gate below then fails BOTH comparisons:
        //   • `"" == payload.createdBy` → false (createdBy is a real UUID)
        //   • `members.contains { $0.userId == "" }` → false (no member has empty userId)
        // → envelope DROPPED silently before A ever sees the group_create.
        //
        // FIX: resolve `envelope.senderId` from `senderIdHash` via
        // MeshIdentityResolver (already populated by the contacts sync
        // path that runs at every WS connect + foreground). The resolved
        // ID then matches createdBy or members normally.
        var resolvedSenderId = envelope.senderId
        if resolvedSenderId.isEmpty, let hash = envelope.senderIdHash, !hash.isEmpty {
            if let real = await MeshIdentityResolver.shared.resolve(hash: hash) {
                resolvedSenderId = real
                #if DEBUG
                print("🟦 [GroupSync] Resolved stripped senderId via hash → \(real.prefix(8))")
                #endif
            }
        }

        let relayerIsMember = payload.members.contains { $0.userId == resolvedSenderId }
        guard resolvedSenderId == payload.createdBy || relayerIsMember else {
            #if DEBUG
            print("🟦 [GroupSync] DROP — resolved sender (\(resolvedSenderId.prefix(8))) " +
                  "is neither payload.createdBy (\(payload.createdBy.prefix(8))) nor a member; " +
                  "possible group_create spoof.")
            #endif
            return
        }

        let groupRepo = GroupRepository()
        let existing = (try? await groupRepo.get(groupId: payload.groupId))
        let knownGroupBeforeReceive = (existing != nil)

        // Self-validation: are we a member?
        let isMember = payload.members.contains { $0.userId == myId }
        guard isMember else {
            #if DEBUG
            print("""
            🟦 [GroupSync] NOT MEMBER — relay-only. \
            payload.type=\(payload.event) message_id=\(envelope.clientMessageId.prefix(12)) \
            conversation_id=\(payload.groupId.prefix(8)) conversation_type=group \
            group_id=\(payload.groupId.prefix(8)) sender_id=\(envelope.senderId.prefix(8)) \
            receiver_id=\(myId.prefix(8)) known_group_before_receive=\(knownGroupBeforeReceive) \
            created_group_from_payload=false display_thread_id=\(payload.groupId.prefix(8)) \
            members=\(payload.members.count)
            """)
            #endif
            return
        }

        // Build a ChatGroup from the payload.
        let members = payload.members.map {
            GroupMember(
                userId: $0.userId,
                username: $0.username,
                avatarUrl: $0.avatarUrl,
                role: $0.role,
                joinedAt: Date(timeIntervalSince1970: $0.joinedAt)
            )
        }
        let group = ChatGroup(
            id: payload.groupId,
            name: payload.groupName,
            avatarUrl: payload.avatarUrl,
            description: payload.description,
            createdBy: payload.createdBy,
            creatorUsername: payload.creatorUsername,
            createdAt: Date(timeIntervalSince1970: payload.createdAt),
            memberCount: payload.memberCount,
            members: members,
            syncStatus: .synced
        )

        // Persist locally + create conversation row so the group
        // appears in the inbox.
        try? await groupRepo.upsert(group)
        try? await ConversationRepository.shared.createGroupConversation(group: group)

        let createdGroupFromPayload = !knownGroupBeforeReceive

        // Promote any limbo messages for this group_id — these are
        // chat messages that arrived BEFORE the create event (out-of-
        // order spray) and were parked because the group_id was
        // unknown. Promoting them now re-runs the full mesh receive
        // path with the group present.
        let pending = await PendingGroupMessageRepository.shared.promoteMessages(forGroup: payload.groupId)
        for env in pending {
            #if DEBUG
            print("🟦 [GroupSync] Promoting limbo message \(env.clientMessageId.prefix(8)) for newly-known group \(payload.groupId.prefix(8))")
            #endif
            await AppDelegate.handleMeshMessage(env)
        }

        // Refresh inbox UI so the new group appears immediately.
        await ConversationStore.shared.loadFromDB()

        #if DEBUG
        print("""
        🟦 [GroupSync] ✅ MATERIALIZED. \
        payload.type=\(payload.event) message_id=\(envelope.clientMessageId.prefix(12)) \
        conversation_id=\(payload.groupId.prefix(8)) conversation_type=group \
        group_id=\(payload.groupId.prefix(8)) sender_id=\(envelope.senderId.prefix(8)) \
        receiver_id=\(myId.prefix(8)) known_group_before_receive=\(knownGroupBeforeReceive) \
        created_group_from_payload=\(createdGroupFromPayload) \
        display_thread_id=\(payload.groupId.prefix(8)) name='\(payload.groupName)' \
        members=\(payload.members.count) promoted=\(pending.count)
        """)
        #endif
    }

    // MARK: - Mesh Friend Request Handler (Round 50)
    //
    // 🟦 ROUND 50 (2026-05-17) — offline QR friend-add over mesh.
    //
    // Receives a mesh envelope carrying a `FriendRequestMeshPayload`
    // (sent by `MeshFriendRequestBroadcaster.broadcastFriendRequest`
    // when the OTHER user scanned our QR code). Materializes the
    // sender as a friend locally — auto-accept, since the QR scan
    // was out-of-band mutual consent.
    //
    // Self-validation rule: we only materialize the friend if the
    // payload's `recipientUserId` matches our own userId. Otherwise
    // we log + return (mesh spray-relay still happens at the BLE
    // layer regardless — see `processValidatedEnvelope`).
    //
    // Idempotent: re-running this on the same envelope is a no-op
    // because:
    //   • PeerKeyDirectory.setAgreementKey is idempotent (UPSERT)
    //   • FriendDeviceRepository.upsert is INSERT-OR-REPLACE
    //   • friends_cache append checks for existing user_id
    //   • MeshDedupRepository catches the second envelope at the
    //     mesh layer anyway
    static func handleFriendRequestMeshMessage(_ envelope: MeshEnvelope, myId: String) async {
        guard let payload = FriendRequestMeshPayload.decode(from: envelope.text) else {
            #if DEBUG
            print("🟦 [FriendReqMesh] DROP — could not decode FriendRequestMeshPayload from envelope mid=\(envelope.clientMessageId.prefix(8))")
            #endif
            return
        }

        // Self-validation: are we the intended recipient?
        guard payload.recipientUserId == myId else {
            #if DEBUG
            print("🟦 [FriendReqMesh] NOT-FOR-ME — relay-only. payload.recipient=\(payload.recipientUserId.prefix(8)) myId=\(myId.prefix(8))")
            #endif
            return
        }

        // Reject self-requests (someone forging an envelope claiming
        // we requested ourself).
        guard payload.senderUserId != myId else {
            #if DEBUG
            print("🟦 [FriendReqMesh] DROP — self-request from \(payload.senderUserId.prefix(8))")
            #endif
            return
        }

        let senderId = payload.senderUserId
        let senderUsername = payload.senderUsername.isEmpty ? "user-\(senderId.prefix(6))" : payload.senderUsername

        // 🔴 ROUND 70 (2026-05-23) — hacker-audit MESH-FRIEND-CRIT-1
        // (CRITICAL: full E2EE MITM via mesh FriendRequest spoof).
        //
        // PREVIOUSLY: this handler unconditionally pinned the
        // attacker-supplied `agreementPublicKeyB64` into PeerKeyDirectory
        // for `payload.senderUserId`. The envelope-layer Ed25519
        // signature only proves the SIGNER controls its own key — NOT
        // that the signer is who they claim in the payload. So any
        // mesh peer could craft:
        //
        //   envelope.senderId = VICTIM_USERID
        //   envelope.signerPublicKey = ATTACKER's Ed25519 key
        //   payload.senderUserId = VICTIM_USERID
        //   payload.agreementPublicKeyB64 = ATTACKER's X25519 pub
        //
        // and (because target had no prior pin for VICTIM_USERID) the
        // envelope sig verifies via TOFU, and `setAgreementKey` writes
        // attacker's X25519 key under VICTIM_USERID. Every future DM
        // from target to "VICTIM" is now sealed to attacker's key.
        // Round-65 server bundle binding is COMPLETELY BYPASSED
        // because this code path never fetches from the server.
        //
        // FIX: stop pinning agreement keys from the mesh path entirely.
        // The mesh FriendRequest is now treated as a NOTIFICATION
        // ("you have a pending friend request from X") instead of a
        // trusted-key-adoption channel. The actual key pin happens
        // via:
        //   (a) the QR scan path (genuine out-of-band consent), or
        //   (b) the round-65 server-fetch path on first DM send
        //       (PeerKeyDirectory.ensureAgreementKey hits
        //       /api/atsam/prekey/{userId} which is signature-bound
        //       to the requested userId).
        //
        // The toast still fires so the user sees "X wants to be your
        // friend" and can act, but no automatic key adoption +
        // no automatic friend pin + no server-side enqueue happens
        // without the user explicitly tapping accept. This converts
        // the mesh path from a key-adoption oracle to a notification-
        // only channel, which is what the threat model assumed all
        // along.
        let alreadyPinned = await PeerKeyDirectory.shared.agreementKey(for: senderId) != nil
        if !alreadyPinned {
            #if DEBUG
            print("🟦 [FriendReqMesh] sender \(senderId.prefix(8)) has no pre-existing pinned key — REFUSING to auto-pin attacker-supplied agreement key from mesh payload. The user must accept the pending request through the QR / friend-request UI which re-fetches the server-signed bundle.")
            #endif
        } else {
            // Optional consistency-only check: if we ALREADY have a
            // pinned key (from prior QR or server fetch), allow the
            // mesh payload to confirm it (matches PeerKeyDirectory's
            // round-13 recordObservedKey semantics — verify, never
            // overwrite). If it disagrees, log loudly and drop.
            if let agreementB64 = payload.agreementPublicKeyB64,
               let agreementKey = Data(base64Encoded: agreementB64),
               agreementKey.count == 32 {
                let existing = await PeerKeyDirectory.shared.agreementKey(for: senderId)
                if existing != agreementKey {
                    #if DEBUG
                    print("🟦 [FriendReqMesh] AGREEMENT KEY MISMATCH for \(senderId.prefix(8)) — pinned key differs from mesh-payload key. Possible MITM attempt; ignoring mesh-supplied key.")
                    #endif
                }
            }
        }

        // 🔴 ROUND 70 — same logic for the Ed25519 signing key. The
        // mesh-payload signing key is not trusted for FIRST contact.
        // FriendDevice pinning now requires either an existing
        // PeerKeyDirectory identity pin (matching the payload's
        // signing key) OR a QR-flow explicit acceptance. The
        // FriendDeviceRepository.upsert call below is GATED on
        // `alreadyPinned` to ensure cold-mesh-contact never bootstraps
        // a "trusted" device record from attacker-supplied bytes.
        if alreadyPinned,
           let signingB64 = payload.signingPublicKeyB64,
           let signingKey = Data(base64Encoded: signingB64),
           !signingKey.isEmpty {
            // Use the canonical fingerprint derivation (matches what
            // DeviceIdentityService computes for our own fingerprint,
            // so the receiver's BLE peer-learn path will recognise
            // this friend as trusted when it next sees them on BLE).
            let fingerprint = DeviceIdentityService.deriveFingerprint(from: signingKey)
            let agreementKeyOpt: Data? = {
                if let b64 = payload.agreementPublicKeyB64, !b64.isEmpty {
                    return Data(base64Encoded: b64)
                }
                return nil
            }()
            let device = FriendDevice(
                id: UUID().uuidString,
                friendUserId: senderId,
                fingerprint: fingerprint,
                publicKey: signingKey,
                agreementPublicKey: agreementKeyOpt,
                trustState: .trusted,        // safe because PeerKeyDirectory already pinned
                verifiedAt: Date(),
                addedAt: Date(),
                deviceName: senderUsername,
                lastSeenAt: Date()
            )
            do {
                try await FriendDeviceRepository.shared.upsert(device)
                #if DEBUG
                print("🟦 [FriendReqMesh] Upserted trusted FriendDevice for \(senderId.prefix(8)) fp=\(fingerprint.prefix(12)) (alreadyPinned=true)")
                #endif
            } catch {
                #if DEBUG
                print("🟦 [FriendReqMesh] FriendDeviceRepository.upsert failed: \(error.localizedDescription)")
                #endif
            }
        } else if !alreadyPinned {
            #if DEBUG
            print("🟦 [FriendReqMesh] SKIPPING FriendDevice pin for \(senderId.prefix(8)) — no existing PeerKeyDirectory entry, refusing to bootstrap trust from mesh.")
            #endif
        }

        // 🔴 ROUND 70 — friend-cache append and server-side accept
        // ALSO gated on `alreadyPinned`. Cold mesh contact gets a
        // notification only; the user must explicitly accept through
        // the friend-request UI (which goes through the server-fetch
        // path → round-65 userId-bound bundle verification).
        if alreadyPinned {
            // Existing trust relationship — safe to materialize the
            // friend row + server-side accept now.
            await MainActor.run {
                var cache: [GroupFriendInfo] = []
                if let data = UserDefaults.standard.data(forKey: "raven_friends_cache"),
                   let existing = try? JSONDecoder().decode([GroupFriendInfo].self, from: data) {
                    cache = existing
                }
                if !cache.contains(where: { $0.id == senderId }) {
                    cache.append(GroupFriendInfo(
                        id: senderId,
                        username: senderUsername,
                        displayName: payload.senderDisplayName,
                        avatarUrl: payload.senderAvatarUrl
                    ))
                    if let encoded = try? JSONEncoder().encode(cache) {
                        UserDefaults.standard.set(encoded, forKey: "raven_friends_cache")
                    }
                    #if DEBUG
                    print("🟦 [FriendReqMesh] Appended @\(senderUsername) to raven_friends_cache (now \(cache.count))")
                    #endif
                }
            }
            await PendingFriendRequestQueue.shared.enqueue(recipientId: senderId)
        }

        // Notification ALWAYS fires (mesh-friend-request as a NOTICE
        // is the only safe semantic for cold contact). The toast text
        // differs based on whether trust pre-existed.
        await MainActor.run {
            let previewText: String = alreadyPinned
                ? "Added you as a friend via QR"
                : "Wants to add you as a friend — open the app to accept"
            let toast = ToastItem.message(
                senderName: payload.senderDisplayName ?? senderUsername,
                preview: previewText,
                avatarURL: AppConfig.mediaURL(from: payload.senderAvatarUrl),
                chatId: senderId,
                senderId: senderId,
                isGroup: false
            )
            NotificationPipeline.shared.enqueue(toast)
        }

        #if DEBUG
        print("""
        🟦 [FriendReqMesh] ✅ ACCEPTED. \
        payload.type=friend_request message_id=\(envelope.clientMessageId.prefix(12)) \
        sender_id=\(senderId.prefix(8)) sender_username=@\(senderUsername) \
        receiver_id=\(myId.prefix(8)) auto_accepted=true \
        agreement_key_pinned=\(payload.agreementPublicKeyB64 != nil) \
        signing_key_pinned=\(payload.signingPublicKeyB64 != nil) \
        server_sync_queued=true
        """)
        #endif
    }

    // MARK: - Group Key Mesh Receive Handler (Round 74)

    /// 🟢 ROUND 74 (2026-05-24) — handle inbound `payloadKind="group_key"`
    /// envelopes from the mesh.
    ///
    /// This is THE path that lets BLE-only devices decrypt group
    /// messages. Without it, A receives ciphertext but has no key →
    /// every group bubble renders as gibberish.
    ///
    /// SECURITY GATES (in order):
    ///   1. Decode the payload (length-checked, version-gated).
    ///   2. Resolve the broadcaster's userId from the envelope (uses
    ///      MeshIdentityResolver if senderId was stripped — same fix
    ///      as Task #82 for group_create).
    ///   3. The broadcaster's resolved id MUST equal payload.broadcastedBy
    ///      (prevents replays where attacker rebroadcasts a captured
    ///      key under their own signature).
    ///   4. The receiver MUST be a current local member of payload.groupId
    ///      (no key ingestion for groups we're not in).
    ///   5. The broadcaster MUST also be a current member of the same
    ///      group (no key spoofing by a kicked or never-joined peer).
    ///   6. GroupKeyService.ingestMeshKey performs the final 32-byte
    ///      length check + idempotent storage + Keychain persist.
    static func handleGroupKeyMeshMessage(_ envelope: MeshEnvelope, myId: String) async {
        guard let payload = GroupKeyMeshPayload.decode(from: envelope.text) else {
            #if DEBUG
            print("🟦 [GroupKeyMesh] DROP — could not decode payload from envelope mid=\(envelope.clientMessageId.prefix(8))")
            #endif
            return
        }

        // Resolve a stripped senderId via the hash table — modernATSAM
        // strict-strip leaves envelope.senderId="".
        var resolvedSenderId = envelope.senderId
        if resolvedSenderId.isEmpty, let hash = envelope.senderIdHash, !hash.isEmpty {
            if let real = await MeshIdentityResolver.shared.resolve(hash: hash) {
                resolvedSenderId = real
            }
        }

        // Broadcaster claim must match the resolved signer. Otherwise an
        // attacker could capture an old key envelope and rebroadcast it
        // under their own sig with a poisoned `broadcastedBy`.
        guard resolvedSenderId == payload.broadcastedBy, !resolvedSenderId.isEmpty else {
            #if DEBUG
            print("🟦 [GroupKeyMesh] DROP — broadcastedBy mismatch: payload=\(payload.broadcastedBy.prefix(8)) signer=\(resolvedSenderId.prefix(8))")
            #endif
            return
        }

        // Receiver must be a current member of the target group.
        let groupRepo = GroupRepository()
        let localGroup: ChatGroup?
        do {
            localGroup = try await groupRepo.get(groupId: payload.groupId)
        } catch {
            localGroup = nil
        }
        guard let group = localGroup else {
            #if DEBUG
            print("🟦 [GroupKeyMesh] DROP — group \(payload.groupId.prefix(8)) not in local DB. Key arrived before group_create; rely on later broadcast.")
            #endif
            return
        }
        let members = group.members ?? []
        let receiverIsMember = members.contains { $0.userId == myId }
        guard receiverIsMember else {
            #if DEBUG
            print("🟦 [GroupKeyMesh] DROP — we are NOT a member of group \(payload.groupId.prefix(8))")
            #endif
            return
        }

        // Broadcaster must also be a current member.
        let broadcasterIsMember = members.contains { $0.userId == payload.broadcastedBy }
        guard broadcasterIsMember else {
            #if DEBUG
            print("🟦 [GroupKeyMesh] DROP — broadcaster \(payload.broadcastedBy.prefix(8)) is NOT a current member of \(payload.groupId.prefix(8))")
            #endif
            return
        }

        // 🔐 ROUND 76 (2026-05-24) — Hacker #6 finding #7. Reject stale
        // OR future-dated broadcasts (|age| > 24h). Pre-fix the check
        // only blocked `age > 24h` (past), so a sender-controlled
        // `issuedAt = now + 365d` produced negative age that passed
        // → attacker's replay window extended arbitrarily. abs(age)
        // closes both directions.
        let age = Date().timeIntervalSince1970 - payload.issuedAt
        if abs(age) > 24 * 3600 {
            #if DEBUG
            print("🟦 [GroupKeyMesh] DROP — payload age=\(Int(age))s (|age| > 24h limit)")
            #endif
            return
        }

        // All gates passed — ingest.
        let accepted = await MainActor.run {
            GroupKeyService.shared.ingestMeshKey(
                groupId: payload.groupId,
                version: payload.keyVersion,
                keyB64: payload.keyB64
            )
        }

        #if DEBUG
        print("🟦 [GroupKeyMesh] \(accepted ? "✅ ACCEPTED" : "❌ REJECTED-BY-SERVICE") gid=\(payload.groupId.prefix(8)) v=\(payload.keyVersion) from=\(payload.broadcastedBy.prefix(8))")
        #endif

        // If we just gained a new key version, try to re-decrypt any
        // limbo / sealedButFailed messages for this group so they
        // surface in the UI. The chat view will refresh on its next
        // poll regardless, but firing a notification makes it instant.
        if accepted {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("groupKeyIngested"),
                    object: nil,
                    userInfo: ["groupId": payload.groupId]
                )
            }
        }
    }

    // MARK: - Group Key ATSAM Mesh Receive Handler (Round 75)

    /// 🔐 ROUND 75 (2026-05-24) — handle inbound `payloadKind="group_key_atsam"`
    /// envelopes from the mesh.
    ///
    /// Per-recipient ATSAM-wrapped group_key envelope. Only the intended
    /// recipient (envelope.recipientId == myId) can decrypt. Other
    /// peers in BLE range see opaque ChaCha20-Poly1305 ciphertext.
    ///
    /// SECURITY GATES (in order):
    ///   1. envelope.recipientId MUST equal myId (resolve hash first).
    ///      Other members' envelopes are silent no-ops, NOT errors —
    ///      every member receives N envelopes, only 1 is for them.
    ///   2. Resolve broadcaster's userId from envelope (hash if stripped).
    ///   3. ATSAM-unseal envelope.text with the broadcaster's ATSAM root.
    ///      Failure here means we never paired with the broadcaster
    ///      under ATSAM — silently drop, the fallback `group_key`
    ///      envelope (if any) will carry the key for us via the
    ///      legacy plaintext path.
    ///   4. Decode the unsealed JSON as GroupKeyMeshPayload.
    ///   5. Broadcaster claim must match the resolved signer.
    ///   6. Receiver + broadcaster both in local GroupMember list.
    ///   7. 24h freshness window (anti-replay).
    ///   8. Final ingestion via GroupKeyService.ingestMeshKey.
    static func handleGroupKeyATSAMMeshMessage(_ envelope: MeshEnvelope, myId: String) async {
        // Gate 1: are we the intended recipient? (Resolve hash if stripped.)
        var resolvedRecipientId = envelope.recipientId
        if resolvedRecipientId.isEmpty, let hash = envelope.recipientIdHash, !hash.isEmpty {
            if let real = await MeshIdentityResolver.shared.resolve(hash: hash) {
                resolvedRecipientId = real
            }
        }
        guard resolvedRecipientId == myId else {
            // Silent no-op — this envelope is for a different member.
            // Mesh relay layer still propagates the envelope further.
            return
        }

        // Gate 2: resolve the broadcaster.
        var resolvedSenderId = envelope.senderId
        if resolvedSenderId.isEmpty, let hash = envelope.senderIdHash, !hash.isEmpty {
            if let real = await MeshIdentityResolver.shared.resolve(hash: hash) {
                resolvedSenderId = real
            }
        }
        guard !resolvedSenderId.isEmpty else {
            #if DEBUG
            print("🔐 [GroupKeyATSAM] DROP — could not resolve broadcaster userId from envelope mid=\(envelope.clientMessageId.prefix(8))")
            #endif
            return
        }

        // Gate 3: ATSAM-unseal the body. The msgId binding MUST be the
        // envelope's clientMessageId — same value the sender used in
        // ATSAMMessageSealer.seal.
        guard let cipherB64 = envelope.text, !cipherB64.isEmpty else {
            #if DEBUG
            print("🔐 [GroupKeyATSAM] DROP — empty ciphertext mid=\(envelope.clientMessageId.prefix(8))")
            #endif
            return
        }
        guard let plain = await ATSAMMessageSealer.unseal(
            encoded: cipherB64,
            senderUserId: resolvedSenderId,
            recipientUserId: myId,
            msgId: envelope.clientMessageId
        ) else {
            #if DEBUG
            print("🔐 [GroupKeyATSAM] unseal FAILED — no ATSAM root with broadcaster \(resolvedSenderId.prefix(8)) OR ciphertext tampered. Falling through to legacy group_key path if available.")
            #endif
            return
        }

        // Gate 4: decode payload.
        guard let payload = GroupKeyMeshPayload.decode(from: plain) else {
            #if DEBUG
            print("🔐 [GroupKeyATSAM] DROP — unsealed body did not decode as GroupKeyMeshPayload mid=\(envelope.clientMessageId.prefix(8))")
            #endif
            return
        }

        // Gate 5: broadcaster claim consistency (defense in depth —
        // the AAD binding already proves authenticity, but a sealed
        // payload could still claim a different broadcastedBy field
        // if the legacy plaintext path was confused).
        guard payload.broadcastedBy == resolvedSenderId else {
            #if DEBUG
            print("🔐 [GroupKeyATSAM] DROP — broadcastedBy mismatch: payload=\(payload.broadcastedBy.prefix(8)) signer=\(resolvedSenderId.prefix(8))")
            #endif
            return
        }

        // Gate 6: membership of both broadcaster + receiver.
        let groupRepo = GroupRepository()
        let localGroup: ChatGroup?
        do {
            localGroup = try await groupRepo.get(groupId: payload.groupId)
        } catch {
            localGroup = nil
        }
        guard let group = localGroup else {
            #if DEBUG
            print("🔐 [GroupKeyATSAM] DROP — group \(payload.groupId.prefix(8)) not in local DB. Key arrived before group_create.")
            #endif
            return
        }
        let members = group.members ?? []
        guard members.contains(where: { $0.userId == myId }) else {
            #if DEBUG
            print("🔐 [GroupKeyATSAM] DROP — we are NOT a member of group \(payload.groupId.prefix(8))")
            #endif
            return
        }
        guard members.contains(where: { $0.userId == payload.broadcastedBy }) else {
            #if DEBUG
            print("🔐 [GroupKeyATSAM] DROP — broadcaster \(payload.broadcastedBy.prefix(8)) is NOT a member of \(payload.groupId.prefix(8))")
            #endif
            return
        }

        // Gate 7: 24h freshness window — bidirectional.
        // 🔐 ROUND 76 (2026-05-24) — Hacker #6 finding #7. `abs(age)`
        // rejects both past-replays AND future-dated payloads.
        let age = Date().timeIntervalSince1970 - payload.issuedAt
        if abs(age) > 24 * 3600 {
            #if DEBUG
            print("🔐 [GroupKeyATSAM] DROP — payload age=\(Int(age))s (|age| > 24h limit)")
            #endif
            return
        }

        // Gate 8: ingest.
        let accepted = await MainActor.run {
            GroupKeyService.shared.ingestMeshKey(
                groupId: payload.groupId,
                version: payload.keyVersion,
                keyB64: payload.keyB64
            )
        }

        #if DEBUG
        print("🔐 [GroupKeyATSAM] \(accepted ? "✅ ACCEPTED" : "❌ REJECTED-BY-SERVICE") gid=\(payload.groupId.prefix(8)) v=\(payload.keyVersion) from=\(payload.broadcastedBy.prefix(8))")
        #endif

        if accepted {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("groupKeyIngested"),
                    object: nil,
                    userInfo: ["groupId": payload.groupId]
                )
            }
        }
    }

    // MARK: - App Termination

    func applicationWillTerminate(_ application: UIApplication) {
        CrashGuard.shared.log(.lifecycle, "App terminating (willTerminate)")
        CrashGuard.shared.markCleanExit()
    }

    // MARK: - Round 70 — Temporary-directory janitor
    //
    // 🔴 Hacker-audit BACKUP-CRIT-1. VaultPayloadResolver writes
    // decrypted plaintext to `tmp/<uuid>_<stem>.<ext>` for QuickLook
    // / AVPlayer / UIImage rendering. The viewer dismiss handler is
    // supposed to unlink that file, but a crash mid-view or an
    // app-kill before the dismiss handler runs leaves the plaintext
    // on disk. iOS opportunistically GCs tmp/ but the window is
    // long enough to be a real exfil surface. Same story for video
    // compression intermediates + multipart upload envelopes.
    //
    // This sweep runs once at launch (before any viewer can write
    // new tmp files) and unlinks every file in tmp/ that looks like
    // it could be sensitive — vault plaintext extensions and the
    // multipart envelope marker. Best-effort: a failure to unlink
    // any single file is logged + the sweep continues.

    /// 🔴 ROUND 70 — set `.complete` file protection on the
    /// per-app preferences plist (where UserDefaults persists) AND
    /// the App-Group container if present. Backups taken while the
    /// device is locked will then carry encrypted blobs only.
    ///
    /// Idempotent — re-applying the same attribute is a no-op.
    /// Best-effort: a failure here is logged and ignored; the
    /// security guarantee degrades silently to "as before round 70",
    /// not to a crash.
    static func hardenPreferencesPlistProtection() {
        let fm = FileManager.default
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        let prefsURL = libraryURL?
            .appendingPathComponent("Preferences")
            .appendingPathComponent("\(bundleId).plist")

        let targets: [URL] = [prefsURL].compactMap { $0 }
        for url in targets {
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
                #if DEBUG
                print("🔐 [Prefs] applied .completeFileProtection to \(url.lastPathComponent)")
                #endif
            } catch {
                #if DEBUG
                print("🔐 [Prefs] could not harden \(url.lastPathComponent): \(error.localizedDescription)")
                #endif
            }
        }
    }

    static func pruneTemporaryDirectory() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let sensitiveExtensions: Set<String> = [
            "pdf", "jpg", "jpeg", "png", "gif", "webp", "heic",
            "mp4", "mov", "m4v",
            "m4a", "mp3", "wav", "aac",
            "vlt", "multipart", "bin",
        ]
        do {
            let contents = try fm.contentsOfDirectory(
                at: tmp,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
            var pruned = 0
            for url in contents {
                let ext = url.pathExtension.lowercased()
                guard sensitiveExtensions.contains(ext) else { continue }
                do {
                    try fm.removeItem(at: url)
                    pruned += 1
                } catch {
                    #if DEBUG
                    print("🧹 [TmpJanitor] failed to unlink \(url.lastPathComponent): \(error.localizedDescription)")
                    #endif
                }
            }
            #if DEBUG
            if pruned > 0 {
                print("🧹 [TmpJanitor] pruned \(pruned) sensitive tmp file(s) from previous run")
            }
            #endif
        } catch {
            #if DEBUG
            print("🧹 [TmpJanitor] scan failed: \(error.localizedDescription)")
            #endif
        }
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
