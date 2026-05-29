//
//  NestedSwipeCoordinator.swift
//  RAVEN
//
//  Shared flag the nested swipe gestures use to claim ownership of an
//  in-flight drag so the root TabPager doesn't also switch tabs. Was
//  bundled with the Phase-4 WIP and got reverted out alongside the
//  rest of the navigation work; reintroduced standalone here.
//

import Foundation

@MainActor
final class NestedSwipeCoordinator {
    static let shared = NestedSwipeCoordinator()
    private init() {}

    /// `true` while a child carousel / horizontal pager is actively
    /// being dragged. Parent pagers check this in their own
    /// `DragGesture.onChanged` and bail out if set, so we don't get
    /// two simultaneous swipes fighting over the same touch.
    var isHandlingSwipe: Bool = false
}
