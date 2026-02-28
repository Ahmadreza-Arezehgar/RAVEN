import SwiftUI

// MARK: - Animated Empty Feed State View
/// Shows a skeleton on a park bench with newspaper blowing in the wind
/// Used when there are no posts in Local or Friends feed
struct AnimatedEmptyFeedView: View {
    let title: String
    let subtitle: String
    let feedType: FeedTab
    var onCreatePost: (() -> Void)? = nil
    
    // Animation states for fallback (when Lottie not available)
    @State private var windOffset: CGFloat = 0
    @State private var newspaperRotation: Double = 0
    @State private var showPulse = false
    @State private var showCreatePostSheet = false
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    init(feedType: FeedTab, onCreatePost: (() -> Void)? = nil) {
        self.feedType = feedType
        self.onCreatePost = onCreatePost
        
        switch feedType {
        case .local:
            self.title = "No local posts nearby"
            self.subtitle = "Be the first one to post something in your area!"
        case .friends:
            self.title = "No posts from friends"
            self.subtitle = "Add friends or wait for them to share something."
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // MARK: - Animation Area
            ZStack {
                // Try Lottie first, fallback to SwiftUI animation
                if lottieAvailable {
                    LottieView(name: "empty_feed_skeleton", loopMode: .loop)
                        .frame(height: 240)
                } else {
                    // Fallback: SwiftUI animated illustration
                    fallbackAnimation
                        .frame(height: 240)
                }
            }
            
            // MARK: - Text Content
            VStack(spacing: 8) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            // MARK: - Action Button
            Button {
                Haptics.medium()
                #if DEBUG
                print("📝 [EmptyFeed] Create Post tapped")
                #endif
                if let onCreatePost = onCreatePost {
                    onCreatePost()
                } else {
                    showCreatePostSheet = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Create Post")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
                .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
            }
            .padding(.top, 8)
        }
        .padding(.top, 40)
        .sheet(isPresented: $showCreatePostSheet) {
            CreatePostView()
        }
        .onAppear {
            if !reduceMotion {
                startFallbackAnimations()
            }
        }
    }
    
    // MARK: - Check if Lottie file exists
    private var lottieAvailable: Bool {
        Bundle.main.path(forResource: "empty_feed_skeleton", ofType: "json") != nil
    }
    
    // MARK: - Fallback SwiftUI Animation
    private var fallbackAnimation: some View {
        ZStack {
            // Park bench
            benchShape
                .offset(y: 60)
            
            // Skeleton figure
            skeletonFigure
                .offset(y: 20)
            
            // Newspaper on head
            newspaperShape
                .offset(y: -40)
                .rotationEffect(.degrees(newspaperRotation))
                .offset(x: windOffset * 0.3)
            
            // Wind lines
            windLines
        }
    }
    
    private var benchShape: some View {
        ZStack {
            // Bench seat
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: [.brown.opacity(0.6), .brown.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 140, height: 12)
            
            // Bench legs
            HStack(spacing: 100) {
                Rectangle()
                    .fill(.brown.opacity(0.5))
                    .frame(width: 8, height: 30)
                Rectangle()
                    .fill(.brown.opacity(0.5))
                    .frame(width: 8, height: 30)
            }
            .offset(y: 20)
            
            // Bench back
            RoundedRectangle(cornerRadius: 3)
                .fill(.brown.opacity(0.5))
                .frame(width: 130, height: 8)
                .offset(y: -30)
        }
    }
    
    private var skeletonFigure: some View {
        VStack(spacing: 0) {
            // Skull
            Circle()
                .fill(.gray.opacity(0.3))
                .frame(width: 40, height: 40)
                .overlay(
                    // Eye sockets
                    HStack(spacing: 10) {
                        Circle().fill(.black.opacity(0.5)).frame(width: 8, height: 8)
                        Circle().fill(.black.opacity(0.5)).frame(width: 8, height: 8)
                    }
                    .offset(y: -2)
                )
            
            // Body
            RoundedRectangle(cornerRadius: 8)
                .fill(.gray.opacity(0.25))
                .frame(width: 30, height: 50)
            
            // Legs
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.gray.opacity(0.2))
                    .frame(width: 12, height: 35)
                RoundedRectangle(cornerRadius: 4)
                    .fill(.gray.opacity(0.2))
                    .frame(width: 12, height: 35)
            }
        }
    }
    
    private var newspaperShape: some View {
        ZStack {
            // Newspaper pages
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.9))
                .frame(width: 50, height: 35)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            
            // Text lines
            VStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.gray.opacity(0.3))
                        .frame(width: 40, height: 2)
                }
            }
            
            // Flapping corner
            Path { path in
                path.move(to: CGPoint(x: 20, y: -17))
                path.addLine(to: CGPoint(x: 30, y: -12 + windOffset * 0.1))
                path.addLine(to: CGPoint(x: 25, y: -5))
            }
            .fill(.white.opacity(0.7))
        }
    }
    
    private var windLines: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(.blue.opacity(0.15))
                    .frame(width: 20 + CGFloat(index * 10), height: 2)
                    .offset(x: windOffset + CGFloat(index * 5))
            }
        }
        .offset(x: -80, y: -50)
    }
    
    // MARK: - Start Animations
    private func startFallbackAnimations() {
        // Wind animation
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            windOffset = 15
        }
        
        // Newspaper flutter
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            newspaperRotation = 5
        }
    }
}

// MARK: - Preview
#Preview("Local Feed Empty") {
    AnimatedEmptyFeedView(feedType: .local)
}

#Preview("Friends Feed Empty") {
    AnimatedEmptyFeedView(feedType: .friends)
}
