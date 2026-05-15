import Foundation
import AuthenticationServices

// MARK: - Apple Sign In Coordinator
class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    
    struct AppleCredential {
        let identityToken: String
        let authorizationCode: String
        let fullName: String?
        let email: String?
    }
    
    typealias Completion = (Result<AppleCredential, Error>) -> Void
    
    private var completion: Completion?
    private weak var presentationWindow: ASPresentationAnchor?
    
    init(completion: @escaping Completion) {
        self.completion = completion
        super.init()
    }
    
    func startSignIn() {
        guard let anchor = resolvePresentationAnchor() else {
            #if DEBUG
            print("❌ [AppleSignIn] No presentation window available")
            #endif
            completion?(.failure(AppleSignInError.noWindow))
            return
        }
        presentationWindow = anchor
        
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
        
        #if DEBUG
        print("🍎 [AppleSignIn] Starting authorization request")
        #endif
    }
    
    // MARK: - ASAuthorizationControllerDelegate
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        #if DEBUG
        print("🍎 [AppleSignIn] Authorization completed")
        #endif
        
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            completion?(.failure(AppleSignInError.invalidCredential))
            return
        }
        
        guard let identityTokenData = appleIDCredential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8) else {
            completion?(.failure(AppleSignInError.missingIdentityToken))
            return
        }
        
        guard let authCodeData = appleIDCredential.authorizationCode,
              let authorizationCode = String(data: authCodeData, encoding: .utf8) else {
            completion?(.failure(AppleSignInError.missingAuthorizationCode))
            return
        }
        
        var fullName: String?
        if let nameComponents = appleIDCredential.fullName {
            let firstName = nameComponents.givenName ?? ""
            let lastName = nameComponents.familyName ?? ""
            if !firstName.isEmpty || !lastName.isEmpty {
                fullName = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
            }
        }
        
        let credential = AppleCredential(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            fullName: fullName,
            email: appleIDCredential.email
        )
        
        #if DEBUG
        print("🍎 [AppleSignIn] Success - email: \(credential.email ?? "nil"), name: \(credential.fullName ?? "nil")")
        #endif
        completion?(.success(credential))
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        // DETAILED LOGGING: Log actual error code and domain
        let nsError = error as NSError
        #if DEBUG
        print("❌ [AppleSignIn] Error occurred!")
        print("   → Domain: \(nsError.domain)")
        print("   → Code: \(nsError.code)")
        print("   → Description: \(error.localizedDescription)")
        print("   → UserInfo: \(nsError.userInfo)")
        #endif
        
        // Check actual ASAuthorizationError code
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled:
                #if DEBUG
                print("   → Status: User cancelled sign-in")
                #endif
                completion?(.failure(AppleSignInError.cancelled))
            case .unknown:
                #if DEBUG
                print("   → Status: Unknown error (NOT user cancel!)")
                #endif
                completion?(.failure(AppleSignInError.unknown))
            case .invalidResponse:
                #if DEBUG
                print("   → Status: Invalid response from Apple")
                #endif
                completion?(.failure(AppleSignInError.invalidResponse))
            case .notHandled:
                #if DEBUG
                print("   → Status: Request not handled (capability/entitlement issue?)")
                #endif
                completion?(.failure(AppleSignInError.notHandled))
            case .failed:
                #if DEBUG
                print("   → Status: Authorization failed")
                #endif
                completion?(.failure(AppleSignInError.failed))
            case .notInteractive:
                #if DEBUG
                print("   → Status: Not interactive")
                #endif
                completion?(.failure(error))
            default:
                // Catches the iOS 18+ cases (matchedExcludedCredential,
                // credentialImport, credentialExport, …) plus anything Apple
                // adds later. We don't have UI for them, so surface the
                // underlying error verbatim.
                #if DEBUG
                print("   → Status: ASAuthorization error code \(authError.code.rawValue)")
                #endif
                completion?(.failure(error))
            }
        } else {
            #if DEBUG
            print("   → Status: Non-ASAuthorization error")
            #endif
            completion?(.failure(error))
        }
    }
    
    // MARK: - ASAuthorizationControllerPresentationContextProviding
    
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let anchor = presentationWindow {
            return anchor
        }
        if let anchor = resolvePresentationAnchor() {
            presentationWindow = anchor
            return anchor
        }
        
        // Never crash user flow here. `startSignIn()` already fails fast when no anchor exists.
        let fallback = ASPresentationAnchor(frame: .zero)
        presentationWindow = fallback
        return fallback
    }
    
    private func resolvePresentationAnchor() -> ASPresentationAnchor? {
        // Prefer foreground-active key window
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
           let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first {
            return keyWindow
        }
        
        // Fallback to any available window
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            return window
        }
        
        return nil
    }
}

// MARK: - Apple Sign In Errors
enum AppleSignInError: Error, LocalizedError {
    case invalidCredential
    case missingIdentityToken
    case missingAuthorizationCode
    case cancelled
    case unknown
    case invalidResponse
    case notHandled
    case failed
    case noWindow
    
    var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Invalid Apple credentials"
        case .missingIdentityToken: return "Missing identity token"
        case .missingAuthorizationCode: return "Missing authorization code"
        case .cancelled: return "Sign in cancelled"
        case .unknown: return "Unknown Apple Sign In error"
        case .invalidResponse: return "Invalid response from Apple"
        case .notHandled: return "Request not handled (check capabilities)"
        case .failed: return "Authorization failed"
        case .noWindow: return "No window available for presentation"
        }
    }
}
