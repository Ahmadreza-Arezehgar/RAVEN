import SwiftUI

// MARK: - Feed State Manager (Shared Singleton for Feed Segment Control)
/// Allows external components (like tab bar context menu) to control
/// which segment (Local/Friends) is displayed in the FeedView.
@Observable
final class FeedStateManager {
    static let shared = FeedStateManager()
    
    /// The currently selected feed tab/segment
    var selectedFeedTab: FeedTab = .local
    
    /// Triggers a feed refresh
    var shouldRefreshFeed: Bool = false
    
    /// Whether chrome (top header + bottom bar) should be hidden due to scroll
    var isChromeHidden: Bool = false
    
    /// Whether a detail view (PostDetail, etc.) is pushed — hides tab bar entirely
    var isDetailViewActive: Bool = false
    
    /// ✅ FIX Bug 13: Deep link post ID to navigate to from push notification
    @ObservationIgnored var deepLinkPostId: String? = nil
    
    /// Last scroll offset for direction detection
    @ObservationIgnored var lastScrollOffset: CGFloat = 0
    
    /// Last time chrome visibility was changed (for debounce)
    @ObservationIgnored var lastChromeChange: Date = .distantPast
    
    private init() {}
    
    /// Switch to local feed with haptic feedback
    func switchToLocal() {
        Haptics.selection()
        withAnimation(.spring(response: 0.3)) {
            selectedFeedTab = .local
        }
    }
    
    /// Switch to friends feed with haptic feedback
    func switchToFriends() {
        Haptics.selection()
        withAnimation(.spring(response: 0.3)) {
            selectedFeedTab = .friends
        }
    }
    
    /// Trigger a refresh of the current feed
    func triggerRefresh() {
        Haptics.light()
        shouldRefreshFeed = true
    }
}
