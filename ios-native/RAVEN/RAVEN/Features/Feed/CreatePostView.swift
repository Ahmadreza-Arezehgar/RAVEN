import SwiftUI

// MARK: - Post Visibility Enum
enum PostVisibility: String, CaseIterable {
    case publicPost = "Public"
    case friendsOnly = "Friends"
    
    var icon: String {
        switch self {
        case .publicPost: return "globe"
        case .friendsOnly: return "person.2"
        }
    }
    
    var description: String {
        switch self {
        case .publicPost: return "Visible to everyone nearby"
        case .friendsOnly: return "Visible to friends only"
        }
    }
    
    var apiValue: String {
        switch self {
        case .publicPost: return "public"
        case .friendsOnly: return "friends"
        }
    }
}


// MARK: - Selected Media Types (Mixed Photo + Video)
enum SelectedMedia {
    case image(UIImage)
    case video(url: URL, thumbnail: UIImage)
}

struct PostMediaItem: Identifiable {
    let id = UUID()
    let media: SelectedMedia
    
    var thumbnail: UIImage {
        switch media {
        case .image(let img): return img
        case .video(_, let thumb): return thumb
        }
    }
    
    var isVideo: Bool {
        if case .video = media { return true }
        return false
    }
}

// MARK: - Compose Post View (Twitter-style, Liquid Glass)
struct CreatePostView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var content = ""
    @State private var visibility: PostVisibility = .publicPost
    @State private var isSubmitting = false
    @State private var selectedMedia: [PostMediaItem] = []  // Mixed photo + video (max 4)
    @State private var showMediaPicker = false
    @State private var showError = false
    @State private var errorMessage = ""
    
    // Voice recording
    @State private var audioRecorder: AudioRecorderService?
    @State private var showVoiceSheet = false
    @State private var hasVoiceRecording = false
    @State private var voiceFileURL: URL?
    @State private var voiceDuration: TimeInterval = 0
    @State private var voiceWaveform: [Float] = []
    @State private var showPaywall = false
    @State private var showUpgradeAlert = false
    @State private var upgradeAlertMessage = ""
    
    private let networkService = NetworkService.shared
    private let maxCharacters = 500
    private var maxMedia: Int { PremiumLimits.maxMediaPerPost }  // Free: 4, RAVEN+: 10
    
    var characterCount: Int {
        content.count
    }
    
    /// Post is valid if it has text OR image OR voice (and within character limit)
    var isValid: Bool {
        let hasContent = !content.trimmingCharacters(in: .whitespaces).isEmpty
        let hasPostMediaItems = !selectedMedia.isEmpty
        let hasVoice = hasVoiceRecording
        return (hasContent || hasPostMediaItems || hasVoice) && characterCount <= maxCharacters
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // Background - subtle gradient for glass effect
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color(.systemGray6).opacity(0.5)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .onTapGesture { hideKeyboard() }
            
            VStack(spacing: 0) {
                // MARK: - Compact Header Bar
                headerBar
                
                // MARK: - Content Area
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Text Input Card (Liquid Glass)
                        textInputCard
                        
                        // Selected Media Preview (Peek stacked style)
                        if !selectedMedia.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Media (\(selectedMedia.count)/\(maxMedia))")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    if selectedMedia.count < maxMedia {
                                        Button {
                                            Haptics.light()
                                            showMediaPicker = true
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus")
                                                Text("Add")
                                            }
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.accentColor)
                                        }
                                    } else if !PremiumLimits.isPremium {
                                        Button {
                                            Haptics.warning()
                                            upgradeAlertMessage = "You've reached the \(maxMedia)-media limit! Upgrade to RAVEN+ to add up to 10 photos & videos per post 🚀"
                                            showUpgradeAlert = true
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "crown.fill")
                                                Text("More")
                                            }
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.orange)
                                        }
                                    }
                                    
                                    // Clear all button
                                    Button {
                                        Haptics.light()
                                        withAnimation(.spring(response: 0.25)) {
                                            selectedMedia.removeAll()
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                // Peek Preview (stacked cards)
                                PeekMediaPreview(media: selectedMedia)
                                    .frame(height: 220)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                                    )
                            )
                            .transition(.scale.combined(with: .opacity))
                        }
                        
                        // Visibility Picker (Glass Segmented)
                        visibilityPicker
                        
                        // Voice Recording Preview
                        if hasVoiceRecording {
                            voicePreviewCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 100) // Space for attach bar
                }
                .onTapGesture { hideKeyboard() }
                
                Spacer(minLength: 0)
            }
            
            // MARK: - Bottom Attach Bar (Floating Glass)
            VStack {
                Spacer()
                attachBar
            }
        }
        .sheet(isPresented: $showMediaPicker) {
            MultiMediaPicker(selectedMedia: $selectedMedia, maxCount: maxMedia)
        }
        .sheet(isPresented: $showVoiceSheet) {
            if let recorder = audioRecorder {
                VoiceRecordingSheet(
                    recorder: recorder,
                    onDone: {
                        if case .recorded(let url, let dur, let wf) = recorder.state {
                            voiceFileURL = url
                            voiceDuration = dur
                            voiceWaveform = wf
                            hasVoiceRecording = true
                            // Voice note can now coexist with media — no clearing
                        }
                        showVoiceSheet = false
                    },
                    onCancel: {
                        showVoiceSheet = false
                    }
                )
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        // RAVEN+ upsell alert with upgrade button
        .alert("Unlock More with RAVEN+", isPresented: $showUpgradeAlert) {
            Button("Upgrade Now ✨") {
                showPaywall = true
            }
            Button("Maybe Later", role: .cancel) {}
        } message: {
            Text(upgradeAlertMessage)
        }
        // RAVEN+ upsell: show paywall when voice recording hits free-tier limit
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowPaywall"))) { _ in
            Haptics.warning()
            showPaywall = true
        }
        .sheet(isPresented: $showPaywall) {
            RavenPlusPaywallView()
        }
    }
    
    // MARK: - Compact Header Bar
    private var headerBar: some View {
        HStack {
            // Cancel Button
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
            }
            
            Spacer()
            
            Text("New Post")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)
            
            Spacer()
            
            // Post Button - Clear active/disabled states
            Button {
                Task {
                    await submitPost()
                }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 20, height: 20)
                    } else {
                        Text("Post")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundColor(isValid ? .white : .secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Group {
                        if isValid {
                            // Active: Filled glass with accent
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        } else {
                            // Disabled: Outline only
                            Color.clear
                        }
                    }
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            isValid ? Color.clear : Color.secondary.opacity(0.3),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: isValid ? Color.accentColor.opacity(0.3) : .clear,
                    radius: 8, y: 4
                )
            }
            .disabled(!isValid || isSubmitting)
            .animation(.easeInOut(duration: 0.15), value: isValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }
    
    // MARK: - Text Input Card
    private var textInputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Label
            Text("What's on your mind?")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            
            // Text Editor with dynamic height
            ZStack(alignment: .topLeading) {
                TextEditor(text: $content)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 220)
                    .padding(12)
                
                // Placeholder
                if content.isEmpty {
                    Text("Share your thoughts...")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
            
            // Character Count - inside card, bottom-right
            HStack {
                Spacer()
                Text("\(characterCount)/\(maxCharacters)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(
                        characterCount > 450
                            ? (characterCount > maxCharacters ? .red : .orange)
                            : .secondary
                    )
                    .animation(.easeInOut(duration: 0.2), value: characterCount > 450)
            }
        }
    }
    
    // MARK: - Media Preview Grid (Multi-Media)
    private var mediaPreviewGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Media (\(selectedMedia.count)/\(maxMedia))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if selectedMedia.count < maxMedia {
                    Button {
                        Haptics.light()
                        showMediaPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Add")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.accentColor)
                    }
                } else if !PremiumLimits.isPremium {
                    Button {
                        Haptics.warning()
                        upgradeAlertMessage = "You've reached the \(maxMedia)-media limit! Upgrade to RAVEN+ to add up to 10 photos & videos per post 🚀"
                        showUpgradeAlert = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "crown.fill")
                            Text("More")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.orange)
                    }
                }
            }
            
            // Grid of selected media
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ForEach(Array(selectedMedia.enumerated()), id: \.element.id) { index, item in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: item.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                            .overlay {
                                if item.isVideo {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .shadow(color: .black.opacity(0.4), radius: 4)
                                }
                            }
                        
                        // Remove button
                        Button {
                            Haptics.light()
                            withAnimation(.spring(response: 0.25)) {
                                selectedMedia.remove(at: index)
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .shadow(color: .black.opacity(0.2), radius: 3)
                        }
                        .padding(6)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
        .transition(.scale.combined(with: .opacity))
    }
    
    // MARK: - Visibility Picker (Glass Segmented)
    private var visibilityPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visibility")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack(spacing: 0) {
                ForEach(PostVisibility.allCases, id: \.self) { option in
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            visibility = option
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.icon)
                                .font(.system(size: 14, weight: .medium))
                            
                            Text(option.rawValue)
                                .font(.system(size: 14, weight: visibility == option ? .semibold : .medium))
                        }
                        .foregroundColor(visibility == option ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            visibility == option
                                ? AnyView(
                                    LinearGradient(
                                        colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                : AnyView(Color.clear)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
        }
    }
    
    // MARK: - Voice Preview Card
    private var voicePreviewCard: some View {
        HStack(spacing: 12) {
            // Mic icon
            Image(systemName: "mic.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
                .frame(width: 40, height: 40)
                .background(Color.orange.opacity(0.12))
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Recording")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text(formatVoiceDuration(voiceDuration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Re-record button
            Button {
                Haptics.light()
                showVoiceSheet = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            
            // Remove button
            Button {
                Haptics.light()
                withAnimation(.spring(response: 0.25)) {
                    hasVoiceRecording = false
                    voiceFileURL = nil
                    voiceDuration = 0
                    voiceWaveform = []
                    audioRecorder?.deleteRecording()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
                )
        )
        .transition(.scale.combined(with: .opacity))
    }
    
    private func formatVoiceDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    // MARK: - Bottom Attach Bar (Floating Glass)
    private var attachBar: some View {
        HStack(spacing: 16) {
             // Add Photo/Video Button
            Button {
                Haptics.light()
                // Upsell: free user at max media → show RAVEN+ paywall
                if selectedMedia.count >= maxMedia && !PremiumLimits.isPremium {
                    upgradeAlertMessage = "You've reached the \(maxMedia)-media limit! Upgrade to RAVEN+ to add up to 10 photos & videos per post 🚀"
                    showUpgradeAlert = true
                    return
                }
                showMediaPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 16, weight: .medium))
                    Text("Media")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                )
            }
            // Media + Voice can now coexist — no mutual exclusion
            
            // Add Voice Button
            Button {
                Haptics.light()
                if audioRecorder == nil {
                    audioRecorder = AudioRecorderService()
                }
                showVoiceSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .medium))
                    Text("Voice")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(hasVoiceRecording ? .white : .orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(hasVoiceRecording ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.regularMaterial))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.orange.opacity(0.3), lineWidth: hasVoiceRecording ? 0 : 0.5)
                )
            }
            // Media + Voice can now coexist — no mutual exclusion
            
            Spacer()
            
            // Character Progress Ring
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 3)
                    .frame(width: 32, height: 32)
                
                Circle()
                    .trim(from: 0, to: min(1, CGFloat(characterCount) / CGFloat(maxCharacters)))
                    .stroke(
                        characterCount > maxCharacters
                            ? Color.red
                            : (characterCount > 450 ? Color.orange : Color.accentColor),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 32, height: 32)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: characterCount)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: -4)
    }
    
    // MARK: - Submit Post
    private func submitPost() async {
        guard isValid else { return }
        
        isSubmitting = true
        Haptics.light()
        
        // Get current user info
        let currentUser = AuthService.shared.currentUser
        let authorId = currentUser?.id ?? ""
        let authorUsername = currentUser?.username ?? "Unknown"
        let authorAvatar = currentUser?.avatarPath
        
        // Generate client-side post ID and request tracing ID
        let clientPostId = UUID().uuidString
        let clientRequestId = UUID().uuidString
        #if DEBUG
        print("🆔 [Post] client_request_id=\(clientRequestId) clientPostId=\(clientPostId)")
        #endif
        
        // Check network status for mesh fallback
        let isOnline = NetworkMonitor.shared.isOnline && NetworkMonitor.shared.serverReachable
        let hasMedia = !selectedMedia.isEmpty || hasVoiceRecording
        let textContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // MESH BROADCAST: Offline + Text-Only → Use Mesh
        if !isOnline && !hasMedia && !textContent.isEmpty {
            await submitViaMesh(
                clientPostId: clientPostId,
                content: textContent,
                authorId: authorId,
                authorUsername: authorUsername,
                authorAvatar: authorAvatar
            )
            return
        }
        
        // MESH BLOCKED: Offline + Media/Voice → Show Error
        if !isOnline && hasMedia {
            errorMessage = "Media and voice posts require internet. Text-only posts can be sent via mesh when offline."
            showError = true
            Haptics.error()
            isSubmitting = false
            return
        }
        
        // ONLINE: Correct flow — upload ALL media FIRST, then create post on server,
        // then insert to UI only after server confirms success.
        do {
            // Step 1: Upload ALL selected media (images + videos) in parallel
            var uploadedMediaPayloads: [PostMediaPayload] = []
            if !selectedMedia.isEmpty {
                #if DEBUG
                print("📤 [\(clientRequestId.prefix(8))] Uploading \(selectedMedia.count) media items in parallel...")
                #endif
                uploadedMediaPayloads = try await withThrowingTaskGroup(of: (Int, PostMediaPayload).self) { group in
                    for (index, item) in selectedMedia.enumerated() {
                        group.addTask { [self] in
                            switch item.media {
                            case .image(let image):
                                #if DEBUG
                                print("📤 [\(clientRequestId.prefix(8))] Uploading image \(index + 1)/\(self.selectedMedia.count)...")
                                #endif
                                let url = try await self.uploadImage(image)
                                #if DEBUG
                                print("✅ [\(clientRequestId.prefix(8))] Image \(index + 1) uploaded: \(url)")
                                #endif
                                return (index, PostMediaPayload(url: url, mediaType: "image", thumbnailUrl: nil))
                                
                            case .video(let videoURL, let thumbnail):
                                #if DEBUG
                                print("📤 [\(clientRequestId.prefix(8))] Uploading video \(index + 1)/\(self.selectedMedia.count)...")
                                #endif
                                let result = try await self.uploadVideo(videoURL: videoURL, thumbnail: thumbnail)
                                #if DEBUG
                                print("✅ [\(clientRequestId.prefix(8))] Video \(index + 1) uploaded: \(result.videoUrl)")
                                #endif
                                return (index, PostMediaPayload(url: result.videoUrl, mediaType: "video", thumbnailUrl: result.thumbnailUrl))
                            }
                        }
                    }
                    var results = [(Int, PostMediaPayload)]()
                    for try await result in group {
                        results.append(result)
                    }
                    // Sort by original index to preserve media order
                    return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
                }
            }
            
            // Legacy backward compat: first image URL
            let firstImageUrl = uploadedMediaPayloads.first(where: { $0.mediaType == "image" })?.url
                ?? uploadedMediaPayloads.first?.thumbnailUrl
            
            // Step 2: Upload voice if present
            var uploadedVoiceUrl: String?
            var uploadedVoiceDuration: Int?
            var uploadedWaveform: [Float]?
            
            if hasVoiceRecording, let fileURL = voiceFileURL {
                #if DEBUG
                print("🎤 [\(clientRequestId.prefix(8))] Uploading voice recording...")
                #endif
                let result = try await VoiceUploadService.upload(fileURL: fileURL)
                uploadedVoiceUrl = result.voiceUrl
                uploadedVoiceDuration = Int(voiceDuration)
                uploadedWaveform = voiceWaveform
                #if DEBUG
                print("✅ [\(clientRequestId.prefix(8))] Voice uploaded: \(result.voiceUrl)")
                #endif
            }
            
            // Step 3: Create post on server (media already uploaded)
            let deviceLocation = await FeedStore.shared.currentLocation
            let body = CreatePostBody(
                content: textContent,
                visibility: visibility.apiValue,
                imageUrl: firstImageUrl,
                imageUrls: uploadedMediaPayloads.isEmpty ? nil : uploadedMediaPayloads.filter({ $0.mediaType == "image" }).map(\.url),
                mediaItems: uploadedMediaPayloads.isEmpty ? nil : uploadedMediaPayloads,
                latitude: deviceLocation?.coordinate.latitude,
                longitude: deviceLocation?.coordinate.longitude,
                voiceUrl: uploadedVoiceUrl,
                voiceDuration: uploadedVoiceDuration,
                waveform: uploadedWaveform,
                clientRequestId: clientRequestId
            )
            
            #if DEBUG
            print("📝 [\(clientRequestId.prefix(8))] Creating post with visibility: '\(body.visibility)', mediaItems count: \(body.mediaItems?.count ?? 0), hasVoice: \(body.voiceUrl != nil)")
            #endif
            
            let newPost: Post = try await networkService.post(
                path: "/api/posts/create",
                body: body
            )
            
            #if DEBUG
            print("✅ [\(clientRequestId.prefix(8))] Post created on server: id=\(newPost.id), visibility=\(newPost.visibility ?? "nil")")
            #endif
            
            // Step 4: Server confirmed — NOW insert to UI (post-success optimistic insert)
            await FeedStore.shared.insertPostOptimistically(newPost)
            
            // Also save to DB cache
            let feedType: FeedType = (visibility == .friendsOnly) ? .friends : .local
            Task.detached {
                try? await PostRepository.shared.upsert(newPost, feedType: feedType)
            }
            
            #if DEBUG
            print("✅ [\(clientRequestId.prefix(8))] Post visible in feed: \(newPost.id)")
            #endif
            
            Haptics.success()
            dismiss()
            
        } catch let apiError as APIError {
            #if DEBUG
            print("❌ [\(clientRequestId.prefix(8))] Post creation failed (API): \(apiError)")
            #endif
            
            // Surface the actual error details for decoding issues
            if case .decodingError(let decodingError) = apiError {
                let detail: String
                switch decodingError {
                case let DecodingError.typeMismatch(type, context):
                    detail = "Type mismatch for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
                case let DecodingError.keyNotFound(key, _):
                    detail = "Missing key: '\(key.stringValue)'"
                case let DecodingError.valueNotFound(type, context):
                    detail = "Null value for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
                case let DecodingError.dataCorrupted(context):
                    detail = "Data corrupted at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
                default:
                    detail = decodingError.localizedDescription
                }
                errorMessage = "Post saved on server but response parsing failed: \(detail)"
            } else {
                errorMessage = "Failed to create post: \(apiError.localizedDescription)"
            }
            showError = true
            Haptics.error()
        } catch {
            #if DEBUG
            print("❌ [\(clientRequestId.prefix(8))] Post creation failed: \(error)")
            #endif
            errorMessage = "Failed to create post: \(error.localizedDescription)"
            showError = true
            Haptics.error()
        }
        
        isSubmitting = false
    }
    
    // MARK: - Submit via Mesh (Offline Text-Only)
    private func submitViaMesh(
        clientPostId: String,
        content: String,
        authorId: String,
        authorUsername: String,
        authorAvatar: String?
    ) async {
        // Create post object for mesh broadcast
        let post = Post(
            id: clientPostId,
            authorId: authorId,
            authorUsername: authorUsername,
            authorAvatar: authorAvatar,
            content: content,
            imageUrl: nil,
            timestamp: Date(),
            editedAt: nil,
            likes: 0,
            comments: 0,
            reposts: 0,
            viewCount: 0,
            isLocal: true,
            isLiked: false,
            isReposted: false,
            visibility: visibility.apiValue,
            distanceM: nil,
            postType: "text",
            roomId: nil,
            source: .nearby
        )
        
        // Save to local DB first (with mesh status)
        do {
            try await PostRepository.shared.upsertMeshPost(post, meshStatus: .queuedMesh)
            #if DEBUG
            print("📡 [MeshPost] Saved mesh draft: \(clientPostId.prefix(8))...")
            #endif
        } catch {
            errorMessage = "Failed to save post locally"
            showError = true
            Haptics.error()
            isSubmitting = false
            return
        }
        
        // Insert into FeedStore for immediate visibility
        let draft = LocalPostDraft(
            clientPostId: clientPostId,
            authorId: authorId,
            authorUsername: authorUsername,
            authorAvatar: authorAvatar,
            content: content,
            imageUrl: nil,
            imageUrls: nil,  // Mesh posts are text-only
            visibility: visibility.apiValue,
            latitude: nil,
            longitude: nil,
            status: .posted,
            timestamp: Date(),
            initialSend: "mesh"
        )
        await FeedStore.shared.insertDraft(draft)
        
        // Broadcast via mesh
        let success = await MeshPostService.shared.broadcast(post: post)
        
        if success {
            #if DEBUG
            print("📡 [MeshPost] Post broadcast via mesh successfully")
            #endif
            Haptics.success()
            dismiss()
        } else {
            // Still saved locally, will sync later
            #if DEBUG
            print("⚠️ [MeshPost] Mesh broadcast failed, but post saved locally")
            #endif
            Haptics.light()
            dismiss()
        }
        
        isSubmitting = false
    }
    
    // MARK: - Upload Image
    private func uploadImage(_ image: UIImage) async throws -> String {
        // Resize + compress on background thread to avoid UI freeze
        let data: Data = try await Task.detached(priority: .userInitiated) {
            var img = image
            
            // Resize to max dimension — Free: 2048px, RAVEN+: 8192px
            let maxDimension: CGFloat = PremiumLimits.maxImageDimension
            if img.size.width > maxDimension || img.size.height > maxDimension {
                let scale = min(maxDimension / img.size.width, maxDimension / img.size.height)
                let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                img = renderer.image { _ in
                    img.draw(in: CGRect(origin: .zero, size: newSize))
                }
            }
            
            // Compress — Free: 0.75, RAVEN+: 1.0 (lossless)
            let quality = PremiumLimits.imageCompressionQuality
            guard let d = img.jpegData(compressionQuality: quality) else {
                throw NSError(domain: "CreatePost", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
            }
            return d
        }.value
        
        #if DEBUG
        print("📸 Image prepared: \(data.count) bytes (\(data.count / 1024) KB)")
        #endif
        
        // Use NetworkService for built-in timeout (120s) and retry (2 retries w/ backoff)
        let result: ImageUploadResponse = try await networkService.uploadMultipart(
            path: "/api/uploads/image",
            fileData: data,
            fileName: "post_image.jpg",
            mimeType: "image/jpeg"
        )
        
        return result.imageUrl
    }
    
    // MARK: - Upload Video (Compress + Upload)
    private func uploadVideo(videoURL: URL, thumbnail: UIImage) async throws -> VideoUploadResult {
        // 1. Compress video — 720p for free, 1080p for RAVEN+
        let compressedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed_\(UUID().uuidString).mp4")
        
        let preset = PremiumLimits.isPremium ? AVAssetExportPreset1920x1080 : AVAssetExportPreset1280x720
        let asset = AVURLAsset(url: videoURL)
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(domain: "CreatePost", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create video export session"])
        }
        
        exportSession.outputURL = compressedURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: exportSession.error ?? NSError(domain: "CreatePost", code: 3, userInfo: [NSLocalizedDescriptionKey: "Video compression failed"]))
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: NSError(domain: "CreatePost", code: 3, userInfo: [NSLocalizedDescriptionKey: "Video compression failed"]))
                }
            }
        }
        
        // Check file size limits
        let attrs = try FileManager.default.attributesOfItem(atPath: compressedURL.path)
        let fileSize = attrs[.size] as? Int ?? 0
        let maxBytes = PremiumLimits.maxFileUploadBytes
        
        if fileSize > maxBytes {
            try? FileManager.default.removeItem(at: compressedURL)
            let maxMB = maxBytes / (1024 * 1024)
            if !PremiumLimits.isPremium {
                // Upsell: free user's video exceeds limit
                await MainActor.run {
                    upgradeAlertMessage = "Your video is too high-quality for the free tier (\(fileSize / (1024 * 1024))MB, max \(maxMB)MB). Upgrade to RAVEN+ for up to 2GB uploads! 🎬"
                    showUpgradeAlert = true
                }
            }
            throw NSError(domain: "CreatePost", code: 4, userInfo: [NSLocalizedDescriptionKey: "Video too large (max \(maxMB)MB)"])
        }
        
        #if DEBUG
        print("🎬 Video compressed: \(fileSize) bytes (\(fileSize / (1024 * 1024)) MB)")
        #endif
        
        // 2. Upload compressed video — stream from disk to avoid OOM for large files
        defer { try? FileManager.default.removeItem(at: compressedURL) }
        
        // Upload video file using streaming multipart (never load entire file into RAM)
        let videoResult = try await uploadVideoStreaming(fileURL: compressedURL)
        
        // 3. Upload thumbnail image
        let thumbData = thumbnail.jpegData(compressionQuality: 0.8) ?? Data()
        let thumbResult: ImageUploadResponse = try await networkService.uploadMultipart(
            path: "/api/uploads/image",
            fileData: thumbData,
            fileName: "post_video_thumb.jpg",
            mimeType: "image/jpeg"
        )
        
        // Clean up source video
        try? FileManager.default.removeItem(at: videoURL)
        
        return VideoUploadResult(
            videoUrl: videoResult.fileUrl,
            thumbnailUrl: thumbResult.imageUrl
        )
    }
    
    // MARK: - Streaming Video Upload (prevents OOM for large files)
    
    /// Uploads a video file by streaming it to a multipart temp file in 512KB chunks,
    /// then using URLSession.upload(fromFile:). This avoids loading the entire file into RAM.
    private func uploadVideoStreaming(fileURL: URL) async throws -> FileUploadResponse {
        let boundary = UUID().uuidString
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: tempURL)
        defer {
            writeHandle.closeFile()
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        // Write multipart header
        var header = Data()
        header.append("--\(boundary)\r\n".data(using: .utf8)!)
        header.append("Content-Disposition: form-data; name=\"file\"; filename=\"post_video.mp4\"\r\n".data(using: .utf8)!)
        header.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        try writeHandle.write(contentsOf: header)
        
        // Stream source file in 512KB chunks to avoid loading it all into RAM
        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { readHandle.closeFile() }
        while try autoreleasepool(invoking: {
            guard let chunk = try readHandle.read(upToCount: 512 * 1024), !chunk.isEmpty else { return false }
            try writeHandle.write(contentsOf: chunk)
            return true
        }) {}
        
        // Write multipart footer
        var footer = Data()
        footer.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        try writeHandle.write(contentsOf: footer)
        
        // Build request
        guard let url = URL(string: "\(AppConfig.apiBaseURL)/api/uploads/file") else {
            throw NSError(domain: "CreatePost", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // Upload from file — never loads entire video into RAM
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: tempURL)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "CreatePost", code: 6, userInfo: [NSLocalizedDescriptionKey: "Video upload failed: \(errorBody)"])
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FileUploadResponse.self, from: responseData)
    }
}

