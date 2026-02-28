import SwiftUI

// MARK: - Loop Mode Enum (for compatibility when Lottie is not installed)
/// This enum mirrors Lottie's LottieLoopMode for API compatibility
enum LottieLoopModeCompat {
    case playOnce
    case loop
    case autoReverse
    case `repeat`(Float)
    case repeatBackwards(Float)
}

#if canImport(Lottie)
import Lottie

/// A SwiftUI wrapper for Lottie animations with loop support
/// Usage: LottieView(name: "animation_name", loopMode: .loop)
struct LottieView: UIViewRepresentable {
    let name: String
    let loopMode: LottieLoopMode
    let animationSpeed: CGFloat
    
    init(name: String, loopMode: LottieLoopModeCompat = .loop, animationSpeed: CGFloat = 1.0) {
        self.name = name
        self.animationSpeed = animationSpeed
        
        // Convert from compat enum to actual Lottie enum
        switch loopMode {
        case .playOnce:
            self.loopMode = .playOnce
        case .loop:
            self.loopMode = .loop
        case .autoReverse:
            self.loopMode = .autoReverse
        case .repeat(let count):
            self.loopMode = .repeat(count)
        case .repeatBackwards(let count):
            self.loopMode = .repeatBackwards(count)
        }
    }
    
    func makeUIView(context: Context) -> UIView {
        let containerView = UIView(frame: .zero)
        containerView.backgroundColor = .clear
        
        let animationView = LottieAnimationView(name: name)
        animationView.loopMode = loopMode
        animationView.animationSpeed = animationSpeed
        animationView.contentMode = .scaleAspectFit
        animationView.backgroundBehavior = .pauseAndRestore // Respect app lifecycle
        animationView.translatesAutoresizingMaskIntoConstraints = false
        animationView.play()
        
        containerView.addSubview(animationView)
        
        NSLayoutConstraint.activate([
            animationView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            animationView.topAnchor.constraint(equalTo: containerView.topAnchor),
            animationView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        return containerView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Animation updates if needed
    }
}

#else

/// Placeholder LottieView when Lottie SDK is not available
/// This allows the code to compile and use the SwiftUI fallback animations
struct LottieView: View {
    let name: String
    var loopMode: LottieLoopModeCompat = .loop
    var animationSpeed: CGFloat = 1.0
    
    init(name: String, loopMode: LottieLoopModeCompat = .loop, animationSpeed: CGFloat = 1.0) {
        self.name = name
        self.loopMode = loopMode
        self.animationSpeed = animationSpeed
    }
    
    var body: some View {
        // Return empty view - the calling code should check lottieAvailable first
        EmptyView()
    }
}

#endif

// MARK: - Preview
#Preview {
    LottieView(name: "empty_feed_skeleton", loopMode: .loop)
        .frame(height: 260)
}
