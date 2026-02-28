import SwiftUI
import LocalAuthentication

// MARK: - App Lock View
/// Full-screen overlay that requires authentication when app becomes active
struct AppLockView: View {
    @AppStorage("biometricEnabled") private var biometricEnabled = false
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    
    let onUnlock: () -> Void
    
    @State private var isAuthenticating = false
    @State private var showPasscodeInput = false
    @State private var passcode = ""
    @State private var errorMessage: String?
    @State private var biometricType: LABiometryType = .none
    
    var body: some View {
        ZStack {
            // Dark blur background
            Color.black
                .ignoresSafeArea()
            
            VStack(spacing: 32) {
                Spacer()
                
                // App Icon
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                // Title
                VStack(spacing: 8) {
                    Text("RAVEN is Locked")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                    
                    Text("Authenticate to continue")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                
                // Error message
                if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                        .multilineTextAlignment(.center)
                }
                
                Spacer()
                
                // Unlock Button
                Button {
                    authenticate()
                } label: {
                    HStack(spacing: 12) {
                        if isAuthenticating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: biometricIcon)
                                .font(.system(size: 20))
                        }
                        
                        Text("Unlock with \(biometricTitle)")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(Capsule())
                }
                .disabled(isAuthenticating)
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            checkBiometricType()
            // Auto-authenticate on appear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                authenticate()
            }
        }
    }
    
    private var biometricTitle: String {
        switch biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }
    
    private var biometricIcon: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }
    
    private func checkBiometricType() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometricType = context.biometryType
        }
    }
    
    private func authenticate() {
        isAuthenticating = true
        errorMessage = nil
        
        // Tell manager we're authenticating to prevent re-locking
        AppLockManager.shared.beginAuthentication()
        
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        
        // Try biometric first if enabled, otherwise fall back to device passcode
        let policy: LAPolicy = biometricEnabled 
            ? .deviceOwnerAuthenticationWithBiometrics 
            : .deviceOwnerAuthentication
        
        let reason = "Unlock RAVEN to access your messages"
        
        context.evaluatePolicy(policy, localizedReason: reason) { success, error in
            DispatchQueue.main.async {
                isAuthenticating = false
                
                if success {
                    Haptics.success()
                    onUnlock()
                } else if let error = error as? LAError {
                    switch error.code {
                    case .userCancel, .systemCancel:
                        // User cancelled - reset auth state but don't unlock
                        AppLockManager.shared.cancelAuthentication()
                    case .biometryNotAvailable, .biometryNotEnrolled:
                        // Fall back to device passcode
                        authenticateWithDevicePasscode()
                    case .userFallback:
                        // User wants to use passcode
                        authenticateWithDevicePasscode()
                    default:
                        errorMessage = "Authentication failed. Try again."
                        AppLockManager.shared.cancelAuthentication()
                        Haptics.error()
                    }
                }
            }
        }
    }
    
    private func authenticateWithDevicePasscode() {
        let context = LAContext()
        let reason = "Unlock RAVEN to access your messages"
        
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            DispatchQueue.main.async {
                if success {
                    Haptics.success()
                    onUnlock()
                } else {
                    errorMessage = "Authentication failed. Try again."
                    Haptics.error()
                }
            }
        }
    }
}

// MARK: - App Lock Manager
@Observable
final class AppLockManager {
    static let shared = AppLockManager()
    
    var isLocked = false
    private var lastBackgroundTime: Date?
    private var isAuthenticating = false  // Prevent re-locking during auth
    
    private init() {
        setupNotifications()
    }
    
    private func setupNotifications() {
        // Use didEnterBackground instead of willResignActive
        // This prevents false triggers when Face ID popup appears (which causes inactive state)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.isAuthenticating != true else { return }
            self?.lastBackgroundTime = Date()
            #if DEBUG
            print("🔒 [AppLock] App entered background, recording time")
            #endif
        }
        
        // Use willEnterForeground instead of didBecomeActive
        // This only fires when truly returning from background, not from Face ID dismiss
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkLockStatus()
        }
    }
    
    private func checkLockStatus() {
        // Don't lock while we're in the middle of authenticating
        guard !isAuthenticating else {
            #if DEBUG
            print("🔒 [AppLock] Skipping lock check - authentication in progress")
            #endif
            return
        }
        
        let appLockEnabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
        guard appLockEnabled else { return }
        
        let timeout = UserDefaults.standard.integer(forKey: "appLockTimeout") // in seconds
        
        if let lastTime = lastBackgroundTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            #if DEBUG
            print("🔒 [AppLock] Time in background: \(elapsed)s, timeout: \(timeout)s")
            #endif
            if elapsed >= Double(timeout) {
                #if DEBUG
                print("🔒 [AppLock] Locking app")
                #endif
                isLocked = true
            }
        } else {
            // First launch with lock enabled
            #if DEBUG
            print("🔒 [AppLock] First launch - locking app")
            #endif
            isLocked = true
        }
    }
    
    func beginAuthentication() {
        isAuthenticating = true
    }
    
    func unlock() {
        isLocked = false
        isAuthenticating = false
        lastBackgroundTime = nil
        #if DEBUG
        print("🔓 [AppLock] Unlocked")
        #endif
    }
    
    func cancelAuthentication() {
        isAuthenticating = false
    }
}

// MARK: - App Lock Modifier
struct AppLockModifier: ViewModifier {
    @State private var lockManager = AppLockManager.shared
    
    func body(content: Content) -> some View {
        ZStack {
            content
                .accessibilityHidden(lockManager.isLocked)
            
            if lockManager.isLocked {
                AppLockView {
                    lockManager.unlock()
                }
                .transition(.opacity)
                .zIndex(999)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: lockManager.isLocked)
    }
}

extension View {
    func withAppLock() -> some View {
        modifier(AppLockModifier())
    }
}

// MARK: - Preview
#Preview {
    AppLockView {
        print("Unlocked!")
    }
}
