import SwiftUI

// MARK: - Auth Gate (Enforces username + email verification before main app)
struct AuthGateView: View {
    @State private var authService = AuthService.shared
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    
    var body: some View {
        
        Group {
            // ✅ Priority 0: Show Splash while checking auth state (PREVENTS LOGIN FLASH!)
            if authService.bootState == .checking {
                LaunchView()
            }
            // ✅ Priority 1: Show Onboarding FIRST (only once ever, BEFORE login)
            else if !hasSeenOnboarding {
                OnboardingView {
                    withAnimation(.spring(response: 0.5)) {
                        hasSeenOnboarding = true
                    }
                }
            }
            // Priority 2: Username Gate (blocks all OAuth/Email users without handle)
            else if authService.requiresUsernameSetup {
                NavigationStack {
                    UsernameSelectionView()
                }
            }
            // Priority 2.5: Phone Collection (optional for OAuth users - only show once)
            else if authService.needsPhoneNumber && !authService.hasSeenPhoneCollection {
                PhoneCollectionView(
                    onComplete: {
                        // Mark as done - user provided phone
                        authService.hasSeenPhoneCollection = true
                        Task { try? await authService.fetchCurrentUser() }
                    },
                    onSkip: nil  // Skip button removed
                )
            }
            // Priority 3: Authenticated state
            else if authService.isAuthenticated {
                // OAuth users (Google/Apple) are implicitly verified by provider
                // Only email/password users need OTP verification
                let isOAuthUser = authService.currentUser?.authMethod != .password
                let isVerified = isOAuthUser || authService.isEmailVerified
                
                if isVerified {
                    // Full access - show main app with swipe tabs
                    MainShellView()
                } else {
                    // Email user with unverified email - show OTP
                    NavigationStack {
                        OTPVerificationView(
                            email: authService.currentUser?.email ?? "",
                            onVerified: {
                                // Token automatically upgraded in AuthService
                            }
                        )
                    }
                }
            } 
            // Priority 4: Not logged in - show landing
            else {
                AuthLandingView()
            }
        }
        .onAppear {
            Task {
                if authService.bootState == .checking {
                    await authService.checkExistingSession()
                }
            }
        }
    }
}

