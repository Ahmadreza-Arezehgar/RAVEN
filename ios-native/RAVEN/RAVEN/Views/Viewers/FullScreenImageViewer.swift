import SwiftUI
import Photos

// MARK: - Full Screen Image Viewer
struct FullScreenImageViewer: View {
    let imageURL: URL
    @Environment(\.dismiss) private var dismiss
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragOffset: CGFloat = 0
    @State private var loadedImage: UIImage?
    
    // Sheets
    @State private var showMarkupEditor = false
    @State private var showForwardSheet = false
    @State private var showShareSheet = false
    @State private var showSaveSuccess = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dark background
                Color.black
                    .ignoresSafeArea()
                    .opacity(backgroundOpacity)
                
                // Image
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .offset(x: offset.width, y: offset.height + dragOffset)
                            .gesture(combinedGesture(in: geometry))
                            .onTapGesture(count: 2) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    if scale > 1 {
                                        scale = 1
                                        offset = .zero
                                    } else {
                                        scale = 2
                                    }
                                    lastScale = scale
                                    lastOffset = offset
                                }
                            }
                            .onAppear {
                                // Cache UIImage for editing
                                Task {
                                    if let (data, _) = try? await URLSession.shared.data(from: imageURL),
                                       let uiImage = UIImage(data: data) {
                                        loadedImage = uiImage
                                    }
                                }
                            }
                            
                    case .failure:
                        VStack(spacing: 16) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Failed to load image")
                                .foregroundStyle(.secondary)
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
                
                // Top bar
                VStack {
                    HStack {
                        // Close button
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(radius: 4)
                        }
                        
                        Spacer()
                        
                        // Forward button
                        Button {
                            showForwardSheet = true
                        } label: {
                            Image(systemName: "arrowshape.turn.up.forward.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(radius: 4)
                        }
                    }
                    .padding()
                    
                    Spacer()
                    
                    // Bottom toolbar
                    HStack(spacing: 40) {
                        // Markup
                        toolbarButton(icon: "pencil.tip.crop.circle", label: "Markup") {
                            showMarkupEditor = true
                        }
                        
                        // Save
                        toolbarButton(icon: "square.and.arrow.down", label: "Save") {
                            saveToPhotos()
                        }
                        
                        // Share
                        toolbarButton(icon: "square.and.arrow.up", label: "Share") {
                            showShareSheet = true
                        }
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 40)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 30)
                }
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showMarkupEditor) {
            if let image = loadedImage {
                MarkupEditorView(image: image) { editedImage in
                    loadedImage = editedImage
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let image = loadedImage {
                ShareSheet(items: [image])
            }
        }
        .overlay {
            if showSaveSuccess {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Saved to Photos")
                    }
                    .padding()
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
    
    // MARK: - Toolbar Button
    
    @ViewBuilder
    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(.white)
        }
    }
    
    // MARK: - Save to Photos
    
    private func saveToPhotos() {
        guard let image = loadedImage else { return }
        
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status == .authorized || status == .limited {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                
                DispatchQueue.main.async {
                    let impact = UINotificationFeedbackGenerator()
                    impact.notificationOccurred(.success)
                    
                    withAnimation(.spring(response: 0.3)) {
                        showSaveSuccess = true
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            showSaveSuccess = false
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Gestures
    
    private func combinedGesture(in geometry: GeometryProxy) -> some Gesture {
        magnificationGesture
            .simultaneously(with: dragGesture)
    }
    
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    // Pan when zoomed
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else {
                    // Swipe down to dismiss when not zoomed
                    if value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
            }
            .onEnded { value in
                if scale > 1 {
                    // Pan ended
                    lastOffset = offset
                } else {
                    // Swipe ended
                    if value.translation.height > 150 || value.velocity.height > 500 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
            }
    }
    
    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                scale = min(max(scale * delta, 0.5), 4.0)
            }
            .onEnded { _ in
                lastScale = 1.0
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if scale < 1 {
                        scale = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }
    
    private var backgroundOpacity: Double {
        let progress = min(dragOffset / 300, 1.0)
        return 1.0 - (progress * 0.5)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - URL Extension for Identifiable
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

#Preview {
    FullScreenImageViewer(imageURL: URL(string: "https://picsum.photos/800/600") ?? URL(fileURLWithPath: "/"))
}

