import SwiftUI

/// Reusable shimmer/skeleton loading animation
struct ShimmerView: View {
    @State private var phase: CGFloat = -1
    
    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [
                    Color.gray.opacity(0.1),
                    Color.gray.opacity(0.2),
                    Color.gray.opacity(0.1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .offset(x: phase * geometry.size.width)
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }
}

/// Skeleton placeholder for account item
struct AccountSkeletonView: View {
    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(Color.gray.opacity(0.15))
                .frame(width: 56, height: 56)
                .overlay(ShimmerView().clipShape(Circle()))
            
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15))
                .frame(width: 50, height: 12)
                .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 4)))
        }
    }
}

/// Skeleton placeholder for post card
struct PostSkeletonView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            Circle()
                .fill(Color.gray.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay(ShimmerView().clipShape(Circle()))
            
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 80, height: 14)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 60, height: 12)
                    
                    Spacer()
                }
                .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 4)))
                
                // Content lines
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 14)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 200, height: 14)
                }
                .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 4)))
                
                // Action bar
                HStack(spacing: 40) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 30, height: 12)
                    }
                }
                .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 4)))
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#Preview("Shimmer") {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            AccountSkeletonView()
            AccountSkeletonView()
            AccountSkeletonView()
        }
        
        Divider()
        
        PostSkeletonView()
        PostSkeletonView()
    }
    .padding()
}
