import SwiftUI

// MARK: - String + Identifiable (needed for .fullScreenCover(item:) with String? bindings)
extension String: @retroactive Identifiable {
    public var id: String { self }
}
// MARK: - Main Shell View (Root Container with Swipe + Haptic Tab Bar)
struct MainShellView: View {
    @State private var selectedTab: AppTab = .home
    @State private var showNewChat = false
    @State private var showCreatePost = false
    @State private var showNewGroup = false
    @State private var showSettings = false
    // Add Account removed — Apple rejects "coming soon" stubs (Guideline 2.2)
    @State private var showSignOutAlert = false
    @State private var showCloseAccountAlert = false
    @State private var showMyQR = false
    @State private var showScanQR = false
    @State private var showProfileSheet = false
    @State private var showNotificationsSheet = false
    @State private var showSearchSheet = false
    @State private var showAudioRooms = false
    @State private var showClubList = false
    @State private var showEchoMap = false
    @State private var showRavenShot = false  // Social map (swipe-right from Home)
    @State private var ravenShotDragOffset: CGFloat = 0  // Interactive drag position
    @State private var deepLinkRoomId: String? = nil
    @State private var profileUserId: String?
    @State private var conversationStore = ConversationStore.shared
    @State private var feedStateManager = FeedStateManager.shared
    @State private var deepLinkRouter = DeepLinkRouter.shared
    

    
    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground)
                .ignoresSafeArea()
                
            // Tab Content with Swipe (real pager with all 4 tab views)
            TabPager(
                tab: $selectedTab,
                feed: {
                    NavigationStack {
                        FeedView()
                    }
                },
                discover: {
                    NavigationStack {
                        DiscoverView()
                    }
                },
                messages: {
                    NavigationStack {
                        InboxView()
                    }
                },
                account: {
                    NavigationStack {
                        AccountView()
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ✅ Only ignore CONTAINER safe area (home indicator), NOT keyboard
            // .ignoresSafeArea(edges: .bottom) defaults to .all regions which kills keyboard avoidance!
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // 📍 Raven Shot: Edge swipe from left to open social map (Home tab only)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard selectedTab == .home else { return }
                        guard !feedStateManager.isDetailViewActive else { return }
                        // 🚧 Bail when RavenShot is already presented OR when a
                        // nested pager has claimed the gesture. Without these
                        // guards, panning the RavenShot map (which fires
                        // horizontal drags) would re-trigger the open
                        // animation on top of the already-open view, causing
                        // SwiftUI to invalidate the Map repeatedly → crash.
                        guard !showRavenShot else { return }
                        guard !NestedSwipeCoordinator.shared.isHandlingSwipe else { return }
                        // Only trigger from left edge (start point near left edge)
                        guard value.startLocation.x < 35 else { return }
                        // Must be predominantly horizontal
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                        guard value.translation.width > 0 else { return }

                        let progress = min(value.translation.width, UIScreen.main.bounds.width)
                        ravenShotDragOffset = progress
                    }
                    .onEnded { value in
                        guard selectedTab == .home else { return }
                        guard !feedStateManager.isDetailViewActive else { return }
                        guard !showRavenShot else { return }
                        guard !NestedSwipeCoordinator.shared.isHandlingSwipe else { return }
                        guard value.startLocation.x < 35 else {
                            withAnimation(.interpolatingSpring(stiffness: 320, damping: 32)) {
                                ravenShotDragOffset = 0
                            }
                            return
                        }

                        let screenWidth = UIScreen.main.bounds.width
                        let velocity = value.predictedEndTranslation.width - value.translation.width
                        // Commit on 22% of screen OR moderate flick velocity
                        if value.translation.width > screenWidth * 0.22 || velocity > 250 {
                            Haptics.medium()
                            withAnimation(.interpolatingSpring(stiffness: 320, damping: 32)) {
                                showRavenShot = true
                                ravenShotDragOffset = 0
                            }
                        } else {
                            withAnimation(.interpolatingSpring(stiffness: 320, damping: 32)) {
                                ravenShotDragOffset = 0
                            }
                        }
                    }
            )
            
            // NOTE: Floating Search Pill removed per Apple/Liquid Glass design
            // Search is now ONLY accessible from the native .searchable modifier in InboxView
            // The bottom bar should be the only interactive element at the bottom
            
            // Floating Radial Menu FAB - ONLY when Home is active (hides with bottom bar)
            if selectedTab == .home && !feedStateManager.isDetailViewActive {
                RadialMenuFAB(
                    onNewPost: { showCreatePost = true },
                    onAudioRoom: { showAudioRooms = true },
                    onClub: { showClubList = true },
                    onEcho: { showEchoMap = true }
                )
                // Smooth slide animation with bottom bar
                .offset(y: feedStateManager.isChromeHidden ? 120 : 0)
                .opacity(feedStateManager.isChromeHidden ? 0 : 1)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: feedStateManager.isChromeHidden)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .zIndex(2)
            }
            
            // Floating Search FAB - ONLY when Messages is active AND not in chat
            if selectedTab == .messages && deepLinkRouter.currentChatRoomId == nil && !feedStateManager.isDetailViewActive {
                Button {
                    Haptics.light()
                    showSearchSheet = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 52, height: 52)
                        .contentShape(Circle())
                        .background(.ultraThinMaterial, in: Circle())

                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 20)
                .padding(.bottom, 100)
                // Smooth slide animation with bottom bar
                .offset(y: feedStateManager.isChromeHidden ? 120 : 0)
                .opacity(feedStateManager.isChromeHidden ? 0 : 1)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: feedStateManager.isChromeHidden)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.5, anchor: .bottomTrailing)
                        .combined(with: .offset(x: 40, y: 20))
                        .combined(with: .opacity),
                    removal: .scale(scale: 0.5, anchor: .bottomTrailing)
                        .combined(with: .offset(x: 40, y: 20))
                        .combined(with: .opacity)
                ))
                .zIndex(2)
            }
            
            // Haptic Tab Bar - Always rendered but animated with offset for smooth hide/show
            // Hide when in Chat, slide down when chrome is hidden from scroll
            if deepLinkRouter.currentChatRoomId == nil && !feedStateManager.isDetailViewActive {
                HapticTabBar(
                    selected: $selectedTab,
                    badgeCount: conversationStore.totalUnreadCount,
                    userAvatarURL: AppConfig.mediaURL(from: AuthService.shared.currentUser?.avatarPath),
                    actionsProvider: makeQuickActions
                )
                .ignoresSafeArea(.keyboard, edges: .bottom)
                // ✅ Smooth slide-out transition instead of abrupt disappearance
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Smooth slide animation: slide down off-screen when hidden
                .offset(y: feedStateManager.isChromeHidden ? 120 : 0)
                .opacity(feedStateManager.isChromeHidden ? 0 : 1)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: feedStateManager.isChromeHidden)
                .zIndex(3)
            }
        }
        // NOTE: Do NOT use .animation(value: selectedTab) here – animating the
        // ZStack body forces all 4 NavigationStacks to layout simultaneously,
        // triggering NSInternalInconsistencyException in UINavigationBar.
        .onChange(of: selectedTab) { _, _ in
            // Show bottom bar when switching tabs (keyboard is already dismissed in ContextMenuTabItem)
            if feedStateManager.isChromeHidden {
                feedStateManager.isChromeHidden = false
            }
        }
        // ✅ Removed .ignoresSafeArea(.keyboard) from here — it was blocking ChatView's composer keyboard avoidance
        // Keyboard ignore is now ONLY on the TabPager container above
        .onAppear {
            // Only start realtime if fully verified (OAuth or email verified)
            let isOAuth = AuthService.shared.currentUser?.authMethod != .password
            let isVerified = isOAuth || AuthService.shared.isEmailVerified
            if isVerified {
                // 🚀 Small 250ms buffer so feed fetch dispatches first; WebSocket
                // connect is small and runs in parallel without competing meaningfully
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    RealtimeEngine.shared.start()
                    
                    // 💓 Start presence heartbeats so server knows we're online
                    PresenceService.shared.startHeartbeat()
                    #if DEBUG
                    print("💓 [App] Started presence heartbeat")
                    #endif
                    
                    // 🚀 Start processing mesh delivery jobs
                    DeliveryJobRunner.shared.start()
                    #if DEBUG
                    print("🚀 [App] Started DeliveryJobRunner")
                    #endif
                }
                
                // 🚀 Delay 2s for heavy contacts sync
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    _ = await ContactsService.shared.requestPermission()
                    if ContactsService.shared.permissionStatus == .authorized {
                        await ContactsService.shared.syncWithServer()
                    }
                }
            }
            
            if let pending = DeepLinkRouter.shared.pendingDestination {
                DeepLinkRouter.shared.pendingDestination = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    DeepLinkRouter.shared.navigate(to: pending)
                }
            }
        }
        .sheet(isPresented: $showNewChat) {
            NewChatView { conversation in
                // Defer ALL state changes to the next run loop to avoid
                // mutating state while still inside the sheet's call stack.
                DispatchQueue.main.async {
                    showNewChat = false
                    // Navigate to chat after a short delay so the sheet can dismiss safely
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        DeepLinkRouter.shared.navigate(to: .chat(roomId: conversation.roomId))
                    }
                }
            }
        }
        .sheet(isPresented: $showNewGroup) {
            NewGroupView()
        }
        .sheet(isPresented: $showCreatePost) {
            CreatePostView()
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                AccountSettingsList()
            }
        }

        .sheet(isPresented: $showMyQR) {
            MyQRCodeView()
        }
        .sheet(isPresented: $showScanQR) {
            ScanQRCodeView()
        }
        .sheet(isPresented: $showSearchSheet) {
            ConversationSearchSheet()
        }
        .sheet(isPresented: $showClubList) {
            NavigationStack {
                ClubListView()
            }
        }
        .sheet(isPresented: $showEchoMap) {
            NavigationStack {
                EchoMapView()
            }
        }
        // Raven Shot map overlay (smooth slide from left)
        .overlay {
            if showRavenShot {
                RavenShotView(isPresented: $showRavenShot)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(999)
            }
        }
        // Interactive peek preview during drag
        .overlay {
            if ravenShotDragOffset > 0 && !showRavenShot {
                RavenShotPeekView(progress: ravenShotDragOffset / UIScreen.main.bounds.width)
                    .frame(width: ravenShotDragOffset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                    .zIndex(998)
            }
        }
        .fullScreenCover(isPresented: $showAudioRooms) {
            NavigationStack {
                RoomListView()
            }
        }
        // MARK: - Alerts
        .alert("sign_out".localized, isPresented: $showSignOutAlert) {
            Button("cancel".localized, role: .cancel) {}
            Button("sign_out".localized, role: .destructive) {
                Haptics.warning()
                Task {
                    try? await AuthService.shared.logout()
                }
            }
        } message: {
            Text("sign_out_confirm".localized)
        }
        .alert("close_account".localized, isPresented: $showCloseAccountAlert) {
            Button("cancel".localized, role: .cancel) {}
            Button("close_account".localized, role: .destructive) {
                Haptics.error()
                #if DEBUG
                print("⚠️ [Account] Closing account...")
                #endif
                Task {
                    do {
                        let _: [String: String] = try await NetworkService.shared.delete(path: "/api/users/me")
                        #if DEBUG
                        print("✅ [Account] Account closed on server")
                        #endif
                    } catch {
                        #if DEBUG
                        print("❌ [Account] Account closure API failed: \(error) — logging out anyway")
                        #endif
                    }
                    // Always logout after confirming closure
                    try? await AuthService.shared.logout()
                }
            }
        } message: {
            Text("close_account_confirm".localized)
        }
        // MARK: - Profile Sheet
        .sheet(isPresented: $showProfileSheet) {
            if let userId = profileUserId {
                NavigationStack {
                    UserProfileView(userId: userId)
                }
            }
        }
        // MARK: - Notifications Sheet
        .sheet(isPresented: $showNotificationsSheet) {
            NavigationStack {
                NotificationsListView()
            }
        }
        // MARK: - Deep Link Handling
        .onReceive(NotificationCenter.default.publisher(for: .deepLinkReceived)) { notification in
            guard let destination = notification.object as? DeepLinkRouter.Destination else { return }
            
            switch destination {
            case .profile(let userId):
                // 🚀 Deep Link: Navigate to profile (from follow/follow_request notifications)
                profileUserId = userId
                showProfileSheet = true
            case .notifications:
                showNotificationsSheet = true
            case .friendRequests:
                // Show notifications sheet for friend requests
                showNotificationsSheet = true
            case .chat, .newChat:
                selectedTab = .messages
                // InboxView already listens for .deepLinkReceived and navigates to the chat.
                // Do NOT call navigate() again here — it re-posts the notification, causing an infinite loop.
            case .post(let postId):
                // 🚀 Deep Link: Navigate to post from like/comment/post_comment/post_like notifications
                selectedTab = .home
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    FeedStateManager.shared.deepLinkPostId = postId
                }
            // (2026-05-15 — round 7) Home-screen Quick Action targets
            // get translated into the same in-app navigation:
            //   newMessage → switch to inbox + post a "compose" hint
            //   newPost    → switch to home + post a "compose post" hint
            //   search     → switch to home + post a "search" hint
            //   voiceNote  → switch to inbox + post a "voice note" hint
            // Each leaf screen listens for the corresponding sub-notification
            // and presents the right composer.
            case .newMessage:
                selectedTab = .messages
                NotificationCenter.default.post(name: .ravenShortcutNewMessage, object: nil)
            case .newPost:
                selectedTab = .home
                NotificationCenter.default.post(name: .ravenShortcutNewPost, object: nil)
            case .search:
                selectedTab = .home
                NotificationCenter.default.post(name: .ravenShortcutSearch, object: nil)
            case .voiceNote:
                selectedTab = .messages
                NotificationCenter.default.post(name: .ravenShortcutVoiceNote, object: nil)
            default:
                break // Other destinations handled elsewhere (audioRoom, etc.)
            }
            DeepLinkRouter.shared.pendingDestination = nil
        }
        // (2026-05-15 — round 7) New Post quick-action lives at the
        // shell layer because the existing `+` FAB also drives
        // `showCreatePost`. Single source of truth — no double sheets.
        .onReceive(NotificationCenter.default.publisher(for: .ravenShortcutNewPost)) { _ in
            showCreatePost = true
        }
        // Search shortcut hops to the Discover tab (no dedicated
        // `.search` tab today) where the user can drive the
        // existing in-app search surface.
        .onReceive(NotificationCenter.default.publisher(for: .ravenShortcutSearch)) { _ in
            selectedTab = .discover
        }
        // ✅ Voice Mini Player Overlay - global, above tab bar
        .overlay(alignment: .bottom) {
            PlayerOverlay()
        }
        // ✅ Toast Notifications Overlay - shows on top of everything
        .overlay {
            ToastHostOverlay()
        }
        // 🌐 Disaster Mode banner has been moved INTO each tab's view
        // (currently FeedView) so it sits BELOW the floating Local/Friends
        // pill on Home rather than overlapping it. Other tabs can mount
        // `DisasterModeBanner()` themselves where it makes sense for their
        // layout if/when they want to surface the offline state.
        // ✅ Audio Room Mini Player — shown when room is minimized
        .overlay(alignment: .top) {
            if RoomService.shared.isInRoom,
               let currentRoom = RoomService.shared.currentRoom?.room,
               deepLinkRoomId == nil {
                
                Button {
                    deepLinkRoomId = currentRoom.id
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.green)
                            .symbolEffect(.variableColor.iterative, isActive: AudioRoomManager.shared.isConnected)
                        
                        Text("Live: \(currentRoom.title)")
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        if AudioRoomManager.shared.isMicEnabled {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassSurface(in: Capsule())
                    .overlay(Capsule().stroke(Color.green.opacity(0.4), lineWidth: 1)) // live-room green tint
                    .padding(.horizontal, 20)
                    .padding(.top, 60)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: RoomService.shared.isInRoom)
            }
        }
        // ✅ Background Mesh Onboarding - shown once after login/setup complete
        .withBackgroundMeshOnboarding()
        .fullScreenCover(item: $deepLinkRoomId) { roomId in
            LiveRoomView(roomId: roomId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .audioRoomDeepLink)) { notification in
            if let slug = notification.userInfo?["slug"] as? String {
                deepLinkRoomId = slug
            }
        }
    }
    
    // MARK: - Quick Actions Provider
    private func makeQuickActions(for tab: AppTab) -> [TabAction] {
        switch tab {
        case .home:
            return [
                TabAction(title: "refresh".localized, systemImage: "arrow.clockwise", tint: .green) {
                    feedStateManager.triggerRefresh()
                },
                TabAction(title: "local".localized, systemImage: "location.circle", tint: .blue) {
                    feedStateManager.switchToLocal()
                },
                TabAction(title: "friends".localized, systemImage: "person.2", tint: .purple) {
                    feedStateManager.switchToFriends()
                }
            ]
            
        case .messages:
            return [
                TabAction(title: "mark_all_read".localized, systemImage: "envelope.open", tint: .gray) {
                    Haptics.success()
                    Task {
                        await ConversationStore.shared.markAllAsRead()
                    }
                },
                TabAction(title: "new_message".localized, systemImage: "square.and.pencil", tint: .blue) {
                    showNewChat = true
                },
                TabAction(title: "new_group".localized, systemImage: "person.3", tint: .purple) {
                    showNewGroup = true
                }
            ]
            
        case .discover:
            return [
                TabAction(title: "search_users".localized, systemImage: "person.magnifyingglass", tint: .blue) {
                    Haptics.selection()
                    // No withAnimation — prevents UICollectionView keyboard crash
                    selectedTab = .discover
                },
                TabAction(title: "scan_qr_code".localized, systemImage: "qrcode.viewfinder", tint: .cyan) {
                    Haptics.selection()
                    showScanQR = true
                },
                TabAction(title: "my_qr_code".localized, systemImage: "qrcode", tint: .purple) {
                    Haptics.selection()
                    showMyQR = true
                }
            ]
            
        case .account:
            return [
                TabAction(title: "settings".localized, systemImage: "gearshape.fill", tint: .gray) {
                    showSettings = true
                },

                TabAction(title: "sign_out".localized, systemImage: "rectangle.portrait.and.arrow.right", tint: .orange) {
                    showSignOutAlert = true
                },
                TabAction(title: "close_account".localized, systemImage: "xmark.circle", tint: .red) {
                    showCloseAccountAlert = true
                }
            ]
        }
    }
}

// MARK: - Preview
#Preview {
    MainShellView()
}

