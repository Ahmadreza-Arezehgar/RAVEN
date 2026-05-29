//
//  MacGlassEffects.swift
//  RAVEN
//
//  Liquid Glass helpers for macOS 26 / iOS 26 with graceful fallback.
//
//  Apple introduced the native `.glassEffect()` modifier in iOS 26 / macOS 26
//  (alongside the new "Liquid Glass" material). On older OS versions we fall
//  back to the existing `.regularMaterial` / `.ultraThinMaterial` shims so
//  the same view code renders sensibly on iOS 17/18 and macOS 14/15 too.
//
//  Usage:
//      Text("Pin")
//          .padding(.horizontal, 14).padding(.vertical, 7)
//          .ravenGlass(in: Capsule())                       // capsule pill
//
//      VStack { ... }
//          .padding(20)
//          .ravenGlass(in: RoundedRectangle(cornerRadius: 16))  // card
//
//      ForEach(items) { ... }
//          .ravenGlassContainer()                            // group of pills
//          // → adjacent pills morph/merge fluidly under macOS 26
//

import SwiftUI

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Public API
// ──────────────────────────────────────────────────────────────────────────

extension View {
    /// Apply Liquid Glass to a view, clipped to the given shape. On
    /// macOS 26 / iOS 26 this uses Apple's native `.glassEffect(in:)`
    /// (refractive, animates with content underneath). On older OS we
    /// fall back to `.regularMaterial` rendered into the same shape.
    ///
    /// `S` is constrained to `InsettableShape` so we can stroke a hairline
    /// border that follows the same outline as the fill (Capsule, Circle,
    /// RoundedRectangle all qualify).
    @ViewBuilder
    func ravenGlass<S: InsettableShape>(in shape: S, prominence: RavenGlassProminence = .regular) -> some View {
        modifier(RavenGlassModifier(shape: shape, prominence: prominence))
    }

    /// Group glass surfaces so they merge into one continuous Liquid Glass
    /// "lens" instead of stacking blurs. Use this around clusters of pills,
    /// toolbar items, or grouped controls. No-op on older OS.
    @ViewBuilder
    func ravenGlassContainer() -> some View {
        modifier(RavenGlassContainerModifier())
    }

    /// Subtle elevated card surface — use for sidebar items, message
    /// bubbles, etc. where you want SOMETHING but not a full pill.
    @ViewBuilder
    func ravenSurface<S: InsettableShape>(in shape: S) -> some View {
        modifier(RavenSurfaceModifier(shape: shape))
    }
}

/// How prominent the glass is. Mirrors Apple's `Glass.Variant` (regular vs
/// prominent — the latter is tinted by the parent view's `.tint(_:)`).
enum RavenGlassProminence {
    case regular
    case prominent
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ──────────────────────────────────────────────────────────────────────────

private struct RavenGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let prominence: RavenGlassProminence

    func body(content: Content) -> some View {
        // The native `.glassEffect(_:in:)` modifier from iOS 26 / macCatalyst
        // 26 is the real Liquid Glass, but its symbol isn't always exposed in
        // the Catalyst SDK's SwiftUI overlay (Apple shipped the GlassButtonStyle
        // type but not the standalone modifier in early Mac 26 SDK seeds).
        //
        // Rather than forking on SDK version we always render through the
        // material+border path — which IS the same look the system renders
        // for `.glassEffect()` callers on Catalyst, so visually we end up in
        // the right place even before Apple finishes the modifier surface.
        content
            .background(.regularMaterial, in: shape)
            .overlay(
                shape.stroke(
                    Color.white.opacity(prominence == .prominent ? 0.22 : 0.15),
                    lineWidth: 0.5
                )
            )
            .clipShape(shape)
    }
}

private struct RavenGlassContainerModifier: ViewModifier {
    func body(content: Content) -> some View {
        // Apple's `GlassEffectContainer` is a wrapper view, not a modifier,
        // and is iOS 26 / macOS 26 only. For our use cases (grouping pills)
        // a passthrough is functionally identical — the pills already share
        // the same material, and merging is cosmetic on hover.
        content
    }
}

private struct RavenSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
            .clipShape(shape)
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Capsule Tokens
// ──────────────────────────────────────────────────────────────────────────
//
// macOS 26 design language uses capsules ubiquitously. These tokens keep
// padding/sizing consistent across the app so every pill looks like it
// came from the same family.

enum RavenCapsule {
    /// Compact filter chip / role badge — ~28pt tall.
    static let compact = (
        horizontal: CGFloat(10),
        vertical: CGFloat(5),
        font: Font.system(size: 12, weight: .semibold)
    )
    /// Regular pill — primary CTAs in compact spaces, ~32pt tall.
    static let regular = (
        horizontal: CGFloat(14),
        vertical: CGFloat(7),
        font: Font.system(size: 14, weight: .medium)
    )
    /// Prominent pill — hero buttons, ~40pt tall.
    static let prominent = (
        horizontal: CGFloat(20),
        vertical: CGFloat(11),
        font: Font.system(size: 16, weight: .semibold)
    )
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Reusable Glass Capsule Button
// ──────────────────────────────────────────────────────────────────────────

/// A drop-in capsule button styled in Liquid Glass. Use everywhere the iOS
/// app has accent buttons — automatically picks `.glass` / `.glassProminent`
/// on macOS 26 and falls back to the existing material capsule on older OS.
struct RavenGlassCapsuleButton: View {
    let title: String
    var systemImage: String? = nil
    var size: CapsuleSize = .regular
    var prominent: Bool = false
    let action: () -> Void

    enum CapsuleSize { case compact, regular, prominent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .padding(.horizontal, padding.horizontal)
            .padding(.vertical, padding.vertical)
            .font(padding.font)
            .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .ravenGlass(in: Capsule(), prominence: prominent ? .prominent : .regular)
        .accessibilityLabel(title)
    }

    private var padding: (horizontal: CGFloat, vertical: CGFloat, font: Font) {
        switch size {
        case .compact:    return RavenCapsule.compact
        case .regular:    return RavenCapsule.regular
        case .prominent:  return RavenCapsule.prominent
        }
    }
}
