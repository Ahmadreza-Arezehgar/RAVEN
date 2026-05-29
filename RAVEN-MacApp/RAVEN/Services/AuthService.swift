// AuthService — authentication state for the macOS app, an
// `@MainActor` `ObservableObject` so SwiftUI views can drive the auth
// landing → main shell transition by observing `isAuthenticated`.
//
// We persist tokens in the keychain (App-Sandbox-private), and on cold
// launch we attempt a `currentUser()` round-trip; if that 401s we drop
// the saved tokens.

import Foundation
import Combine

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published private(set) var currentUser: User?
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var isBootstrapping: Bool = true
    @Published private(set) var lastError: String?

    private init() {}

    // MARK: - Lifecycle

    /// Try to restore the session from keychain on app launch.
    ///
    /// We only wipe the saved token when the server actively rejects it
    /// (401 / authExpired). Transient failures (offline, DNS hiccup, decode
    /// mismatch from a server-side schema change) must NOT log the user
    /// out — that would silently sign them out every time their Wi-Fi
    /// blinks. In those cases we leave the token in keychain and surface
    /// an unauthenticated UI for now; the next launch will retry.
    func bootstrapFromKeychain() async {
        defer { isBootstrapping = false }
        guard
            let token = KeychainService.shared.read(.accessToken),
            !token.isEmpty
        else {
            isAuthenticated = false
            return
        }
        do {
            let user = try await NetworkService.shared.currentUser()
            currentUser = user
            isAuthenticated = true
            RealtimeEngine.shared.start()
            BLEMeshEngine.shared.start()
        } catch APIError.authExpired {
            // Token genuinely rejected — wipe so we don't loop.
            KeychainService.shared.wipe()
            currentUser = nil
            isAuthenticated = false
        } catch APIError.http(let code, _) where code == 401 {
            // Defense in depth: if a code path bypasses the authExpired
            // mapping, treat 401 the same way.
            KeychainService.shared.wipe()
            currentUser = nil
            isAuthenticated = false
        } catch {
            // Transient (transport, decode, server 5xx). Keep the token —
            // user can still try operations that may bypass /me, and the
            // next cold launch will re-attempt.
            currentUser = nil
            isAuthenticated = false
            #if DEBUG
            print("⚠️ [auth] keychain bootstrap failed transiently, keeping token: \(error)")
            #endif
        }
    }

    // MARK: - Email login

    func signIn(username: String, password: String) async {
        lastError = nil
        do {
            let resp = try await NetworkService.shared.login(
                username: username, password: password)
            persist(resp)
            do {
                let user = try await NetworkService.shared.currentUser()
                currentUser = user
            } catch {
                // Fallback: the login response already gave us username +
                // user_id; build a thin User so the UI can move on.
                currentUser = User(
                    id: resp.userId,
                    username: resp.username,
                    email: nil,
                    firstName: nil,
                    lastName: nil,
                    avatarPath: nil,
                    bio: nil
                )
            }
            isAuthenticated = true
            RealtimeEngine.shared.start()
            BLEMeshEngine.shared.start()
        } catch {
            lastError = friendly(error)
        }
    }

    // MARK: - Apple Sign-In

    private var appleCoordinator: AppleSignInCoordinator?

    /// Kick off the Sign-in-with-Apple flow via our own coordinator (used for
    /// non-button entry points). The coordinator owns the
    /// `ASAuthorizationController`; we hold a strong reference here for the
    /// duration of the flow so the system delegate callbacks land. On success
    /// we POST `identity_token` + `authorization_code` to the same backend
    /// endpoint the iOS app uses (`/api/auth/oauth/apple`).
    func signInWithApple() async {
        lastError = nil
        let credential: AppleSignInCoordinator.AppleCredential
        do {
            credential = try await withCheckedThrowingContinuation { cont in
                let coord = AppleSignInCoordinator { result in
                    cont.resume(with: result)
                }
                self.appleCoordinator = coord
                coord.startSignIn()
            }
        } catch {
            appleCoordinator = nil
            if let appleErr = error as? AppleSignInError, case .cancelled = appleErr { return }
            lastError = friendly(error)
            return
        }
        appleCoordinator = nil

        await completeAppleSignIn(
            identityToken: credential.identityToken,
            authorizationCode: credential.authorizationCode
        )
    }

    /// Backend exchange entry point for callers that already have an Apple
    /// credential — primarily SwiftUI's `SignInWithAppleButton` whose
    /// `onCompletion` hands us the `ASAuthorization` directly.
    func completeAppleSignIn(identityToken: String, authorizationCode: String) async {
        lastError = nil
        await exchangeOAuth(provider: "apple") {
            try await NetworkService.shared.oauthApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode
            )
        }
    }

    /// Surface a user-visible error from external auth callbacks (e.g. when
    /// SwiftUI's SignInWithAppleButton returns an error directly to the view
    /// without going through AuthService).
    func reportSignInError(_ message: String) {
        lastError = message
    }

    /// Clear any pending sign-in error. Called when an auth sheet dismisses
    /// so a stale error from a previous attempt doesn't bleed onto the
    /// landing screen.
    func clearSignInError() {
        lastError = nil
    }

    // MARK: - Google Sign-In

    private var googleCoordinator: GoogleSignInCoordinator?
    private var googleInFlight: Bool = false

    func signInWithGoogle() async {
        // ASWebAuthenticationSession-driven OAuth: the coordinator's
        // completion closure fires on a private XPC queue, NOT the main
        // thread. Anything inside this closure is therefore non-isolated;
        // accessing `@MainActor` state from it crashes with
        // `swift_task_checkIsolatedSwift` under strict concurrency. So:
        //   1. The closure does the absolute minimum — resume the
        //      continuation and return.
        //   2. We clean up `self.googleCoordinator` AFTER the await
        //      resumes (we're back on the MainActor at that point).
        if googleInFlight { return }
        googleInFlight = true
        defer { googleInFlight = false }

        lastError = nil
        let credential: GoogleSignInCoordinator.GoogleCredential
        do {
            credential = try await withCheckedThrowingContinuation { cont in
                // Note: do NOT capture `self` in the completion closure —
                // it would force a MainActor access on a background queue.
                let coord = GoogleSignInCoordinator { result in
                    cont.resume(with: result)
                }
                self.googleCoordinator = coord
                coord.startSignIn()
            }
            self.googleCoordinator = nil
        } catch {
            self.googleCoordinator = nil
            if let googleErr = error as? GoogleSignInError, case .cancelled = googleErr { return }
            lastError = friendly(error)
            return
        }

        await exchangeOAuth(provider: "google") {
            try await NetworkService.shared.oauthGoogle(idToken: credential.idToken)
        }
    }

    /// Shared backend exchange path for OAuth providers. Persists tokens on
    /// success and surfaces a friendly error message on failure. If the server
    /// signals `requires_username` we keep the user signed-out and prompt them
    /// to finish onboarding from another client — username selection isn't
    /// part of the App Store MVP UI yet.
    private func exchangeOAuth(provider: String,
                               request: () async throws -> OAuthTokenResponse) async {
        do {
            let resp = try await request()
            if resp.requiresUsername == true || (resp.username ?? "").isEmpty {
                lastError = "\(provider.capitalized) account is missing a username. Pick one in the iOS app, then try again."
                return
            }
            KeychainService.shared.set(resp.token, for: .accessToken)
            KeychainService.shared.set(resp.refreshToken, for: .refreshToken)
            KeychainService.shared.set(resp.userId, for: .userId)
            KeychainService.shared.set(resp.username ?? "", for: .username)
            do {
                currentUser = try await NetworkService.shared.currentUser()
            } catch {
                currentUser = User(
                    id: resp.userId,
                    username: resp.username ?? "",
                    email: nil,
                    firstName: nil,
                    lastName: nil,
                    avatarPath: nil,
                    bio: nil
                )
            }
            isAuthenticated = true
            RealtimeEngine.shared.start()
            BLEMeshEngine.shared.start()
        } catch {
            lastError = friendly(error)
        }
    }

    // MARK: - Bluetooth login (Phase 1: limited mesh-only session)
    //
    // Triggered when the macOS QR sheet receives a signature-verified
    // `MeshLoginApprovalEnvelope` over BLE — the phone broadcast it
    // because the internet path to `/api/auth/qr-login/scan` failed.
    //
    // Honest scope:
    // • This signs the user in for **local mesh purposes only**. We
    //   set `currentUser` from the envelope's `userId`/`username`,
    //   flip `isAuthenticated = true`, and start the mesh engine.
    //   We do NOT persist a server access token (the server didn't
    //   issue one — by definition, the internet was unreachable).
    // • As a result: any code path that calls the server with
    //   `Bearer <token>` will fail until the user signs in normally
    //   (with internet) on this desktop. Mesh chat works.
    // • Phase 2 (`docs/BLUETOOTH-LOGIN.md`): persist the envelope so
    //   when the desktop reaches the internet again, it can call
    //   a deferred `/qr-login/approve` and pull a real JWT.
    //
    func completeBluetoothLogin(_ env: MeshLoginApprovalEnvelope) {
        // Treat as authenticated locally — but don't write a fake
        // token to the keychain; that would let the rest of the app
        // attempt server calls that always 401.
        KeychainService.shared.set(env.userId, for: .userId)
        KeychainService.shared.set(env.username, for: .username)
        currentUser = User(
            id: env.userId,
            username: env.username,
            email: nil,
            firstName: nil,
            lastName: nil,
            avatarPath: nil,
            bio: nil
        )
        isAuthenticated = true
        // Mesh-only mode: start BLE engine but skip RealtimeEngine
        // (it would hammer the server with WS reconnects we know
        // will fail — see scope notes in BLUETOOTH-LOGIN.md).
        BLEMeshEngine.shared.start()
    }

    // MARK: - QR-code login

    func completeQrLogin(_ poll: QrPollResponse) {
        guard
            poll.status == "approved",
            let token = poll.token,
            let userId = poll.userId,
            let username = poll.username
        else {
            return
        }
        KeychainService.shared.set(token, for: .accessToken)
        KeychainService.shared.set(poll.refreshToken, for: .refreshToken)
        KeychainService.shared.set(userId, for: .userId)
        KeychainService.shared.set(username, for: .username)
        currentUser = User(
            id: userId,
            username: username,
            email: nil,
            firstName: nil,
            lastName: nil,
            avatarPath: nil,
            bio: nil
        )
        isAuthenticated = true
        RealtimeEngine.shared.start()
        BLEMeshEngine.shared.start()
    }

    // MARK: - Avatar

    /// Upload a local image to the server and set it as the user's avatar.
    /// Returns once `currentUser.avatarPath` is updated so SwiftUI views
    /// re-render with the new image.
    func updateAvatar(imageData: Data, filename: String) async throws {
        let url = try await NetworkService.shared.uploadImage(
            data: imageData, filename: filename, mimeType: mimeType(for: filename))
        let user = try await NetworkService.shared.setAvatar(imageUrl: url)
        currentUser = user
    }

    private func mimeType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".heic") || lower.hasSuffix(".heif") { return "image/heic" }
        return "image/jpeg"
    }

    // MARK: - Profile editing

    /// `PATCH /api/users/me` — server expects a single `display_name`
    /// (first + last combined) plus `bio`. We send only the keys that
    /// actually have content so callers can pass empty strings without
    /// overwriting server-side values to empty.
    func updateProfile(displayName: String?, bio: String?) async throws {
        var fields: [String: String] = [:]
        if let v = displayName, !v.trimmingCharacters(in: .whitespaces).isEmpty {
            fields["display_name"] = v.trimmingCharacters(in: .whitespaces)
        }
        if let v = bio {
            // Bio is allowed to be cleared, so we don't trim-skip it — but
            // we do trim trailing whitespace.
            fields["bio"] = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !fields.isEmpty else { return }
        let updated = try await NetworkService.shared.updateProfile(fields)
        currentUser = updated
    }

    // MARK: - Sign out

    func signOut() {
        RealtimeEngine.shared.stop()
        BLEMeshEngine.shared.stop()
        Task { await MeshBridgeReceiver.shared.reset() }
        Task { await MeshDedupRepository.shared.reset() }
        KeychainService.shared.wipe()
        Self.purgeUserScopedDefaults()
        currentUser = nil
        isAuthenticated = false
        lastError = nil
    }

    /// Wipe every `UserDefaults` key that holds *user-scoped* state
    /// (per-conversation drafts, "hide for me" tombstones, disappearing-
    /// message defaults). Without this, signing into a different account
    /// on the same machine surfaces the previous user's drafts and
    /// hidden-message lists — a real privacy leak. App-level prefs
    /// (background mode, launch-at-login) are deliberately *not* wiped
    /// because they describe how this machine should behave, not what
    /// belongs to a specific account.
    private static func purgeUserScopedDefaults() {
        let defaults = UserDefaults.standard
        let prefixes = ["raven_draft_", "raven_hidden_messages_", "raven_chat_expiry_"]
        for key in defaults.dictionaryRepresentation().keys
            where prefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    private func persist(_ resp: LoginResponse) {
        KeychainService.shared.set(resp.token, for: .accessToken)
        KeychainService.shared.set(resp.refreshToken, for: .refreshToken)
        KeychainService.shared.set(resp.userId, for: .userId)
        KeychainService.shared.set(resp.username, for: .username)
    }

    private func friendly(_ error: Error) -> String {
        if let api = error as? APIError {
            switch api {
            case .http(let code, let body):
                // Pull `detail` out of FastAPI's standard error body
                // ({"detail": "..."}) when present — gives Apple/Google
                // OAuth a sensible message ("Invalid Apple token") instead
                // of the email-login-specific fallback.
                if let detail = extractDetail(body), !detail.isEmpty {
                    return detail
                }
                if code == 401 { return "Wrong username or password." }
                return body.isEmpty ? "Server error." : body
            case .authExpired:
                return "Session expired."
            case .decode:
                return "Unexpected response from server."
            case .transport:
                return "Couldn't reach server. Check your network."
            case .malformedURL:
                return "Couldn't build the request. This is a bug."
            }
        }
        return error.localizedDescription
    }

    /// Decode `{"detail": "<msg>"}` from a FastAPI error body.
    private func extractDetail(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["detail"] as? String
    }
}
