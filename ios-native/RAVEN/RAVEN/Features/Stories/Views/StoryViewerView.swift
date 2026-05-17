import SwiftUI
import UIKit

// MARK: - Story Viewer View
/// Full-screen story viewer with gestures, screenshot prevention, and dismiss animation
struct StoryViewerView: View {
    let author: StoryAuthor
    let onDismiss: (Set<String>) -> Void  // Returns IDs of seen stories to remove from feed
    
    @State private var stories: [Story] = []
    @State private var currentIndex = 0
    @State private var isLoading = true
    @State private var showSeenPlaceholder = false
    @State private var showLikeAnimation = false
    @State private var showReplySheet = false
    @State private var replyText = ""
    @State private var dragOffset: CGSize = .zero
    
    // Fix: Delayed rendering to prevent black screen / freeze on first open
    @State private var isReadyToPlay = false
    
    // Screenshot Prevention
    @State private var screenshotBlocked = false
    @State private var showScreenshotWarning = false
    
    // Dismiss Animation
    @State private var dismissingStoryId: String? = nil
    @State private var dismissOffset: CGSize = .zero
    @State private var dismissOpacity: Double = 1.0
    
    // Seen Stories Tracking
    @State private var seenStoryIds: Set<String> = []

    /// Strong reference to the screenshot observer token. 🟠 BUG FIX
    /// (2026-05-10): the previous version dropped the
    /// `addObserver(forName:…)` token on the floor — every viewer
    /// presentation registered ANOTHER observer that survived past
    /// dismissal, so a single screenshot triggered N copies of
    /// `handleScreenshot` once the user had opened a few stories.
    @State private var screenshotObserver: NSObjectProtocol?
    
    // Single-View Timer
    @State private var singleViewTimer: Timer?
    @State private var singleViewTimeRemaining: Int = 30
    @State private var showSingleViewWarning = false
    
    // Delete Confirmation (for story owner)
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    
    // Report (for other users' stories — required by App Store UGC guidelines)
    @State private var showReportSheet = false
    
    @Environment(\.dismiss) private var dismiss
    
    private var currentStory: Story? {
        guard currentIndex < stories.count else { return nil }
        return stories[currentIndex]
    }
    
    /// Check if current story is Friends-only (screenshot restricted)
    private var isFriendsStory: Bool {
        currentStory?.audience == "friends"
    }
    
    var body: some View {
        ZStack {
            // Background fades as user swipes down
            Color.black
                .opacity(1.0 - Double(abs(dragOffset.height) / 500))
                .ignoresSafeArea()
            
            // Fix: Only render content after a short delay to prevent first-frame freeze
            if isReadyToPlay {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if let story = currentStory {
                    // Story Content
                    storyContent(story)
                    
                    // Like Animation
                    if showLikeAnimation {
                        likeAnimationView
                    }
                    
                    // Screenshot Block Overlay (for Friends stories)
                    if screenshotBlocked {
                        screenshotBlockOverlay
                    }
                    
                    // Screenshot Warning Toast
                    if showScreenshotWarning {
                        screenshotWarningToast
                    }
                } else {
                    // No stories - all have been seen
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("All caught up!")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
            } else {
                // Solid black placeholder until UI is ready to render
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            loadStories()
            observeScreenshots()
            
            // Fix: Delayed render to force SwiftUI re-layout and prevent black screen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isReadyToPlay = true
            }
        }
        .onDisappear {
            stopSingleViewTimer()
            stopObservingScreenshots()
            // Return seen story IDs to caller for removal from feed
            onDismiss(seenStoryIds)
        }
        .onChange(of: currentIndex) { _, newIndex in
            handleStoryChange()
        }
        .sheet(isPresented: $showReplySheet) {
            replySheet
        }
        // Delete Confirmation Alert (for story owner)
        .confirmationDialog(
            "Delete Story?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteCurrentStory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This story will be permanently deleted.")
        }
        // Report Sheet (UGC compliance)
        .sheet(isPresented: $showReportSheet) {
            if let story = currentStory {
                ReportView(
                    targetType: .story,
                    targetId: story.id,
                    targetName: "\(story.authorUsername)'s story",
                    reportedUserId: story.authorId
                )
            }
        }
    }
    
