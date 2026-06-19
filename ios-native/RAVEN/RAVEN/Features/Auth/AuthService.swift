import Foundation

// MARK: - App Boot State (Prevents login flash)
enum AppBootState {
    case checking       // Still loading auth from Keychain
    case authenticated  // Valid session found
    case unauthenticated // No session / expired
}

// MARK: - Auth Service
//
// `@MainActor`-isolated (BUG FIX 2026-05-10): the previous version was
// non-isolated and let `Task.detached(priority: .utility)` write
// `currentUser` / `requiresUsernameSetup` off-main from inside
// `bootstrapFromKeychain` (line ~657). SwiftUI views observe these
// `@Observable` properties from the main actor — concurrent writes
// risked torn reads, animation glitches, and Swift-6 concurrency
// warnings. Mirrors the same fix already applied to `MessageService`.
@MainActor
@Observable
class AuthService {
    static let shared = AuthService()
    
    var bootState: AppBootState = .checking  // ✅ Start in checking state
    var currentUser: User?
    var requiresUsernameSetup = false  // True when OAuth user needs to set username
    
    // Persisted: user has seen/skipped phone collection
    var hasSeenPhoneCollection: Bool {
        get { UserDefaults.standard.bool(forKey: "hasSeenPhoneCollection") }
        set { UserDefaults.standard.set(newValue, forKey: "hasSeenPhoneCollection") }
    }
    
    var isAuthenticated: Bool { currentUser != nil }
    
    /// OAuth user who completed username but hasn't added phone
    var needsPhoneNumber: Bool {
        guard let user = currentUser else { return false }
        let isOAuth = user.authMethod == .google || user.authMethod == .apple
        return isOAuth && (user.phone == nil || user.phone?.isEmpty == true)
    }
    var isEmailVerified: Bool { currentUser?.emailVerified ?? false }
    var needsEmailVerification: Bool { isAuthenticated && !isEmailVerified }

    private init() {}

    // MARK: - Serverless (key-based) identity
    //
    // Messenger pivot: the device's on-device Ed25519 keypair
    // (DeviceIdentityService) IS the account. Registration = generate/load
    // the keypair + pick a local display name. No server, no email, no
    // password, no token. `currentUser.id` becomes the device fingerprint,
    // which the whole messaging/mesh layer already uses for sender/recipient
    // addressing — so peers identify each other by fingerprint (exchanged via
    // QR / proximity), with zero server.

    /// UserDefaults key for the locally-chosen display name.
    private static let localDisplayNameKey = "raven.local.displayName"

    /// Whether the user has explicitly chosen a display name yet. (A keypair
    /// always exists after first launch; this tracks the one-time name step.)
    var hasChosenLocalDisplayName: Bool {
        UserDefaults.standard.string(forKey: Self.localDisplayNameKey)?.isEmpty == false
    }

    /// Build `currentUser` from the on-device keypair. No server. Always
    /// succeeds once DeviceIdentityService can produce a fingerprint.
    @discardableResult
    func bootstrapLocalIdentity() async -> Bool {
        do {
            try await DeviceIdentityService.shared.initialize()
        } catch {
            #if DEBUG
            print("❌ [Auth] DeviceIdentity init failed: \(error)")
            #endif
            bootState = .unauthenticated
            return false
        }
        guard let fingerprint = DeviceIdentityService.shared.fingerprint else {
            bootState = .unauthenticated
            return false
        }
        let name = UserDefaults.standard.string(forKey: Self.localDisplayNameKey) ?? "Raven User"
        currentUser = User(
            localId: fingerprint,
            displayName: name,
            publicKey: DeviceIdentityService.shared.publicKeyBase64
        )
        requiresUsernameSetup = false
        bootState = .authenticated
        #if DEBUG
        print("🔑 [Auth] Serverless identity ready — fingerprint \(fingerprint)")
        #endif
        return true
    }

