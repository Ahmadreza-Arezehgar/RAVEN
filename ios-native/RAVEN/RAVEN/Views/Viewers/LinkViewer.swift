import SwiftUI

// Note: InAppBrowserSheet, WebView, URL extension, and String.firstURL are defined elsewhere

// MARK: - Link Preview Card
struct LinkPreviewCard: View {
    let url: URL
    var onTap: (() -> Void)? = nil
    
    @State private var title: String?
    @State private var domain: String?
    @State private var imageURL: URL?
    @State private var isLoading = true
    
    var body: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            onTap?()
        } label: {
            HStack(spacing: 10) {
                // Thumbnail
                if let imageURL = imageURL {
                    AsyncImage(url: imageURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        placeholderIcon
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    placeholderIcon
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    if isLoading {
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(title ?? url.host ?? "Link")
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        
                        Text(domain ?? url.host ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 220)
        .task {
            await fetchMetadata()
        }
    }
    
    private var placeholderIcon: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.blue.opacity(0.1))
            .frame(width: 48, height: 48)
            .overlay {
                Image(systemName: "link")
                    .foregroundStyle(.blue)
            }
    }
    
    private func fetchMetadata() async {
        defer { isLoading = false }
        
        domain = url.host
        
        // ⚡ FIX: Download first 64KB in one shot on a background thread.
        // Previously streamed byte-by-byte on @MainActor, causing 65,536 context
        // switches that froze scrolling and spiked CPU to 100%.
        do {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            
            let data = try await Task.detached(priority: .background) {
                let (data, _) = try await URLSession.shared.data(for: request)
                return data
            }.value
            
            if let html = String(data: data, encoding: .utf8) {
                // Extract title from <title> tag
                if let titleStart = html.range(of: "<title>"),
                   let titleEnd = html[titleStart.upperBound...].range(of: "</title>") {
                    title = String(html[titleStart.upperBound..<titleEnd.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                // Extract og:image
                if let ogImagePattern = html.range(of: "og:image\" content=\""),
                   let contentEnd = html[ogImagePattern.upperBound...].range(of: "\"") {
                    let imageString = String(html[ogImagePattern.upperBound..<contentEnd.lowerBound])
                    imageURL = URL(string: imageString)
                }
            }
        } catch {
            // Silently fail - show fallback UI
        }
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 20) {
        LinkPreviewCard(url: URL(string: "https://apple.com") ?? URL(fileURLWithPath: "/"))
    }
    .padding()
}

