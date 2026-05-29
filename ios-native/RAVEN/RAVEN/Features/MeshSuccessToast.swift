import SwiftUI

// MARK: - Success Toast View (Reusable Mesh Feature Feedback)
/// A beautiful animated toast that confirms an action completed successfully.
/// Used after creating Echo, Club, or Vault items.

struct MeshSuccessToast: View {
    let icon: String
    let title: String
    let subtitle: String
    let gradient: [Color]
    @Binding var isPresented: Bool
    
    @State private var appear = false
    
    var body: some View {
        if isPresented {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(
                        LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .symbolEffect(.bounce, value: appear)
                
                Text(title)
                    .font(.headline)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: 280)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(gradient.first?.opacity(0.3) ?? .clear, lineWidth: 1)
            )
            .shadow(color: gradient.first?.opacity(0.2) ?? .clear, radius: 20, y: 8)
            .scaleEffect(appear ? 1 : 0.6)
            .opacity(appear ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    appear = true
                }
                // Auto-dismiss after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        appear = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isPresented = false
                    }
                }
            }
        }
    }
}
