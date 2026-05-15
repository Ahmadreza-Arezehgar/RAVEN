import SwiftUI
import AVFoundation

/// Comments Sheet with Liquid Glass design — supports text, voice & image comments
struct CommentsSheetView: View {
    let post: Post
    let feedStore: FeedStore
    
    private var realPostId: String {
        post.id.components(separatedBy: "-loop-")[0]
    }
    
    @State private var comments: [Comment] = []
    @State private var isLoading = true
    @State private var commentText = ""
    @State private var isSubmitting = false
    @State private var replyTarget: Comment? = nil
    @State private var voiceSubmitError: String? = nil
    @Environment(\.dismiss) private var dismiss
    
    // Photo comment
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage? = nil
    
    // Voice comment — recording (state owned here, managed by VoiceRecordingBar)
    @State private var isRecording = false
    @State private var recordedAudioURL: URL? = nil
    @State private var previewDuration: TimeInterval = 0
    @State private var showPaywall = false
    
    private let networkService = NetworkService.shared
    private var maxVoiceDuration: TimeInterval { PremiumLimits.voiceMessageMaxDuration }
    
    /// Whether send button should be enabled
    private var canSend: Bool {
        !commentText.trimmingCharacters(in: .whitespaces).isEmpty
        || selectedImage != nil
        || recordedAudioURL != nil
    }
    
