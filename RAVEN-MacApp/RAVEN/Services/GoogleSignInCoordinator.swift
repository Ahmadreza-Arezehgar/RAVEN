// GoogleSignInCoordinator — macOS coordinator for Google Sign-In.
//
// We do NOT use Google's `GoogleSignIn-iOS` SDK on this macOS build because
// its GTMAppAuth keychain layer fails under our signing setup (development
// cert without a real provisioning profile). Instead we drive the OAuth 2.0
// + PKCE flow directly with `ASWebAuthenticationSession`, exchange the auth
// code for an id_token via Google's token endpoint, and hand that id_token
// to the AuthService → backend → done.
//
// The id_token is the only thing our server needs (`POST /api/auth/oauth/google`
// in `server/routers/auth.py` calls `verify_google_token(id_token)`). We never
// persist any Google credentials locally — once the server returns its own
// session JWT we store that in the app's own KeychainService.

import Foundation
import AppKit
import AuthenticationServices
import CryptoKit

// NOTE: this class is intentionally NOT `@MainActor`, AND it does NOT
// directly conform to `ASWebAuthenticationPresentationContextProviding`.
//
// In recent SDKs that protocol is `@MainActor`-isolated. Conforming this
// class to it would make the entire class @MainActor by inheritance — and
// then ASWebAuthenticationSession's completion (which fires on a private
// XPC queue) trips Swift's runtime executor check
// (`swift_task_checkIsolatedSwift`) and crashes with `EXC_BREAKPOINT`.
//
// We dodge that by giving the SDK a SEPARATE small @MainActor-isolated
// bridge object (`PresentationAnchorProvider`) for the protocol conformance,
// while keeping this coordinator non-isolated so the XPC callback can run
// without isolation checks.
final class GoogleSignInCoordinator: NSObject {

    struct GoogleCredential {
        let idToken: String
        let email: String?
        let name: String?
    }

    /// `@Sendable` so the compiler enforces that closures stored here don't
    /// capture actor-isolated state — that's what crashed earlier.
    typealias Completion = @Sendable (Result<GoogleCredential, Error>) -> Void

    /// Read the OAuth client id from `Info.plist` (`GIDClientID`). Falls back
    /// to the iOS-native client id so a fresh checkout still runs end to end
    /// if `Info.plist` hasn't been updated for this build yet.
    static let clientId: String = {
        if let plistId = Bundle.main.infoDictionary?["GIDClientID"] as? String, !plistId.isEmpty {
            return plistId
        }
        return "516053629173-teh5np0h3i3ar6b25sd78d6o8ft1qhg9.apps.googleusercontent.com"
    }()

    /// Reverse-client-id URL scheme that Google redirects back to. Must match
    /// the `CFBundleURLSchemes` entry in Info.plist.
    private static var redirectScheme: String {
        // Convert `516053629173-xxxxx.apps.googleusercontent.com` →
        // `com.googleusercontent.apps.516053629173-xxxxx`.
        let host = clientId.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(host)"
    }

    private var completion: Completion?
    private var session: ASWebAuthenticationSession?
    private var pkceVerifier: String?
    /// MainActor-isolated bridge that conforms to
    /// `ASWebAuthenticationPresentationContextProviding`. Held strongly so
    /// AuthenticationServices' weak presentation-context-provider reference
    /// doesn't dangle.
    private let anchorProvider = PresentationAnchorProvider()

    init(completion: @escaping Completion) {
        self.completion = completion
        super.init()
    }

