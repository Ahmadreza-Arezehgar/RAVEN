import SwiftUI

// MARK: - Raven Design System Tokens (2026-08 Obsidian/Aurora redesign)
/// Single source of truth for Raven iOS visuals.
/// Brand: pure black + dark violet `#7C3AED` (Obsidian base, Aurora accents).
/// `cyan`/`cyanDeep` are legacy names now aliased onto the violet family so
/// every existing consumer re-skins at once; a mechanical rename is deferred.
/// Usage: `DS.violet`, `DS.ink`, `DS.titleFont`, `.ravenScreen()`
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

    // MARK: Brand palette — Obsidian black + Aurora violet
    /// Primary accent — dark violet.
    static let violet = Color(red: 0.486, green: 0.227, blue: 0.929)      // #7C3AED
    static let violetDeep = Color(red: 0.357, green: 0.129, blue: 0.714)  // #5B21B6
    static let violetSoft = Color(red: 0.655, green: 0.545, blue: 0.980)  // #A78BFA
    /// Internet/p2p path indicator (mesh is violet, internet is blue).
    static let pathBlue = Color(red: 0.161, green: 0.553, blue: 1.0)      // #298DFF

    /// LEGACY ALIASES — old names repointed onto the violet family so every
    /// existing `DS.cyan` consumer flips with the redesign. Do not use in new
    /// code; use `violet`/`violetDeep`/`violetSoft`.
    static let cyan = violet
    static let cyanDeep = violetDeep
    static let teal = Color(red: 0.15, green: 0.78, blue: 0.72)

    /// Obsidian surfaces: pure black base, violet-tinted elevation.
    static let ink = Color.black                                          // #000000
    static let inkElevated = Color(red: 0.051, green: 0.027, blue: 0.086) // #0D0716
    static let charcoal = Color(red: 0.090, green: 0.063, blue: 0.133)    // #171022
    static let mist = Color(red: 0.93, green: 0.92, blue: 0.97)

    // Primary / secondary accents used across the app (map old names → brand).
    static let accentBlue = pathBlue
    static let accentPurple = violetSoft
    static let accentGray = Color.secondary
    static let accentDanger = Color(red: 1.0, green: 0.32, blue: 0.36)
    static let accentSuccess = Color(red: 0.25, green: 0.85, blue: 0.55)

    // MARK: Gradients
    static var signalGradient: LinearGradient {
        LinearGradient(
            colors: [violet, violetDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var inkAura: RadialGradient {
        RadialGradient(
            colors: [violet.opacity(0.20), violet.opacity(0.05), .clear],
            center: .topTrailing,
            startRadius: 20,
            endRadius: 420
        )
    }

    static var bubbleOutgoing: LinearGradient {
        LinearGradient(
            colors: [violetDeep.opacity(0.95), violet.opacity(0.85)],
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