    // MARK: - Story Content
    @ViewBuilder
    private func storyContent(_ story: Story) -> some View {
        ZStack {
            // Story Image
            AsyncImage(url: URL(string: story.mediaUrl)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                case .failure:
                    Color.black
                case .empty:
                    ProgressView()
                        .tint(.white)
                @unknown default:
                    Color.black
                }
            }
            
            // UI Overlay
            VStack {
                // Top Bar
                topBar(story: story)
                
                Spacer()
                
                // Bottom Bar
                bottomBar(story: story)
            }
            .opacity(dismissingStoryId == story.id ? 0 : 1)
        }
        // Apply dismiss animation to entire ZStack
        .offset(x: dismissingStoryId == story.id ? dismissOffset.width : 0,
                y: dismissingStoryId == story.id ? dismissOffset.height : dragOffset.height)
        .opacity(dismissingStoryId == story.id ? dismissOpacity : 1.0 - Double(abs(dragOffset.height)) / 400.0)
        .scaleEffect(dismissingStoryId == story.id ? 0.9 : 1.0)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    handleDragEnd(value)
                }
        )
        .onTapGesture(count: 2) {
            handleDoubleTap()
        }
        .onTapGesture {
            handleSingleTap()
        }
        // Long Press: Delete (own) or Report (others)
        .onLongPressGesture(minimumDuration: 0.5) {
            if currentStory?.isOwn == true {
                Haptics.medium()
                showDeleteConfirm = true
            } else {
                Haptics.medium()
                showReportSheet = true
            }
        }
    }
    
    // MARK: - Screenshot Block Overlay (Full black)
    private var screenshotBlockOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .transition(.opacity)
    }
    
    // MARK: - Screenshot Warning Toast (Liquid Glass)
    private var screenshotWarningToast: some View {
        VStack {
            Spacer()
            
            HStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                
                Text("Screenshot is not allowed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.red.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .red.opacity(0.3), radius: 12, y: 4)
            .padding(.bottom, 100)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    
    // MARK: - Top Bar
    private func topBar(story: Story) -> some View {
        VStack(spacing: 8) {
            // Single-view timer indicator
            if story.isSingleView && singleViewTimeRemaining > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 12))
                    Text("Single View - \(singleViewTimeRemaining)s")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.8), in: Capsule())
            }
            
            HStack(spacing: 12) {
                // Author Avatar
                AsyncImage(url: URL(string: story.authorAvatar ?? "")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(.gray.opacity(0.3))
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(story.authorUsername)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        
                        // Scope Badge
                        ScopeBadge(scope: story.audience, isSingleView: story.isSingleView)
                    }
                    
                    Text(story.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                
                Spacer()
                
                // Close Button
                Button {
                    handleManualClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 60)
    }
    
    // MARK: - Bottom Bar
    private func bottomBar(story: Story) -> some View {
        HStack(spacing: 20) {
            // Reply Button
            Button {
                showReplySheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                    Text("Reply")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
            }
            
            Spacer()
            
            // Seen Count (for own stories)
            if story.isOwn {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                    Text("\(story.seenCount)")
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
    }
    
    // MARK: - Like Animation
    private var likeAnimationView: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 80))
            .foregroundStyle(.red)
            .scaleEffect(showLikeAnimation ? 1.0 : 0.3)
            .opacity(showLikeAnimation ? 1.0 : 0.0)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showLikeAnimation)
    }
    
    // MARK: - Reply Sheet
    private var replySheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Reply to story...", text: $replyText)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                
                Button {
                    sendReply()
                } label: {
                    Text("Send")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .disabled(replyText.isEmpty)
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        showReplySheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    // MARK: - Actions
    private func loadStories() {
        Task {
            do {
                stories = try await StoryService.shared.getUserStories(userId: author.authorId)
                
                // Filter out already-seen stories (server should filter, but double-check)
                stories = stories.filter { !$0.isSeen }
                
                if stories.isEmpty {
                    // No unseen stories - dismiss immediately
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        onDismiss(seenStoryIds)
                    }
                }
                
                isLoading = false
            } catch {
                #if DEBUG
                print("❌ Failed to load stories: \(error)")
                #endif
                isLoading = false
            }
        }
    }
    
    private func handleDragEnd(_ value: DragGesture.Value) {
        let threshold: CGFloat = 100
        
        if value.translation.height < -threshold {
            // Swipe UP = Mark as seen + animated dismiss
            animateDismissAndMarkSeen()
        } else if value.translation.width > threshold {
            // Swipe RIGHT = Reply
            showReplySheet = true
            withAnimation(.spring(response: 0.3)) {
                dragOffset = .zero
            }
        } else if value.translation.height > threshold {
            // Swipe DOWN = Close viewer
            handleManualClose()
        } else {
            // Not enough drag — spring back to original position
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                dragOffset = .zero
            }
        }
    }
    
    /// Animate story dismiss: fade up + slide left + remove from list
    private func animateDismissAndMarkSeen() {
        guard let story = currentStory else { return }
        
        Haptics.light()
        
        // Track this story as seen
        seenStoryIds.insert(story.id)
        dismissingStoryId = story.id
        
        // Send to server immediately
        Task {
            try? await StoryService.shared.markSeen(storyId: story.id, reason: "swipe")
        }
        
        // Phase 1: Fade up slightly
        withAnimation(.easeOut(duration: 0.15)) {
            dismissOffset = CGSize(width: 0, height: -30)
            dismissOpacity = 0.7
        }
        
        // Phase 2: Slide left and fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeIn(duration: 0.2)) {
                dismissOffset = CGSize(width: -UIScreen.main.bounds.width, height: -30)
                dismissOpacity = 0
            }
        }
        
        // Phase 3: Remove from list and show next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // Reset animation state
            dismissingStoryId = nil
            dismissOffset = .zero
            dismissOpacity = 1.0
            dragOffset = .zero
            
            // Remove the seen story from local array
            stories.removeAll { $0.id == story.id }
            
            // Adjust index if needed
            if currentIndex >= stories.count {
                currentIndex = max(0, stories.count - 1)
            }
            
            // If no more stories, dismiss viewer
            if stories.isEmpty {
                onDismiss(seenStoryIds)
            }
        }
    }
    
    private func handleDoubleTap() {
        guard let story = currentStory else { return }
        
        // Like animation
        Haptics.medium()
        withAnimation {
            showLikeAnimation = true
        }
        
        // Hide after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation {
                showLikeAnimation = false
            }
        }
        
        // Send like to server
        Task {
            try? await StoryService.shared.toggleLike(storyId: story.id)
        }
    }
    
    private func handleSingleTap() {
        // Advance to next story or dismiss if last
        if currentIndex < stories.count - 1 {
            // Auto-mark current as seen when tapping to next
            if let story = currentStory {
                seenStoryIds.insert(story.id)
                Task {
                    try? await StoryService.shared.markSeen(storyId: story.id, reason: "swipe")
                }
            }
            currentIndex += 1
        } else {
            // Last story - mark as seen and dismiss
            if let story = currentStory {
                seenStoryIds.insert(story.id)
                Task {
                    try? await StoryService.shared.markSeen(storyId: story.id, reason: "swipe")
                }
            }
            onDismiss(seenStoryIds)
        }
    }
    
    // MARK: - Single-View Timer
    private func handleStoryChange() {
        stopSingleViewTimer()
        
        if let story = currentStory, story.isSingleView && !story.isSeen {
            startSingleViewTimer()
        }
    }
    
    private func startSingleViewTimer() {
        singleViewTimeRemaining = 30
        singleViewTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if singleViewTimeRemaining > 0 {
                singleViewTimeRemaining -= 1
                
                // Warning at 5 seconds
                if singleViewTimeRemaining == 5 {
                    showSingleViewWarning = true
                    Haptics.warning()
                }
            } else {
                // Timer expired - auto mark as seen and animate dismiss
                handleSingleViewTimeout()
            }
        }
    }
    
    private func stopSingleViewTimer() {
        singleViewTimer?.invalidate()
        singleViewTimer = nil
        showSingleViewWarning = false
    }
    
    private func handleSingleViewTimeout() {
        guard let story = currentStory, story.isSingleView else { return }
        
        stopSingleViewTimer()
        Haptics.warning()
        
        // Mark as seen and animate dismiss
        seenStoryIds.insert(story.id)
        Task {
            try? await StoryService.shared.markSeen(storyId: story.id, reason: "timeout")
        }
        
        animateDismissAndMarkSeen()
    }
    
    private func handleManualClose() {
        // Mark current story as seen when manually closing
        if let story = currentStory, !story.isSeen {
            seenStoryIds.insert(story.id)
            Task {
                try? await StoryService.shared.markSeen(storyId: story.id, reason: "manual_close")
            }
        }
        stopSingleViewTimer()
        onDismiss(seenStoryIds)
    }
    
    private func sendReply() {
        guard let story = currentStory, !replyText.isEmpty else { return }
        
        let content = replyText
        replyText = ""
        showReplySheet = false
        
        Haptics.medium()
        
        Task {
            try? await StoryService.shared.reply(storyId: story.id, content: content)
        }
    }
    
    // MARK: - Delete Story (Owner Only)
    private func deleteCurrentStory() {
        guard let story = currentStory, story.isOwn else { return }
        
        isDeleting = true
        Haptics.warning()
        
        Task {
            do {
                try await StoryService.shared.deleteStory(storyId: story.id)
                
                await MainActor.run {
                    // Remove from local list
                    stories.removeAll { $0.id == story.id }
                    
                    // Adjust index
                    if currentIndex >= stories.count {
                        currentIndex = max(0, stories.count - 1)
                    }
                    
                    Haptics.success()
                    isDeleting = false
                    
                    // If no more stories, dismiss viewer
                    if stories.isEmpty {
                        onDismiss(seenStoryIds)
                    }
                }
                
                #if DEBUG
                print("🗑️ Story deleted successfully")
                #endif
            } catch {
                await MainActor.run {
                    Haptics.error()
                    isDeleting = false
                }
                #if DEBUG
                print("❌ Failed to delete story: \(error)")
                #endif
            }
        }
    }
    
    // MARK: - Screenshot Detection & Prevention
    private func observeScreenshots() {
        // Tear down any prior observer before registering a new one,
        // so re-presenting the viewer (e.g. user navigates away and
        // back) doesn't stack observers.
        if let token = screenshotObserver {
            NotificationCenter.default.removeObserver(token)
        }
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { _ in
            handleScreenshot()
        }
    }

    /// Tear down the screenshot observer. Call from `.onDisappear`.
    private func stopObservingScreenshots() {
        if let token = screenshotObserver {
            NotificationCenter.default.removeObserver(token)
            screenshotObserver = nil
        }
    }
    
    private func handleScreenshot() {
        guard let story = currentStory else { return }
        
        // For Friends stories: Block and show warning
        if story.audience == "friends" {
            Haptics.error()
            
            // Show black overlay immediately
            withAnimation(.easeIn(duration: 0.05)) {
                screenshotBlocked = true
            }
            
            // Show warning toast
            withAnimation(.spring(response: 0.3)) {
                showScreenshotWarning = true
            }
            
            // Hide overlay after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeOut(duration: 0.2)) {
                    screenshotBlocked = false
                }
            }
            
            // Hide warning toast after longer delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.spring(response: 0.3)) {
                    showScreenshotWarning = false
                }
            }
            
            // Report to server
            Task {
                try? await StoryService.shared.reportScreenshot(storyId: story.id)
            }
            
            #if DEBUG
            print("📸 Screenshot BLOCKED on Friends story")
            #endif
        } else {
            // For Local stories: Just log (no blocking)
            #if DEBUG
            print("📸 Screenshot taken on Local story (allowed)")
            #endif
        }
    }
}

// MARK: - Preview
#Preview {
    StoryViewerView(
        author: StoryAuthor(
            authorId: "1",
            authorUsername: "testuser",
            authorAvatar: nil,
            hasUnseen: true,
            storyCount: 3,
            latestStoryId: "story1",
            latestCreatedAt: Date()
        ),
        onDismiss: { _ in }
    )
}
