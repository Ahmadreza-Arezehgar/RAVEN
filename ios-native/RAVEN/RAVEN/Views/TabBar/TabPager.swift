import SwiftUI

// MARK: - Tab Pager (Horizontal Swipe Between Tabs)
/// A proper pager that hosts multiple tab views and allows swiping between them
struct TabPager<FeedContent: View, DiscoverContent: View, MessagesContent: View, AccountContent: View>: View {
    @Binding var tab: AppTab
    
    // Tab content providers (concrete types, no AnyView)
    let feedView: FeedContent
    let discoverView: DiscoverContent
    let messagesView: MessagesContent
    let accountView: AccountContent
    
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
        TabView(selection: $tab) {
            feedView
                .toolbar(.hidden, for: .tabBar)
                .tag(AppTab.home)
            
            messagesView
                .toolbar(.hidden, for: .tabBar)
                .tag(AppTab.messages)
            
            discoverView
                .toolbar(.hidden, for: .tabBar)
                .tag(AppTab.discover)
            
            accountView
                .toolbar(.hidden, for: .tabBar)
                .tag(AppTab.account)
        }
        // Swiping between root tabs containing NavigationStacks causes
        // UIKit layout crashes (NSInternalInconsistencyException) when keyboards
        // and large titles are involved. Standard iOS behavior is non-swipeable root tabs.
        .toolbar(.hidden, for: .tabBar)
        .toolbarVisibility(.hidden, for: .tabBar)
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
