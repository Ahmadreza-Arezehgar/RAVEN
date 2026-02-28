import SwiftUI

// MARK: - Floating Action Button
struct FloatingActionButton: View {
    let icon: String
    let action: () -> Void
    var size: CGFloat = 54
    
    var body: some View {
        Button(action: {
            Haptics.medium()
            action()
        }) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial.opacity(0.8))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Floating Actions Overlay
struct FloatingActionsOverlay: View {
    @Binding var selectedTab: AppTab
    @Namespace private var fabNamespace
    
    let onNewPost: () -> Void
    let onNewMessage: () -> Void
    let onNewGroup: () -> Void
    
    // Dock position (near TabBar)
    private let dockBottomPadding: CGFloat = 88
    private let fabBottomPadding: CGFloat = 104
    private let fabHorizontalPadding: CGFloat = 24
    
    var body: some View {
        ZStack {
            // Invisible dock anchor near TabBar
            Color.clear
                .frame(width: 1, height: 1)
                .matchedGeometryEffect(id: "fabDock", in: fabNamespace)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, dockBottomPadding)
            
            // FABs based on selected tab
            switch selectedTab {
            case .home:
                // New Post FAB (right)
                FloatingActionButton(icon: "plus") {
                    onNewPost()
                }
                .matchedGeometryEffect(id: "primaryFAB", in: fabNamespace)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, fabHorizontalPadding)
                .padding(.bottom, fabBottomPadding)
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))
                
            case .messages:
                // New Message FAB (right)
                FloatingActionButton(icon: "square.and.pencil") {
                    onNewMessage()
                }
                .matchedGeometryEffect(id: "primaryFAB", in: fabNamespace)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, fabHorizontalPadding)
                .padding(.bottom, fabBottomPadding)
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))
                
                // New Group FAB (left)
                FloatingActionButton(icon: "person.2.badge.plus") {
                    onNewGroup()
                }
                .matchedGeometryEffect(id: "secondaryFAB", in: fabNamespace)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, fabHorizontalPadding)
                .padding(.bottom, fabBottomPadding)
                .transition(.asymmetric(
                    insertion: .scale.combined(with: .opacity),
                    removal: .scale.combined(with: .opacity)
                ))
                
            case .discover, .account:
                // FAB docks to TabBar (invisible)
                FloatingActionButton(icon: "plus") {}
                    .matchedGeometryEffect(id: "primaryFAB", in: fabNamespace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, dockBottomPadding)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedTab)
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()
        
        FloatingActionsOverlay(
            selectedTab: .constant(.home),
            onNewPost: {},
            onNewMessage: {},
            onNewGroup: {}
        )
    }
}
