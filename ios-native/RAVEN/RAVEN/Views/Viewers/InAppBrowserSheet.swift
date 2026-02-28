import SwiftUI

// MARK: - In-App Browser Sheet (Liquid Glass 75%)
struct InAppBrowserSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    
    @State private var isLoading = true
    @State private var progress: Double = 0
    @State private var currentURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var showCopiedToast = false
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            headerView
            
            // MARK: - Address Bar
            addressBarView
            
            // MARK: - Progress Bar
            if isLoading {
                ProgressView(value: progress)
                    .tint(.blue)
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)
            }
            
            // MARK: - Web Content
            WebView(
                url: url,
                isLoading: $isLoading,
                progress: $progress,
                currentURL: $currentURL,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                copiedToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
    
    // MARK: - Header View
    private var headerView: some View {
        HStack(spacing: 12) {
            // Domain info
            VStack(alignment: .leading, spacing: 2) {
                Text(currentURL?.host ?? url.host ?? "Link")
                    .font(.headline)
                    .lineLimit(1)
                
                if isLoading {
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Secure connection")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            
            Spacer()
            
            // Open in Safari button
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                UIApplication.shared.open(currentURL ?? url)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                    Text("Open")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    
    // MARK: - Address Bar
    private var addressBarView: some View {
        HStack(spacing: 10) {
            // Lock icon
            Image(systemName: currentURL?.scheme == "https" ? "lock.fill" : "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // URL
            Text(displayURL)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            // Copy button
            Button {
                UIPasteboard.general.string = (currentURL ?? url).absoluteString
                let impact = UINotificationFeedbackGenerator()
                impact.notificationOccurred(.success)
                
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showCopiedToast = true
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showCopiedToast = false
                    }
                }
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    
    // MARK: - Copied Toast
    private var copiedToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Copied to clipboard")
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        .padding(.bottom, 24)
    }
    
    // MARK: - Helpers
    private var displayURL: String {
        let urlToDisplay = currentURL ?? url
        var components = URLComponents(url: urlToDisplay, resolvingAgainstBaseURL: false)
        components?.scheme = nil
        let path = components?.string ?? urlToDisplay.absoluteString
        
        // Remove leading "//" and trailing "/"
        var cleaned = path
        if cleaned.hasPrefix("//") {
            cleaned = String(cleaned.dropFirst(2))
        }
        if cleaned.hasSuffix("/") {
            cleaned = String(cleaned.dropLast())
        }
        
        // Truncate if too long
        if cleaned.count > 50 {
            return String(cleaned.prefix(47)) + "..."
        }
        return cleaned
    }
}

#Preview {
    InAppBrowserSheet(url: URL(string: "https://apple.com") ?? URL(fileURLWithPath: "/"))
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        .presentationBackground(.ultraThinMaterial)
}
