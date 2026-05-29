//
//  AvatarCacheService.swift
//  RAVEN
//
//  Persistent on-disk cache for user avatars + group avatars so the
//  app renders identities correctly when there is no internet at all.
//
//  Why this exists
//  ───────────────
//  Conversations + messages already survive offline (SQLCipher),
//  message attachments survive offline (`MediaCacheService` writes to
//  `Documents/attachments/`), but avatar bytes were relying on
//  `URLCache.shared`. URLCache honours HTTP `Cache-Control` headers
//  which our server does not always set, so on a cold launch with no
//  network the AsyncImage spinners would just stay forever.
//
//  This service pins avatar bytes to `Documents/avatars/<sha>.bin`
//  so they're recoverable from disk regardless of HTTP cache state.
//  Total cap: 100 MB (rough rule: 100k avatars at average ~1 KB
//  thumbnail; way more headroom than the social graph ever reaches).
//
//  Threading model
//  ───────────────
//  `actor` so concurrent reads from many SwiftUI views serialise on
//  one source of truth. The disk writes use Foundation's atomic
//  `Data.write(to:options:.atomic)` so a partial write can never
//  produce a half-decoded image.
//

import Foundation
import UIKit

actor AvatarCacheService {
    static let shared = AvatarCacheService()

    /// Where avatars live on disk. Created lazily on first use.
    private let directoryURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Hard cap on total cache size in bytes. Older files are
    /// LRU-evicted past this threshold by a periodic prune.
    private let maxCacheBytes: UInt64 = 100 * 1024 * 1024

    /// Per-URL in-flight gate so two views asking for the same avatar
    /// share a single network round trip instead of racing.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    /// Fast in-process memory cache so repeat reads don't pay the
    /// disk-decode cost. Bounded by `NSCache` to avoid growing
    /// unbounded across long sessions.
    private let memoryCache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 256          // ~social graph upper bound
        c.totalCostLimit = 32 * 1024 * 1024  // ~32 MB
        return c
    }()

    private init() {}

    // MARK: - Public API

    /// Returns the avatar `UIImage` for `url`, preferring (in order):
    ///   1. memory cache (instant, no I/O)
    ///   2. disk cache (`Documents/avatars/<sha>.bin`, survives reboot)
    ///   3. network fetch (best-effort; nil on failure)
    /// Concurrent calls for the same URL share a single download.
    func image(for url: URL) async -> UIImage? {
        // 1) memory
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }
        // 2) disk
        let path = filePath(for: url)
        if let data = try? Data(contentsOf: path),
           let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: url as NSURL,
                                  cost: data.count)
            return image
        }
        // 3) network — coalesce in-flight requests
        if let task = inFlight[url] {
            return await task.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.fetchAndCache(url)
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }

    /// Force-evict an avatar (e.g. when the user changes their photo).
    /// The next `image(for:)` will re-download.
    func invalidate(_ url: URL) {
        memoryCache.removeObject(forKey: url as NSURL)
        try? FileManager.default.removeItem(at: filePath(for: url))
    }

    /// Drop everything — used on sign-out so the next user doesn't
    /// see the previous user's social-graph avatars.
    func wipe() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: directoryURL)
        try? FileManager.default.createDirectory(at: directoryURL,
                                                  withIntermediateDirectories: true)
    }

    /// Best-effort prune to stay under `maxCacheBytes`. Walks the
    /// directory by oldest-modified-first and deletes until under
    /// cap. Cheap to call once per launch.
    func prune() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentAccessDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: directoryURL,
                                                       includingPropertiesForKeys: keys,
                                                       options: .skipsHiddenFiles) else { return }
        var totalSize: UInt64 = 0
        var entries: [(url: URL, accessed: Date, size: UInt64)] = []
        for f in files {
            let vals = try? f.resourceValues(forKeys: Set(keys))
            let size = UInt64(vals?.totalFileAllocatedSize ?? 0)
            totalSize += size
            entries.append((f, vals?.contentAccessDate ?? .distantPast, size))
        }
        guard totalSize > maxCacheBytes else { return }
        // Oldest-accessed first → evict to under cap with 10% headroom.
        entries.sort { $0.accessed < $1.accessed }
        let target = UInt64(Double(maxCacheBytes) * 0.9)
        for entry in entries {
            if totalSize <= target { break }
            try? fm.removeItem(at: entry.url)
            totalSize -= entry.size
        }
    }

    // MARK: - Internals

    /// SHA-256 prefix of the URL → disk file. Stable across launches
    /// (same URL always lands in the same path), so we can probe the
    /// disk without an index. We use `.bin` (not `.jpg`) because the
    /// server may serve PNG / WebP / JPEG and `UIImage(data:)` is
    /// happy with any of them.
    private func filePath(for url: URL) -> URL {
        let hash = AvatarCacheService.sha256Hex(url.absoluteString)
        return directoryURL.appendingPathComponent("\(hash).bin", isDirectory: false)
    }

    private func fetchAndCache(_ url: URL) async -> UIImage? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        // We're our own cache — let URLSession not duplicate work.
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = UIImage(data: data) else {
            return nil
        }

        let path = filePath(for: url)
        try? data.write(to: path, options: .atomic)
        memoryCache.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }

    private static func sha256Hex(_ s: String) -> String {
        // Self-contained SHA-256 via CommonCrypto so we don't need
        // to import CryptoKit just for this module's hashing.
        let bytes = Array(s.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeBufferPointer { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(bytes.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// SHA-256 imports
import CommonCrypto
