import SwiftUI

// MARK: - Nested Swipe Coordinator
/// Shared state so a nested horizontal pager can claim a horizontal drag and
/// prevent the root TabPager from also switching tabs on the same gesture.
@MainActor
@Observable
final class NestedSwipeCoordinator {
    static let shared = NestedSwipeCoordinator()
    private init() {}
    var isHandlingSwipe: Bool = false
}

// MARK: - Tab Pager (Horizontal Swipe Between Tabs)
//
// MESSENGER PIVOT (2026-06): two tabs — Chats + Settings.
struct TabPager<ChatsContent: View, SettingsContent: View>: View {
    @Binding var tab: AppTab

    let chatsView: ChatsContent
    let settingsView: SettingsContent

    @GestureState private var dragOffset: CGFloat = 0

    init(
        tab: Binding<AppTab>,
        @ViewBuilder chats: () -> ChatsContent,
        @ViewBuilder settings: () -> SettingsContent
    ) {
        _tab = tab
        self.chatsView = chats()
        self.settingsView = settings()
    }

    var body: some View {
        GeometryReader { geo in
            let screenWidth = geo.size.width

            HStack(spacing: 0) {
                chatsView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.messages)

                settingsView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.account)
            }
            .offset(x: -CGFloat(tab.rawValue) * screenWidth + dragOffset)
            .animation(.interpolatingSpring(stiffness: 320, damping: 32), value: tab)
            // Edge-anchored, deliberate-only tab swipe (see history). Bails in
            // chat / detail contexts so back-swipe & swipe-to-reply win.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .updating($dragOffset) { value, state, _ in
                        if NestedSwipeCoordinator.shared.isHandlingSwipe { return }
                        if FeedStateManager.shared.isDetailViewActive { return }
                        if DeepLinkRouter.shared.currentChatRoomId != nil { return }
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                        let isLeftEdge = value.startLocation.x < 60
                        let isRightEdge = value.startLocation.x > screenWidth - 60
                        guard isLeftEdge || isRightEdge else { return }
                        let tabIndex = CGFloat(tab.rawValue)
                        if (tabIndex == 0 && value.translation.width > 0) ||
                           (tabIndex == CGFloat(AppTab.allCases.count - 1) && value.translation.width < 0) {
                            state = value.translation.width * 0.3 // rubber-band at the ends
                        } else {
                            state = value.translation.width
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
