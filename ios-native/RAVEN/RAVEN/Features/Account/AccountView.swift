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
    
    @State private var showQR = false   // redesign — identity hero → My QR Code

    // Expanded header height
    private let expandedHeight: CGFloat = 260
    private let collapsedHeight: CGFloat = 84
    private let collapseDistance: CGFloat = 160

    // Top safe-area inset read straight from the key window — robust even
    // though the shell's TabPager ignores the container safe area (a SwiftUI
    // GeometryReader would report 0 inside that ignoring context).
    private var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.safeAreaInsets.top) ?? 47
    }

    // 0 = expanded, 1 = collapsed
    private var progress: CGFloat {
        // scrollY starts at ~0 and goes NEGATIVE when scrolling up
        // We want progress 0->1 as user scrolls up
        let p = min(1, max(0, -scrollY / collapseDistance))
        return p
    }

    var body: some View {
        ZStack {
            // Adaptive backdrop: deep base + a soft violet aura at the top so
            // the identity hero reads as the focal point (RAVEN's look — dark,
            // futuristic, faint violet glow — while still adapting to light).
            SettingsBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    RavenIdentityHero(
                        user: authService.currentUser,
                        onCameraTap: {
                            Haptics.light()
                            showImagePicker = true
                        },
                        onQRTap: {
                            Haptics.light()
                            showQR = true
                        },
                        onEditTap: {
                            Haptics.light()
                            showEditProfile = true
                        }
                    )

                    // Settings sections, now INLINE (was a gear → modal sheet —
                    // an awkward extra hop on a near-empty profile screen).
                    AccountSettingsContent()
                }
                .padding(.horizontal, 16)
                // The shell's TabPager ignores the top safe area, so pad the
                // hero clear of the status bar / Dynamic Island ourselves.
                .padding(.top, safeTop + 10)
                .padding(.bottom, 130) // clear the floating tab bar
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
        .sheet(isPresented: $showQR) {
            MyQRCodeView()
        }
    }
    
    private func uploadAvatar() async {
        guard let image = selectedImage else { return }

        isUploadingAvatar = true
        defer { isUploadingAvatar = false }

        do {
            // Step 1: hardened multipart upload (retries on transient errors —
            // the ad-hoc URLSession.shared call this used to do had no retry,
            // so a single radio hiccup on older iOS would surface as a hard
            // failure with no recovery).
            let imageUrl = try await AttachmentService.shared.uploadAvatarImage(image)

            // Step 2: tell the server this URL is the new avatar.
            struct ProfilePictureBody: Encodable { let imageUrl: String }
            let _: Empty = try await NetworkService.shared.post(
                path: "/api/users/profile-picture",
                body: ProfilePictureBody(imageUrl: imageUrl)
            )

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


// MARK: - Public Avatar for reuse in other views
struct ProfileAvatarView: View {
    let avatarPath: String?
    let initials: String
    let size: CGFloat

    var body: some View {
        GlassAvatar(name: initials, path: avatarPath, size: size, showGlow: false)
    }
}

// MARK: - Settings Redesign — ink + cyan aura (brand, not purple glow)
private struct SettingsBackdrop: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            DS.inkAura
                .opacity(0.9)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Settings Redesign — Identity / Security hero
private struct RavenIdentityHero: View {
    let user: User?
    var onCameraTap: () -> Void
    var onQRTap: () -> Void
    var onEditTap: () -> Void

    private var fingerprint: String { DeviceIdentityService.shared.fingerprint ?? "—" }

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle()
                        .fill(DS.cyan.opacity(0.28))
                        .frame(width: 108, height: 108)
                        .blur(radius: 22)
                    GlassAvatar(name: user?.displayName ?? "?", path: user?.avatarPath, size: 92, showGlow: false)
                        .overlay(
                            Circle().stroke(DS.signalGradient, lineWidth: 2.5)
                        )
                }
                Button(action: onCameraTap) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.ink)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(DS.signalGradient))
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)

            VStack(spacing: 4) {
                Text("RAVEN")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2.5)
                    .foregroundStyle(DS.cyanDeep)
                HStack(spacing: 6) {
                    Text(user?.displayName ?? "You")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if user?.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(DS.cyan)
                    }
                }
                Text("Messaging Beyond Connectivity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let uname = user?.username, !uname.isEmpty {
                Text("@\(uname)")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            Button(action: onQRTap) {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode").font(.system(size: 13, weight: .semibold))
                    Text(fingerprint).font(DS.mono(.subheadline))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).opacity(0.5)
                }
                .foregroundStyle(DS.cyanDeep)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(DS.cyan.opacity(0.12)))
                .overlay(Capsule().stroke(DS.cyan.opacity(0.28), lineWidth: 1))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                SecurityPill(icon: "lock.shield.fill", text: "End-to-end", tint: DS.accentSuccess)
                SecurityPill(icon: "key.fill", text: "No account", tint: DS.cyanDeep)
            }
            .padding(.top, 2)

            HStack(spacing: 10) {
                HeroActionButton(title: "My QR Code", icon: "qrcode", action: onQRTap)
                HeroActionButton(title: "Edit Profile", icon: "pencil", action: onEditTap)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusHero, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusHero, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [DS.cyan.opacity(0.55), DS.teal.opacity(0.15), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: DS.cyan.opacity(0.14), radius: 24, x: 0, y: 10)
    }
}

private struct SecurityPill: View {
    let icon: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

private struct HeroActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
