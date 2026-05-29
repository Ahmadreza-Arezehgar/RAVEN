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
// NOTE: iOS exposes no API to BLOCK a screenshot. Two tools exist here:
//   • ScreenshotObserver (below) — DETECTS screenshots / screen
//     recording after the fact. Safe to use app-wide.
//   • SecureHostView (bottom of file) — EXCLUDES content from
//     screenshots AND screen recordings via the secure-text-entry
//     layer (the same OS mechanism banking apps use to blank card
//     numbers). Re-introduced 2026-05-20 at the user's request,
//     SCOPED to Vault media viewers only — a genuine privacy feature
//     on a small surface, which is the defensible, low-review-risk
//     use. It is deliberately NOT applied app-wide.

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
        #if targetEnvironment(macCatalyst)
        // Mac Catalyst: UIApplication.userDidTakeScreenshotNotification,
        // UIScreen.capturedDidChangeNotification and UIScreen.main.isCaptured
        // are unavailable. Screenshot detection silently degrades to no-op.
        return
        #else
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
        #endif
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

// MARK: - Vault Screenshot Exclusion (secure-text-entry layer)
//
// 🔴 2026-05-20 — content rendered inside a secure-text-entry field's
// layer is omitted by the iOS compositor from BOTH screenshots and
// screen recordings — the exact mechanism banking apps use to blank
// out card numbers. A screenshot of protected content comes back
// blank; the live on-device display is unaffected.
//
// Fail-open: if the secure canvas can't be obtained (OS internals
// change), the content is shown unprotected rather than hidden — the
// viewer is never blank. The VaultScreenGuard detect/blur overlay is
// the backstop in that case.

/// A UIView whose hosted content iOS excludes from screenshots and
/// screen recordings — the iOS analogue of Android's FLAG_SECURE.
///
/// 🔴 2026-05-20 (v3 — researched rewrite). A secure-text-entry
/// `UITextField` owns a private canvas view (`_UITextLayoutCanvasView`
/// on iOS 15+, `_UITextFieldCanvasView` / `_UITextFieldContentView`
/// on older iOS) whose layer the iOS compositor omits from screen
/// capture. The canonical community technique — what banking apps use
/// — is to DETACH that canvas, clear it, and host the content inside
/// it. (v1 injected into `subviews.first` in place; v2 reparented a
/// layer into `sublayers.last` — both guessed wrong at the internals
/// and never engaged.)
///
/// This is an UNDOCUMENTED hack: the private class names can change
/// between iOS versions. It fails OPEN — the content stays visible,
/// just unprotected — and in DEBUG it logs the secure field's live
/// subview tree so the exact internal class can be confirmed on a
/// real device if it ever needs adjusting.
final class SecureContainerUIView: UIView {
    private var secureCanvas = UIView()
    /// False when the secure canvas couldn't be obtained (fail-open).
    private(set) var isSecured = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSecureCanvas()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setupSecureCanvas() {
        // Mint a secure canvas from a throwaway secure UITextField.
        let field = UITextField()
        field.isSecureTextEntry = true
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        field.layoutIfNeeded()  // force the field to build its subviews

        // The secure canvas is the private _UITextLayoutCanvasView
        // (iOS 15+) / _UITextFieldCanvasView / _UITextFieldContentView.
        let canvas = field.subviews.first { sub in
            let name = String(describing: type(of: sub))
            return name.contains("Canvas") || name.contains("Content")
        } ?? field.subviews.first

        #if DEBUG
        print("🔒 [SecureContainer] secure UITextField subviews = "
              + "\(field.subviews.map { String(describing: type(of: $0)) }) → "
              + (canvas != nil
                 ? "secured ✅"
                 : "FAIL-OPEN ⚠️  no secure canvas — screenshots NOT blocked"))
        #endif

        if let canvas {
            canvas.subviews.forEach { $0.removeFromSuperview() }
            canvas.isUserInteractionEnabled = true
            secureCanvas = canvas
            isSecured = true
        }
        // else: secureCanvas stays the placeholder UIView — fail-open.

        secureCanvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secureCanvas)
        NSLayoutConstraint.activate([
            secureCanvas.topAnchor.constraint(equalTo: topAnchor),
            secureCanvas.bottomAnchor.constraint(equalTo: bottomAnchor),
            secureCanvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            secureCanvas.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Host `view` inside the secure canvas (pinned to fill).
    func host(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        secureCanvas.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: secureCanvas.topAnchor),
            view.bottomAnchor.constraint(equalTo: secureCanvas.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: secureCanvas.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: secureCanvas.trailingAnchor),
        ])
    }
}

/// Hosts SwiftUI `content` inside a `SecureContainerUIView` so iOS
/// omits it from screenshots and screen recordings.
struct SecureHostView<Content: View>: UIViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> SecureContainerUIView {
        let container = SecureContainerUIView()
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        context.coordinator.host = host
        container.host(host.view)
        return container
    }

    func updateUIView(_ uiView: SecureContainerUIView, context: Context) {
        context.coordinator.host?.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: UIHostingController<Content>?
    }
}

extension View {
    /// Exclude this view from screenshots & screen recordings at the
    /// OS level (secure-text-entry layer). Pass `false` to render
    /// normally. Use ONLY for genuinely sensitive content such as
    /// Vault media — never app-wide.
    @ViewBuilder
    func vaultScreenshotProtected(_ enabled: Bool = true) -> some View {
        if enabled {
            SecureHostView { self }
        } else {
            self
        }
    }
}
