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
// OBSIDIAN REDESIGN (2026-08): four pages in AppTab.rawValue order —
// Contacts · Chats · Network · Settings.
struct TabPager<ContactsContent: View, ChatsContent: View, NetworkContent: View, SettingsContent: View>: View {
    @Binding var tab: AppTab

    let contactsView: ContactsContent
    let chatsView: ChatsContent
    let networkView: NetworkContent
    let settingsView: SettingsContent

    @Environment(\.layoutDirection) private var layoutDirection

    @GestureState private var dragOffset: CGFloat = 0

    init(
        tab: Binding<AppTab>,
        @ViewBuilder contacts: () -> ContactsContent,
        @ViewBuilder chats: () -> ChatsContent,
        @ViewBuilder network: () -> NetworkContent,
        @ViewBuilder settings: () -> SettingsContent
    ) {
        _tab = tab
        self.contactsView = contacts()
        self.chatsView = chats()
        self.networkView = network()
        self.settingsView = settings()
    }

    var body: some View {
        GeometryReader { geo in
            let screenWidth = geo.size.width
            // RTL: SwiftUI mirrors the HStack's visual order, so the page-offset
            // must move the opposite physical direction. dirSign mirrors the
            // page offset (-1 under RTL) while the live dragOffset stays physical
            // so the content keeps tracking the finger.
            let isRTL = layoutDirection == .rightToLeft
            let dirSign: CGFloat = isRTL ? -1 : 1

            HStack(spacing: 0) {
                contactsView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.contacts)

                chatsView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.messages)

                networkView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.network)

                settingsView
                    .frame(width: screenWidth, height: geo.size.height)
                    .tag(AppTab.account)
            }
            .offset(x: dirSign * (-CGFloat(tab.rawValue) * screenWidth) + dragOffset)
            .animation(DS.tabSpring, value: tab)
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
                        // Physical drag that runs past an end: in LTR that's a
                        // right-drag at tab 0 / left-drag at the last tab; under
                        // RTL the offending direction is mirrored (dirSign).
                        if (tabIndex == 0 && value.translation.width * dirSign > 0) ||
                           (tabIndex == CGFloat(AppTab.allCases.count - 1) && value.translation.width * dirSign < 0) {
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
                        // Map physical drag to tab steps. In LTR a left-drag
                        // (negative) advances to the next tab; under RTL the
                        // next tab lives the other way, so mirror translation +
                        // velocity by dirSign before the +1/-1 decision.
                        let dirTranslation = value.translation.width * dirSign
                        let dirVelocity = velocity * dirSign

                        if dirTranslation < -threshold || dirVelocity < -400 {
                            if let next = AppTab(rawValue: tab.rawValue + 1) {
                                Haptics.light()
                                tab = next
                            }
                        } else if dirTranslation > threshold || dirVelocity > 400 {
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
