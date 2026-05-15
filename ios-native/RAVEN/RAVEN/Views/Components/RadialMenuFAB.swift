import SwiftUI

// MARK: - Radial Menu FAB (Floating Action Button with Expandable Options)
/// Floating button that expands into a radial menu with New Post, Audio Room, Club, and Echo options.
/// Uses Apple Liquid Glass design with spring droplet animations.
struct RadialMenuFAB: View {
    /// Whether the menu is currently expanded
    @State private var isExpanded = false
    
    /// Actions
    let onNewPost: () -> Void
    let onAudioRoom: () -> Void
    let onClub: () -> Void
    let onEcho: () -> Void
    
    // Liquid Glass spring animation
    private let dropletSpring = Animation.spring(
        response: 0.5,
        dampingFraction: 0.7,
        blendDuration: 0.25
    )
    
    // Staggered animation delays for 4 items
    private let stagger1: Double = 0.0
    private let stagger2: Double = 0.06
    private let stagger3: Double = 0.12
    private let stagger4: Double = 0.18
    
    // Layout constants
    private let fabSize: CGFloat = 56
    private let fabBottomPadding: CGFloat = 100
    private let fabTrailingPadding: CGFloat = 20
    
    var body: some View {
        ZStack {
            // Full-screen dimmed background when expanded
            if isExpanded {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeMenu()
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
                    .zIndex(0)
            }
            
            // Menu items positioned from bottom-right
            VStack(spacing: 14) {
                // Option items (shown when expanded)
                if isExpanded {
                    // Option 1: New Post (appears first with stagger)
                    RadialMenuItem(
                        icon: "square.and.pencil",
                        label: "New Post",
                        color: .blue
                    ) {
                        closeMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onNewPost()
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.1, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                                .animation(dropletSpring.delay(stagger1)),
                            removal: .scale(scale: 0.1, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                                .animation(.easeOut(duration: 0.2))
                        )
                    )
                    
                    // Option 2: Audio Room
                    RadialMenuItem(
                        icon: "waveform.circle.fill",
                        label: "Audio Room",
                        color: .purple
                    ) {
                        closeMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onAudioRoom()
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.1, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                                .animation(dropletSpring.delay(stagger2)),
                            removal: .scale(scale: 0.1, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                                .animation(.easeOut(duration: 0.15))
                        )
                    )
                    
                    // Option 3: Club (mesh group tracking)
                    RadialMenuItem(
                        icon: "person.3.fill",
                        label: "Club",
                        color: .orange
                    ) {
                        closeMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onClub()
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.1, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                                .animation(dropletSpring.delay(stagger3)),
                            removal: .scale(scale: 0.1, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                                .animation(.easeOut(duration: 0.12))
                        )
                    )
                    
                    // Option 4: Echo (anonymous broadcast)
                    RadialMenuItem(
                        icon: "waveform",
                        label: "Echo",
                        color: .indigo
                    ) {
                        closeMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            onEcho()
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.1, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                                .animation(dropletSpring.delay(stagger4)),
                            removal: .scale(scale: 0.1, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                                .animation(.easeOut(duration: 0.1))
                        )
                    )
                }
                
                // Main FAB button (+ morphs to ×)
                Button {
                    Haptics.light()
                    withAnimation(dropletSpring) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: fabSize, height: fabSize)
                        .background(.ultraThinMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
                        .rotationEffect(.degrees(isExpanded ? 45 : 0))
                        .scaleEffect(isExpanded ? 1.05 : 1.0)
                }
                .buttonStyle(RadialMenuButtonStyle())
                .accessibilityLabel(isExpanded ? "Close menu" : "Create")
                .accessibilityHint("Double tap to open the create menu")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, fabTrailingPadding)
            .padding(.bottom, fabBottomPadding)
            .zIndex(1)
        }
        .animation(dropletSpring, value: isExpanded)
    }
    
    private func closeMenu() {
        Haptics.light()
        withAnimation(dropletSpring) {
            isExpanded = false
        }
    }
}

// MARK: - Radial Menu Button Style
struct RadialMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Radial Menu Item (Liquid Glass Style)
struct RadialMenuItem: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Label capsule
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
                    }
                
                // Icon circle with gradient
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.65)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        }
                    
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .background(.regularMaterial, in: Circle())
                .shadow(color: color.opacity(0.4), radius: 10, x: 0, y: 5)
            }
        }
        .buttonStyle(RadialMenuButtonStyle())
        .accessibilityLabel(label)
        .accessibilityHint("Double tap to \(label.lowercased())")
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        LinearGradient(
            colors: [.blue.opacity(0.3), .purple.opacity(0.2)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        
        // Fake tab bar
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .frame(height: 70)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        }
        
        RadialMenuFAB(
            onNewPost: { print("New Post tapped") },
            onAudioRoom: { print("Audio Room tapped") },
            onClub: { print("Club tapped") },
            onEcho: { print("Echo tapped") }
        )
    }
}