    /// Serverless registration: persist the chosen display name and (re)build
    /// the local identity. Call from the onboarding display-name screen.
    func registerLocalIdentity(displayName: String) async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? "Raven User" : trimmed, forKey: Self.localDisplayNameKey)
        await bootstrapLocalIdentity()
    }
    
    // MARK: - Register
    
    struct RegisterRequest: Encodable {
        let username: String
        let password: String
        let firstName: String
        let lastName: String
        let birthYear: Int
        let email: String
        let phone: String?
    }
    
    func register(
        username: String,
        password: String,
        firstName: String,
        lastName: String,
        birthYear: Int,
        email: String,
        phone: String? = nil
    ) async throws {
        // ⚠️ Phase 2A client-side password stretching is DISABLED.
        // It must stay in lockstep with login() — the deployed server
        // hashes whatever it receives, so register + login must send
        // the password the same way. Re-enable both together only
        // once the server-side counterpart + migration have shipped.
        let request = RegisterRequest(
            username: username,
            password: password,
            firstName: firstName,
            lastName: lastName,
            birthYear: birthYear,
            email: email,
            phone: phone
        )

        let response: TokenResponse = try await NetworkService.shared.post(
            path: "/api/auth/register",
            body: request
        )
        
        // Save restricted token with refresh token
        let scope: TokenScope = response.tokenScope == "full" ? .full : .restricted
        try await KeychainService.shared.saveToken(
            response.token,
            scope: scope,
            userId: response.userId,
            refreshToken: response.refreshToken
        )
        
        // Fetch user profile
        try await fetchCurrentUser()
        
        // Associate user with RevenueCat for subscription management
        if let userId = currentUser?.id {
            await SubscriptionService.shared.login(appUserID: userId)
        }
        
        // Register push token now that we're authenticated
        await PushNotificationService.shared.retryTokenRegistration()
    }
    
    // MARK: - Login
    
    struct LoginRequest: Encodable {
        let username: String
        let password: String
    }
    
    func login(username: String, password: String) async throws {
        // ⚠️ Phase 2A client-side password stretching is DISABLED.
        // The deployed server has no matching `RVNS1$` handling, and
        // every existing account's hash is of the RAW password — so
        // sending a stretched value would lock out every current
        // user. Re-enable only once the server-side counterpart and
        // an account-hash migration have shipped. See
        // PasswordStretcher.swift (kept for that future work).
        let request = LoginRequest(username: username, password: password)

        let response: TokenResponse = try await NetworkService.shared.post(
            path: "/api/auth/login",
            body: request
        )
        
        // Login only allowed for verified users
        try await KeychainService.shared.saveToken(
            response.token,
            scope: .full,
            userId: response.userId,
            refreshToken: response.refreshToken
        )
        
        try await fetchCurrentUser()
        
        // Register push token now that we're authenticated
        await PushNotificationService.shared.retryTokenRegistration()
        
        // Associate user with RevenueCat for subscription management
        if let userId = currentUser?.id {
            await SubscriptionService.shared.login(appUserID: userId)
        }
    }
    
    // MARK: - Send OTP
    
    struct SendCodeRequest: Encodable {
        let identifier: String
        let channel: String
        let purpose: String
    }
    
    struct SendCodeResponse: Decodable {
        let success: Bool
        let message: String?
        let expiresInSeconds: Int?
    }
    
    func sendVerificationCode(email: String, purpose: String = "verify_email") async throws -> Int {
        let request = SendCodeRequest(
            identifier: email,
            channel: "email",
            purpose: purpose
        )
        
        let response: SendCodeResponse = try await NetworkService.shared.post(
            path: "/api/auth/send-code",
            body: request
        )
        
        return response.expiresInSeconds ?? 600
    }
    
    /// Check if email is available for registration AND send verification code in one step.
    /// Returns `(available, errorMessage)`.
    /// When available == true, the verification code has already been sent.
    func checkEmailAndSendCode(email: String) async throws -> (available: Bool, message: String?) {
        let request = SendCodeRequest(
            identifier: email,
            channel: "email",
            purpose: "registration"
        )
        
        do {
            let _: SendCodeResponse = try await NetworkService.shared.post(
                path: "/api/auth/send-code",
                body: request
            )
            // Success — email is available and code was sent
            return (true, nil)
        } catch let error as APIError {
            switch error {
            case .badRequest(let msg):
                if msg.lowercased().contains("already registered") {
                    return (false, "This email is already registered. Try signing in instead.")
                }
                return (false, msg)
            case .rateLimited:
                return (false, "Too many attempts. Please wait a moment.")
            default:
                throw error
            }
        }
    }
    
    // MARK: - Verify OTP
    
    struct VerifyCodeRequest: Encodable {
        let identifier: String
        let code: String
        let purpose: String
    }
    
    func verifyCode(email: String, code: String, purpose: String = "verify_email") async throws {
        let request = VerifyCodeRequest(
            identifier: email,
            code: code,
            purpose: purpose
        )
        
        let response: VerifyCodeResponse = try await NetworkService.shared.post(
            path: "/api/auth/verify-code",
            body: request
        )
        
        // Upgrade to full token if provided
        if let fullToken = response.fullAccessToken {
            try await KeychainService.shared.upgradeToFullToken(fullToken)
        }
        
        // Refresh user to get updated email_verified
        try await fetchCurrentUser()
    }
    
    // MARK: - Reset Password
    
    struct ResetPasswordRequest: Encodable {
        let identifier: String
        let code: String
        let newPassword: String
        
        enum CodingKeys: String, CodingKey {
            case identifier
            case code
            case newPassword = "new_password"
        }
    }
    
    struct ResetPasswordResponse: Decodable {
        let success: Bool
        let message: String?
    }
    
    func resetPassword(email: String, code: String, newPassword: String) async throws {
        let request = ResetPasswordRequest(
            identifier: email,
            code: code,
            newPassword: newPassword
        )
        
        let _: ResetPasswordResponse = try await NetworkService.shared.post(
            path: "/api/auth/reset-password",
            body: request
        )
    }
    
    // MARK: - Google OAuth
    
    struct GoogleOAuthRequest: Encodable {
        let idToken: String
    }
    
    func googleSignIn(idToken: String) async throws -> Bool {
        let request = GoogleOAuthRequest(idToken: idToken)
        
        let response: TokenResponse = try await NetworkService.shared.post(
            path: "/api/auth/oauth/google",
            body: request
        )
        
        // OAuth users always get full scope - Google already verified email
        try await KeychainService.shared.saveToken(
            response.token,
            scope: .full,
            userId: response.userId,
            refreshToken: response.refreshToken
        )
        
        // Check if user needs to set username - either explicit flag or null username
        let needsUsername = response.requiresUsername == true || response.username == nil
        
        if needsUsername {
            requiresUsernameSetup = true
        } else {
            try await fetchCurrentUser()
            // Associate user with RevenueCat for subscription management
            if let userId = currentUser?.id {
                await SubscriptionService.shared.login(appUserID: userId)
            }
            // Register push token now that we're authenticated
            await PushNotificationService.shared.retryTokenRegistration()
        }
        
        return needsUsername
    }
    
    // MARK: - Apple OAuth
    
    struct AppleOAuthRequest: Encodable {
        let identityToken: String
        let authorizationCode: String
        let fullName: String?
        let email: String?
    }
    
    func appleSignIn(
        identityToken: String,
        authorizationCode: String,
        fullName: String? = nil,
        email: String? = nil
    ) async throws -> Bool {
        let request = AppleOAuthRequest(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            fullName: fullName,
            email: email
        )
        
        let response: TokenResponse = try await NetworkService.shared.post(
            path: "/api/auth/oauth/apple",
            body: request
        )
        
        // OAuth users always get full scope - Apple already verified email
        try await KeychainService.shared.saveToken(
            response.token,
            scope: .full,
            userId: response.userId,
            refreshToken: response.refreshToken
        )
        
        // Check if user needs to set username - either explicit flag or null username
        let needsUsername = response.requiresUsername == true || response.username == nil
        
        if needsUsername {
            requiresUsernameSetup = true
        } else {
            try await fetchCurrentUser()
            // Associate user with RevenueCat for subscription management
            if let userId = currentUser?.id {
                await SubscriptionService.shared.login(appUserID: userId)
            }
            // Register push token now that we're authenticated
            await PushNotificationService.shared.retryTokenRegistration()
        }
        
        return needsUsername
    }
    
    // MARK: - Set Username (OAuth flow)
    
    struct SetUsernameRequest: Encodable {
        let username: String
        let tempToken: String
    }
    
    func setUsername(_ username: String) async throws {
        guard let (token, _) = await KeychainService.shared.getToken() else {
            throw APIError.unauthorized
        }
        
        let request = SetUsernameRequest(username: username, tempToken: token)
        
        let _: EmptyResponse = try await NetworkService.shared.post(
            path: "/api/auth/set-username",
            body: request
        )
        
        requiresUsernameSetup = false
        try await fetchCurrentUser()
    }
    
    struct EmptyResponse: Decodable {}
    
    // MARK: - Check Username Availability
    
    struct UsernameCheckResponse: Decodable {
        let available: Bool
        let suggestion: String?
    }
    
    func checkUsernameAvailability(_ username: String) async throws -> Bool {
        let response: UsernameCheckResponse = try await NetworkService.shared.get(
            path: "/api/auth/check-username",
            queryItems: [URLQueryItem(name: "username", value: username)]
        )
        return response.available
    }
    
    // MARK: - Fetch User
    
    func fetchCurrentUser() async throws {
        do {
            currentUser = try await NetworkService.shared.get(path: "/api/users/me")
            cacheUserProfile(currentUser)  // Persist for offline boot

            // Forward server-granted premium status (e.g. admin accounts)
            if let user = currentUser {
                await SubscriptionService.shared.setServerPremiumStatus(user.isPremium)

                // 🔴 ROUND 71 phase 3 — register the signed-in user in
                // MeshIdentityResolver so inbound strict-strip
                // envelopes addressed to us via the hashed identity
                // token resolve back to our real id. Without this,
                // self-recipient envelopes drop into the "bridge"
                // branch and never decrypt locally. Friends are
                // registered separately via
                // `GroupService.fetchFriends()` / `getCachedFriends()`.
                await MeshIdentityResolver.shared.register(userId: user.id)
            }

            // Hydrate notification + privacy settings from server (fire-and-forget)
            Task { await hydrateSettingsFromServer() }
        } catch APIError.restricted {
            // Restricted token can still fetch basic user info
            throw APIError.restricted
        } catch APIError.usernameRequired {
            // User needs to set username first
            requiresUsernameSetup = true
            throw APIError.usernameRequired
        }
    }
    
    // MARK: - Settings Hydration
    
    /// Pull notification + privacy settings from server and write to @AppStorage.
    /// Ensures preferences survive reinstall / device change.
    private func hydrateSettingsFromServer() async {
        struct SettingsResponse: Decodable {
            let notification: NotifPrefs
            let privacy: PrivacyPrefs
        }
        struct NotifPrefs: Decodable {
            let pushEnabled: Bool
            let messagesEnabled: Bool
            let friendRequestsEnabled: Bool
            let likesCommentsEnabled: Bool
            let soundsEnabled: Bool
            let messagePreview: Bool
            // Bug 9 fix: Removed explicit snake_case raw values (e.g. = "push_enabled").
            // NetworkService decoder uses .convertFromSnakeCase → push_enabled becomes pushEnabled.
            // The old explicit keys caused double conversion: decoder already converted, then
            // CodingKey mapped BACK to snake_case, so nothing matched.
            enum CodingKeys: String, CodingKey {
                case pushEnabled, messagesEnabled, friendRequestsEnabled
                case likesCommentsEnabled, soundsEnabled, messagePreview
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                pushEnabled = (try? c.decode(Bool.self, forKey: .pushEnabled)) ?? true
                messagesEnabled = (try? c.decode(Bool.self, forKey: .messagesEnabled)) ?? true
                friendRequestsEnabled = (try? c.decode(Bool.self, forKey: .friendRequestsEnabled)) ?? true
                likesCommentsEnabled = (try? c.decode(Bool.self, forKey: .likesCommentsEnabled)) ?? true
                soundsEnabled = (try? c.decode(Bool.self, forKey: .soundsEnabled)) ?? true
                messagePreview = (try? c.decode(Bool.self, forKey: .messagePreview)) ?? true
            }
        }
        struct PrivacyPrefs: Decodable {
            let showOnlineStatus: Bool
            let readReceipts: Bool
            let whoCanMessage: String
            let whoCanSeeProfile: String
            // Bug 9 fix: Same fix — removed explicit snake_case raw values
            enum CodingKeys: String, CodingKey {
                case showOnlineStatus, readReceipts, whoCanMessage, whoCanSeeProfile
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                showOnlineStatus = (try? c.decode(Bool.self, forKey: .showOnlineStatus)) ?? true
                readReceipts = (try? c.decode(Bool.self, forKey: .readReceipts)) ?? true
                whoCanMessage = (try? c.decode(String.self, forKey: .whoCanMessage)) ?? "everyone"
                whoCanSeeProfile = (try? c.decode(String.self, forKey: .whoCanSeeProfile)) ?? "public"
            }
        }
        
        do {
            let settings: SettingsResponse = try await NetworkService.shared.get(
                path: "/api/users/me/settings"
            )
            let d = UserDefaults.standard
            // Notification preferences
            d.set(settings.notification.pushEnabled, forKey: "pushNotifications")
            d.set(settings.notification.messagesEnabled, forKey: "messageNotifications")
            d.set(settings.notification.friendRequestsEnabled, forKey: "friendRequestNotifications")
            d.set(settings.notification.likesCommentsEnabled, forKey: "likesCommentsNotifications")
            d.set(settings.notification.soundsEnabled, forKey: "soundsEnabled")
            d.set(settings.notification.messagePreview, forKey: "messagePreview")
            // Privacy preferences
            d.set(settings.privacy.showOnlineStatus, forKey: "showOnlineStatus")
            d.set(settings.privacy.readReceipts, forKey: "readReceipts")
            d.set(settings.privacy.whoCanMessage, forKey: "whoCanMessage")
            d.set(settings.privacy.whoCanSeeProfile, forKey: "whoCanSeeProfile")
            
            #if DEBUG
            print("✅ [Auth] Settings hydrated from server")
            #endif
        } catch {
            // Non-fatal — local @AppStorage values remain as fallback
            #if DEBUG
            print("⚠️ [Auth] Failed to hydrate settings: \(error)")
            #endif
        }
    }
    
    // MARK: - Offline Profile Cache
    
    private static let cachedUserKey = "cachedUserProfile"
    
    private func cacheUserProfile(_ user: User?) {
        guard let user else { return }
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Self.cachedUserKey)
        }
    }
    
    func loadCachedUserProfile() -> User? {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedUserKey) else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }
    
    // MARK: - Logout
    
    func logout() async throws {
        AuthLogger.log(.logoutDecision, detail: "explicit logout")
        
        // 1. Clear keychain (token)
        // Use try? — keychain failure must not block remaining cleanup
        try? await KeychainService.shared.deleteAll()

        // 🔴 ROUND 71 phase 3 — wipe MeshIdentityResolver so the
        // next account that signs in on the same device doesn't
        // inherit the previous user's peer→userId map. Pre-fix the
        // map persisted across logouts, meaning a hashed peer
        // token for user A's contact could resolve under user B's
        // session (cross-account identity leak in the local mesh
        // receive path).
        await MeshIdentityResolver.shared.reset()

        // 🔐 ROUND 76 (2026-05-24) — Hacker #9 V1 CRITICAL.
        //
        // Pre-fix, logout() wiped KeychainService + DB but left:
        //   • ATSAMRootStorage Keychain rows (service prefix
        //     `app.raven.ios.atsam.root` ≠ KeychainService's
        //     `app.raven.ios`, so `deleteAll()` skipped them)
        //   • GroupKeyService Keychain blob (service
        //     `com.raven.groupkeys`)
        //   • SealedReplayWindow UserDefaults blob
        //     (`raven.sealer.replayWindow.v1`)
        //
        // Cross-account leak: User A logs out → User B logs in
        // on the same device → B's GroupKeyService loads A's
        // persisted group keys; B's ATSAMRootStorage returns A's
        // ATSAM roots when sending to A's old peers. B could
        // decrypt incoming ATSAM ciphertext addressed to A and
        // forge outbound messages from A.
        //
        // Fix: explicit purge of every per-user crypto store BEFORE
        // signaling the rest of logout. All three calls are
        // best-effort `try?`-equivalent (the storages internally
        // swallow Keychain errors) so a failure doesn't block the
        // rest of cleanup.
        await ATSAMRootStorage.shared.purgeAll()
        await MainActor.run { GroupKeyService.shared.reset() }
        // SealedReplayWindow is a fileprivate actor inside
        // MessageContentSealer; expose a purge hook via the sealer.
        await MessageContentSealer.purgeReplayWindow()
        
        // 2. Clear SQLite database (messages, conversations, notifications, posts)
        try? await DatabaseService.shared.clearAllData()
        
        // 2b. Dismiss audio playback (stop any playing audio)
        await MainActor.run { AudioPlaybackStore.shared.dismiss() }
        
        // 3. Stop mesh/presence services (must happen before clearing stores)
        await MainActor.run {
            BLEMeshEngine.shared.stop()
            BackgroundMeshManager.shared.stopBackgroundLocationAnchor()
            PresenceService.shared.stopHeartbeat()
        }
        
        // 4. Clear in-memory stores
        await MainActor.run {
            ConversationStore.shared.conversations = []
            NotificationStore.shared.notifications = []
            ContactsService.shared.contacts = []
            ContactsService.shared.matches = []
            BlockService.shared.clearBlockList()
            ModerationService.shared.clearActions()
        }
        
        // 4. Clear image caches
        URLCache.shared.removeAllCachedResponses()
        // 4b. Wipe avatar disk cache so the next user doesn't see the
        // previous user's social-graph avatars on first launch (they
        // would resolve correctly to new avatars eventually but the
        // first paint would briefly show the wrong faces).
        await AvatarCacheService.shared.wipe()
        
        // 5. Clear session-related user defaults (preserve design/language/onboarding prefs)
        let sessionKeys = [
            "cachedUserProfile",
            "pushNotifications", "messageNotifications", "friendRequestNotifications",
            "likesCommentsNotifications", "soundsEnabled", "messagePreview",
            "showOnlineStatus", "readReceipts", "whoCanMessage", "whoCanSeeProfile",
            "hasSeenPhoneCollection", "twoFactorEnabled",
            "appLockEnabled", "appLockTimeout", "hideInAppSwitcher",
            "discovery_suggestions_cache", "discovery_suggestions_timestamp",
            "raven_friends_cache", "raven_contact_matches_cache"
        ]
        for key in sessionKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // 🔐 BUG FIX (2026-05-10): also drop every per-conversation
        // `draft_<roomId>` key. The old hard-coded sessionKeys list
        // missed these, so logging out of account A and into account
        // B preloaded A's draft into any chat that happened to share
        // the same deterministic 1:1 roomId.
        let allKeys = UserDefaults.standard.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("draft_") || key.hasPrefix("scrollPos_") || key.hasPrefix("unread_") {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // (MessageStore is per-room and deallocated when its view
        // unmounts on logout — no global singleton wipe needed here.
        // The previous-round audit's claim about a `MessageStore.shared`
        // was based on a pattern that doesn't actually exist in this
        // codebase. False positive — no fix required.)
        
        // 7. Clear RevenueCat identity
        await SubscriptionService.shared.logout()

        // 8. Clear shared cookie storage for the API host so the next
        // user doesn't inherit FastAPI session cookies (CSRF, telemetry,
        // refresh hints) set during the previous session.
        // BUG FIX (2026-05-10): NetworkService uses
        // `URLSessionConfiguration.default` whose `httpCookieStorage`
        // is `HTTPCookieStorage.shared` — cookies survived logout
        // before this. We also drop URLCache and reset URL credential
        // storage for the API host.
        if let apiURL = URL(string: AppConfig.apiBaseURL),
           let cookies = HTTPCookieStorage.shared.cookies(for: apiURL) {
            for cookie in cookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        URLCache.shared.removeAllCachedResponses()

        // 9. Reset auth state
        currentUser = nil
        requiresUsernameSetup = false
        
        #if DEBUG
        print("[AuthService] Logged out - all data cleared")
        #endif
    }
    
    // MARK: - Graceful Re-Auth (Network Resilience)
    
    /// Called when API requests fail with 401 after exhausted refresh.
    /// Instead of immediately logging out, tries one more re-validation.
    /// Only logs out on confirmed auth failure — NOT on network errors.
    func handleForceReAuth() async {
        AuthLogger.log(.logoutDecision, detail: "handleForceReAuth called — validating session")
        
        // 1. Do we even have credentials?
        guard await KeychainService.shared.getRefreshToken() != nil else {
            AuthLogger.log(.logoutDecision, detail: "no refresh token — must logout")
            try? await logout()
            bootState = .unauthenticated
            return
        }
        
        // 2. Try to fetch user (will auto-refresh via NetworkService if needed)
        do {
            try await fetchCurrentUser()
            // Session is still valid — false alarm
            AuthLogger.log(.networkErrorIgnored, detail: "session re-validated successfully — NOT logging out")
        } catch let error as APIError where error.isAuthError {
            // Confirmed auth failure from server → must logout
            AuthLogger.log(.logoutDecision, detail: "confirmed auth error: \(error) — logging out")
            try? await logout()
            bootState = .unauthenticated
        } catch {
            // Network/timeout/DNS error — keep user logged in with cached profile
            if let cached = loadCachedUserProfile() {
                currentUser = cached
                
                // Restore premium status for offline use
                Task { @MainActor in
                    SubscriptionService.shared.setServerPremiumStatus(cached.isPremium)
                }
                
                AuthLogger.log(.networkErrorIgnored, detail: "network error during re-auth, using cached profile for \(cached.username ?? "user")")
            } else {
                AuthLogger.log(.networkErrorIgnored, detail: "network error + no cached profile — staying authenticated with stale state")
            }
            // Do NOT change bootState or logout — user stays logged in
        }
    }
    
    // MARK: - Check Session (Bootstrap)
    
    func checkExistingSession() async {
        // 🔑 SERVERLESS IDENTITY (messenger pivot): the on-device Ed25519
        // keypair IS the account. No server token is required — the app
        // always boots into a local key-based identity. The server-based
        // bootstrap below is dead while serverless mode is active, but kept
        // (unreferenced) until the legacy auth methods are removed.
        await bootstrapLocalIdentity()
    }

    func checkExistingSessionServerLegacy() async {
        guard await KeychainService.shared.getToken() != nil else {
            bootState = .unauthenticated
            return
        }

        // 🚀 FAST PATH: لاگین آنی از روی کَش (بدون انتظار برای اینترنت)
        if let cached = loadCachedUserProfile() {
            currentUser = cached
            bootState = .authenticated // خروج فوری از صفحه اسپلش
            
            Task { @MainActor in
                SubscriptionService.shared.setServerPremiumStatus(cached.isPremium)
            }
            
            // گرفتن اطلاعات آپدیت‌شده در پس‌زمینه، بدون اینکه کاربر متوجه شود
            // Was `Task.detached(priority: .utility)` which wrote
            // currentUser / requiresUsernameSetup off-main. The class is
            // now `@MainActor`-isolated, so a regular `Task { ... }`
            // inherits MainActor and the inner `await` writes are safe.
            // The 500ms sleep keeps the original "let UI fully load
            // first" intent.
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                do {
                    try await self.fetchCurrentUser()
                } catch APIError.usernameRequired {
                    self.requiresUsernameSetup = true
                } catch let error as APIError where error.isAuthError {
                    try? await self.logout()
                    self.bootState = .unauthenticated
                } catch {
                    // در صورت قطعی اینترنت، اپلیکیشن با همان کش به کار خود ادامه می‌دهد
                }
            }
            return
        }
        
        // اگر کَش خالی بود (مثل نصب اولیه اپلیکیشن)
        do {
            try await fetchCurrentUser()
            bootState = .authenticated
        } catch APIError.usernameRequired {
            requiresUsernameSetup = true
            bootState = .authenticated
        } catch let error as APIError where error.isAuthError {
            #if DEBUG
            print("🔒 [Auth] Auth error — logging out: \(error)")
            #endif
            try? await logout()
            bootState = .unauthenticated
        } catch {
            // Network/timeout error — no cache available
            bootState = .unauthenticated
            #if DEBUG
            print("⚠️ [Auth] No cache + network error — showing login")
            #endif
        }
    }
}

// Note: TokenResponse and VerifyCodeResponse are defined in Models/User.swift