    func startSignIn() {
        let verifier = Self.makePKCEVerifier()
        let challenge = Self.pkceChallenge(for: verifier)
        self.pkceVerifier = verifier
        let state = UUID().uuidString
        let redirectUri = "\(Self.redirectScheme):/oauth2redirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components.url else {
            completion?(.failure(GoogleSignInError.invalidAuthURL))
            return
        }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: Self.redirectScheme
        ) { [weak self] callbackURL, error in
            // The fewest possible bytes of Swift run on the XPC queue —
            // immediately hop to the main queue and do all the real work
            // there. Doing anything more here (including reading a
            // captured property) trips Swift's runtime executor check
            // and crashes the process.
            DispatchQueue.main.async {
                self?.handleCallbackResult(callbackURL: callbackURL, error: error,
                                           expectedState: state, redirectUri: redirectUri)
            }
        }
        session.presentationContextProvider = anchorProvider
        // Don't share Safari session cookies — keeps OAuth isolated and
        // forces a clean prompt every time, which is what App Review
        // expects.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            self.session = nil
            completion?(.failure(GoogleSignInError.sessionDidNotStart))
        }
    }

    /// Synchronous entry point — runs on the main queue (DispatchQueue.main).
    /// Decodes the callback URL, fires the completion for trivial failures,
    /// and kicks off the async token-exchange Task for the success path.
    private func handleCallbackResult(callbackURL: URL?,
                                       error: Error?,
                                       expectedState: String,
                                       redirectUri: String) {
        if let error = error {
            let nsErr = error as NSError
            if nsErr.domain == ASWebAuthenticationSessionError.errorDomain
                && nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                completion?(.failure(GoogleSignInError.cancelled))
            } else {
                completion?(.failure(error))
            }
            session = nil
            return
        }
        guard let callbackURL = callbackURL else {
            completion?(.failure(GoogleSignInError.noCallback))
            session = nil
            return
        }

        // Run the token exchange in a Task on the global pool. We're now
        // on the main queue, so Task inheritance is safe.
        Task {
            await self.handleCallback(callbackURL,
                                       expectedState: expectedState,
                                       redirectUri: redirectUri)
            self.session = nil
        }
    }

    private func handleCallback(_ url: URL, expectedState: String, redirectUri: String) async {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else {
            completion?(.failure(GoogleSignInError.malformedCallback))
            return
        }
        if let err = items.first(where: { $0.name == "error" })?.value {
            completion?(.failure(GoogleSignInError.providerError(err)))
            return
        }
        guard let returnedState = items.first(where: { $0.name == "state" })?.value,
              returnedState == expectedState else {
            completion?(.failure(GoogleSignInError.stateMismatch))
            return
        }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let verifier = pkceVerifier else {
            completion?(.failure(GoogleSignInError.malformedCallback))
            return
        }

        do {
            let credential = try await exchangeCodeForIDToken(
                code: code,
                redirectUri: redirectUri,
                codeVerifier: verifier
            )
            completion?(.success(credential))
        } catch {
            completion?(.failure(error))
        }
    }

    /// `POST https://oauth2.googleapis.com/token` exchange — auth code +
    /// PKCE verifier in, id_token out. Native OAuth 2.0 clients skip
    /// `client_secret` entirely.
    private func exchangeCodeForIDToken(
        code: String,
        redirectUri: String,
        codeVerifier: String
    ) async throws -> GoogleCredential {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
        ]
        req.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleSignInError.tokenExchangeFailed(body)
        }

        struct TokenResponse: Decodable {
            let id_token: String?
            let access_token: String?
        }
        let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let idToken = parsed.id_token else {
            throw GoogleSignInError.noIdToken
        }
        // Decode email/name out of the id_token's middle segment (a base64
        // JWT payload). Best-effort — server is the authoritative validator.
        let claims = Self.decodeJWTClaims(idToken)
        return GoogleCredential(
            idToken: idToken,
            email: claims?["email"] as? String,
            name: claims?["name"] as? String
        )
    }

    // MARK: - PKCE helpers

    private static func makePKCEVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}

enum GoogleSignInError: Error, LocalizedError {
    case noWindow
    case cancelled
    case noIdToken
    case noAuthInKeychain
    case keychainUnavailable
    case invalidAuthURL
    case sessionDidNotStart
    case noCallback
    case malformedCallback
    case stateMismatch
    case providerError(String)
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWindow:                return "Could not find a window for presentation"
        case .cancelled:               return "Sign in cancelled"
        case .noIdToken:               return "No ID token received from Google"
        case .noAuthInKeychain:        return "No saved Google session"
        case .keychainUnavailable:
            return "Couldn't access the keychain. Make sure the app is signed with a Developer Team and try again."
        case .invalidAuthURL:          return "Couldn't build the Google sign-in URL."
        case .sessionDidNotStart:      return "macOS refused to launch the OAuth window."
        case .noCallback:              return "Sign-in completed but no callback was returned."
        case .malformedCallback:       return "The Google redirect URL was malformed."
        case .stateMismatch:           return "OAuth state mismatch — sign-in aborted for safety."
        case .providerError(let s):    return "Google reported: \(s)"
        case .tokenExchangeFailed(let s):
            return "Couldn't exchange the auth code with Google. \(s.prefix(140))"
        }
    }
}

private extension Data {
    /// Base64 URL-safe encoding without `=` padding (per RFC 7636 § 4.1).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tiny @MainActor bridge that conforms to
/// `ASWebAuthenticationPresentationContextProviding` (which the SDK now
/// declares as @MainActor in newer SDK headers). Keeping this conformance
/// off the main coordinator class is what stops Swift's runtime executor
/// check from crashing when ASWebAuthenticationSession's completion fires
/// on a background XPC queue.
@MainActor
final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let app = NSApplication.shared
        return app.keyWindow
            ?? app.mainWindow
            ?? app.windows.first(where: { $0.isVisible })
            ?? NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    }
}
