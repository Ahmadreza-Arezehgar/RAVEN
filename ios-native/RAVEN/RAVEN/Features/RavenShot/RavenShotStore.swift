//
//  RavenShotStore.swift
//  RAVEN
//
//  Data store for Raven Shot social map.
//  Aggregates location-enabled Posts, Echoes, and Clubs
//  with privacy-aware visibility filtering.
//

import Foundation
import CoreLocation

// MARK: - Raven Shot Store

@MainActor @Observable
final class RavenShotStore {
    static let shared = RavenShotStore()
    
    var items: [RavenShotItem] = []
    var isLoading = false
    var selectedItem: RavenShotItem?
    var errorMessage: String?
    
    private let networkService = NetworkService.shared
    
    private init() {}
    
    // MARK: - Load Map Items
    
    /// Fetch all location-enabled content for the social map.
    /// Combines posts from the API with local Echo and Club data.
    func loadItems(near coordinate: CLLocationCoordinate2D? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        
        var allItems: [RavenShotItem] = []
        
        // 1. Fetch posts with Raven Shot flag from API
        do {
            let posts = try await fetchRavenShotPosts(near: coordinate)
            let postItems = posts.compactMap { RavenShotItem.from(post: $0) }
            allItems.append(contentsOf: postItems)
            #if DEBUG
            print("📍 [RavenShot] Loaded \(postItems.count) posts for map")
            #endif
        } catch {
            #if DEBUG
            print("❌ [RavenShot] Failed to load posts: \(error)")
            #endif
            errorMessage = "Failed to load map content"
        }

        // 1b. 🌐 MESH-ONLY: include locally-stored mesh posts that were
        // received via BLE broadcast. These have `showOnRavenShot == true`
        // and lat/lng populated by the sender (now wired via
        // `MeshPostEnvelope.latitude/longitude`). They appear on the map
        // even with no internet — the offline social-map story.
        if let meshPosts = try? await PostRepository.shared.getMeshPostsForRavenShot() {
            let meshItems = meshPosts.compactMap { RavenShotItem.from(post: $0) }
            // De-dupe against server-fetched posts (mesh + server can both
            // carry the same post id once it's bridged).
            let knownIds = Set(allItems.map(\.id))
            let newOnes = meshItems.filter { !knownIds.contains($0.id) }
            allItems.append(contentsOf: newOnes)
            #if DEBUG
            print("📍 [RavenShot] Added \(newOnes.count) mesh-only posts to map")
            #endif
        }
        
        // 2. Add Echoes with location data
        // Ensure echoes are loaded if store is empty
        if EchoStore.shared.receivedEchoes.isEmpty {
            await EchoStore.shared.loadEchoes()
        }
        let echoItems = EchoStore.shared.receivedEchoes
            .compactMap { RavenShotItem.from(echo: $0) }
        allItems.append(contentsOf: echoItems)
        #if DEBUG
        print("📍 [RavenShot] Added \(echoItems.count) echoes to map")
        #endif
        
        // 3. Add EVERY active club we know about, not just our own.
        //
        // The ClubRepository stores every club we've ever heard a `clubPing`
        // from via BLE mesh, plus our own. Showing all of them on the map
        // turns RavenShot into a real social map: walk past a venue with
        // someone running a club, see it appear as a pin, tap to join.
        //
        // Pin position is the CLUB CENTROID (mean of all known member
        // coordinates). This is stable across membership changes — unlike
        // the previous implementation, which moved as members joined/left.
        do {
            let allClubs = try await ClubRepository.shared.getActiveClubs()
            for club in allClubs {
                let members = (try? await ClubRepository.shared.getMembers(clubId: club.id)) ?? []
                guard let centroid = clubCentroid(members: members) else { continue }
                let isOwn = (club.id == ClubStore.shared.activeClub?.id)
                if let item = RavenShotItem.from(
                    club: club,
                    creatorLocation: centroid,
                    creatorName: club.name + (isOwn ? " · You" : ""),
                    creatorAvatar: nil
                ) {
                    allItems.append(item)
                }
            }
            #if DEBUG
            print("📍 [RavenShot] Added \(allClubs.count) active clubs to map")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ [RavenShot] getActiveClubs failed: \(error)")
            #endif
        }
        
        // 4. Sort by timestamp (newest first)
        allItems.sort { $0.timestamp > $1.timestamp }
        
        items = allItems
        isLoading = false
    }
    
    // MARK: - Refresh
    
    func refresh() async {
        let location = LocationManager.shared.lastLocation
        await loadItems(near: location?.coordinate)
    }
    
    // MARK: - API Fetch
    
    /// Fetch posts marked for Raven Shot from the server.
    private func fetchRavenShotPosts(near coordinate: CLLocationCoordinate2D?) async throws -> [Post] {
        var path = "/api/posts/raven-shot/feed?limit=100"
        
        if let coord = coordinate {
            path += "&latitude=\(coord.latitude)&longitude=\(coord.longitude)"
        }
        
        do {
            let posts: [Post] = try await networkService.get(path: path)
            return posts
        } catch {
            // Fallback: use existing feed posts that have location + raven shot flag
            #if DEBUG
            print("⚠️ [RavenShot] API fallback — using cached feed posts")
            #endif
            let allPosts = FeedStore.shared.mergedLocalPosts + FeedStore.shared.friendsPosts
            return allPosts.filter { post in
                post.latitude != nil &&
                post.longitude != nil &&
                post.showOnRavenShot == true
            }
        }
    }
    
    // MARK: - Selection
    
    func select(_ item: RavenShotItem?) {
        selectedItem = item
    }
    
    func clearSelection() {
        selectedItem = nil
    }

    // MARK: - Helpers

    /// Compute a stable centroid for a club's members. Prefers precise
    /// GPS when available; falls back to the H3-cell centre when not.
    /// Returns nil when no member has any usable coordinate.
    private func clubCentroid(members: [ClubMember]) -> CLLocationCoordinate2D? {
        var lats: [Double] = []
        var lngs: [Double] = []
        for m in members {
            if let lat = m.preciseLat, let lng = m.preciseLng {
                lats.append(lat); lngs.append(lng)
            } else if let cell = m.h3Cell {
                let c = H3Lite.cellToLatLng(cell)
                lats.append(c.lat); lngs.append(c.lng)
            }
        }
        guard !lats.isEmpty else { return nil }
        let avgLat = lats.reduce(0, +) / Double(lats.count)
        let avgLng = lngs.reduce(0, +) / Double(lngs.count)
        return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLng)
    }
}
