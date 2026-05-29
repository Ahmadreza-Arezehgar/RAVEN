// AppleSignInCoordinator — macOS sibling of the iOS coordinator at
// `../../ios-native/RAVEN/RAVEN/Features/Auth/AppleSignInCoordinator.swift`.
// Same authorization flow; the only differences are the presentation anchor
// (NSWindow vs UIWindow) and that `NSApplication.connectedScenes` doesn't
// exist on macOS so we walk `NSApplication.windows` instead.

import Foundation
import AppKit
import AuthenticationServices

final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    struct AppleCredential {
        let identityToken: String
        let authorizationCode: String
        let fullName: String?
        let email: String?
    }

    typealias Completion = (Result<AppleCredential, Error>) -> Void

    private var completion: Completion?
    private weak var presentationWindow: NSWindow?

    init(completion: @escaping Completion) {
        self.completion = completion
        super.init()
    }

    func startSignIn() {
        guard let anchor = resolvePresentationAnchor() else {
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
    }

    // MARK: - ASAuthorizationControllerDelegate

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
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
        completion?(.success(credential))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError {
            switch authError.code {
            case .canceled:        completion?(.failure(AppleSignInError.cancelled))
            case .invalidResponse: completion?(.failure(AppleSignInError.invalidResponse))
            case .notHandled:      completion?(.failure(AppleSignInError.notHandled))
            case .failed:          completion?(.failure(AppleSignInError.failed))
            case .unknown:         completion?(.failure(AppleSignInError.unknown))
            default:               completion?(.failure(error))
            }
        } else {
            completion?(.failure(error))
        }
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let anchor = presentationWindow { return anchor }
        if let anchor = resolvePresentationAnchor() {
            presentationWindow = anchor
            return anchor
        }
        // Fallback — should not happen because startSignIn() fails fast when
        // no window exists. AppKit doesn't have a "zero-frame placeholder
        // window" pattern like UIKit does, so we make a hidden one.
        let fallback = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        presentationWindow = fallback
        return fallback
    }

    private func resolvePresentationAnchor() -> NSWindow? {
        let app = NSApplication.shared
        if let key = app.keyWindow { return key }
        if let main = app.mainWindow { return main }
        return app.windows.first(where: { $0.isVisible })
    }
}

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
        case .invalidCredential:        return "Invalid Apple credentials"
        case .missingIdentityToken:     return "Missing identity token"
        case .missingAuthorizationCode: return "Missing authorization code"
        case .cancelled:                return "Sign in cancelled"
        case .unknown:                  return "Unknown Apple Sign In error"
        case .invalidResponse:          return "Invalid response from Apple"
        case .notHandled:               return "Request not handled (check capabilities)"
        case .failed:                   return "Authorization failed"
        case .noWindow:                 return "No window available for presentation"
        }
    }
}