// MARK: - Welcome View
struct WelcomeView: View {
    @State private var showLogin = false
    @State private var showSignUp = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                
                // Logo
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.2), .purple.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 140, height: 140)
                        .blur(radius: 2)
                    
                    Image("RavenLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }
                
                VStack(spacing: 8) {
                    Text("RAVEN")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Secure messaging with or without internet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                Spacer()
                
                // Features
                VStack(spacing: 16) {
                    FeatureRow(icon: "lock.shield", title: "End-to-end encrypted")
                    FeatureRow(icon: "antenna.radiowaves.left.and.right", title: "Works offline via mesh")
                    FeatureRow(icon: "bolt.fill", title: "Fast and reliable")
                }
                .padding(.horizontal, 40)
                
                Spacer()
                
                // Buttons
                VStack(spacing: 16) {
                    Button {
                        showSignUp = true
                    } label: {
                        Text("Create Account")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(
                                    colors: [.blue, .blue.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    
                    Button {
                        showLogin = true
                    } label: {
                        Text("Sign In")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(.white.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
            .navigationDestination(isPresented: $showLogin) {
                LoginView()
            }
            .navigationDestination(isPresented: $showSignUp) {
                SignUpView()
            }
        }
    }
}

// MARK: - Feature Row
struct FeatureRow: View {
    let icon: String
    let title: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 30)
            
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Spacer()
        }
    }
}

// MARK: - Main Tab View (Only accessible after email verification)
struct MainTabView: View {
    @State private var selectedTab: AppTab = .home
    @State private var conversationStore = ConversationStore.shared
    @State private var deepLinkRouter = DeepLinkRouter.shared
    @State private var showCreatePost = false
    @State private var showNewChat = false
    @State private var showNewGroup = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab Content - extends under the glass bar for blur effect
            Group {
                switch selectedTab {
                case .home:
                    FeedView()
                case .messages:
                    NavigationStack {
                        InboxView()
                    }
                case .discover:
                    DiscoverView()
                case .account:
                    AccountView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom) // ✅ Content goes under glass bar
            
            // Floating Action Buttons - animate from/to TabBar
            FloatingActionsOverlay(
                selectedTab: $selectedTab,
                onNewPost: { showCreatePost = true },
                onNewMessage: { showNewChat = true },
                onNewGroup: { showNewGroup = true }
            )
            
            // Custom Haptic Tab Bar - Hide when in Chat
            if deepLinkRouter.currentChatRoomId == nil {
                HapticTabBar(
                    selected: $selectedTab,
                    badgeCount: conversationStore.totalUnreadCount,
                    actionsProvider: makeQuickActions
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard) // Don't push up when keyboard shows
        .onAppear {
            RealtimeEngine.shared.start()
            PresenceService.shared.startHeartbeat()  // 💓 Start presence heartbeats so server knows we're online
            DeliveryJobRunner.shared.start()  // 🚀 Start processing mesh delivery jobs
            #if DEBUG
            print("💓 [App] Started presence heartbeat")
            print("🚀 [App] Started DeliveryJobRunner")
            #endif
            
            // Handle pending deep link
            if let pending = DeepLinkRouter.shared.pendingDestination {
                DeepLinkRouter.shared.navigate(to: pending)
                DeepLinkRouter.shared.pendingDestination = nil
            }
        }
        .sheet(isPresented: $showCreatePost) {
            CreatePostView()
        }
        .sheet(isPresented: $showNewChat) {
            NewChatView { conversation in
                showNewChat = false
                // Navigate to messages tab and then to chat
                selectedTab = .messages
            }
        }
        .sheet(isPresented: $showNewGroup) {
            NewGroupView()
        }
        // ✅ Toast Notifications Overlay - shows on top of everything
        .overlay {
            ToastHostOverlay()
        }
    }
    
    // MARK: - Quick Actions Provider
    private func makeQuickActions(for tab: AppTab) -> [TabAction] {
        switch tab {
        case .home:
            return [
                TabAction(title: "Create Post", systemImage: "plus.circle", tint: .blue) {
                    showCreatePost = true
                },
                TabAction(title: "Refresh Feed", systemImage: "arrow.clockwise", tint: .green) {
                    #if DEBUG
                    print("🟢 Refresh Feed tapped")
                    #endif
                }
            ]
        case .messages:
            return [
                TabAction(title: "New Chat", systemImage: "square.and.pencil", tint: .blue) {
                    #if DEBUG
                    print("🔵 New Chat tapped")
                    #endif
                },
                TabAction(title: "Mesh Status", systemImage: "antenna.radiowaves.left.and.right", tint: .purple) {
                    #if DEBUG
                    print("🟣 Mesh Status tapped")
                    #endif
                }
            ]
        case .discover:
            return [
                TabAction(title: "Scan QR", systemImage: "qrcode.viewfinder", tint: .cyan) {
                    #if DEBUG
                    print("🔵 Scan QR tapped")
                    #endif
                },
                TabAction(title: "Find Nearby", systemImage: "location.magnifyingglass", tint: .green) {
                    #if DEBUG
                    print("🟢 Find Nearby tapped")
                    #endif
                }
            ]
        case .account:
            return [
                TabAction(title: "Edit Profile", systemImage: "pencil", tint: .pink) {
                    #if DEBUG
                    print("🩷 Edit Profile tapped")
                    #endif
                },
                TabAction(title: "Settings", systemImage: "gearshape.fill", tint: .gray) {
                    #if DEBUG
                    print("⚙️ Settings tapped")
                    #endif
                }
            ]
        }
    }
}

// MARK: - Home View (Primary Entry Point)
struct HomeView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Welcome to RAVEN")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Your feed will appear here")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 100)
        }
        .navigationTitle("Home")
        .toolbar {
            // Notification bell icon - top right (iOS UX standard)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    #if DEBUG
                    print("🔔 Notifications tapped")
                    #endif
                } label: {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

// MARK: - Placeholder Views
struct DiscoverPlaceholderView: View {
    var body: some View {
        Text("Discover")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .navigationTitle("Discover")
    }
}

struct AccountPlaceholderView: View {
    var body: some View {
        Text("Account")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .navigationTitle("Account")
    }
}


// Note: InboxView and ConversationRow are defined in Features/Inbox/InboxView.swift

#Preview {
    AuthGateView()
}

// Note: OnboardingView is defined in Features/Onboarding/OnboardingView.swift
