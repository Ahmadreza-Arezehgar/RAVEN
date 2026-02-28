import SwiftUI

// MARK: - Story Preview View
/// Shows captured photo with Liquid Glass controls and audience picker
/// Apple Liquid Glass Design: Capsule-based, floating UI, no solid backgrounds
struct StoryPreviewView: View {
    let image: UIImage
    let onPost: () -> Void
    let onRetake: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAudience: StoryAudience = .friends
    @State private var isSingleView: Bool = false
    @State private var isPosting = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Full-screen image
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .ignoresSafeArea()
                
                // Very subtle vignette (not dark)
                RadialGradient(
                    colors: [.clear, .black.opacity(0.2)],
                    center: .center,
                    startRadius: 300,
                    endRadius: 600
                )
                .ignoresSafeArea()
                
                // UI Controls - Floating above image
                VStack(spacing: 0) {
                    // MARK: - Top Bar (Liquid Glass)
                    topBar
                        .padding(.top, geometry.safeAreaInsets.top + 8)
                    
                    Spacer()
                    
                    // MARK: - Bottom Controls (Floating, no dark background)
                    bottomControls
                        .padding(.bottom, max(geometry.safeAreaInsets.bottom, 20) + 8)
                }
                .padding(.horizontal, 20)
            }
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 16) {
            // Back Button - Glass Circle
            Button {
                Haptics.light()
                onRetake()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                    )
            }
            
            Spacer()
            
            // Title Capsule - Liquid Glass
            Text("New Story")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
            
            Spacer()
            
            // Placeholder for balance
            Color.clear.frame(width: 36, height: 36)
        }
    }
    
    // MARK: - Bottom Controls (Floating - NO dark gradient)
    private var bottomControls: some View {
        VStack(spacing: 12) {
            // Audience Selector - Liquid Glass Capsule Switch
            audienceSelector
            
            // Single-View Toggle - Subtle
            singleViewToggle
            
            // Share Button - Floating Capsule
            shareButton
        }
    }
    
    // MARK: - Audience Selector (Apple Capsule Switch - FIXED)
    private var audienceSelector: some View {
        HStack(spacing: 0) {
            ForEach(StoryAudience.allCases, id: \.self) { audience in
                Button {
                    Haptics.medium()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedAudience = audience
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: audience.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(audience.title)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(selectedAudience == audience ? .white : .white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Group {
                            if selectedAudience == audience {
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: audience == .friends ?
                                                        [.purple.opacity(0.4), .pink.opacity(0.3)] :
                                                        [.green.opacity(0.4), .teal.opacity(0.3)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                                    )
                                    .shadow(color: (audience == .friends ? Color.purple : Color.green).opacity(0.25), radius: 8, y: 3)
                            }
                        }
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial.opacity(0.5), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    
    // MARK: - Single-View Toggle (Subtle, minimal)
    private var singleViewToggle: some View {
        Button {
            Haptics.medium()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isSingleView.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                // Icon
                Image(systemName: isSingleView ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSingleView ? .orange : .white.opacity(0.5))
                    .frame(width: 20, height: 20)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(isSingleView ? "Single View" : "Normal View")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    
                    Text(isSingleView ? "Disappears after viewing" : "Can be viewed multiple times")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                
                Spacer()
                
                // Glass Toggle
                ZStack {
                    Capsule()
                        .fill(isSingleView ? .orange.opacity(0.7) : .white.opacity(0.12))
                        .frame(width: 42, height: 24)
                        .overlay(
                            Capsule()
                                .strokeBorder(isSingleView ? .orange.opacity(0.4) : .white.opacity(0.1), lineWidth: 0.5)
                        )
                    
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .offset(x: isSingleView ? 9 : -9)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial.opacity(0.5), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSingleView ? .orange.opacity(0.2) : .white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }

    
    // MARK: - Share Button (Floating Gradient Capsule)
    private var shareButton: some View {
        Button {
            postStory()
        } label: {
            HStack(spacing: 10) {
                if isPosting {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Share Story")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                ZStack {
                    // Blur layer underneath for glass effect
                    Capsule()
                        .fill(.ultraThinMaterial)
                    
                    // Subtle gradient overlay
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: selectedAudience == .friends ?
                                    [.purple.opacity(0.7), .pink.opacity(0.6)] :
                                    [.green.opacity(0.7), .teal.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .opacity(isPosting ? 0.5 : 1.0)
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: (selectedAudience == .friends ? Color.purple : Color.green).opacity(0.3), radius: 16, y: 6)
        }
        .disabled(isPosting)
        .buttonStyle(ScaleButtonStyle(scale: 0.97))
        .animation(.spring(response: 0.3), value: isPosting)
    }
    
    // MARK: - Post Story
    private func postStory() {
        guard !isPosting else { return }
        
        Haptics.medium()
        isPosting = true
        
        Task {
            do {
                // 1. Upload image to CDN
                guard let imageData = image.jpegData(compressionQuality: PremiumLimits.imageCompressionQuality) else {
                    throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
                }
                
                let mediaUrl = try await StoryService.shared.uploadStoryMedia(data: imageData)
                
                // 2. Create story with audience and single-view setting
                try await StoryService.shared.createStory(
                    mediaUrl: mediaUrl,
                    mediaType: "image",
                    audience: selectedAudience.rawValue,
                    isSingleView: isSingleView
                )
                
                // ✅ Notify StoryRingView to refresh
                NotificationCenter.default.post(name: .storyCreated, object: nil)
                #if DEBUG
                print("📸 [StoryPreviewView] Posted storyCreated notification (single-view: \(isSingleView))")
                #endif
                
                Haptics.success()
                onPost()
                
            } catch {
                #if DEBUG
                print("❌ Story post failed: \(error)")
                #endif
                Haptics.error()
                isPosting = false
            }
        }
    }
}

// MARK: - Scale Button Style
private struct ScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.98
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Story Audience
enum StoryAudience: String, CaseIterable {
    case friends = "friends"
    case local = "local"
    
    var title: String {
        switch self {
        case .friends: return "Friends"
        case .local: return "Local"
        }
    }
    
    var icon: String {
        switch self {
        case .friends: return "person.2.fill"
        case .local: return "location.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .friends: return .purple
        case .local: return .green
        }
    }
}

#Preview {
    StoryPreviewView(
        image: UIImage(systemName: "photo")!,
        onPost: {},
        onRetake: {}
    )
}
