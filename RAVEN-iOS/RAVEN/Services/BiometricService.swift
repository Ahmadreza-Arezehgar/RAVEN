// RAVEN - Biometric Service
// Converted from Flutter biometric_service.dart

import Foundation
import LocalAuthentication

/// Handles Face ID / Touch ID authentication
struct BiometricService {
    
    /// Check if biometric auth is available
    static func isAvailable() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
    
    /// Get biometric type
    static var biometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }
    
    /// Authenticate with biometrics
    static func authenticate(reason: String = "Authenticate to access RAVEN") async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            print("❌ [Biometric] Not available: \(error?.localizedDescription ?? "Unknown")")
            return false
        }
        
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            if success {
                print("✅ [Biometric] Authenticated")
            }
            return success
        } catch {
            print("❌ [Biometric] Failed: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Authenticate with biometrics or passcode fallback
    static func authenticateWithFallback(reason: String = "Authenticate to access RAVEN") async -> Bool {
        let context = LAContext()
        
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return success
        } catch {
            return false
        }
    }
    
    enum BiometricType: String {
        case none = "None"
        case faceID = "Face ID"
        case touchID = "Touch ID"
        case opticID = "Optic ID"
        
        var icon: String {
            switch self {
            case .faceID: return "faceid"
            case .touchID: return "touchid"
            case .opticID: return "opticid"
            case .none: return "lock"
            }
        }
    }
}
