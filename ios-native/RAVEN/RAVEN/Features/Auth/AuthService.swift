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

    /// OAuth user who completed username but hasn't added phone.
    /// Serverless model: there is no OAuth (Google/Apple) path anymore, so
    /// this is always `false` for the local key-based identity. Kept as a
    /// stable accessor for any view still reading it.
    var needsPhoneNumber: Bool {
        guard let user = currentUser else { return false }
        let isOAuth = user.authMethod == .google || user.authMethod == .apple
        return isOAuth && (user.phone == nil || user.phone?.isEmpty == true)
    }

    /// Serverless (no-account) model: there is no email to verify — the
    /// on-device keypair IS the account. This MUST report `true` whenever an
    /// identity exists so the email-verification gate never blocks realtime
    /// connect / sync (see `RealtimeEngine`'s readiness checks, which guard on
    /// `auth.isEmailVerified`). Returns `false` only when there is no identity
    /// at all, in which case `isAuthenticated` is already `false`.
    var isEmailVerified: Bool { isAuthenticated }

    /// Serverless model: never require email verification. Always `false`.
    var needsEmailVerification: Bool { false }

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

    /// UserDefaults key for the locally-chosen avatar file path (serverless —
    /// the avatar lives on-device only, so it must be re-applied to currentUser
    /// on every launch by bootstrapLocalIdentity).
    private static let localAvatarPathKey = "raven.local.avatarPath"

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
        // Persist the fingerprint as the canonical serverless self-id so
        // KeychainService.getUserId() — which the mesh/bridge/crypto layer reads
        // for `isForMe`, signing and addressing — returns OUR identity, not an
        // empty (fresh install) or stale server-era UUID. Without this the bridge
        // drops legitimate inbound messages and the device seals under the wrong id.
        try? await KeychainService.shared.saveUserId(fingerprint)
        let name = UserDefaults.standard.string(forKey: Self.localDisplayNameKey) ?? "Raven User"
        currentUser = User(
            localId: fingerprint,
            displayName: name,
            publicKey: DeviceIdentityService.shared.publicKeyBase64
        )
        // Re-apply the locally-stored avatar (serverless: not in any server record).
        currentUser?.avatarPath = UserDefaults.standard.string(forKey: Self.localAvatarPathKey)
        requiresUsernameSetup = false
        bootState = .authenticated
        #if DEBUG
        print("🔑 [Auth] Serverless identity ready — fingerprint \(fingerprint)")
        #endif
        return true
    }

    /// Serverless registration: persist the chosen display name and (re)build
    /// the local identity. Call from the onboarding display-name screen.
    /// Returns `true` on success; `false` if device-key generation failed
    /// (e.g. the Keychain is unavailable) so the caller can surface an error
    /// instead of spinning on "Creating identity…" forever.
    @discardableResult
    func registerLocalIdentity(displayName: String) async -> Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? "Raven User" : trimmed, forKey: Self.localDisplayNameKey)
        return await bootstrapLocalIdentity()
    }

    /// Serverless display-name edit: persist the new name to the local key and
    /// rebuild `currentUser` in place so the change is visible immediately AND
    /// survives relaunch (bootstrapLocalIdentity reads the same key). There is
    /// no server record for the device-fingerprint account, so this — not a
    /// `/api/users/me` PATCH — is the canonical way to change the display name.
    /// Returns `false` only if the device keypair has no fingerprint yet.
    @discardableResult
    func setLocalDisplayName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "Raven User" : trimmed
        UserDefaults.standard.set(final, forKey: Self.localDisplayNameKey)
        guard let fingerprint = DeviceIdentityService.shared.fingerprint else { return false }
        // Same initializer used by bootstrapLocalIdentity — keeps id/publicKey consistent.
        currentUser = User(
            localId: fingerprint,
            displayName: final,
            publicKey: DeviceIdentityService.shared.publicKeyBase64
        )
        // Editing the name rebuilds currentUser, so re-apply the stored avatar.
        currentUser?.avatarPath = UserDefaults.standard.string(forKey: Self.localAvatarPathKey)
        return true
    }

    /// Serverless avatar persistence: store the local avatar file path (or clear
    /// it) so it survives relaunch + name edits. No server round-trip.
    func setLocalAvatarPath(_ path: String?) {
        if let path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: Self.localAvatarPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.localAvatarPathKey)
        }
        currentUser?.avatarPath = path
    }

    // MARK: - Register / Login (REMOVED — serverless)
    //
    // The server-era `register(...)` and `login(...)` methods (POST
    // /api/auth/register, /api/auth/login) plus their `RegisterRequest` /
    // `LoginRequest` bodies were deleted in the serverless pivot. The local
    // key-based identity (registerLocalIdentity / bootstrapLocalIdentity) is
    // now the only account path — there is no username/password, token, or
    // server. Grep-confirmed zero call sites before removal.

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
    
    // MARK: - OAuth + Set Username (REMOVED — serverless)
    //
    // `googleSignIn(...)` / `appleSignIn(...)` (POST /api/auth/oauth/google,
    // /api/auth/oauth/apple) and `setUsername(...)` (POST
    // /api/auth/set-username), plus their request structs, were deleted in the
    // serverless pivot. There is no OAuth provider, no server username
    // namespace, and no `requiresUsernameSetup` server step — the local
    // key-based identity replaces all of it. Grep-confirmed zero call sites
    // before removal.

    /// Empty server response shape, retained for any in-file decode use.
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
        // PeerKeyDirectory uses service `app.raven.ios.peerKey` (not
        // KeychainService's `app.raven.ios`), so deleteAll() never
        // touches trust pins. Wipe them on logout to stop User B from
        // inheriting User A's peer identity/agreement pins.
        await PeerKeyDirectory.shared.purgeAllPins()
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
        // always boots into a local key-based identity. (The legacy
        // token/cache server bootstrap, `checkExistingSessionServerLegacy`,
        // was removed in the serverless cleanup — it had zero call sites.)
        await bootstrapLocalIdentity()
    }
}

// Note: TokenResponse and VerifyCodeResponse are defined in Models/User.swift
