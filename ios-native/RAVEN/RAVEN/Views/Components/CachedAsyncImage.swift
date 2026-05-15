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
        
        // 2. Download
        do {
            var request = URLRequest(url: url)
            // Add auth header for internal media URLs
            if let (token, _) = await KeychainService.shared.getToken(),
               url.host == AppConfig.mediaURL(from: "/")?.host {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard !Task.isCancelled,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }
            
            // ✅ Perf fix: ImageIO downsampling — never loads full-res bitmap into RAM.
            // A 48MP camera photo would consume ~180MB uncompressed; this path reads
            // only the bytes needed for a 1024px thumbnail.
            let preparedImage = await Task.detached(priority: .userInitiated) {
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
            
            guard let finalImage = preparedImage else { return }
            
            // 3. Cache + display
            ImageCache.shared.store(finalImage, for: url)
            self.uiImage = finalImage
        } catch {
            // Network error — leave placeholder visible
        }
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
