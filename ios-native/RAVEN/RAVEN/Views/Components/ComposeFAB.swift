import SwiftUI

// MARK: - Compose FAB (Floating Action Button - Liquid Glass)
/// Floating button for creating new posts. Shows on Home tab only.
/// Features scroll-aware scale animation for a natural iOS feel.
struct ComposeFAB: View {
    /// Whether the user is currently scrolling (shrinks FAB slightly)
    let isScrolling: Bool
    /// Action to perform when tapped
    let onTap: () -> Void
    
    var body: some View {
        Button {
            Haptics.light()
            onTap()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .scaleEffect(isScrolling ? 0.92 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isScrolling)
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()
        
        VStack {
            Spacer()
            
            HStack {
                Spacer()
                ComposeFAB(isScrolling: false) {
                    print("Create post tapped")
                }
                .padding(.trailing, 20)
                .padding(.bottom, 100)
            }
        }
    }
}