    var body: some View {
        ZStack {
            // Main content
            VStack(spacing: 0) {
                // MARK: - Header (dynamic based on state)
                headerView
                
                // MARK: - Post Preview (Glass Card)
                if !isRecording {
                    postPreviewCard
                        .padding(.horizontal)
                }
                
                // MARK: - Comments List or Empty State
                if isRecording {
                    // Recording Mode: comments faded + locked
                    ZStack {
                        if !comments.isEmpty {
                            commentsList
                                .opacity(0.25)
                                .allowsHitTesting(false)
                                .blur(radius: 2)
                        } else {
                            Spacer()
                        }
                        
                        // Center: animated rings while recording
                        VStack(spacing: DS.space16) {
                            ZStack {
                                ForEach(0..<3, id: \.self) { i in
                                    Circle()
                                        .stroke(Color.accentColor.opacity(0.15 - Double(i) * 0.04), lineWidth: 2)
                                        .frame(width: CGFloat(60 + i * 30), height: CGFloat(60 + i * 30))
                                        .scaleEffect(isRecording ? 1.15 : 0.9)
                                        .animation(
                                            .easeInOut(duration: 1.2)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(i) * 0.2),
                                            value: isRecording
                                        )
                                }
                                
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.accentColor)
                            }
                            
                            Text("Recording...")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    skeletonLoadingView
                } else if comments.isEmpty {
                    emptyCommentsView
                } else {
                    commentsList
                }
                
                // MARK: - Input Area
                if isRecording || recordedAudioURL != nil {
                    VoiceRecordingBar(
                        isRecording: $isRecording,
                        recordedAudioURL: $recordedAudioURL,
                        previewDuration: $previewDuration,
                        maxDuration: maxVoiceDuration,
                        onSend: { url, duration in
                            recordedAudioURL = url
                            previewDuration = duration
                            Task { await submitComment() }
                        },
                        onCancel: { }
                    )
                } else {
                    commentInputBar
                }
            }
        }
        .task {
            await loadComments()
        }
        .alert("Voice Comment Failed", isPresented: Binding(
            get: { voiceSubmitError != nil },
            set: { if !$0 { voiceSubmitError = nil } }
        )) {
            Button("OK", role: .cancel) { voiceSubmitError = nil }
        } message: {
            Text(voiceSubmitError ?? "Unknown error")
        }
        // RAVEN+ upsell: show paywall when voice recording hits free-tier limit
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowPaywall"))) { _ in
            Haptics.warning()
            showPaywall = true
        }
        .sheet(isPresented: $showPaywall) {
            RavenPlusPaywallView()
        }
        // 🚀 Lazy image picker — avoids PhotosPicker XPC freeze on first open
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView { image in
                withAnimation(.spring(response: 0.25)) {
                    selectedImage = image
                }
                showImagePicker = false
            }
        }
    }
    
    // MARK: - Dynamic Header
    
    private var headerView: some View {
        HStack(spacing: DS.space8) {
            if isRecording {
                // Recording mode header
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.red)
                    .symbolEffect(.pulse, isActive: isRecording)
                
                Text("Recording voice comment")
                    .font(.headline)
                    .foregroundColor(.primary)
            } else {
                Text("Comments")
                    .font(.headline)
            }
            
            Spacer()
            
            if !isRecording {
                Text("\(post.comments)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.25), value: isRecording)
    }
    
    // MARK: - Skeleton Loading View
    private var skeletonLoadingView: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { index in
                SkeletonCommentRow(delay: Double(index) * 0.1)
            }
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
    }
    
    // MARK: - Post Preview Card
    private var postPreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AsyncImage(url: URL(string: post.authorAvatar ?? "")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay {
                            Text(String(post.authorUsername.prefix(1)).uppercased())
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                
                Text("@\(post.authorUsername)")
                    .font(.subheadline.weight(.medium))
                
                Spacer()
                
                Text(post.timestamp.timeAgoString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Text(post.content)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(4)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard))
    }
    
    // MARK: - Empty Comments View
    private var emptyCommentsView: some View {
        VStack(spacing: 12) {
            Spacer()
            
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .thin))
                .foregroundColor(.secondary)
            
            Text("No comments yet")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Be the first to share your thoughts!")
                .font(.subheadline)
                .foregroundStyle(.secondary.opacity(0.7))
            
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Comments List
    private var commentsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(comments) { comment in
                    CommentRow(
                        comment: comment,
                        onReply: { target in
                            replyTarget = target
                            Haptics.light()
                        },
                        onVote: { commentId, vote in
                            voteComment(commentId: commentId, vote: vote)
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    
                    if comment.id != comments.last?.id {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 0.5)
                            .padding(.leading, 58)
                    }
                }
            }
            .padding(.top, 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: comments.count)
        }
        .onTapGesture { hideKeyboard() }
    }
    
    // MARK: - Comment Input Bar (normal mode)
    private var commentInputBar: some View {
        VStack(spacing: 0) {
            // Reply indicator
            if let target = replyTarget {
                HStack {
                    Text("Replying to @\(target.authorName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        withAnimation { replyTarget = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, DS.space16)
                .padding(.vertical, DS.space8)
                .background(Color.gray.opacity(0.1))
            }
            
            // Image preview (above composer)
            if let image = selectedImage {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusInner))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                withAnimation(.spring(response: 0.25)) {
                                    selectedImage = nil
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .offset(x: 6, y: -6)
                        }
                    
                    Text("Photo attached")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
                .padding(.horizontal, DS.space16)
                .padding(.top, DS.space8)
                .transition(.scale.combined(with: .opacity))
            }
            
            // Voice preview is now handled by VoiceRecordingBar in the input area
            
            // Main composer row
            HStack(spacing: DS.space8) {
                // Attachment button (photo picker)
                if recordedAudioURL == nil && !isRecording {
                    // 🚀 Simple Button to avoid PhotosPicker XPC freeze on first open
                    Button {
                        Haptics.light()
                        showImagePicker = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                
                // Text field
                TextField(
                    replyTarget != nil ? "Reply..." :
                        (selectedImage != nil ? "Add a caption…" : "Write a comment…"),
                    text: $commentText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.leading, 4)
                
                // Right side: Send or Mic
                if canSend {
                    // Send button
                    Button {
                        Task { await submitComment() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .frame(width: 24, height: 24)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .disabled(isSubmitting)
                    .transition(.scale.combined(with: .opacity))
                } else if recordedAudioURL == nil && selectedImage == nil {
                    // Mic button (tap to start recording)
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.7))
                        .onTapGesture {
                            isRecording = true
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, DS.space12)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: -DS.shadowY)
            .padding(.horizontal, DS.space16)
            .padding(.vertical, DS.space12)
            .padding(.bottom, DS.space8) // Safe area clearance
            .background(Color(.systemBackground).opacity(0.5))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedImage != nil)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: recordedAudioURL != nil)
    }
    
    // MARK: - Load Comments
    private func loadComments() async {
        if let cachedComments = feedStore.getCachedComments(for: realPostId), !cachedComments.isEmpty {
            comments = cachedComments
            let voiceCount = cachedComments.filter { $0.commentType == "voice" }.count
            #if DEBUG
            print("🔵 [VOICE-DEBUG] loadComments: FROM CACHE — total=\(cachedComments.count), voice=\(voiceCount)")
            #endif
            isLoading = false
            return
        }
        
        isLoading = true
        
        do {
            let fetchedComments: [Comment] = try await networkService.get(
                path: "/api/comments/post/\(realPostId)"
            )
            comments = fetchedComments
            feedStore.setCachedComments(fetchedComments, for: realPostId)
            let voiceCount = fetchedComments.filter { $0.commentType == "voice" }.count
            #if DEBUG
            print("🔵 [VOICE-DEBUG] loadComments: FROM SERVER — total=\(fetchedComments.count), voice=\(voiceCount)")
            #endif
            if voiceCount > 0 {
                for c in fetchedComments where c.commentType == "voice" {
                    #if DEBUG
                    print("🔵 [VOICE-DEBUG]   voice comment: id=\(c.id), mediaUrl=\(c.mediaUrl ?? "nil"), duration=\(c.durationSec ?? -1)")
                    #endif
                }
            }
        } catch let decodingError as DecodingError {
            #if DEBUG
            print("❌ [VOICE-DEBUG] DECODE ERROR loading comments:")
            #endif
            switch decodingError {
            case .keyNotFound(let key, let context):
                #if DEBUG
                print("   Key not found: '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue })")
                #endif
            case .typeMismatch(let type, let context):
                #if DEBUG
                print("   Type mismatch: expected \(type) at path: \(context.codingPath.map { $0.stringValue })")
                #endif
            case .valueNotFound(let type, let context):
                #if DEBUG
                print("   Value not found: \(type) at path: \(context.codingPath.map { $0.stringValue })")
                #endif
            case .dataCorrupted(let context):
                #if DEBUG
                print("   Data corrupted: \(context.debugDescription)")
                #endif
            @unknown default:
                #if DEBUG
                print("   Unknown: \(decodingError)")
                #endif
            }
        } catch {
            #if DEBUG
            print("❌ Failed to load comments: \(error)")
            #endif
        }
        
        isLoading = false
    }
    
    // MARK: - Submit Comment
    private func submitComment() async {
        let commentType: String
        var mediaUrlToSend: String? = nil
        var durationSecToSend: Double? = nil
        
        if let audioURL = recordedAudioURL {
            commentType = "voice"
            durationSecToSend = previewDuration
            
            #if DEBUG
            print("")
            print("🔵🔵🔵 [VOICE-DEBUG] ====== SUBMIT VOICE COMMENT START (CommentsSheetView) ======")
            print("🔵 [VOICE-DEBUG] Step 0: recordedAudioURL=\(audioURL.path)")
            print("🔵 [VOICE-DEBUG] Step 0: previewDuration=\(previewDuration)s")
            #endif
            
            // Check file exists on disk
            let fileExists = FileManager.default.fileExists(atPath: audioURL.path)
            let diskSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? -1
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 1: File check — exists=\(fileExists), size=\(diskSize) bytes")
            #endif
            
            if !fileExists {
                #if DEBUG
                print("🔴 [VOICE-DEBUG] Step 1 FAILED: Recording file missing from disk!")
                #endif
                voiceSubmitError = "Recording file not found"
                return
            }
            
            // Step 2: Upload
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 2: Uploading voice...")
            #endif
            do {
                mediaUrlToSend = try await uploadVoice(audioURL)
                #if DEBUG
                print("🔵 [VOICE-DEBUG] Step 2 DONE: Upload succeeded — url=\(mediaUrlToSend ?? "nil")")
                #endif
            } catch {
                #if DEBUG
                print("🔴 [VOICE-DEBUG] Step 2 FAILED: Upload error — \(error)")
                print("🔴 [VOICE-DEBUG]   Error type: \(type(of: error))")
                #endif
                voiceSubmitError = "Voice upload failed: \(error.localizedDescription)"
                Haptics.error()
                return
            }
        } else if let image = selectedImage {
            commentType = "image"
            
            do {
                mediaUrlToSend = try await uploadImage(image)
            } catch {
                #if DEBUG
                print("❌ Image upload failed: \(error)")
                #endif
                Haptics.error()
                isSubmitting = false
                return
            }
        } else {
            commentType = "text"
            guard !commentText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        }
        
        let textToSubmit = commentText.trimmingCharacters(in: .whitespaces)
        let parentId = replyTarget?.id
        isSubmitting = true
        
        if commentType == "voice" {
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 3: Building optimistic comment — type=\(commentType), mediaUrl=\(mediaUrlToSend ?? "nil"), duration=\(durationSecToSend ?? 0), parentId=\(parentId ?? "nil")")
            #endif
        }
        
        // Optimistic UI
        let tempId = UUID().uuidString
        let currentUser = AuthService.shared.currentUser
        let optimisticComment = Comment(
            id: tempId,
            postId: realPostId,
            authorId: currentUser?.id ?? "",
            authorName: currentUser?.displayName ?? currentUser?.username ?? "me",
            authorAvatar: currentUser?.avatarPath,
            isVerified: currentUser?.isVerified ?? false,
            isPremium: currentUser?.isPremium,
            parentCommentId: parentId,
            content: textToSubmit,
            timestamp: Date(),
            score: 0,
            myVote: 0,
            isAiGenerated: false,
            replies: [],
            commentType: commentType,
            mediaUrl: mediaUrlToSend,
            durationSec: durationSecToSend
        )
        
        if parentId == nil {
            let countBefore = comments.count
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                comments.insert(optimisticComment, at: 0)
            }
            if commentType == "voice" {
                #if DEBUG
                print("🔵 [VOICE-DEBUG] Step 4: Optimistic insert done — before=\(countBefore), after=\(comments.count)")
                #endif
            }
        } else if let safeParentId = parentId {
            // Insert reply into parent's replies array (optimistic)
            updateCommentInTree(commentId: safeParentId) { parent in
                var updatedParent = parent
                var updatedReplies = parent.replies
                updatedReplies.append(optimisticComment)
                updatedParent = Comment(
                    id: parent.id, postId: parent.postId, authorId: parent.authorId,
                    authorName: parent.authorName, authorAvatar: parent.authorAvatar,
                    isVerified: parent.isVerified, isPremium: parent.isPremium,
                    parentCommentId: parent.parentCommentId,
                    content: parent.content, timestamp: parent.timestamp,
                    score: parent.score, myVote: parent.myVote,
                    isAiGenerated: parent.isAiGenerated, replies: updatedReplies,
                    commentType: parent.commentType, mediaUrl: parent.mediaUrl,
                    durationSec: parent.durationSec
                )
                return updatedParent
            }
            if commentType == "voice" {
                #if DEBUG
                print("🔵 [VOICE-DEBUG] Step 4: Optimistic reply inserted under parentId=\(safeParentId)")
                #endif
            }
        }
        
        // Clear input
        commentText = ""
        replyTarget = nil
        selectedImage = nil
        if let url = recordedAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedAudioURL = nil
        previewDuration = 0
        Haptics.light()
        if commentType == "voice" {
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 4b: Input cleared & recording deleted")
            #endif
        }
        
        do {
            struct CommentBody: Encodable {
                let postId: String
                let content: String
                let parentCommentId: String?
                let commentType: String
                let mediaUrl: String?
                let durationSec: Double?
                
                enum CodingKeys: String, CodingKey {
                    case postId = "post_id"
                    case content
                    case parentCommentId = "parent_comment_id"
                    case commentType = "comment_type"
                    case mediaUrl = "media_url"
                    case durationSec = "duration_sec"
                }
            }
            
            if commentType == "voice" {
                #if DEBUG
                print("🔵 [VOICE-DEBUG] Step 5: Calling /api/comments/create — postId=\(post.id), content='\(textToSubmit)', type=voice, mediaUrl=\(mediaUrlToSend ?? "nil"), duration=\(durationSecToSend ?? 0)")
                #endif
            }
            
            let serverComment: Comment = try await networkService.post(
                path: "/api/comments/create",
                body: CommentBody(
                    postId: realPostId,
                    content: textToSubmit,
                    parentCommentId: parentId,
                    commentType: commentType,
                    mediaUrl: mediaUrlToSend,
                    durationSec: durationSecToSend
                )
            )
            
            if commentType == "voice" {
                #if DEBUG
                print("🔵 [VOICE-DEBUG] Step 6: Server response decoded!")
                print("🔵 [VOICE-DEBUG]   id=\(serverComment.id)")
                print("🔵 [VOICE-DEBUG]   commentType=\(serverComment.commentType ?? "nil")")
                print("🔵 [VOICE-DEBUG]   mediaUrl=\(serverComment.mediaUrl ?? "nil")")
                print("🔵 [VOICE-DEBUG]   durationSec=\(serverComment.durationSec ?? -1)")
                print("🔵 [VOICE-DEBUG]   content='\(serverComment.content)'")
                #endif
            }
            
            if parentId == nil {
                if let index = comments.firstIndex(where: { $0.id == tempId }) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        comments[index] = serverComment
                    }
                    if commentType == "voice" {
                        #if DEBUG
                        print("🔵 [VOICE-DEBUG] Step 7: Replaced optimistic at index \(index) with server comment")
                        #endif
                    }
                } else if commentType == "voice" {
                    #if DEBUG
                    print("🔴 [VOICE-DEBUG] Step 7: Could not find optimistic comment tempId=\(tempId) in comments!")
                    #endif
                }
            } else {
                await loadComments()
                if commentType == "voice" {
                    #if DEBUG
                    print("🔵 [VOICE-DEBUG] Step 7: Reloaded all comments (reply mode)")
                    #endif
                }
            }
            
            // Update cache so reopening sheet shows latest
            feedStore.setCachedComments(comments, for: realPostId)
            
            Haptics.success()
            
            if commentType == "voice" {
                #if DEBUG
                print("🔵 [VOICE-DEBUG] Step 8: Comments count=\(comments.count), cache updated")
                #endif
                let voiceCount = comments.filter { $0.commentType == "voice" }.count
                #if DEBUG
                print("🔵 [VOICE-DEBUG] Step 8: Voice comments in list = \(voiceCount)")
                print("🔵🔵🔵 [VOICE-DEBUG] ====== SUBMIT VOICE COMMENT SUCCESS ======")
                print("")
                #endif
            }
            
        } catch let decodingError as DecodingError {
            if commentType == "voice" {
                #if DEBUG
                print("🔴🔴🔴 [VOICE-DEBUG] DECODING ERROR:")
                #endif
                switch decodingError {
                case .keyNotFound(let key, let context):
                    #if DEBUG
                    print("🔴 [VOICE-DEBUG]   Key not found: '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue })")
                    #endif
                case .typeMismatch(let type, let context):
                    #if DEBUG
                    print("🔴 [VOICE-DEBUG]   Type mismatch: expected \(type) at path: \(context.codingPath.map { $0.stringValue })")
                    #endif
                case .valueNotFound(let type, let context):
                    #if DEBUG
                    print("🔴 [VOICE-DEBUG]   Value not found: \(type) at path: \(context.codingPath.map { $0.stringValue })")
                    #endif
                case .dataCorrupted(let context):
                    #if DEBUG
                    print("🔴 [VOICE-DEBUG]   Data corrupted: \(context.debugDescription)")
                    #endif
                @unknown default:
                    #if DEBUG
                    print("🔴 [VOICE-DEBUG]   Unknown: \(decodingError)")
                    #endif
                }
                voiceSubmitError = "Failed to decode server response"
            }
            withAnimation(.spring(response: 0.3)) {
                comments.removeAll { $0.id == tempId }
            }
            Haptics.error()
        } catch {
            if commentType == "voice" {
                #if DEBUG
                print("🔴🔴🔴 [VOICE-DEBUG] ERROR: \(error)")
                print("🔴 [VOICE-DEBUG] Error type: \(type(of: error))")
                print("🔴 [VOICE-DEBUG] Error description: \(error.localizedDescription)")
                #endif
                voiceSubmitError = "Failed to send voice comment: \(error.localizedDescription)"
            }
            withAnimation(.spring(response: 0.3)) {
                comments.removeAll { $0.id == tempId }
            }
            Haptics.error()
        }
        
        isSubmitting = false
    }
    
    // MARK: - Upload Image
    private func uploadImage(_ image: UIImage) async throws -> String {
        guard let data = image.jpegData(compressionQuality: PremiumLimits.imageCompressionQuality) else {
            throw NSError(domain: "Comment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to compress image"])
        }
        
        let boundary = UUID().uuidString
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"comment_image.jpg\"\r\n")
        body.appendString("Content-Type: image/jpeg\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")
        
        let urlString = "\(AppConfig.apiBaseURL)/api/uploads/image"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Comment", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw NSError(domain: "Comment", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image upload failed"])
        }
        
        struct UploadResponse: Decodable {
            let imageUrl: String
            enum CodingKeys: String, CodingKey { case imageUrl = "image_url" }
        }
        
        let result = try JSONDecoder().decode(UploadResponse.self, from: responseData)
        return result.imageUrl
    }
    
    // MARK: - Upload Voice
    private func uploadVoice(_ audioURL: URL) async throws -> String {
        let data = try Data(contentsOf: audioURL)
        let boundary = UUID().uuidString
        let filename = audioURL.lastPathComponent
        
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: audio/m4a\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")
        
        let urlString = "\(AppConfig.apiBaseURL)/api/uploads/voice"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Comment", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw NSError(domain: "Comment", code: 3, userInfo: [NSLocalizedDescriptionKey: "Voice upload failed"])
        }
        
        struct UploadResponse: Decodable {
            let voiceUrl: String
            enum CodingKeys: String, CodingKey { case voiceUrl = "voice_url" }
        }
        
        let result = try JSONDecoder().decode(UploadResponse.self, from: responseData)
        return result.voiceUrl
    }
    
    // MARK: - Vote Comment
    private func voteComment(commentId: String, vote: Int) {
        // Optimistic update
        updateVoteInTree(commentId: commentId, vote: vote)
        Haptics.light()
        
        // Fire API
        Task {
            do {
                struct VoteBody: Encodable {
                    let vote: Int
                }
                struct VoteResponse: Decodable {
                    let status: String
                    let action: String
                    let myVote: Int
                    let score: Int
                }
                
                let response: VoteResponse = try await networkService.post(
                    path: "/api/comments/\(commentId)/vote",
                    body: VoteBody(vote: vote)
                )
                
                // Apply server truth
                updateCommentInTree(commentId: commentId) { comment in
                    var updated = comment
                    updated = Comment(
                        id: comment.id,
                        postId: comment.postId,
                        authorId: comment.authorId,
                        authorName: comment.authorName,
                        authorAvatar: comment.authorAvatar,
                        isVerified: comment.isVerified,
                        isPremium: comment.isPremium,
                        parentCommentId: comment.parentCommentId,
                        content: comment.content,
                        timestamp: comment.timestamp,
                        score: response.score,
                        myVote: response.myVote,
                        isAiGenerated: comment.isAiGenerated,
                        replies: comment.replies,
                        commentType: comment.commentType,
                        mediaUrl: comment.mediaUrl,
                        durationSec: comment.durationSec
                    )
                    return updated
                }
                feedStore.setCachedComments(comments, for: post.id)
            } catch {
                #if DEBUG
                print("❌ Vote failed: \(error)")
                #endif
                // Revert optimistic update
                updateVoteInTree(commentId: commentId, vote: 0)
            }
        }
    }
    
    /// Optimistic vote update — toggles or sets vote in comment tree
    private func updateVoteInTree(commentId: String, vote: Int) {
        updateCommentInTree(commentId: commentId) { comment in
            let currentVote = comment.myVote
            let newVote = (currentVote == vote) ? 0 : vote
            let scoreDelta = newVote - currentVote
            
            return Comment(
                id: comment.id,
                postId: comment.postId,
                authorId: comment.authorId,
                authorName: comment.authorName,
                authorAvatar: comment.authorAvatar,
                isVerified: comment.isVerified,
                isPremium: comment.isPremium,
                parentCommentId: comment.parentCommentId,
                content: comment.content,
                timestamp: comment.timestamp,
                score: comment.score + scoreDelta,
                myVote: newVote,
                isAiGenerated: comment.isAiGenerated,
                replies: comment.replies,
                commentType: comment.commentType,
                mediaUrl: comment.mediaUrl,
                durationSec: comment.durationSec
            )
        }
    }
    
    /// Recursively find and update a comment in the tree
    private func updateCommentInTree(commentId: String, transform: (Comment) -> Comment) {
        func update(in list: inout [Comment]) -> Bool {
            for i in list.indices {
                if list[i].id == commentId {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        list[i] = transform(list[i])
                    }
                    return true
                }
                if update(in: &list[i].replies) { return true }
            }
            return false
        }
        _ = update(in: &comments)
    }
    
    // MARK: - Helpers
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Skeleton Comment Row
private struct SkeletonCommentRow: View {
    let delay: Double
    @State private var shimmerOffset: CGFloat = -200
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 38, height: 38)
                .shimmer(offset: shimmerOffset, delay: delay)
            
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 100, height: 14)
                    .shimmer(offset: shimmerOffset, delay: delay)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 12)
                    .shimmer(offset: shimmerOffset, delay: delay)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 180, height: 12)
                    .shimmer(offset: shimmerOffset, delay: delay)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 400
            }
        }
    }
}

#Preview {
    CommentsSheetView(
        post: Post(
            id: "test",
            authorId: "user1",
            authorUsername: "testuser",
            authorAvatar: nil,
            content: "This is a test post content that spans multiple lines to show how it looks in the preview card.",
            imageUrl: nil,
            timestamp: Date(),
            editedAt: nil,
            likes: 42,
            comments: 5,
            reposts: 3,
            viewCount: 128,
            isLocal: false,
            isLiked: false,
            isReposted: false,
            visibility: "public",
            distanceM: nil,
            postType: "text",
            roomId: nil
        ),
        feedStore: FeedStore.shared
    )
    .presentationDetents([.fraction(0.55), .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(.ultraThinMaterial)
}
