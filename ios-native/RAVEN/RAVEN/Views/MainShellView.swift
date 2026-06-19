import SwiftUI

// MARK: - String + Identifiable (needed for .fullScreenCover(item:) with String? bindings)
extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Main Shell View (Root container — 2 tabs: Chats + Settings)
//
// MESSENGER PIVOT (2026-06): collapsed from the 4-tab social shell (Home feed /
// Messages / Discover / Account) to a focused two-tab messenger — Chats +
// Settings. The radial "new post" FAB, audio-room mini-player, RavenShot
// edge-swipe map, and the social sheets/deep-links were all removed.
struct MainShellView: View {
    @State private var selectedTab: AppTab = .messages
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var showSettings = false
    @State private var showSignOutAlert = false
    @State private var showCloseAccountAlert = false
    @State private var showMyQR = false
    @State private var showScanQR = false
    @State private var showProfileSheet = false
    @State private var showNotificationsSheet = false
    @State private var showSearchSheet = false
    @State private var profileUserId: String?
    @State private var conversationStore = ConversationStore.shared
    @State private var feedStateManager = FeedStateManager.shared
    @State private var deepLinkRouter = DeepLinkRouter.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground)
                .ignoresSafeArea()

            // Two-tab pager: Chats (Inbox) + Settings (Account).
            TabPager(
                tab: $selectedTab,
                chats: {
                    NavigationStack {
                        InboxView()
                    }
                },
                settings: {
                    NavigationStack {
                        AccountView()
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.top, .bottom])

            // Floating Search FAB — only on Chats, and not while in a chat.
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
                .offset(y: feedStateManager.isChromeHidden ? 120 : 0)
                .opacity(feedStateManager.isChromeHidden ? 0 : 1)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: feedStateManager.isChromeHidden)
                .transition(.scale(scale: 0.5, anchor: .bottomTrailing).combined(with: .opacity))
                .zIndex(2)
            }

            // Haptic Tab Bar — hidden while in a chat / detail view.
            if deepLinkRouter.currentChatRoomId == nil && !feedStateManager.isDetailViewActive {
                HapticTabBar(
                    selected: $selectedTab,
                    badgeCount: conversationStore.totalUnreadCount,
                    userAvatarURL: AppConfig.mediaURL(from: AuthService.shared.currentUser?.avatarPath),
                    actionsProvider: makeQuickActions
                )
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .offset(y: feedStateManager.isChromeHidden ? 120 : 0)
                .opacity(feedStateManager.isChromeHidden ? 0 : 1)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: feedStateManager.isChromeHidden)
                .zIndex(3)
            }
        }
        .onChange(of: selectedTab) { _, _ in
            if feedStateManager.isChromeHidden {
                feedStateManager.isChromeHidden = false
            }
        }
        .onAppear {
            // Realtime + mesh delivery startup. With a local key identity there
            // is no email gate; start once we have an identity.
            if AuthService.shared.isAuthenticated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    RealtimeEngine.shared.start()
                    PresenceService.shared.startHeartbeat()
                    DeliveryJobRunner.shared.start()
                }
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
                DispatchQueue.main.async {
                    showNewChat = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        DeepLinkRouter.shared.navigate(to: .chat(roomId: conversation.roomId))
                    }
                }
            }
        }
        .sheet(isPresented: $showNewGroup) {
            NewGroupView()
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
        // MARK: - Alerts
        .alert("sign_out".localized, isPresented: $showSignOutAlert) {
            Button("cancel".localized, role: .cancel) {}
            Button("sign_out".localized, role: .destructive) {
                Haptics.warning()
                Task { try? await AuthService.shared.logout() }
            }
        } message: {
            Text("sign_out_confirm".localized)
        }
        .alert("close_account".localized, isPresented: $showCloseAccountAlert) {
            Button("cancel".localized, role: .cancel) {}
            Button("close_account".localized, role: .destructive) {
                Haptics.error()
                Task {
                    do {
                        let _: [String: String] = try await NetworkService.shared.delete(path: "/api/users/me")
                    } catch {
                        #if DEBUG
                        print("❌ [Account] Account closure API failed: \(error) — logging out anyway")
                        #endif
                    }
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
        // MARK: - Deep Link Handling (messenger destinations only)
        .onReceive(NotificationCenter.default.publisher(for: .deepLinkReceived)) { notification in
            guard let destination = notification.object as? DeepLinkRouter.Destination else { return }
            switch destination {
            case .profile(let userId):
                profileUserId = userId
                showProfileSheet = true
            case .notifications, .friendRequests:
                showNotificationsSheet = true
            case .chat, .newChat:
                selectedTab = .messages
                // InboxView listens for .deepLinkReceived and navigates to the chat.
            case .newMessage:
                selectedTab = .messages
                NotificationCenter.default.post(name: .ravenShortcutNewMessage, object: nil)
            default:
                break
            }
            DeepLinkRouter.shared.pendingDestination = nil
        }
        // ✅ Voice Mini Player Overlay — global, above tab bar
        .overlay(alignment: .bottom) {
            PlayerOverlay()
        }
        // ✅ Toast Notifications Overlay
        .overlay {
            ToastHostOverlay()
        }
        // ✅ Background Mesh Onboarding — shown once after setup completes
        .withBackgroundMeshOnboarding()
    }

    // MARK: - Quick Actions Provider (per-tab long-press menu)
    private func makeQuickActions(for tab: AppTab) -> [TabAction] {
        switch tab {
        case .messages:
            return [
                TabAction(title: "mark_all_read".localized, systemImage: "envelope.open", tint: .gray) {
                    Haptics.success()
                    Task { await ConversationStore.shared.markAllAsRead() }
                },
                TabAction(title: "new_message".localized, systemImage: "square.and.pencil", tint: .blue) {
                    showNewChat = true
                },
                TabAction(title: "new_group".localized, systemImage: "person.3", tint: .purple) {
                    showNewGroup = true
                }
            ]
        case .account:
            return [
                TabAction(title: "settings".localized, systemImage: "gearshape.fill", tint: .gray) {
                    showSettings = true
                },
                TabAction(title: "scan_qr_code".localized, systemImage: "qrcode.viewfinder", tint: .cyan) {
                    Haptics.selection()
                    showScanQR = true
                },
                TabAction(title: "my_qr_code".localized, systemImage: "qrcode", tint: .purple) {
                    Haptics.selection()
                    showMyQR = true
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
