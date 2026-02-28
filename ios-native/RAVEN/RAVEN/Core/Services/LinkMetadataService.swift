import Foundation
import LinkPresentation

// MARK: - Link Metadata Model
struct LinkMetadata: Identifiable {
    let id: String
    let url: URL
    var title: String?
    var iconURL: URL?
    var imageURL: URL?
    var imageData: Data?
    var iconData: Data?
    
    init(url: URL) {
        self.id = url.absoluteString
        self.url = url
    }
    
    var domain: String {
        url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }
    
    var displayTitle: String {
        title ?? domain
    }
}

// MARK: - Link Metadata Service
@MainActor
final class LinkMetadataService: ObservableObject {
    static let shared = LinkMetadataService()
    
    @Published private(set) var cache: [String: LinkMetadata] = [:]
    @Published private(set) var loadingURLs: Set<String> = []
    
    private init() {}
    
    // MARK: - Fetch Metadata
    
    func fetchMetadata(for url: URL) async -> LinkMetadata {
        let key = url.absoluteString
        
        // Return cached if available
        if let cached = cache[key] {
            return cached
        }
        
        // Mark as loading
        loadingURLs.insert(key)
        
        defer {
            loadingURLs.remove(key)
        }
        
        var metadata = LinkMetadata(url: url)
        
        do {
            let provider = LPMetadataProvider()
            provider.timeout = 10
            
            let lpMetadata = try await provider.startFetchingMetadata(for: url)
            
            metadata.title = lpMetadata.title
            
            // Get image data
            if let imageProvider = lpMetadata.imageProvider {
                if let data = try? await loadImageData(from: imageProvider) {
                    metadata.imageData = data
                }
            }
            
            // Get icon data
            if let iconProvider = lpMetadata.iconProvider {
                if let data = try? await loadImageData(from: iconProvider) {
                    metadata.iconData = data
                }
            }
        } catch {
            #if DEBUG
            print("LinkMetadata fetch error: \(error)")
            #endif
        }
        
        // Cache result
        cache[key] = metadata
        
        return metadata
    }
    
    // MARK: - Helper
    
    private func loadImageData(from provider: NSItemProvider) async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
    
    // MARK: - Check Cache
    
    func getCached(for url: URL) -> LinkMetadata? {
        cache[url.absoluteString]
    }
    
    func isLoading(url: URL) -> Bool {
        loadingURLs.contains(url.absoluteString)
    }
    
    // MARK: - Clear Cache
    
    func clearCache() {
        cache.removeAll()
    }
}

// MARK: - URL Detection Helper
extension String {
    var detectedURLs: [URL] {
        // ⚡ Fast-path: skip expensive NSDataDetector if text doesn't look like it contains a URL
        guard self.contains("http://") || self.contains("https://") || self.contains("www.") || self.contains("raven://") else { return [] }
        
        // Bug 6 fix: Use static detector to avoid expensive re-allocation during scroll
        let matches = PerformanceConstants.linkDetector?.matches(in: self, options: [], range: NSRange(location: 0, length: utf16.count)) ?? []
        
        return matches.compactMap { match in
            guard let range = Range(match.range, in: self) else { return nil }
            let urlString = String(self[range])
            return URL(string: urlString)
        }
    }
    
    var containsURL: Bool {
        !detectedURLs.isEmpty
    }
    
    var firstURL: URL? {
        detectedURLs.first
    }
}
