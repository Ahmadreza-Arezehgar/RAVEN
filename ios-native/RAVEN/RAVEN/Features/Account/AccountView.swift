import SwiftUI

// MARK: - Account View
struct AccountView: View {

    @State private var authService = AuthService.shared
    @State private var feedStateManager = FeedStateManager.shared
    @State private var scrollY: CGFloat = 0  // Direct scroll position
    @State private var lastScrollY: CGFloat = 0  // For direction detection
    
    // Chrome hide/show settings
    private let threshold: CGFloat = 14
    private let debounce: TimeInterval = 0.12
    
    // Avatar photo picker states
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?
    @State private var showAvatarPreview = false
    @State private var isUploadingAvatar = false
    @State private var showEditProfile = false  // Edit Profile sheet

    // Expanded header height
    private let expandedHeight: CGFloat = 260
    private let collapsedHeight: CGFloat = 84
    private let collapseDistance: CGFloat = 160

    // 0 = expanded, 1 = collapsed
    private var progress: CGFloat {
        // scrollY starts at ~0 and goes NEGATIVE when scrolling up
        // We want progress 0->1 as user scrolls up
        let p = min(1, max(0, -scrollY / collapseDistance))
        return p
    }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top

            ZStack(alignment: .top) {

                // Background - adaptive for light/dark mode
                Color(.systemBackground)
                    .ignoresSafeArea()

                // ✅ Scroll Content
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {

                        // Offset tracker at TOP of scroll content
                        GeometryReader { proxy in
                            let offsetY = proxy.frame(in: .named("accountScroll")).minY
                            Color.clear
                                .onChange(of: offsetY) { _, newValue in
                                    scrollY = newValue
                                    handleScrollDirection(offset: newValue)
                                }
                                .onAppear {
                                    scrollY = offsetY
                                }
                        }
                        .frame(height: 1)

                        // Spacer for header
                        Color.clear
                            .frame(height: expandedHeight + safeTop + 12)

                        // Content
                        AccountSettingsContent()
                            .padding(.horizontal, 16)
                            .padding(.bottom, 120)
                    }
                }
                .coordinateSpace(name: "accountScroll")

