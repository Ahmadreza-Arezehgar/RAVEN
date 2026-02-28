import Foundation
import UIKit
import GoogleSignIn

// MARK: - Google Sign In Coordinator
// Uses GoogleSignIn SDK (same as Flutter app)
class GoogleSignInCoordinator {
    
    struct GoogleCredential {
        let idToken: String
        let email: String?
        let name: String?
    }
    
    typealias Completion = (Result<GoogleCredential, Error>) -> Void
    
    // Google OAuth Configuration — read from Info.plist for environment flexibility.
    // Add a GIDClientID key to Info.plist with the value for each build configuration.
    static let clientId: String = {
        if let plistId = Bundle.main.infoDictionary?["GIDClientID"] as? String, !plistId.isEmpty {
            return plistId
        }
        // Fallback for existing builds until Info.plist is updated
        return "516053629173-teh5np0h3i3ar6b25sd78d6o8ft1qhg9.apps.googleusercontent.com"
    }()
    
    private var completion: Completion?
    
    init(completion: @escaping Completion) {
        self.completion = completion
    }
    
    func startSignIn() {
        #if DEBUG
        print("🔵 [GoogleSignIn] Starting Google Sign-In flow with SDK")
        #endif
        
        // Configure Google Sign-In with the client ID
        let config = GIDConfiguration(clientID: Self.clientId)
        GIDSignIn.sharedInstance.configuration = config
        
        // Get the topmost view controller for presenting
        guard let rootViewController = Self.getTopmostViewController() else {
            #if DEBUG
            print("❌ [GoogleSignIn] No view controller available")
            #endif
            completion?(.failure(GoogleSignInError.noViewController))
            return
        }
        
        // Start the sign-in flow
        GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                let nsError = error as NSError
                // DETAILED LOGGING: Log actual error code and domain
                #if DEBUG
                print("❌ [GoogleSignIn] Error occurred!")
                print("   → Domain: \(nsError.domain)")
                print("   → Code: \(nsError.code)")
                print("   → Description: \(error.localizedDescription)")
                print("   → UserInfo: \(nsError.userInfo)")
                #endif
                
                // Check if user actually cancelled
                if nsError.code == GIDSignInError.canceled.rawValue {
                    #if DEBUG
                    print("   → Status: User cancelled sign-in")
                    #endif
                    self.completion?(.failure(GoogleSignInError.cancelled))
                } else if nsError.code == GIDSignInError.hasNoAuthInKeychain.rawValue {
                    #if DEBUG
                    print("   → Status: No auth in keychain")
                    #endif
                    self.completion?(.failure(GoogleSignInError.noAuthInKeychain))
                } else if nsError.code == GIDSignInError.EMM.rawValue {
                    #if DEBUG
                    print("   → Status: EMM (Enterprise) error")
                    #endif
                    self.completion?(.failure(error))
                } else {
                    #if DEBUG
                    print("   → Status: Unknown error - NOT user cancel")
                    #endif
                    self.completion?(.failure(error))
                }
                return
            }
            
            guard let user = result?.user,
                  let idToken = user.idToken?.tokenString else {
                #if DEBUG
                print("❌ [GoogleSignIn] No ID token received")
                #endif
                self.completion?(.failure(GoogleSignInError.noIdToken))
                return
            }
            
            let credential = GoogleCredential(
                idToken: idToken,
                email: user.profile?.email,
                name: user.profile?.name
            )
            
            #if DEBUG
            print("✅ [GoogleSignIn] Success - email: \(credential.email ?? "nil"), name: \(credential.name ?? "nil")")
            #endif
            self.completion?(.success(credential))
        }
    }
    
    // MARK: - Helper: Get Topmost View Controller
    
    private static func getTopmostViewController() -> UIViewController? {
        // Find the foreground active window scene
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            #if DEBUG
            print("❌ [GoogleSignIn] No foreground active window scene!")
            #endif
            return nil
        }
        
        // Get key window or first window
        guard let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
              var topVC = keyWindow.rootViewController else {
            #if DEBUG
            print("❌ [GoogleSignIn] No root view controller!")
            print("   → windowScene: \(windowScene)")
            print("   → windows count: \(windowScene.windows.count)")
            #endif
            return nil
        }
        
        // Traverse to topmost presented view controller
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        // Handle navigation controllers
        if let nav = topVC as? UINavigationController, let visible = nav.visibleViewController {
            topVC = visible
        }
        
        // Handle tab bar controllers
        if let tab = topVC as? UITabBarController, let selected = tab.selectedViewController {
            topVC = selected
        }
        
        #if DEBUG
        print("✅ [GoogleSignIn] Presenting from: \(type(of: topVC))")
        #endif
        return topVC
    }
}

// MARK: - Google Sign In Errors
enum GoogleSignInError: Error, LocalizedError {
    case noViewController
    case cancelled
    case noIdToken
    case noAuthInKeychain
    
    var errorDescription: String? {
        switch self {
        case .noViewController: return "Could not find view controller"
        case .cancelled: return "Sign in cancelled"
        case .noIdToken: return "No ID token received from Google"
        case .noAuthInKeychain: return "No auth in keychain"
        }
    }
}
