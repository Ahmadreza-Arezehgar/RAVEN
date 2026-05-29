//
//  FeedStoreBookmarkStubs.swift
//  RAVEN
//
//  `FeedVideoPlayer` (and the post bubble bookmark button) call into
//  `FeedStore.toggleBookmark(postId:)` / `isBookmarked(postId:)`. The
//  real persistence (UserDefaults-backed bookmark set) was removed in
//  the Phase-4 revert. Stub it on top of `UserDefaults` so toggles
//  survive app restarts even though no server sync is wired up.
//

import Foundation

extension FeedStore {
    private static let bookmarkDefaultsKey = "raven.bookmarkedPostIds.v1"

    /// Server-id slice of locally bookmarked posts. Read once at
    /// startup; mutations write back through to UserDefaults.
    private static var bookmarked: Set<String> {
        get {
            let stored = UserDefaults.standard.array(forKey: bookmarkDefaultsKey) as? [String] ?? []
            return Set(stored)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: bookmarkDefaultsKey)
        }
    }

    /// Whether the given post id is currently bookmarked by the user.
    func isBookmarked(postId: String) -> Bool {
        Self.bookmarked.contains(postId.components(separatedBy: "-loop-")[0])
    }

    /// Flip the bookmark state for the given post id. Returns the
    /// new "now-bookmarked" value so the caller can update its
    /// optimistic UI.
    @discardableResult
    func toggleBookmark(postId: String) -> Bool {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        var set = Self.bookmarked
        if set.contains(serverId) {
            set.remove(serverId)
            Self.bookmarked = set
            return false
        } else {
            set.insert(serverId)
            Self.bookmarked = set
            return true
        }
    }

    /// `FeedVideoPlayer` asks the store for the latest snapshot of a
    /// post (counts can change while the player is open). Walk every
    /// `@Published` array and return the first hit by `serverId`.
    func livePost(byId serverId: String) -> Post? {
        if let hit = mergedLocalPosts.first(where: { $0.serverId == serverId }) { return hit }
        if let hit = friendsPosts.first(where: { $0.serverId == serverId }) { return hit }
        if let hit = recommendedPosts.first(where: { $0.serverId == serverId }) { return hit }
        return nil
    }

    // MARK: - Save-offline / not-interested stubs
    //
    // The Phase-4 commit added local persistence + server sync for
    // "save to offline" and the "show fewer like this" tap. The revert
    // dropped them. Stub on top of UserDefaults so the FullscreenVideo
    // overflow menu still does *something* — the saved-for-offline list
    // is just a set of post ids; not-interested is recorded but not
    // surfaced anywhere else yet.

    private static let savedOfflineKey = "raven.savedOfflinePostIds.v1"
    private static let notInterestedKey = "raven.notInterestedPostIds.v1"

    private static var savedOfflineSet: Set<String> {
        get { Set(UserDefaults.standard.array(forKey: savedOfflineKey) as? [String] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: savedOfflineKey) }
    }

    @discardableResult
    func toggleSaveOffline(postId: String) -> Bool {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        var set = Self.savedOfflineSet
        if set.contains(serverId) {
            set.remove(serverId)
            Self.savedOfflineSet = set
            return false
        } else {
            set.insert(serverId)
            Self.savedOfflineSet = set
            return true
        }
    }

    func markNotInterested(postId: String) {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        var set = Set(UserDefaults.standard.array(forKey: Self.notInterestedKey) as? [String] ?? [])
        set.insert(serverId)
        UserDefaults.standard.set(Array(set), forKey: Self.notInterestedKey)
    }
}

// MARK: - PostMedia.isVideo helper
//
// `PostMedia` ships a `mediaType: String?` ("image" | "video") and
// callers used to ask `media.isVideo`. The convenience accessor lived
// in the Phase-4 commit; restore it as a small extension.
extension PostMedia {
    var isVideo: Bool { (mediaType ?? "image").lowercased() == "video" }
}
