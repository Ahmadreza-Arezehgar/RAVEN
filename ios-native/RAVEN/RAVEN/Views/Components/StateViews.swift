import SwiftUI

// MARK: - Glass Shimmer Loading View
/// A Liquid Glass styled loading view with shimmer effect
/// Used for loading states in conversations, feeds, etc.
struct GlassShimmerLoadingView: View {
    @State private var shimmerOffset: CGFloat = -200
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<5, id: \.self) { index in
                shimmerRow(delay: Double(index) * 0.1)
            }
        }
        .padding(16)
        .onAppear {
            isAnimating = true
            startShimmer()
        }
        .onDisappear {
            isAnimating = false
        }
    }
    
    private func shimmerRow(delay: Double) -> some View {
        HStack(spacing: 14) {
            // Avatar placeholder
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 50, height: 50)
                .shimmer(offset: shimmerOffset, delay: delay)
            
            VStack(alignment: .leading, spacing: 6) {
                // Name placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(.ultraThinMaterial)
                    .frame(width: 120, height: 14)
                    .shimmer(offset: shimmerOffset, delay: delay)
                
                // Message placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(.ultraThinMaterial)
                    .frame(width: 180, height: 12)
                    .shimmer(offset: shimmerOffset, delay: delay)
            }
            
            Spacer()
            
            // Time placeholder
            RoundedRectangle(cornerRadius: 4)
                .fill(.ultraThinMaterial)
                .frame(width: 40, height: 10)
                .shimmer(offset: shimmerOffset, delay: delay)
        }
        .padding(14)
        .background(.ultraThinMaterial.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
    
    private func startShimmer() {
        guard isAnimating else { return }
        
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            shimmerOffset = 400
        }
    }
}

// MARK: - Shimmer Effect Modifier
extension View {
    func shimmer(offset: CGFloat, delay: Double = 0) -> some View {
        self.overlay(
            LinearGradient(
                colors: [
                    .clear,
                    .white.opacity(0.3),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 100)
            .offset(x: offset)
            .animation(.linear(duration: 1.5).repeatForever(autoreverses: false).delay(delay), value: offset)
        )
        .mask(self)
    }
}

// MARK: - Error State View
/// A Liquid Glass styled error view with retry button
struct ErrorStateView: View {
    let message: String
    let error: Error
    let onRetry: () -> Void
    
    @State private var showDetails = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Error icon with glass background
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 80, height: 80)
                
                Image(systemName: "network.slash")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
            }
            
            // Message capsule
            VStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text(errorDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            
            // Retry button
            Button {
                Haptics.medium()
                onRetry()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
                .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
            }
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var errorDescription: String {
        if (error as NSError).domain == NSURLErrorDomain {
            return "Check your internet connection"
        }
        return "Something went wrong"
    }
}

// MARK: - Previews
#Preview("Shimmer Loading") {
    GlassShimmerLoadingView()
}

#Preview("Error State") {
    ErrorStateView(
        message: "Couldn't load messages",
        error: URLError(.notConnectedToInternet),
        onRetry: {}
    )
}
