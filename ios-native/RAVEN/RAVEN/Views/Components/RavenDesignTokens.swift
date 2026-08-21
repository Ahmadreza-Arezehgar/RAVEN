import SwiftUI

// MARK: - Raven Design System Tokens (2026-08 "RAVEN://TERMINAL" redesign)
/// Single source of truth for Raven iOS visuals.
///
/// Brand: CRT phosphor terminal. Near-black green-tinted surfaces,
/// phosphor-green primary accent, amber secondary, monospace type
/// everywhere, hairline borders instead of glass blur, sharp corners,
/// scanline/grid screen atmosphere.
///
/// Legacy color names (`cyan`, `violet`, `teal`) are aliased onto the
/// phosphor family so every existing consumer re-skins at once; a
/// mechanical rename is deferred.
/// Usage: `DS.phosphor`, `DS.ink`, `DS.mono(.callout)`, `.ravenScreen()`
enum DS {

    // MARK: Corner Radii (terminal = sharp)
    static let radiusCard: CGFloat = 10
    static let radiusInner: CGFloat = 6
    static let radiusPill: CGFloat = 4
    static let radiusHero: CGFloat = 14

    // MARK: Spacing (8-point grid)
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32

    // MARK: Shadow (terminals glow, they don't cast)
    static let shadowColor = Color.black.opacity(0.5)
    static let shadowRadius: CGFloat = 12
    static let shadowY: CGFloat = 4

    // MARK: Terminal palette — CRT accent on near-black
    // v2 (2026-08): the accent family is USER-SELECTABLE (phosphor green /
    // ion blue / amber CRT) via `AppSettings.terminalAccent`. Every color
    // below resolves through the live setting at body-evaluation time, so
    // @Observable access tracking re-skins any view that reads them the
    // moment the user flips the accent in Settings → Design.

    /// Live accent theme selected by the user.
    static var accent: AppSettings.TerminalAccent { AppSettings.shared.terminalAccent }

    /// Primary neon accent (name kept from the green-only era).
    static var phosphor: Color { accent.primary }
    static var phosphorDeep: Color { accent.deep }
    static var phosphorSoft: Color { accent.soft }
    /// Warning/draft highlight — fixed amber across themes (semantic, not decorative).
    static let amber = Color(red: 1.0, green: 0.69, blue: 0.0)             // #FFB000
    /// Internet/p2p path indicator (mesh is accent, internet is cyan-blue).
    static let pathBlue = Color(red: 0.208, green: 0.784, blue: 1.0)       // #35C8FF

    /// LEGACY ALIASES — old Obsidian/Aurora names repointed onto the
    /// accent family so every existing consumer flips with the redesign.
    /// Do not use in new code; use `phosphor`/`phosphorDeep`/`phosphorSoft`.
    static var violet: Color { phosphor }
    static var violetDeep: Color { phosphorDeep }
    static var violetSoft: Color { phosphorSoft }
    static var cyan: Color { phosphor }
    static var cyanDeep: Color { phosphorDeep }
    static let teal = Color(red: 0.102, green: 0.706, blue: 0.529)         // #1AB487

    /// Console surfaces: near-black, accent-tinted elevation ladder.
    static var ink: Color { accent.ink }
    static var inkElevated: Color { accent.inkElevated }
    static var charcoal: Color { accent.charcoal }
    static var mist: Color { accent.mist }

    // Primary / secondary accents used across the app (map old names → brand).
    static let accentBlue = pathBlue
    static var accentPurple: Color { phosphorSoft }
    static let accentGray = Color.secondary
    static let accentDanger = Color(red: 1.0, green: 0.333, blue: 0.333)   // #FF5555
    static var accentSuccess: Color { phosphor }

    // MARK: Hairlines & grids
    /// Standard 1px console border.
    static var hairline: Color { phosphor.opacity(0.22) }
    /// Fainter rule for row separators inside panels.
    static var hairlineDim: Color { phosphor.opacity(0.10) }

    // MARK: Gradients
    static var signalGradient: LinearGradient {
        LinearGradient(
            colors: [phosphorDeep, phosphor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var inkAura: RadialGradient {
        RadialGradient(
            colors: [phosphor.opacity(0.10), phosphor.opacity(0.02), .clear],
            center: .topTrailing,
            startRadius: 20,
            endRadius: 420
        )
    }

    static var bubbleOutgoing: LinearGradient {
        LinearGradient(
            colors: [phosphorDeep.opacity(0.38), phosphorDeep.opacity(0.22)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Typography (monospace console hierarchy; Dynamic Type friendly)
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .monospaced, weight: .bold)
    }

    static func title(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .monospaced, weight: .semibold)
    }

    static func body(_ style: Font.TextStyle = .body) -> Font {
        .system(style, design: .monospaced, weight: .regular)
    }

    static func caption(_ style: Font.TextStyle = .caption) -> Font {
        .system(style, design: .monospaced, weight: .medium)
    }

    static func mono(_ style: Font.TextStyle = .caption) -> Font {
        .system(style, design: .monospaced, weight: .medium)
    }

    // MARK: Console chrome
    static let navBarHeight: CGFloat = 56
    static let navButtonSize: CGFloat = 36

    // MARK: Bottom Safe Padding
    static let bottomTabClearance: CGFloat = 100

    // MARK: Motion (terminal: instant, mechanical)
    static let tabSpring = Animation.interpolatingSpring(stiffness: 480, damping: 34)
    static let openChatSpring = Animation.spring(response: 0.30, dampingFraction: 0.90)
    static let sendPulse = Animation.spring(response: 0.25, dampingFraction: 0.75)
}

// MARK: - Screen atmosphere (CRT console)

struct RavenScreenBackground: View {
    var body: some View {
        ZStack {
            DS.ink
            // Phosphor wash from the top corner + faint floor bounce.
            LinearGradient(
                colors: [
                    DS.phosphor.opacity(0.05),
                    Color.clear,
                    DS.phosphor.opacity(0.02),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            DS.inkAura
                .opacity(0.9)
                .allowsHitTesting(false)
            TerminalGrid()
                .allowsHitTesting(false)
            ScanlineOverlay()
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Console Panel Modifier (replaces glass cards)

struct RavenCardModifier: ViewModifier {
    var radius: CGFloat = DS.radiusCard
    var padding: CGFloat = DS.space16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DS.inkElevated.opacity(0.92))
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.hairline, lineWidth: 1)
            }
            // Corner ticks — the terminal-panel signature.
            .overlay(TerminalCornerTicks(radius: radius))
            .shadow(color: .black.opacity(0.45), radius: DS.shadowRadius, y: DS.shadowY)
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

// MARK: - Primary CTA ([ EXECUTE ] style)

struct RavenPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .monospaced, weight: .semibold))
            .foregroundStyle(DS.ink)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                    .fill(DS.phosphor)
                    .opacity(configuration.isPressed ? 0.75 : 1)
                    .shadow(color: DS.phosphor.opacity(configuration.isPressed ? 0.0 : 0.35), radius: 10, y: 0)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                    .strokeBorder(DS.phosphorSoft.opacity(0.5), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(DS.sendPulse, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RavenPrimaryButtonStyle {
    static var ravenPrimary: RavenPrimaryButtonStyle { .init() }
}
