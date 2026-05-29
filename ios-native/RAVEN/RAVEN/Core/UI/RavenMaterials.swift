//
//  RavenMaterials.swift
//  RAVEN
//
//  Unified Liquid Glass design system — materials, animations, and modifiers.
//

import SwiftUI

// MARK: - Raven Materials

enum RavenMaterial {
    /// Primary surface: sheets, cards, overlays
    static let primary: Material = .ultraThinMaterial
    
    /// Secondary: tooltips, badges
    static let secondary: Material = .regularMaterial
    
    /// Elevated: modal headers, floating elements
    static let elevated: Material = .thickMaterial
}

// MARK: - Liquid Glass Modifiers

/// Adaptive border color: white in dark mode, dark in light mode
private struct AdaptiveGlassBorder: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: AnyShape
    
    func body(content: Content) -> some View {
        content.overlay(
            shape.stroke(
                colorScheme == .dark
                    ? Color.white.opacity(0.15)
                    : Color.black.opacity(0.08),
                lineWidth: 1
            )
        )
    }
}

extension View {
    /// Liquid Glass card effect with rounded corners.
    func liquidGlass(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .modifier(AdaptiveGlassBorder(shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius))))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }
    
    /// Liquid Glass capsule effect.
    func liquidCapsule() -> some View {
        self
            .background(.ultraThinMaterial, in: Capsule())
            .modifier(AdaptiveGlassBorder(shape: AnyShape(Capsule())))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
    
    /// Liquid Glass top bar (only top corners rounded).
    func liquidTopBar(cornerRadius: CGFloat = 24) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            topTrailingRadius: cornerRadius
        )
        return self
            .background(shape.fill(.ultraThinMaterial))
            .modifier(AdaptiveGlassBorder(shape: AnyShape(shape)))
    }
}

// MARK: - Raven Animation Presets

enum RavenAnimation {
    /// Default spring — sheets, page transitions
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.8)
    
    /// Snappy — pin selection, quick toggles
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.75)
    
    /// Smooth — color changes, opacity
    static let smooth = Animation.smooth(duration: 0.35)
    
    /// Bouncy — alerts, drop notifications
    static let bouncy = Animation.bouncy(duration: 0.5, extraBounce: 0.15)
    
    /// Sheet appear/dismiss
    static let sheetAppear = Animation.interpolatingSpring(stiffness: 250, damping: 22)
    
    /// Fade — echo aging, status transitions
    static let fade = Animation.easeOut(duration: 0.6)
}

// MARK: - Status Colors

extension Color {
    /// Member status colors for Club maps
    static let memberActive  = Color.green
    static let memberStale   = Color.orange
    static let memberDropped = Color.red
}
