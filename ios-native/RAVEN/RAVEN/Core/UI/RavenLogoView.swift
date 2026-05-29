// RavenLogoView.swift
//
// Drop-in Raven logo whose backdrop **shifts with the time of day**.
//
//   • Morning / afternoon  → bright white capsule.
//   • Sunset / dusk        → warm purple-to-orange gradient.
//   • Night                → near-black capsule with a soft purple
//                            inner glow so the wordmark still pops.
//
// Only the logo's CONTAINER changes — the asset itself (Image("RavenLogo"))
// stays untouched. This keeps the home-screen app icon, push-notification
// icon, and the App Store listing identical; the dynamic feel lives
// strictly inside the running app, exactly per the spec.
//
// Transition policy:
//   • A 5-minute timer recomputes the mode on its own. Wake-from-
//     background recomputes immediately via the scenePhase observer.
//   • SwiftUI animates the backdrop change via
//     `.animation(.easeInOut(duration: 1.6))` — no sudden jumps.
//   • The clock-only path needs no permissions and works offline; a
//     follow-up can wire in approximate-location sunrise/sunset when
//     the user opts in (see `SolarTimes`-style work in earlier rounds).
//
// Liquid-Glass parity:
//   The capsule honours the same `.ultraThinMaterial` / blur language
//   as the rest of the chrome (see `RavenMaterials.swift`); the
//   per-mode tint is layered *behind* the material so the texture
//   stays consistent across day and night.

import SwiftUI

// MARK: - Mode

/// Phases the logo cycles through over the course of a day. Reused
/// across previews + tests; not exposed in settings (the logo decides
/// for itself based on the local clock).
enum RavenLogoMode: String, CaseIterable, Equatable, Sendable {
    case day, sunset, night

    /// Bands chosen to feel "natural" without needing real solar data:
    ///   06:00–06:30  sunset (dawn glow)
    ///   06:30–17:30  day
    ///   17:30–19:30  sunset (golden hour)
    ///   19:30–06:00  night
    static func current(at date: Date = Date()) -> RavenLogoMode {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let total = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        switch total {
        case 360..<390:    return .sunset   // 06:00 – 06:30
        case 390..<1050:   return .day      // 06:30 – 17:30
        case 1050..<1170:  return .sunset   // 17:30 – 19:30
        default:           return .night
        }
    }

