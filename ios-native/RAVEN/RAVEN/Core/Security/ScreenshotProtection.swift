import SwiftUI
import UIKit

// MARK: - Environment Key for Screenshot Exception
private struct ScreenshotAllowedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Set to true to allow screenshots on specific screens (e.g., My QR Code)
    var screenshotAllowed: Bool {
        get { self[ScreenshotAllowedKey.self] }
        set { self[ScreenshotAllowedKey.self] = newValue }
    }
}

extension View {
    /// Allow screenshots for this view and its children
    func allowScreenshots(_ allowed: Bool = true) -> some View {
        environment(\.screenshotAllowed, allowed)
    }
}

// MARK: - Screenshot Protection
// NOTE: The UITextField.isSecureTextEntry hack was removed because Apple
// has historically rejected apps that exploit UITextField subview injection
// for screenshot blocking. Until Apple provides an official API, the only
// App-Store-safe approach is the ScreenshotObserver overlay below.

// MARK: - Screenshot Observer (for additional protection)
/// Monitors for screenshot/recording and can trigger additional actions
@MainActor
final class ScreenshotObserver: ObservableObject {
    @Published var isBeingCaptured = false
    @Published var screenshotJustTaken = false
    
    private var notificationObservers: [NSObjectProtocol] = []
    
    init() {
        setupObservers()
    }
    
    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    private func setupObservers() {
        // Screenshot notification (iOS 11+)
        let screenshotObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            #if DEBUG
            print("📸 Screenshot detected!")
            #endif
            Task { @MainActor in
                self?.handleScreenshot()
            }
        }
        notificationObservers.append(screenshotObserver)
        
        // Screen recording detection
        let recordingObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let isCaptured = UIScreen.main.isCaptured
                self?.isBeingCaptured = isCaptured
                if isCaptured {
                    #if DEBUG
                    print("🔴 Screen recording started!")
                    #endif
                }
            }
        }
        notificationObservers.append(recordingObserver)
        
        // Initial check
        isBeingCaptured = UIScreen.main.isCaptured
    }
    
    private func handleScreenshot() {
        // Flash the captured state briefly
        screenshotJustTaken = true
        Haptics.warning()
        
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            screenshotJustTaken = false
        }
    }
}

// MARK: - View Modifier for App-Wide Protection
struct ScreenshotProtectionModifier: ViewModifier {
    @Environment(\.screenshotAllowed) private var screenshotAllowed
    @StateObject private var observer = ScreenshotObserver()
    
    func body(content: Content) -> some View {
        ZStack {
            content
            
            if !screenshotAllowed && (observer.isBeingCaptured || observer.screenshotJustTaken) {
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 48))
                            Text("Screen Recording Active")
                                .font(.headline)
                        }
                        .foregroundStyle(.white.opacity(0.6))
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: observer.isBeingCaptured)
        .animation(.easeInOut(duration: 0.2), value: observer.screenshotJustTaken)
    }
}

extension View {
    /// Protects this view from screenshots and screen recordings
    func screenshotProtected() -> some View {
        modifier(ScreenshotProtectionModifier())
    }
}

// MARK: - Preview
#Preview {
    VStack {
        Text("This content is protected!")
            .font(.title)
            .padding()
        
        Text("Screenshots will show a black screen")
            .foregroundStyle(.secondary)
    }
    .screenshotProtected()
}
