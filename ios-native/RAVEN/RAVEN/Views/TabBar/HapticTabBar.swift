import SwiftUI

// MARK: - Haptic Tab Bar (Custom Tab Bar with Native iOS Context Menu)
struct HapticTabBar: View {
    @Binding var selected: AppTab
    let badgeCount: Int
    let actionsProvider: (AppTab) -> [TabAction]
    
    /// Droplet effect: shrink when Messages is active
    private var isMessages: Bool { selected == .messages }
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                // Use native UIContextMenuInteraction for authentic iOS behavior
                ContextMenuTabItem(
                    tab: tab,
                    isSelected: selected == tab,
                    badgeCount: tab == .messages ? badgeCount : 0,
                    actions: actionsProvider(tab),
                    onTap: {
                        // Keyboard dismissal + delay handled by ContextMenuTabItem.handleTap()
                        // Do NOT use withAnimation here — animating selectedTab forces
                        // concurrent UINavigationBar layouts → crash
                        selected = tab
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        // Native Liquid Glass effect (iOS 26+) — no .interactive() to avoid extra selection highlight
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.gray.opacity(0.2)
            .ignoresSafeArea()
        
        VStack {
            Spacer()
            
            HapticTabBar(
                selected: .constant(.home),
                badgeCount: 3,
                actionsProvider: { tab in
                    switch tab {
                    case .home:
                        return [
                            TabAction(title: "Create Post", systemImage: "plus.circle", tint: .blue) {},
                            TabAction(title: "Refresh Feed", systemImage: "arrow.clockwise", tint: .green) {}
                        ]
                    case .messages:
                        return [
                            TabAction(title: "New Chat", systemImage: "square.and.pencil", tint: .blue) {},
                            TabAction(title: "Mesh Status", systemImage: "antenna.radiowaves.left.and.right", tint: .purple) {}
                        ]
                    case .discover:
                        return [
                            TabAction(title: "Scan QR", systemImage: "qrcode.viewfinder", tint: .cyan) {}
                        ]
                    case .account:
                        return [
                            TabAction(title: "Edit Profile", systemImage: "pencil", tint: .pink) {},
                            TabAction(title: "Settings", systemImage: "gearshape.fill", tint: .gray) {}
                        ]
                    }
                }
            )
        }
    }
}
