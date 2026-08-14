import SwiftUI
import ImageIO

// MARK: - Image Cache (RAM-only, NSCache)
/// Shared singleton with LRU eviction. NSCache auto-purges under memory pressure.

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    
    private let cache = NSCache<NSURL, UIImage>()
    
    private init() {
        cache.countLimit = 150                      // Max ~150 images
        cache.totalCostLimit = 100 * 1024 * 1024    // ~100 MB
    }
    
    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }
    
    func store(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
    
    /// ⚡ PERF: Prefetch images for upcoming feed cards so they're in cache before scroll.
    /// Fire-and-forget — failures are silently ignored (the card will load on its own).
    func prefetch(urls: [URL]) {
        for url in urls {
            guard image(for: url) == nil else { continue }  // Skip if already cached
            Task.detached(priority: .utility) {
                do {
                    let (data, response) = try await Self.imageSession.data(from: url)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else { return }
                    
                    let prepared = await Task.detached(priority: .utility) {
                        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                        guard let source = CGImageSourceCreateWithData(data as CFData, opts) else { return nil as UIImage? }
                        let downOpts: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1024
                        ]
                        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, downOpts as CFDictionary) else { return nil as UIImage? }
                        return UIImage(cgImage: cg)
                    }.value
                    
                    if let img = prepared {
                        self.store(img, for: url)
                    }
                } catch {
                    // Prefetch failure is non-critical — card will load normally
                }
            }
        }
    }
    
    // ⚡ PERF: Dedicated session for image downloads — matches NetworkService config
    // (cellular access, constrained network, waitsForConnectivity)
    // Lives here (non-generic class) because Swift forbids static stored properties in generic types.
    static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 6  // More parallel image downloads
        return URLSession(configuration: RavenRuntimePolicy.protectForXCTest(config))
    }()
}

// MARK: - CachedAsyncImage
/// Drop-in replacement for `AsyncImage` that caches decoded images in RAM.
/// Eliminates the re-decode-on-every-scroll problem that causes frame drops.

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    
    var body: some View {
        Group {
            // 1. Synchronous memory cache check — prevents placeholder flash during scroll
            if let url = url, let cachedImage = ImageCache.shared.image(for: url) {
                content(Image(uiImage: cachedImage))
            }
            // 2. Just downloaded
            else if let uiImage {
                content(Image(uiImage: uiImage))
            }
            // 3. Not cached — download
            else {
                placeholder()
                    .task(id: url) {
                        await loadImage()
                    }
            }
        }
        // Bug 10 fix: Clear stale image when URL changes (cell recycled during scroll)
        // Without this, the previous image stays visible ("ghosting") until the new one loads
        .onChange(of: url) { _, _ in
            uiImage = nil
        }
    }
    
    private func loadImage() async {
        guard let url, !isLoading else { return }

        // 1. Check RAM cache
        if let cached = ImageCache.shared.image(for: url) {
            self.uiImage = cached
            return
        }

        isLoading = true
        defer { isLoading = false }

        // 🔴 Bug fix (2026-05-15): the previous implementation rejected
        // every file:// URL because URLSession returns a plain
        // `URLResponse` (not `HTTPURLResponse`) for local file loads —
        // the `as? HTTPURLResponse` cast failed and the method bailed
        // out before decoding. Outgoing image bubbles store their
        // bytes locally first via `attachmentsDirectory/<id>.jpg`, so
        // the local-cache hit was being silently dropped and the user
        // saw the gray "photo" placeholder for every photo they sent.
        //
        // Split the read into two paths: file:// → load straight off
        // disk; everything else → keep the existing HTTP path with
        // auth headers + status check.
        if url.isFileURL {
            await loadImageFromFile(at: url)
            return
        }

        do {
            var request = URLRequest(url: url)
            // Add auth header for internal media URLs
            if let (token, _) = await KeychainService.shared.getToken(),
               url.host == AppConfig.mediaURL(from: "/")?.host {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await ImageCache.imageSession.data(for: request)

            guard !Task.isCancelled,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }

            // ✅ Perf fix: ImageIO downsampling — never loads full-res bitmap into RAM.
            // A 48MP camera photo would consume ~180MB uncompressed; this path reads
            // only the bytes needed for a 1024px thumbnail.
            if let finalImage = await downsample(data: data) {
                ImageCache.shared.store(finalImage, for: url)
                self.uiImage = finalImage
            }
        } catch {
            // Network error — leave placeholder visible
        }
    }

    /// Local-file fast path. Reads the data off disk and runs the
    /// same ImageIO downsample so a 48MP capture doesn't park
    /// uncompressed in RAM. Cancellation-aware.
    private func loadImageFromFile(at url: URL) async {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !Task.isCancelled else { return }
            if let finalImage = await downsample(data: data) {
                ImageCache.shared.store(finalImage, for: url)
                self.uiImage = finalImage
            }
        } catch {
            // Disk read error — leave placeholder visible.
            #if DEBUG
            print("⚠️ [CachedAsyncImage] Failed to read local file at \(url.path): \(error.localizedDescription)")
            #endif
        }
    }

    /// Shared ImageIO thumbnail step used by both the network and
    /// file paths. Caps the long edge at 1024px so chat scroll stays
    /// smooth even with phone-camera-quality originals.
    private func downsample(data: Data) async -> UIImage? {
        return await Task.detached(priority: .userInitiated) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil as UIImage? }
            let downsampleOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil as UIImage? }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

// MARK: - Convenience Init (matches AsyncImage API)

extension CachedAsyncImage where Placeholder == ProgressView<EmptyView, EmptyView> {
    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.url = url
        self.content = content
        self.placeholder = { ProgressView() }
    }
}
