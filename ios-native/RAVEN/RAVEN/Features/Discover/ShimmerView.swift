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
            
            RoundedRectangle(cornerRadius: 4, style: .continuous)
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
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 80, height: 14)
                    
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 60, height: 12)
                    
                    Spacer()
                }
                .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 4)))
                
                // Content lines
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 14)
                    
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 200, height: 14)
                }
                .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 4)))
                
                // Action bar
                HStack(spacing: 40) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
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

// MARK: - View Modifiers

/// Overlays a moving highlight on top of a view to make a static skeleton
/// look like it's actually loading. Use on `.fill(...)` placeholders that
/// would otherwise sit perfectly still.
struct ShimmeringModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(
            ShimmerView()
                .mask(content)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmeringModifier())
    }
}

/// Stagger an item's first appearance by its index in a list — small fade +
/// slide so the row by row layout feels alive instead of popping in all at
/// once. Cap at 12 entries so a long list doesn't take seconds to settle.
struct StaggeredAppearModifier: ViewModifier {
    let index: Int
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 8)
            .onAppear {
                let delay = Double(min(index, 12)) * 0.04
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(delay)) {
                    visible = true
                }
            }
    }
}

extension View {
    func staggeredAppear(index: Int) -> some View {
        modifier(StaggeredAppearModifier(index: index))
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
