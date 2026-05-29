//
//  VideoPrefetcher.swift
//  RAVEN
//
//  2026-05-16 — round 12.
//
//  Tiny LRU that prewarms feed videos so the first-frame appears
//  the moment the user scrolls onto a card.
//
//  Why this exists:
//  Before today the feed's onAppear prefetch hook explicitly SKIPPED
//  video URLs (`!firstMedia.isVideo`) and only warmed image avatars
//  + the first still. That left video cards waiting for the moov-
//  atom round-trip + the first byte range when they came into view,
//  which the user reported as "video kheili dir miyad" (videos take
//  too long to appear). Tapping the cell didn't help — the player
//  still had to bootstrap from scratch.
//
//  The mechanism is the standard AVFoundation prewarm dance:
//    1. Build an `AVURLAsset` with the URL.
//    2. Ask AVFoundation to async-load `.playable` + `.duration`,
//       which triggers an HTTP range request for the moov atom and
//       parses it into memory.
//    3. Park the asset in an LRU so the next AVPlayer that opens
//       the same URL gets the warm asset (AVFoundation caches the
//       moov + the parsed track group at the URL level, so even
//       handing off to a different AVPlayerItem benefits).
//
//  The LRU is intentionally tiny (cap = 4) — videos are heavy and
//  we never want prewarmed bytes to evict the active player's own
//  cache window.

import Foundation
import AVFoundation

actor VideoPrefetcher {
    static let shared = VideoPrefetcher()

    /// Cap on how many concurrent prewarms we keep alive. Picked to
    /// match the feed's "look-ahead 4 cards" window — anything bigger
    /// is wasted bandwidth on cards the user will likely scroll past.
    private let maxConcurrent = 4

    /// LRU stack: most-recently-requested URL is at the end.
    private var lru: [(url: URL, asset: AVURLAsset)] = []

    private init() {}

    /// Fire-and-forget prewarm. Idempotent — calling twice on the
    /// same URL is a no-op (we just bump the URL to the front of the
    /// LRU). Skips local file URLs (already on disk).
    func prefetch(urls: [URL]) {
        for url in urls {
            schedule(url)
        }
    }

    private func schedule(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else { return }

        // Already prewarmed — promote to most-recent slot.
        if let idx = lru.firstIndex(where: { $0.url == url }) {
            let entry = lru.remove(at: idx)
            lru.append(entry)
            return
        }

        // Build a fresh asset and kick the moov-atom load. AVFoundation
        // is happy to hold onto the parsed metadata for the lifetime
        // of the AVURLAsset, so we keep a reference inside the LRU.
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        Task.detached(priority: .utility) {
            // iOS 16+ async load API; falls back gracefully on older
            // OSes via the synchronous-but-async-queueing variant.
            if #available(iOS 16.0, *) {
                _ = try? await asset.load(.isPlayable, .duration, .tracks)
            } else {
                let keys = ["playable", "duration", "tracks"]
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    asset.loadValuesAsynchronously(forKeys: keys) {
                        cont.resume()
                    }
                }
            }
        }

        lru.append((url: url, asset: asset))
        if lru.count > maxConcurrent {
            // Drop oldest entries — releasing the AVURLAsset reference
            // is what tells AVFoundation it can free the warmed bytes.
            lru.removeFirst(lru.count - maxConcurrent)
        }
    }

    /// Convenience used by code paths that just want to drop the
    /// whole cache (e.g. on logout, on memory warning).
    func purge() {
        lru.removeAll()
    }
}
