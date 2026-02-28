import SwiftUI
import PDFKit

/// Presentation view for displaying PDF/Image in audio rooms
struct PresentationView: View {
    let asset: AudioRoomAsset
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black.opacity(0.95)
                    .ignoresSafeArea()
                
                // Content
                switch asset.type {
                case .image:
                    imageView(in: geometry)
                case .pdf:
                    pdfView
                }
                
                // Close hint
                VStack {
                    HStack {
                        Spacer()
                        
                        // File info badge
                        if let fileName = asset.fileName {
                            Text(fileName)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    .padding()
                    
                    Spacer()
                    
                    // Zoom hint
                    Text("Pinch to zoom")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.bottom, 20)
                }
            }
        }
    }
    
    // MARK: - Image View
    
    private func imageView(in geometry: GeometryProxy) -> some View {
        AsyncImage(url: URL(string: asset.url)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnification)
                    .gesture(drag)
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            scale = scale == 1.0 ? 2.0 : 1.0
                            offset = .zero
                        }
                    }
                    
            case .failure:
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 50))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Failed to load image")
                        .foregroundStyle(.white.opacity(0.5))
                }
                
            case .empty:
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                    
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - PDF View
    
    private var pdfView: some View {
        PDFViewer(url: URL(string: asset.url))
    }
    
    // MARK: - Gestures
    
    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification / lastScale
                lastScale = value.magnification
                scale *= delta
                scale = min(max(scale, 0.5), 4.0)
            }
            .onEnded { _ in
                lastScale = 1.0
                if scale < 1.0 {
                    withAnimation(.spring()) {
                        scale = 1.0
                        offset = .zero
                    }
                }
            }
    }
    
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }
}

// MARK: - PDF Viewer (UIKit wrapped)

struct PDFViewer: UIViewRepresentable {
    let url: URL?
    
    class Coordinator: NSObject {
        var isLoaded = false
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .black
        return pdfView
    }
    
    func updateUIView(_ pdfView: PDFView, context: Context) {
        guard let url = url, !context.coordinator.isLoaded else { return }
        context.coordinator.isLoaded = true
        
        // Bug 11 fix: load PDF with auth token (protected endpoints need Bearer token)
        Task {
            do {
                var request = URLRequest(url: url)
                if let (token, _) = await KeychainService.shared.getToken() {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                // Download to disk instead of loading into RAM (prevents OOM on large files)
                let (tempLocalUrl, _) = try await URLSession.shared.download(for: request)
                
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent(url.lastPathComponent)
                
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try? FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.moveItem(at: tempLocalUrl, to: tempURL)
                
                if let document = PDFDocument(url: tempURL) {
                    await MainActor.run {
                        pdfView.document = document
                    }
                }
            } catch {
                #if DEBUG
                print("❌ Failed to load PDF: \(error)")
                #endif
                context.coordinator.isLoaded = false // Allow retry on error
            }
        }
    }
}

// MARK: - Compact Presentation Card (for inline display in room)

struct PresentationCard: View {
    let asset: AudioRoomAsset
    @State private var showFullScreen = false
    
    var body: some View {
        Button {
            showFullScreen = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Preview
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                    
                    if asset.type == .image {
                        AsyncImage(url: URL(string: asset.url)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            ProgressView()
                        }
                        .clipped()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 32))
                            Text("PDF")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.white)
                    }
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // File name
                if let fileName = asset.fileName {
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                // Tap hint
                HStack {
                    Image(systemName: "hand.tap")
                    Text("Tap to view")
                }
                .font(.caption2)
                .foregroundStyle(.blue)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showFullScreen) {
            ZStack {
                PresentationView(asset: asset)
                
                // Close button
                VStack {
                    HStack {
                        Button {
                            showFullScreen = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.7))
                                .padding()
                        }
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
    }
}

#Preview {
    VStack {
        PresentationCard(asset: AudioRoomAsset(
            id: "1",
            type: .pdf,
            url: "https://example.com/test.pdf",
            fileName: "Presentation.pdf"
        ))
        .padding()
    }
    .background(Color.black)
}
