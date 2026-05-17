import SwiftUI
import UIKit

// MARK: - Profile Summary Response
/// Response model for /api/users/{id}/profileSummary endpoint
struct ProfileSummaryResponse: Codable {
    let postsCount: Int
    let friendsCount: Int
    let isFriend: Bool
    let requestStatus: String  // none, pending, accepted
    let isOnline: Bool?
    let lastActiveAt: String?
}
// MARK: - User Preview Card
/// A larger profile preview popup triggered by long-press on avatars
/// Shows: avatar, full name, username, bio, and join date
/// Uses native iOS context menu haptic animation style
struct UserPreviewCard: View {
    let userId: String
    let username: String
    let displayName: String?
    let avatarPath: String?
    let bio: String?
    let createdAt: Date?
    var isVerified: Bool = false
    var isPremium: Bool = false
    var onViewProfile: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    @State private var isAppearing = false
    @State private var dragOffset: CGFloat = 0
    
    // Live stats from API
    @State private var postsCount: Int?
    @State private var friendsCount: Int?
    @State private var requestStatus: String = "none"  // none, pending, accepted
    @State private var isLoadingStats = true
    
    var body: some View {
        VStack(spacing: 16) {
            // Large Avatar
            GlassAvatar(
                name: displayName ?? username,
                path: avatarPath,
                size: 100,
                showGlow: true
            )
            .shadow(color: .blue.opacity(0.2), radius: 12, y: 4)
            
            // Name & Username
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text(displayName ?? username)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                    
                    if isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)
                    }
                    if isPremium {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                    }
                }
                
                Text("@\(username)")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            // Bio (if present)
            if let bio = bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            
            // Stats/Info Row
            HStack(spacing: 24) {
                // Posts count
                VStack(spacing: 2) {
                    if isLoadingStats {
                        Text("–")
                            .font(.system(size: 16, weight: .bold))
                            .redacted(reason: .placeholder)
                    } else {
                        Text("\(postsCount ?? 0)")
                            .font(.system(size: 16, weight: .bold))
                    }
                    Text("Posts")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                
                // Friends count
                VStack(spacing: 2) {
                    if isLoadingStats {
                        Text("–")
                            .font(.system(size: 16, weight: .bold))
                            .redacted(reason: .placeholder)
                    } else {
                        Text("\(friendsCount ?? 0)")
                            .font(.system(size: 16, weight: .bold))
                    }
                    Text("Friends")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            
            // Join date
            if let createdAt = createdAt {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13))
                    Text("Joined \(formatJoinedDate(createdAt))")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            }
            
            // View Profile Button
            Button {
                Haptics.light()
                dismiss()
                onViewProfile?()
            } label: {
                Text("View Profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [.blue, .blue.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 300)
        // Liquid Glass material effect (iOS 15+)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        // Native iOS context menu style animation
        .scaleEffect(isAppearing ? 1.0 : 0.6)
        .opacity(isAppearing ? 1.0 : 0.0)
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation.height * 0.3
                }
                .onEnded { value in
                    if abs(value.translation.height) > 100 {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isAppearing = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            dismiss()
                        }
                    } else {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .onAppear {
            // Native iOS context menu spring animation
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isAppearing = true
            }
            // Fetch live stats
            Task { await fetchProfileSummary() }
        }
    }
    
    // MARK: - Fetch Profile Summary
    private func fetchProfileSummary() async {
        do {
            let summary: ProfileSummaryResponse = try await NetworkService.shared.get(
                path: "/api/users/\(userId)/profileSummary"
            )
            await MainActor.run {
                postsCount = summary.postsCount
                friendsCount = summary.friendsCount
                requestStatus = summary.requestStatus
                isLoadingStats = false
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to fetch profile summary: \(error)")
            #endif
            await MainActor.run {
                isLoadingStats = false
            }
        }
    }
    
    private func formatJoinedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en"
        
        switch languageCode {
        case "fa":
            formatter.calendar = Calendar(identifier: .persian)
            formatter.dateFormat = "yyyy/MM/dd"
        default:
            formatter.dateFormat = "MMM d, yyyy"
        }
        
        return formatter.string(from: date)
    }
}

// MARK: - User Preview Popup Modifier
/// A view modifier that presents a UserPreviewCard on long-press with native haptic touch feel
struct UserPreviewPopupModifier: ViewModifier {
    let userId: String
    let username: String
    let displayName: String?
    let avatarPath: String?
    let bio: String?
    let createdAt: Date?
    var isVerified: Bool = false
    var isPremium: Bool = false
    var onViewProfile: (() -> Void)? = nil
    
    @State private var showPreview = false
    @State private var showFullProfile = false
    
    func body(content: Content) -> some View {
        content
            .onLongPressGesture(minimumDuration: 0.3) {
                // Native iOS medium haptic (like context menu)
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                showPreview = true
            }
            .fullScreenCover(isPresented: $showPreview) {
                ZStack {
                    // Dimmed background with blur - tap to dismiss
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                showPreview = false
                            }
                        }
                    
                    // Preview card
                    UserPreviewCard(
                        userId: userId,
                        username: username,
                        displayName: displayName,
                        avatarPath: avatarPath,
                        bio: bio,
                        createdAt: createdAt,
                        isVerified: isVerified,
                        isPremium: isPremium,
                        onViewProfile: {
                            showPreview = false
                            if let onViewProfile = onViewProfile {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    onViewProfile()
                                }
                            } else {
                                // Default: navigate to full profile
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showFullProfile = true
                                }
                            }
                        }
                    )
                }
                .background(ClearBackgroundView())
            }
            // Default full profile navigation
            .fullScreenCover(isPresented: $showFullProfile) {
                NavigationStack {
                    UserProfileView(userId: userId)
                }
            }
    }
}

// MARK: - Clear Background Helper
struct ClearBackgroundView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - View Extension
extension View {
    /// Adds a long-press gesture that shows a user preview popup with native haptic touch feel
    func userPreviewPopup(
        userId: String,
        username: String,
        displayName: String? = nil,
        avatarPath: String? = nil,
        bio: String? = nil,
        createdAt: Date? = nil,
        isVerified: Bool = false,
        isPremium: Bool = false,
        onViewProfile: (() -> Void)? = nil
    ) -> some View {
        modifier(UserPreviewPopupModifier(
            userId: userId,
            username: username,
            displayName: displayName,
            avatarPath: avatarPath,
            bio: bio,
            createdAt: createdAt,
            isVerified: isVerified,
            isPremium: isPremium,
            onViewProfile: onViewProfile
        ))
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        
        UserPreviewCard(
            userId: "preview-id",
            username: "johndoe",
            displayName: "John Doe",
            avatarPath: nil,
            bio: "iOS Developer • Coffee enthusiast ☕️ • Building cool stuff with SwiftUI",
            createdAt: Date().addingTimeInterval(-86400 * 365)
        )
    }
}