// MARK: - Request Body
struct PostMediaPayload: Encodable {
    let url: String
    let mediaType: String  // "image" or "video"
    let thumbnailUrl: String?  // Required for videos
    
    enum CodingKeys: String, CodingKey {
        case url
        case mediaType = "media_type"
        case thumbnailUrl = "thumbnail_url"
    }
}

private struct CreatePostBody: Encodable {
    let content: String  // Required by API (send empty string for image-only posts)
    let visibility: String
    let imageUrl: String?  // Legacy single image (backward compat)
    let imageUrls: [String]?  // Legacy multi-image (backward compat)
    let mediaItems: [PostMediaPayload]?  // NEW: Mixed media with type info
    let latitude: Double?  // Device location for feed geohash
    let longitude: Double?  // Device location for feed geohash
    let voiceUrl: String?
    let voiceDuration: Int?
    let waveform: [Float]?
    let clientRequestId: String?  // End-to-end tracing ID
    
    enum CodingKeys: String, CodingKey {
        case content
        case visibility
        case imageUrl = "image_url"
        case imageUrls = "image_urls"
        case mediaItems = "media_items"
        case latitude
        case longitude
        case voiceUrl = "voice_url"
        case voiceDuration = "voice_duration"
        case waveform
        case clientRequestId = "client_request_id"
    }
}

