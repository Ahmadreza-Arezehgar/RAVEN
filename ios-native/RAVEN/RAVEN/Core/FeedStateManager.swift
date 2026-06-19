import SwiftUI

// MARK: - Shell Chrome State (Shared Singleton)
/// Tracks transient shell-chrome state shared across the tab shell:
/// whether the top header + bottom bar are hidden on scroll, and whether a
/// pushed detail view should suppress the tab bar entirely.
///
/// (Formerly drove the social feed's segment control — the feed was removed in
/// the messenger pivot, so this now only governs chrome visibility.)
@Observable
final class FeedStateManager {
    static let shared = FeedStateManager()

    /// Whether chrome (top header + bottom bar) should be hidden due to scroll
    var isChromeHidden: Bool = false

    /// Whether a detail view is pushed — hides tab bar entirely
    var isDetailViewActive: Bool = false

    /// Last scroll offset for direction detection
    @ObservationIgnored var lastScrollOffset: CGFloat = 0

    /// Last time chrome visibility was changed (for debounce)
    @ObservationIgnored var lastChromeChange: Date = .distantPast

    private init() {}
}
