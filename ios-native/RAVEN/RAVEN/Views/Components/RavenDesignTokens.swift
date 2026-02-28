import SwiftUI

// MARK: - Raven Design System Tokens
/// Single source of truth for all visual constants.
/// Usage: `DS.radiusCard`, `DS.space16`, `DS.accentBlue`
enum DS {
    
    // MARK: Corner Radii
    static let radiusCard: CGFloat  = 22   // All glass cards, sheets, containers
    static let radiusInner: CGFloat = 12   // Inner elements — images, chips, text fields
    static let radiusPill: CGFloat  = 100  // Capsule / pill shapes
    
    // MARK: Spacing (8-point grid)
    static let space4:  CGFloat = 4
    static let space8:  CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16
    static let space24: CGFloat = 24
    static let space32: CGFloat = 32
    
    // MARK: Shadow
    static let shadowColor  = Color.black.opacity(0.08)
    static let shadowRadius: CGFloat = 10
    static let shadowY: CGFloat = 4
    
    // MARK: Accent Palette (limited to 3)
    static let accentBlue   = Color.blue
    static let accentPurple = Color.purple
    static let accentGray   = Color.secondary
    
    // MARK: Glass Nav Bar
    static let navBarHeight: CGFloat = 56
    static let navButtonSize: CGFloat = 36
    
    // MARK: Bottom Safe Padding
    /// Content padding to avoid overlap with floating tab bar
    static let bottomTabClearance: CGFloat = 100
}

// MARK: - Glass Card Modifier (convenience)
/// Applies consistent glass card styling to any view.
/// ```
/// myView.ravenCard()
/// ```
struct RavenCardModifier: ViewModifier {
    var radius: CGFloat = DS.radiusCard
    var padding: CGFloat = DS.space16
    
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
    }
}

extension View {
    func ravenCard(radius: CGFloat = DS.radiusCard, padding: CGFloat = DS.space16) -> some View {
        modifier(RavenCardModifier(radius: radius, padding: padding))
    }
}
