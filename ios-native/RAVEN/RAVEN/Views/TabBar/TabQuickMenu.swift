import SwiftUI

// MARK: - Tab Quick Menu (Liquid Glass Popup)
struct TabQuickMenu: View {
    let actions: [TabAction]
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            // Handle bar
            Capsule()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 44, height: 5)
                .padding(.top, 10)
            
            // Action buttons
            VStack(spacing: 6) {
                ForEach(actions) { action in
                    Button {
                        Haptics.light()
                        action.handler()
                        onDismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.systemImage)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(action.tint)
                                .frame(width: 24)
                            
                            Text(action.title)
                                .foregroundStyle(.primary)
                                .font(.system(size: 15, weight: .semibold))
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .liquidGlassRowBackground()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: 340)
        .liquidGlassContainer(cornerRadius: 22)
        .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 10)
    }
}

// MARK: - Liquid Glass View Extensions
extension View {
    /// Apply Liquid Glass container background with fallback for older iOS
    @ViewBuilder
    func liquidGlassContainer(cornerRadius: CGFloat) -> some View {
        self
            .background {
                Group {
                    if #available(iOS 15.0, *) {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.clear)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.22), lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
    
    /// Apply Liquid Glass capsule background with fallback
    @ViewBuilder
    func liquidGlassCapsule() -> some View {
        self
            .background {
                Group {
                    if #available(iOS 15.0, *) {
                        Capsule()
                            .fill(.clear)
                            .background(.ultraThinMaterial, in: Capsule())
                    } else {
                        Capsule()
                            .fill(.ultraThinMaterial)
                    }
                }
            }
            .clipShape(Capsule())
    }
    
    /// Apply Liquid Glass row highlight background
    @ViewBuilder
    func liquidGlassRowBackground() -> some View {
        self
            .background {
                Group {
                    if #available(iOS 15.0, *) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.clear)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
            }
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
        
        TabQuickMenu(
            actions: [
                TabAction(title: "New Chat", systemImage: "square.and.pencil", tint: .blue) {},
                TabAction(title: "Mesh Status", systemImage: "antenna.radiowaves.left.and.right", tint: .purple) {}
            ],
            onDismiss: {}
        )
    }
}