    /// Capsule background. `LinearGradient` even for solid modes so
    /// SwiftUI animates between gradients homogeneously — switching
    /// types mid-animation produces visible "snap" frames.
    var background: LinearGradient {
        switch self {
        case .day:
            return LinearGradient(
                colors: [Color.white, Color(white: 0.96)],
                startPoint: .top, endPoint: .bottom
            )
        case .sunset:
            return LinearGradient(
                colors: [
                    Color(red: 0.45, green: 0.27, blue: 0.78),  // raven purple
                    Color(red: 0.95, green: 0.55, blue: 0.36),  // sunset orange
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .night:
            return LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.03, blue: 0.06),
                    Color(red: 0.06, green: 0.04, blue: 0.10),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    /// Optional inner glow drawn on top of the capsule. Only `.night`
    /// uses it — a soft purple haze around the logo to keep contrast.
    var innerGlow: RadialGradient {
        switch self {
        case .night:
            return RadialGradient(
                colors: [
                    Color(red: 0.45, green: 0.30, blue: 0.85).opacity(0.30),
                    Color.clear,
                ],
                center: .center, startRadius: 4, endRadius: 90
            )
        case .day, .sunset:
            // Clear → render is a no-op cost. Keeps the view shape
            // identical across modes so SwiftUI's diff is small.
            return RadialGradient(
                colors: [Color.clear, Color.clear],
                center: .center, startRadius: 0, endRadius: 1
            )
        }
    }

    /// Border tint so the capsule reads on top of either a light or
    /// dark surrounding surface.
    var borderColor: Color {
        switch self {
        case .day:    return Color.black.opacity(0.06)
        case .sunset: return Color.white.opacity(0.12)
        case .night:  return Color.white.opacity(0.10)
        }
    }

    /// Tint applied to the logo asset itself when the capsule goes
    /// dark. Day keeps the asset's native colors; `.night` and
    /// `.sunset` lift it to white so the wordmark stays legible.
    var logoTint: Color? {
        switch self {
        case .day:    return nil          // render as designed
        case .sunset: return .white
        case .night:  return .white
        }
    }
}

// MARK: - View

/// The drop-in. Use anywhere the RAVEN logo currently appears.
///
/// Example:
///
///     RavenLogoView()
///         .frame(width: 72, height: 72)
///
/// or
///
///     RavenLogoView(diameter: 56)
///
/// Animations crossfade between modes over ~1.6 s; cheap to drop into
/// the splash, settings header, auth landing, or any sheet.
struct RavenLogoView: View {
    /// Override the auto-computed mode (useful for previews / settings
    /// row that wants to show the .day variant regardless of time).
    let modeOverride: RavenLogoMode?
    /// Asset name in the bundle's Assets.xcassets — defaults to the
    /// existing `RavenLogo` imageset used everywhere else in the app.
    let assetName: String
    /// Outer diameter of the capsule. The logo image is centered with
    /// internal padding so the asset never touches the rim.
    let diameter: CGFloat

    @State private var liveMode: RavenLogoMode = RavenLogoMode.current()
    @Environment(\.scenePhase) private var scenePhase

    init(modeOverride: RavenLogoMode? = nil,
         assetName: String = "RavenLogo",
         diameter: CGFloat = 64) {
        self.modeOverride = modeOverride
        self.assetName = assetName
        self.diameter = diameter
    }

    private var mode: RavenLogoMode { modeOverride ?? liveMode }

    var body: some View {
        ZStack {
            // Capsule background — the part that shifts with time.
            Circle()
                .fill(mode.background)

            // Optional inner glow (only visible at night).
            Circle()
                .fill(mode.innerGlow)
                .blendMode(.plusLighter)

            // Liquid-Glass texture layered on top so the look matches
            // the rest of the app's capsules + cards.
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(mode == .day ? 0.10 : 0.18)
                .blendMode(.overlay)

            // The logo asset itself. Tint only in non-day modes so the
            // wordmark stays legible against the darker backdrop.
            Image(assetName)
                .resizable()
                .renderingMode(mode.logoTint == nil ? .original : .template)
                .scaledToFit()
                .frame(width: diameter * 0.62, height: diameter * 0.62)
                .foregroundStyle(mode.logoTint ?? .black)
        }
        .frame(width: diameter, height: diameter)
        .overlay(
            Circle().stroke(mode.borderColor, lineWidth: 0.5)
        )
        .shadow(
            color: mode == .night
                ? Color.purple.opacity(0.35)
                : Color.black.opacity(0.10),
            radius: mode == .night ? 14 : 8,
            x: 0, y: 4
        )
        // Crossfade between modes. 1.6 s is slow enough to be
        // perceived as "the sky moved", fast enough not to feel
        // sluggish if the user happens to open the app right at the
        // transition boundary.
        .animation(.easeInOut(duration: 1.6), value: mode)
        .onAppear { recompute() }
        .onChange(of: scenePhase) { _, phase in
            // Foreground-wake: re-derive immediately rather than wait
            // for the 5-minute timer. The animation still runs so a
            // mode change feels like the app "woke up to a new sky".
            if phase == .active { recompute() }
        }
        // Light heartbeat so the mode advances while the app stays
        // open across a sunset / dawn boundary. 5 minutes is
        // plenty — the bands are 30-min minimum.
        .task(id: "raven-logo-tick") {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                recompute()
            }
        }
    }

    private func recompute() {
        let new = RavenLogoMode.current()
        if new != liveMode { liveMode = new }
    }
}

// MARK: - Previews

#Preview("Day · 72pt") {
    RavenLogoView(modeOverride: .day, diameter: 72)
        .padding(40)
        .background(Color(.systemBackground))
}

#Preview("Sunset · 72pt") {
    RavenLogoView(modeOverride: .sunset, diameter: 72)
        .padding(40)
        .background(Color(.systemBackground))
}

#Preview("Night · 72pt") {
    RavenLogoView(modeOverride: .night, diameter: 72)
        .padding(40)
        .background(Color(.systemBackground))
}
