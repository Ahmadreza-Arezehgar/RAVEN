import SwiftUI

// MARK: - Nested Swipe Coordinator
/// Shared state so a nested horizontal pager (e.g. MeshFeaturesContainerView)
/// can claim a horizontal drag and prevent the root TabPager from also
/// switching tabs in response to the same gesture.
@MainActor
@Observable
final class NestedSwipeCoordinator {
    static let shared = NestedSwipeCoordinator()
    private init() {}
    /// Set by an inner pager while it is actively interpreting a horizontal drag.
    var isHandlingSwipe: Bool = false
}

// MARK: - Tab Pager (Horizontal Swipe Between Tabs)
/// A proper pager that hosts multiple tab views and allows swiping between them
struct TabPager<FeedContent: View, DiscoverContent: View, MessagesContent: View, AccountContent: View>: View {
    @Binding var tab: AppTab
    
    // Tab content providers (concrete types, no AnyView)
    let feedView: FeedContent
    let discoverView: DiscoverContent
    let messagesView: MessagesContent
    let accountView: AccountContent
    
    @GestureState private var dragOffset: CGFloat = 0
    
    init(
        tab: Binding<AppTab>,
        @ViewBuilder feed: () -> FeedContent,
        @ViewBuilder discover: () -> DiscoverContent,
        @ViewBuilder messages: () -> MessagesContent,
        @ViewBuilder account: () -> AccountContent
    ) {
        _tab = tab
        self.feedView = feed()
        self.discoverView = discover()
        self.messagesView = messages()
        self.accountView = account()
    }
    
    var body: some View {
        GeometryReader { geo in
            let screenWidth = geo.size.width
            
            HStack(spacing: 0) {
                feedView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.home)
                
                messagesView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.messages)
                
                discoverView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.discover)
                
                accountView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.account)
            }
            .offset(x: -CGFloat(tab.rawValue) * screenWidth + dragOffset)
            .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: tab)
            // ───────────────────────────────────────────────────────────
            // 🛡️ Tab-swipe rules (deliberate-only)
            //
            // Goal: a casual finger flick inside a chat / discover detail /
            // post body should NOT switch tabs. Switching tabs is a system-
            // level action; users should only invoke it intentionally.
            //
            // Rules:
            //   1. `minimumDistance: 30pt` — must drag at least 30pt before
            //      the gesture even starts being interpreted (was 12).
            //   2. **Predominantly horizontal**: |dx| > |dy| × 1.6 (was 1.2).
            //   3. **Edge-anchored**: drag must START within 60pt of the
            //      left or right screen edge. Mid-screen drags are ignored
            //      entirely. This is the iOS-native pattern (Settings,
            //      Mail) — page swipe lives at the edges, content gestures
            //      live in the middle.
            //   4. **Bail when a deeper view is active**: if `isDetailViewActive`
            //      is true (chat, post detail, etc.) OR `currentChatRoomId`
            //      is set, the user is in a pushed view and any swipe is
            //      meant for THAT view (back-swipe, swipe-to-reply), not
            //      for switching tabs.
            //   5. **Higher commit threshold**: 30% of screen width OR
            //      flick velocity > 400 pt/s (was 22% / 250).
            //   6. Existing nested-pager guard still applies.
            // ───────────────────────────────────────────────────────────
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .updating($dragOffset) { value, state, _ in
                        if NestedSwipeCoordinator.shared.isHandlingSwipe { return }
                        // Bail in deeper navigation contexts (chat open,
                        // post detail open, settings sheet up, etc.)
                        if FeedStateManager.shared.isDetailViewActive { return }
                        if DeepLinkRouter.shared.currentChatRoomId != nil { return }
                        // Must be predominantly horizontal (1.6× ratio)
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                        // Edge-anchored: only honour drags that START at an edge
                        let isLeftEdge = value.startLocation.x < 60
                        let isRightEdge = value.startLocation.x > screenWidth - 60
                        guard isLeftEdge || isRightEdge else { return }
                        // Reserve the left edge of Home for the RavenShot open gesture
                        if tab == .home && isLeftEdge && value.translation.width > 0 { return }
                        // Rubber-band at edges, 1:1 finger tracking elsewhere
                        let tabIndex = CGFloat(tab.rawValue)
                        if (tabIndex == 0 && value.translation.width > 0) ||
                           (tabIndex == CGFloat(AppTab.allCases.count - 1) && value.translation.width < 0) {
                            state = value.translation.width * 0.3 // Rubber-band
                        } else {
                            state = value.translation.width // 1:1 finger tracking
                        }
                    }
                    .onEnded { value in
                        if NestedSwipeCoordinator.shared.isHandlingSwipe { return }
                        if FeedStateManager.shared.isDetailViewActive { return }
                        if DeepLinkRouter.shared.currentChatRoomId != nil { return }
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                        let isLeftEdge = value.startLocation.x < 60
                        let isRightEdge = value.startLocation.x > screenWidth - 60
                        guard isLeftEdge || isRightEdge else { return }
                        if tab == .home && isLeftEdge && value.translation.width > 0 { return }

                        // Commit on 30% of screen OR a real flick (>400 pt/s)
                        let threshold = screenWidth * 0.30
                        let velocity = value.predictedEndTranslation.width - value.translation.width

                        if value.translation.width < -threshold || velocity < -400 {
                            if let next = AppTab(rawValue: tab.rawValue + 1) {
                                Haptics.light()
                                tab = next
                            }
                        } else if value.translation.width > threshold || velocity > 400 {
                            if let prev = AppTab(rawValue: tab.rawValue - 1) {
                                Haptics.light()
                                tab = prev
                            }
                        }
                    }
            )
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - Simple Tab Pager (for single content that changes)
/// A simpler pager for when content is provided externally and changes based on tab
struct SimpleTabPager<Content: View>: View {
    @Binding var tab: AppTab
    let content: Content
    
    @GestureState private var dragX: CGFloat = 0
    
    init(tab: Binding<AppTab>, @ViewBuilder content: () -> Content) {
        _tab = tab
        self.content = content()
    }
    
    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .offset(x: dragX)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .updating($dragX) { value, state, _ in
                            if abs(value.translation.width) > abs(value.translation.height) {
                                state = value.translation.width * 0.3 // Slight resistance
                            }
                        }
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            
                            let threshold: CGFloat = 70
                            let velocity = value.predictedEndTranslation.width - value.translation.width
                            
                            if value.translation.width < -threshold || velocity < -300 {
                                if let next = AppTab(rawValue: tab.rawValue + 1) {
                                    Haptics.light()
                                    tab = next
                                }
                            } else if value.translation.width > threshold || velocity > 300 {
                                if let prev = AppTab(rawValue: tab.rawValue - 1) {
                                    Haptics.light()
                                    tab = prev
                                }
                            }
                        }
                )
        }
    }
}