                // ✅ Pinned Header overlay - allows touches to pass through to content
                ProfileHeaderPinned(
                    user: authService.currentUser,
                    safeTop: safeTop,
                    expandedHeight: expandedHeight,
                    collapsedHeight: collapsedHeight,
                    progress: progress,
                    onCameraTap: {
                        Haptics.light()
                        showImagePicker = true
                    },
                    onEditTap: {
                        Haptics.light()
                        showEditProfile = true
                    }
                )
                // Note: Hit testing enabled for camera button and edit button
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showImagePicker, onDismiss: {
            if selectedImage != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showAvatarPreview = true
                }
            }
        }) {
            ImagePicker(image: $selectedImage)
        }
        .sheet(isPresented: $showAvatarPreview) {
            AvatarPreviewSheet(
                image: selectedImage,
                isUploading: $isUploadingAvatar,
                onConfirm: {
                    Task { await uploadAvatar() }
                },
                onCancel: {
                    selectedImage = nil
                    showAvatarPreview = false
                },
                onChangePhoto: {
                    showAvatarPreview = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showImagePicker = true
                    }
                }
            )
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileView()
        }
    }
    
    private func uploadAvatar() async {
        guard let image = selectedImage else { return }
        
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        
        do {
            // Offload heavy image processing to background thread to avoid OOM/freeze
            let imageData: Data = try await Task.detached(priority: .userInitiated) {
                let safeImage = image.downscaled(maxDimension: 1024)
                guard let data = safeImage.jpegData(compressionQuality: 0.8) else {
                    throw URLError(.cannotDecodeContentData)
                }
                return data
            }.value
            
            let baseURL = AppConfig.apiBaseURL
            
            // Step 1: Upload image to /api/uploads/image
            let boundary = UUID().uuidString
            var body = Data()
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n")
            body.appendString("Content-Type: image/jpeg\r\n\r\n")
            body.append(imageData)
            body.appendString("\r\n--\(boundary)--\r\n")
            
            guard let uploadURL = AppConfig.apiURL(path: "/api/uploads/image") else { return }
            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "POST"
            uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            
            if let (token, _) = await KeychainService.shared.getToken() {
                uploadRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            let (uploadData, uploadResponse) = try await URLSession.shared.upload(for: uploadRequest, from: body)
            
            guard let httpResponse = uploadResponse as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                #if DEBUG
                print("❌ Image upload failed with status: \((uploadResponse as? HTTPURLResponse)?.statusCode ?? -1)")
                #endif
                Haptics.error()
                return
            }
            
            // Parse response to get image URL
            guard let uploadResult = try? JSONDecoder().decode(ImageUploadResponse.self, from: uploadData) else {
                #if DEBUG
                print("❌ Failed to parse upload response")
                #endif
                Haptics.error()
                return
            }
            
            #if DEBUG
            print("✅ Image uploaded: \(uploadResult.imageUrl)")
            #endif
            
            // Step 2: Update profile picture at /api/users/profile-picture
            guard let profileURL = AppConfig.apiURL(path: "/api/users/profile-picture") else { return }
            var profileRequest = URLRequest(url: profileURL)
            profileRequest.httpMethod = "POST"
            profileRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            if let (token, _) = await KeychainService.shared.getToken() {
                profileRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            let profileBody = ["image_url": uploadResult.imageUrl]
            profileRequest.httpBody = try JSONEncoder().encode(profileBody)
            
            let (_, profileResponse) = try await URLSession.shared.data(for: profileRequest)
            
            guard let profileHttpResponse = profileResponse as? HTTPURLResponse,
                  (200...299).contains(profileHttpResponse.statusCode) else {
                #if DEBUG
                print("❌ Profile picture update failed with status: \((profileResponse as? HTTPURLResponse)?.statusCode ?? -1)")
                #endif
                Haptics.error()
                return
            }
            
            // Refresh user profile
            try await authService.fetchCurrentUser()
            
            await MainActor.run {
                Haptics.success()
                selectedImage = nil
                showAvatarPreview = false
            }
            
            #if DEBUG
            print("✅ Profile picture updated successfully")
            #endif
        } catch {
            #if DEBUG
            print("❌ Avatar upload failed: \(error)")
            #endif
            await MainActor.run { Haptics.error() }
        }
    }
    
    // Response model for image upload
    private struct ImageUploadResponse: Codable {
        let imageUrl: String
        let filename: String
        
        enum CodingKeys: String, CodingKey {
            case imageUrl = "image_url"
            case filename
        }
    }
    
    // MARK: - Handle Scroll Direction (Hide/Show Bottom Bar)
    private func handleScrollDirection(offset: CGFloat) {
        let delta = offset - lastScrollY
        lastScrollY = offset
        
        // Near top: always show chrome
        if offset > -10 {
            if feedStateManager.isChromeHidden {
                feedStateManager.isChromeHidden = false
            }
            return
        }
        
        // Debounce
        let now = Date()
        guard now.timeIntervalSince(feedStateManager.lastChromeChange) > debounce else { return }
        
        // Scroll up (content moves up, finger swipes up) → hide chrome
        if delta < -threshold {
            if !feedStateManager.isChromeHidden {
                feedStateManager.lastChromeChange = now
                feedStateManager.isChromeHidden = true
            }
        }
        // Scroll down (content moves down, finger swipes down) → show chrome
        else if delta > threshold {
            if feedStateManager.isChromeHidden {
                feedStateManager.lastChromeChange = now
                feedStateManager.isChromeHidden = false
            }
        }
    }
}


// MARK: - Pinned Header (Liquid Glass + Proper Collapse)
private struct ProfileHeaderPinned: View {

    let user: User?
    let safeTop: CGFloat
    let expandedHeight: CGFloat
    let collapsedHeight: CGFloat
    let progress: CGFloat
    var onCameraTap: (() -> Void)? = nil
    var onEditTap: (() -> Void)? = nil

    // Sizes
    private let expandedAvatar: CGFloat = 110
    private let collapsedAvatar: CGFloat = 44

    private func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        a + (b - a) * progress
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cardW = w - 32

            let headerH = lerp(expandedHeight, collapsedHeight)

            // Avatar positions
            let avatarSize = lerp(expandedAvatar, collapsedAvatar)

            // Expanded: center
            let avatarXExpanded = cardW / 2
            let avatarYExpanded = 38 + expandedAvatar / 2

            // Collapsed: top-left inside card
            let avatarXCollapsed: CGFloat = 22 + collapsedAvatar / 2
            let avatarYCollapsed: CGFloat = collapsedHeight / 2

            let avatarX = lerp(avatarXExpanded, avatarXCollapsed)
            let avatarY = lerp(avatarYExpanded, avatarYCollapsed)

            // Text position: Y moves up, but X stays CENTER always
            let textYExpanded = 38 + expandedAvatar + 18 + 26
            let textYCollapsed = collapsedHeight / 2
            let textY = lerp(textYExpanded, textYCollapsed)
            
            // Text X: ALWAYS centered (no horizontal movement)
            let textX = cardW / 2

