// RAVEN - Chat Details View
// Converted from Flutter chat_details_page.dart

import SwiftUI

struct ChatDetailsView: View {
    let recipientId: String
    let recipientName: String
    
    @State private var user: User?
    @State private var selectedTab = 0
    @State private var isMuted = false
    @State private var isBlocked = false
    @State private var sharedMedia: [String] = []
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Profile Header
                profileHeader
                
                // Quick Actions
                quickActions
                
                // Shared Content Tabs
                sharedContentSection
            }
            .padding()
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadUser()
        }
    }
    
    // MARK: - Profile Header
    var profileHeader: some View {
        VStack(spacing: 16) {
            AvatarView(url: user?.avatarUrl, name: recipientName, size: 100)
            
            VStack(spacing: 4) {
                Text(user?.displayName ?? recipientName)
                    .font(.title2.bold())
                
                Text("@\(user?.username ?? "")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let bio = user?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.top)
    }
    
    // MARK: - Quick Actions
    var quickActions: some View {
        HStack(spacing: 16) {
            actionButton(icon: "phone.fill", label: "Call") {
                // Call
            }
            
            actionButton(icon: "video.fill", label: "Video") {
                // Video call
            }
            
            actionButton(icon: "magnifyingglass", label: "Search") {
                // Search in chat
            }
            
            actionButton(icon: isMuted ? "bell.slash.fill" : "bell.fill", label: isMuted ? "Unmute" : "Mute") {
                isMuted.toggle()
            }
        }
        .padding()
        .glassBackground()
    }
    
    @ViewBuilder
    func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.ravenPrimary.opacity(0.2))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(.ravenPrimary)
                }
                
                Text(label)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
        }
    }
    
    // MARK: - Shared Content
    var sharedContentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Tab Selector
            HStack(spacing: 0) {
                tabButton("Photos", index: 0)
                tabButton("Files", index: 1)
                tabButton("Voice", index: 2)
                tabButton("Links", index: 3)
            }
            .glassBackground(cornerRadius: 10)
            
            // Content
            switch selectedTab {
            case 0:
                photosGrid
            case 1:
                filesSection
            case 2:
                voiceSection
            default:
                linksSection
            }
        }
    }
    
    @ViewBuilder
    func tabButton(_ title: String, index: Int) -> some View {
        Button {
            withAnimation { selectedTab = index }
        } label: {
            Text(title)
                .font(.subheadline)
                .fontWeight(selectedTab == index ? .semibold : .regular)
                .foregroundColor(selectedTab == index ? .primary : .secondary)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    selectedTab == index ? Color.ravenPrimary.opacity(0.2) : Color.clear
                )
        }
    }
    
    var photosGrid: some View {
        Group {
            if sharedMedia.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle.angled", description: Text("Photos shared in this chat will appear here"))
                    .frame(height: 200)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(sharedMedia, id: \.self) { url in
                        AsyncImage(url: URL(string: url)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 100)
                                .clipped()
                        } placeholder: {
                            Rectangle()
                                .fill(Color(UIColor.systemGray5))
                                .frame(height: 100)
                        }
                    }
                }
            }
        }
    }
    
    var filesSection: some View {
        ContentUnavailableView("No Files", systemImage: "doc", description: Text("Files shared in this chat will appear here"))
            .frame(height: 200)
    }
    
    var voiceSection: some View {
        ContentUnavailableView("No Voice Messages", systemImage: "waveform", description: Text("Voice messages shared in this chat will appear here"))
            .frame(height: 200)
    }
    
    var linksSection: some View {
        ContentUnavailableView("No Links", systemImage: "link", description: Text("Links shared in this chat will appear here"))
            .frame(height: 200)
    }
    
    // MARK: - Load User
    func loadUser() {
        Task {
            user = try? await APIService.shared.getUserById(recipientId)
        }
    }
}

// MARK: - UI Components
struct AvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 40
    
    var body: some View {
        Group {
            if let urlString = url, let imageUrl = URL(string: urlString) {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        initialsView
                    case .empty:
                        ProgressView()
                    @unknown default:
                        initialsView
                    }
                }
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
    
    var initialsView: some View {
        ZStack {
            LinearGradient(
                colors: [.ravenPrimary, .ravenSecondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Text(name.initials)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

#Preview {
    NavigationStack {
        ChatDetailsView(recipientId: "123", recipientName: "John Doe")
    }
    .preferredColorScheme(.dark)
}