// MARK: - Upload Responses
// Note: No CodingKeys needed — NetworkService's decoder uses .convertFromSnakeCase
// which automatically maps image_url → imageUrl, thumbnail_url → thumbnailUrl
private struct ImageUploadResponse: Decodable {
    let imageUrl: String
    let thumbnailUrl: String?
}

private struct VideoUploadResult {
    let videoUrl: String
    let thumbnailUrl: String
}

// MARK: - Media Picker (PHPicker for high-quality images and videos up to 2 min)
import PhotosUI
import AVFoundation

struct MediaPicker: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Binding var selectedVideoURL: URL?
    @Environment(\.dismiss) private var dismiss
    
    // Max video duration: 2 minutes
    static var maxVideoDuration: TimeInterval { PremiumLimits.isPremium ? 600 : 120 }
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .any(of: [.images, .videos])
        // Request high quality originals
        config.preferredAssetRepresentationMode = .current
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPicker
        
        init(_ parent: MediaPicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            
            guard let provider = results.first?.itemProvider else { return }
            
            // Handle video
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
                    guard let url = url, error == nil else {
                        #if DEBUG
                        print("❌ Failed to load video: \(error?.localizedDescription ?? "unknown")")
                        #endif
                        return
                    }
                    
                    // Copy to temp location
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "post_video_\(UUID().uuidString).mov"
                    )
                    
                    do {
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        
                        // Check video duration
                        let asset = AVAsset(url: tempURL)
                        Task {
                            let duration = try await asset.load(.duration)
                            let seconds = CMTimeGetSeconds(duration)
                            
                             if seconds > MediaPicker.maxVideoDuration {
                                 #if DEBUG
                                 print("⚠️ Video too long: \(seconds)s, max: \(MediaPicker.maxVideoDuration)s")
                                 #endif
                                 try? FileManager.default.removeItem(at: tempURL)
                                 // Upsell: free user's video exceeds duration limit
                                 if !PremiumLimits.isPremium {
                                     await MainActor.run {
                                         NotificationCenter.default.post(name: NSNotification.Name("ShowPaywall"), object: nil)
                                     }
                                 }
                                 return
                             }
                            
                            #if DEBUG
                            print("✅ Video selected: \(seconds)s")
                            #endif
                            await MainActor.run {
                                self?.parent.selectedVideoURL = tempURL
                                self?.parent.selectedImage = nil
                            }
                        }
                    } catch {
                        #if DEBUG
                        print("❌ Failed to copy video: \(error)")
                        #endif
                    }
                }
            }
            // Handle image (high quality)
            else if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] image, error in
                    DispatchQueue.main.async {
                        if let uiImage = image as? UIImage {
                            self?.parent.selectedImage = uiImage
                            self?.parent.selectedVideoURL = nil
                            #if DEBUG
                            print("✅ High-quality image selected")
                            #endif
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Legacy Image Picker (UIKit Bridge - kept for compatibility)
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = false  // Keep original quality
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.videoMaximumDuration = MediaPicker.maxVideoDuration
        picker.videoQuality = .typeHigh  // High quality
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Prefer original for better quality
            if let original = info[.originalImage] as? UIImage {
                parent.image = original
            } else if let edited = info[.editedImage] as? UIImage {
                parent.image = edited
            }
            parent.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Multi-Media Picker (PHPicker for mixed images + videos)
struct MultiMediaPicker: UIViewControllerRepresentable {
    @Binding var selectedMedia: [PostMediaItem]
    let maxCount: Int
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        // Allow selecting remaining slots
        let remainingSlots = max(1, maxCount - selectedMedia.count)
        config.selectionLimit = remainingSlots
        config.filter = .any(of: [.images, .videos])  // Mixed media
        config.preferredAssetRepresentationMode = .current
        
        #if DEBUG
        print("📷 MultiMediaPicker: maxCount=\(maxCount), current=\(selectedMedia.count), limit=\(remainingSlots)")
        #endif
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MultiMediaPicker
        
        init(_ parent: MultiMediaPicker) {
            self.parent = parent
        }
        
        // Thread-safe buffer for loaded media items
        private class MediaBuffer {
            private var _items: [PostMediaItem?]
            private let lock = NSLock()
            
            init(count: Int) {
                _items = Array(repeating: nil, count: count)
            }
            
            func set(item: PostMediaItem?, at index: Int) {
                lock.lock()
                _items[index] = item
                lock.unlock()
            }
            
            var items: [PostMediaItem?] {
                lock.lock()
                defer { lock.unlock() }
                return _items
            }
        }
        
        /// Downsample image at file URL using ImageIO (memory-efficient).
        private static func downsampledImage(at url: URL, maxDimension: CGFloat) -> UIImage? {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
            
            let downsampleOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
            ]
            
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }
        
        /// Generate a thumbnail from a video URL using AVAssetImageGenerator.
        private static func generateVideoThumbnail(from url: URL) -> UIImage? {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            
            do {
                let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
                return UIImage(cgImage: cgImage)
            } catch {
                #if DEBUG
                print("⚠️ Failed to generate video thumbnail: \(error)")
                #endif
                return nil
            }
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // ⚠️ Do NOT dismiss yet — load media FIRST, then dismiss.
            
            #if DEBUG
            print("📷 PHPicker returned \(results.count) results")
            #endif
            
            // Limit to remaining slots
            let remaining = max(0, parent.maxCount - parent.selectedMedia.count)
            let limited = Array(results.prefix(remaining))
            
            guard !limited.isEmpty else {
                #if DEBUG
                print("⚠️ No media to load (already at max or cancelled)")
                #endif
                self.parent.dismiss()
                return
            }
            
            #if DEBUG
            print("📷 Loading \(limited.count) media items (remaining slots: \(remaining))")
            #endif
            
            let buffer = MediaBuffer(count: limited.count)
            let group = DispatchGroup()
            
            for (i, result) in limited.enumerated() {
                group.enter()
                let provider = result.itemProvider
                
                // Check for video first
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                        defer { group.leave() }
                        guard let url = url, error == nil else {
                            #if DEBUG
                            print("❌ Error loading video \(i): \(error?.localizedDescription ?? "unknown")")
                            #endif
                            return
                        }
                        
                        // Copy to temp directory (PHPicker file is ephemeral)
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("post_video_\(UUID().uuidString).\(url.pathExtension)")
                        do {
                            try FileManager.default.copyItem(at: url, to: tempURL)
                        } catch {
                            #if DEBUG
                            print("❌ Failed to copy video \(i): \(error)")
                            #endif
                            return
                        }
                        
                        // Generate thumbnail
                        guard let thumbnail = Self.generateVideoThumbnail(from: tempURL) else {
                            #if DEBUG
                            print("⚠️ Video \(i) thumbnail generation failed, skipped")
                            #endif
                            try? FileManager.default.removeItem(at: tempURL)
                            return
                        }
                        
                        let item = PostMediaItem(media: .video(url: tempURL, thumbnail: thumbnail))
                        buffer.set(item: item, at: i)
                        #if DEBUG
                        print("✅ Video \(i) loaded + thumbnail generated")
                        #endif
                    }
                }
                // Handle image
                else if provider.hasItemConformingToTypeIdentifier("public.image") {
                    provider.loadFileRepresentation(forTypeIdentifier: "public.image") { url, error in
                        defer { group.leave() }
                        if let error = error {
                            #if DEBUG
                            print("❌ Error loading image \(i): \(error.localizedDescription)")
                            #endif
                            return
                        }
                        guard let url = url else {
                            #if DEBUG
                            print("❌ No URL for image \(i)")
                            #endif
                            return
                        }
                        // Downsample based on premium tier
                        if let downsampled = Self.downsampledImage(at: url, maxDimension: PremiumLimits.maxImageDimension) {
                            let item = PostMediaItem(media: .image(downsampled))
                            buffer.set(item: item, at: i)
                            #if DEBUG
                            print("✅ Image \(i) loaded + downsampled")
                            #endif
                        } else {
                            #if DEBUG
                            print("⚠️ Image \(i) downsampling failed, skipped")
                            #endif
                        }
                    }
                } else {
                    // Fallback: load as UIImage (rare path)
                    provider.loadObject(ofClass: UIImage.self) { obj, error in
                        defer { group.leave() }
                        if let uiImage = obj as? UIImage {
                            let item = PostMediaItem(media: .image(uiImage))
                            buffer.set(item: item, at: i)
                        }
                    }
                }
            }
            
            // When all media loaded, update binding FIRST, then dismiss
            group.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                let ordered = buffer.items.compactMap { $0 }
                #if DEBUG
                print("📷 Buffer complete: \(ordered.count) media items loaded successfully")
                #endif
                let toAdd = ordered.prefix(self.parent.maxCount - self.parent.selectedMedia.count)
                self.parent.selectedMedia.append(contentsOf: toAdd)
                #if DEBUG
                print("✅ All media added! Total selectedMedia: \(self.parent.selectedMedia.count)")
                #endif
                
                // NOW dismiss — binding is updated, SwiftUI state is committed
                self.parent.dismiss()
            }
        }
    }
}


#Preview {
    CreatePostView()
}