            // Glass card - positioned at top, sized exactly to header
            LiquidGlassCard(cornerRadius: 34) {
                ZStack {
                    // Avatar - moves to top-left on collapse
                    GlassAvatar(
                        name: user?.displayName ?? "?",
                        path: user?.avatarPath,
                        size: avatarSize,
                        showGlow: false
                    )
                    .position(x: avatarX, y: avatarY)

                    // Camera button with tap
                    CameraBadge()
                        .opacity(Double(1 - progress * 1.5))
                        .position(
                            x: avatarX + avatarSize * 0.32,
                            y: avatarY + avatarSize * 0.32
                        )
                        .onTapGesture {
                            if progress < 0.5 {
                                onCameraTap?()
                            }
                        }

                    // Name - stays CENTERED horizontally
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Text(user?.displayName ?? "User")
                                .font(.system(size: lerp(22, 17), weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            
                            if user?.isVerified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: lerp(16, 12)))
                                    .foregroundStyle(.blue)
                            }
                            
                            // Checking local SubscriptionService directly for the account tab
                            if user?.isPremium == true || SubscriptionService.shared.isPremium {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: lerp(14, 10)))
                                    .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                            }
                        }

                        Text("@\(user?.username ?? "username")")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .opacity(Double(1 - progress))

                        if let createdAt = user?.createdAt {
                            Text("Joined \(formatJoinedDate(createdAt))")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary.opacity(0.65))
                                .opacity(Double(1 - progress))
                        }
                    }
                    .frame(width: cardW - 80)
                    .multilineTextAlignment(.center)
                    .position(x: textX, y: textY)
                    
                    Button {
                        onEditTap?()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.9))
                            .frame(width: 36, height: 36)
                            .background(.primary.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(Double(progress))
                    .position(x: cardW - 30, y: collapsedHeight / 2)
                    .allowsHitTesting(progress > 0.5)
                }
            }
            .frame(width: cardW, height: headerH)
            .padding(.horizontal, 16)
            .padding(.top, safeTop + 10)
        }
        // ✅ Key fix: frame to actual header height so it doesn't cover content
        .frame(height: expandedHeight + safeTop + 30)
        .ignoresSafeArea(edges: .top)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.88), value: progress)
    }

    private func formatJoinedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }
}


// MARK: - Avatar Preview Sheet
private struct AvatarPreviewSheet: View {
    let image: UIImage?
    @Binding var isUploading: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onChangePhoto: () -> Void
    
    // Image positioning state
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    
    private let cropSize: CGFloat = 280
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                
                // Instruction text
                Text("Pinch to zoom, drag to position")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                // Cropping area
                if let image = image {
                    ZStack {
                        // The movable/zoomable image
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: cropSize * scale, height: cropSize * scale)
                            .offset(offset)
                            .gesture(
                                SimultaneousGesture(
                                    DragGesture()
                                        .onChanged { gesture in
                                            offset = CGSize(
                                                width: lastOffset.width + gesture.translation.width,
                                                height: lastOffset.height + gesture.translation.height
                                            )
                                        }
                                        .onEnded { _ in
                                            lastOffset = offset
                                        },
                                    MagnificationGesture()
                                        .onChanged { value in
                                            let newScale = lastScale * value
                                            scale = min(max(newScale, 1.0), 4.0) // Limit zoom 1x-4x
                                        }
                                        .onEnded { _ in
                                            lastScale = scale
                                        }
                                )
                            )
                            .simultaneousGesture(
                                TapGesture(count: 2)
                                    .onEnded {
                                        withAnimation(.spring(response: 0.3)) {
                                            scale = 1.0
                                            lastScale = 1.0
                                            offset = .zero
                                            lastOffset = .zero
                                        }
                                    }
                            )
                    }
                    .frame(width: cropSize, height: cropSize)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.3), lineWidth: 3)
                    )
                    .overlay(
                        // Grid overlay for positioning help
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            .padding(cropSize / 4)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 25, x: 0, y: 12)
                }
                
                Text("Double-tap to reset")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.7))
                
                Spacer()
                
                VStack(spacing: 14) {
                    Button {
                        onConfirm()
                    } label: {
                        HStack(spacing: 8) {
                            if isUploading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(isUploading ? "Uploading..." : "Use This Photo")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(isUploading)
                    
                    Button {
                        onChangePhoto()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("Choose Different Photo")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(isUploading)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("Profile Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .foregroundStyle(.secondary)
                        .disabled(isUploading)
                }
            }
        }
    }
}


// MARK: - Liquid Glass Card (local version for header)
private struct LiquidGlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.6)
                )
                .shadow(color: .primary.opacity(0.12), radius: 22, x: 0, y: 12)

            // subtle sheen
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.06),
                            Color.clear,
                            Color.primary.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.overlay)
                .opacity(0.9)

            content
        }
    }
}


// MARK: - Camera badge
private struct CameraBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.primary.opacity(0.18), lineWidth: 0.6))
            Image(systemName: "camera.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .frame(width: 30, height: 30)
        .shadow(color: .primary.opacity(0.15), radius: 10, x: 0, y: 6)
    }
}

// MARK: - Public Avatar for reuse in other views
struct ProfileAvatarView: View {
    let avatarPath: String?
    let initials: String
    let size: CGFloat

    var body: some View {
        GlassAvatar(name: initials, path: avatarPath, size: size, showGlow: false)
    }
}
