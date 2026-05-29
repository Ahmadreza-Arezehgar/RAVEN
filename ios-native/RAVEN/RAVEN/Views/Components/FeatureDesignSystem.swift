//
//  FeatureDesignSystem.swift
//  RAVEN
//
//  Design System extensions for the 5 new mesh features.
//  Builds on existing DS tokens & LiquidGlassComponents.
//

import SwiftUI

// MARK: - Feature Color Palette

/// Each new feature has a dedicated color for capsule icons and accent elements.
enum FeatureColor {
    case adaptiveSpray      // Blue → Cyan
    case deliveryConfidence  // Green → Mint
    case geoFenced          // Orange → Pink
    case internetBridge     // Purple → Indigo
    case dataMules          // Ruby → Pink
    
    var primary: Color {
        switch self {
        case .adaptiveSpray:      return Color(red: 0, green: 0.478, blue: 1)       // #007AFF
        case .deliveryConfidence:  return Color(red: 0.204, green: 0.780, blue: 0.349) // #34C759
        case .geoFenced:          return Color(red: 1, green: 0.584, blue: 0)        // #FF9500
        case .internetBridge:     return Color(red: 0.686, green: 0.322, blue: 0.871) // #AF52DE
        case .dataMules:          return Color(red: 1, green: 0.176, blue: 0.333)    // #FF2D55
        }
    }
    
    var gradient: LinearGradient {
        switch self {
        case .adaptiveSpray:
            return LinearGradient(colors: [primary, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .deliveryConfidence:
            return LinearGradient(colors: [primary, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .geoFenced:
            return LinearGradient(colors: [primary, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .internetBridge:
            return LinearGradient(colors: [primary, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .dataMules:
            return LinearGradient(colors: [primary, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Capsule Icon

/// Feature-specific icon in capsule shape with gradient fill and colored shadow.
/// Aspect ratio 1.6:1, SF Symbol center, 0.5pt white border.
struct CapsuleIcon: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 28
    
    var body: some View {
        ZStack {
            Capsule()
                .fill(tint.gradient)
                .frame(width: size * 1.6, height: size)
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.4), lineWidth: 0.5)
                }
                .shadow(color: tint.opacity(0.4), radius: 8, y: 4)
            
            Image(systemName: systemImage)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Metric Card

/// Glass-backed stat card used in detail sheets and dashboards.
struct MetricCard: View {
    let icon: String
    let value: String
    let label: String
    var tint: Color = .blue
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(tint.gradient)
            
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous))
    }
}

// MARK: - Glass Capsule Button Style

/// Button style that renders as a frosted glass capsule.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var tint: Color = .blue
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule()
                            .stroke(tint.opacity(0.3), lineWidth: 0.5)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassCapsuleButtonStyle {
    static var glassCapsule: GlassCapsuleButtonStyle { .init() }
    static func glassCapsule(tint: Color) -> GlassCapsuleButtonStyle { .init(tint: tint) }
}

// MARK: - Feature Glass Card (Enhanced)

/// Enhanced glass card with gradient border for feature sheets.
/// Uses cornerRadius: 24 and gradient white border as specified.
struct FeatureGlassCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.3),
                                        .white.opacity(0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
            }
    }
}

// MARK: - Animation Constants

extension Animation {
    /// Standard spring for all state transitions across new features.
    static let featureSpring = Animation.spring(response: 0.4, dampingFraction: 0.8)
}

// MARK: - Glass Sheet Transition

extension AnyTransition {
    /// Standard glass morph transition for sheets.
    static var glassMorph: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .scale(scale: 0.95).combined(with: .opacity)
        )
    }
}

// MARK: - Privacy Notice View

/// Reusable privacy notice for geo-fence, gateway, and mule features.
struct PrivacyNotice: View {
    let icon: String
    let text: String
    var tint: Color = .orange
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous))
    }
}
