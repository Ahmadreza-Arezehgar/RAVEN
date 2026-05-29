//
//  RavenShotStubs.swift
//  RAVEN
//
//  Stubs for the RavenShot map APIs the Phase-4 commit added and
//  the revert dropped: `Post.showOnRavenShot` (whether the post
//  opted into the social map) and
//  `PostRepository.getMeshPostsForRavenShot()` (mesh-delivered
//  posts that should appear on the map).
//

import Foundation

// `Post.showOnRavenShot` is now a stored property on Post (added in
// Models/Post.swift). No extension needed.

extension PostRepository {
    /// Mesh-delivered posts the user has cached locally that are
    /// flagged for the RavenShot map. Stub: returns an empty array
    /// so `RavenShotStore` builds and the map shows no pins.
    func getMeshPostsForRavenShot() async throws -> [Post] {
        []
    }
}
