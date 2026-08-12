import SwiftUI

// MARK: - Raven Design System Tokens (2026 chic redesign)
/// Single source of truth for Raven iOS visuals.
/// Brand: raven-messager.com — cyan signal `#40F2FF` on deep ink charcoal.
/// Usage: `DS.cyan`, `DS.ink`, `DS.titleFont`, `.ravenScreen()`
enum DS {

    // MARK: Corner Radii
    static let radiusCard: CGFloat = 20
    static let radiusInner: CGFloat = 12
    static let radiusPill: CGFloat = 100
    static let radiusHero: CGFloat = 28

    // MARK: Spacing (8-point grid)
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32

    // MARK: Shadow
    static let shadowColor = Color.black.opacity(0.12)
    static let shadowRadius: CGFloat = 16
    static let shadowY: CGFloat = 6

    // MARK: Brand palette — ONE cohesive system (cyan signal + ink)
    /// Signature Raven cyan (site `#40F2FF`).
    static let cyan = Color(red: 0.251, green: 0.949, blue: 1.0) // #40F2FF
    static let cyanDeep = Color(red: 0.05, green: 0.72, blue: 0.82)
    static let teal = Color(red: 0.15, green: 0.78, blue: 0.72)

    /// Deep ink / charcoal for dark surfaces and text hierarchy.
    static let ink = Color(red: 0.04, green: 0.05, blue: 0.07) // near-black
    static let inkElevated = Color(red: 0.09, green: 0.10, blue: 0.13)
    static let charcoal = Color(red: 0.14, green: 0.15, blue: 0.18)
    static let mist = Color(red: 0.92, green: 0.94, blue: 0.96)

    // Primary / secondary accents used across the app (map old names → brand).
    static let accentBlue = cyan
    /// Soft lilac reserved for rare secondary chips — NOT a purple glow theme.
    static let accentPurple = Color(red: 0.45, green: 0.55, blue: 0.62) // cool slate, not violet
    static let accentGray = Color.secondary
    static let accentDanger = Color(red: 1.0, green: 0.32, blue: 0.36)
    static let accentSuccess = Color(red: 0.25, green: 0.85, blue: 0.55)

    // MARK: Gradients
    static var signalGradient: LinearGradient {
        LinearGradient(
            colors: [cyan, cyanDeep, teal],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var inkAura: RadialGradient {
        RadialGradient(
            colors: [cyan.opacity(0.22), cyan.opacity(0.06), .clear],
            center: .topTrailing,
            startRadius: 20,
            endRadius: 420
        )
    }

    static var bubbleOutgoing: LinearGradient {
        LinearGradient(
            colors: [cyanDeep.opacity(0.95), cyan.opacity(0.85)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Typography (SF Pro — careful hierarchy; Dynamic Type friendly)
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .default, weight: .bold)
    }

    static func title(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .default, weight: .semibold)
    }

    static func body(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .default, weight: .regular)
    }

    static func caption(_ style: Font.TextStyle = .caption) -> Font {
        .system(style, design: .default, weight: .medium)
    }

    static func mono(_ style: Font.TextStyle = .caption) -> Font {
        .system(style, design: .monospaced, weight: .medium)
    }

    // MARK: Glass Nav Bar
    static let navBarHeight: CGFloat = 56
    static let navButtonSize: CGFloat = 36

    // MARK: Bottom Safe Padding
    static let bottomTabClearance: CGFloat = 100

    // MARK: Motion
    static let tabSpring = Animation.interpolatingSpring(stiffness: 320, damping: 30)
    static let openChatSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let sendPulse = Animation.spring(response: 0.28, dampingFraction: 0.72)
}

// MARK: - Screen atmosphere

struct RavenScreenBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            // Soft ink wash (light mode: faint cyan mist; dark: deep charcoal glow)
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    DS.cyan.opacity(0.04),
                    Color(.systemBackground),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            DS.inkAura
                .opacity(0.85)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass Card Modifier

struct RavenCardModifier: ViewModifier {
    var radius: CGFloat = DS.radiusCard
    var padding: CGFloat = DS.space16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        DS.cyan.opacity(0.35),
                                        Color.white.opacity(0.08),
                                        DS.teal.opacity(0.12),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    }
            }
            .shadow(color: DS.cyan.opacity(0.08), radius: DS.shadowRadius, y: DS.shadowY)
    }
}

extension View {
    func ravenCard(radius: CGFloat = DS.radiusCard, padding: CGFloat = DS.space16) -> some View {
        modifier(RavenCardModifier(radius: radius, padding: padding))
    }

    /// Full-screen Raven atmosphere behind content.
    func ravenScreen() -> some View {
        background { RavenScreenBackground() }
    }
}

// MARK: - Primary CTA

struct RavenPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .default, weight: .semibold))
            .foregroundStyle(DS.ink)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.signalGradient)
                    .opacity(configuration.isPressed ? 0.85 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.sendPulse, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RavenPrimaryButtonStyle {
    static var ravenPrimary: RavenPrimaryButtonStyle { .init() }
}
