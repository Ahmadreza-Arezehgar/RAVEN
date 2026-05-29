import SwiftUI
import Photos

// MARK: - Full Screen Image Viewer
struct FullScreenImageViewer: View {
    let imageURL: URL
    /// 🟥 ROUND 32 (2026-05-17) — vault-aware image loading.
    ///
    /// The chat-composer "Vault" toggle re-wraps the JPEG bytes with
    /// `VaultFileCrypto` (RVNV1 magic + AES-GCM ciphertext) before
    /// upload.  Until this round `FullScreenImageViewer` only knew
    /// how to render a raw JPEG via `AsyncImage(url:)` — vault
    /// images fell into the `.failure` branch and the user saw
    /// "Failed to load image".
    ///
    /// New design:
    ///   1. `VaultPayloadResolver.resolve(...)` downloads the file,
    ///      sniffs for RVNV1, decrypts if vault, returns a local
    ///      tmp URL.  Non-vault files pass through unchanged.
    ///   2. The view loads the resolved bytes as `UIImage` so the
    ///      same render path works for both encrypted and plain
    ///      attachments.
    ///   3. `messageId` is the AES-GCM AAD — the chat surface
    ///      passes the originating `ChatMessage.id` so AEAD verify
    ///      passes.  Omit for non-chat callers (the resolver also
    ///      tries the empty-AAD fallback for legacy uploads).
    var messageId: String? = nil
    /// Optional original file name — propagates the user-visible
    /// extension so the decrypted tmp file lands as `.jpg`/`.png`
    /// (matters for share-sheet handoff later).
    var originalFileName: String? = nil

    /// 🔴 2026-05-20 — screenshot-detection callback.
    ///
    /// `userDidTakeScreenshotNotification` fires app-wide AFTER a
    /// screenshot is taken. Previously this viewer relied on
    /// `ChatView`'s screenshot listener to catch it — but that
    /// listener sits on a view that is COVERED by this
    /// `.fullScreenCover`, so in practice the screenshot of a Vault
    /// photo was detected unreliably (the user reported "no
    /// screenshot event fires for the vault photo"). This viewer is
    /// the view actually on screen, so it must own the detection.
    ///
    /// The `Bool` argument is `isVaultImage` — the chat surface uses
    /// it to phrase a Vault-specific system message ("took a
    /// screenshot of a Vault photo") versus the generic one.
    var onScreenshot: ((Bool) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragOffset: CGFloat = 0
    @State private var loadedImage: UIImage?
    @State private var loadError: String? = nil
    @State private var resolvedTmpURL: URL? = nil   // for cleanup on dismiss
    /// 🔴 2026-05-20 — set once the loader knows the payload was a
    /// vault image. Drives screenshot exclusion + removal of the
    /// Save / Share / Markup / Forward controls.
    @State private var isVaultImage = false
    /// 🔴 2026-05-20 — drives the brief "screenshot detected" toast
    /// shown after `userDidTakeScreenshotNotification` fires.
    @State private var showScreenshotToast = false

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

                // Image — vault-aware loader (round 32).  Replaces
                // the old `AsyncImage(url:)` that couldn't render
                // RVNV1 ciphertext.
                Group {
                    if let uiImage = loadedImage {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            // 🔴 2026-05-20 — exclude a vault image from
                            // screenshots / screen recordings via the
                            // secure-text-entry layer. No-op for normal
                            // images.
                            .vaultScreenshotProtected(isVaultImage)
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
                    } else if loadError != nil {
                        VStack(spacing: 16) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Failed to load image")
                                .foregroundStyle(.secondary)
                            if let e = loadError {
                                Text(e)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary.opacity(0.7))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                            Button("Retry") {
                                Task { await loadAndDecryptIfNeeded() }
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                    } else {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    await loadAndDecryptIfNeeded()
                }
                .onDisappear {
                    // Clean the decrypted tmp file so plaintext doesn't
                    // sit in /tmp longer than the viewer's lifetime.
                    if let tmp = resolvedTmpURL,
                       tmp.path.contains(FileManager.default.temporaryDirectory.path) {
                        try? FileManager.default.removeItem(at: tmp)
                    }
                }
                // 🔴 2026-05-20 — own the screenshot detection while
                // this viewer is on screen. The notification fires
                // app-wide; this viewer is the front-most view, so it
                // is the reliable place to catch a screenshot of the
                // image (Vault or not). The `ChatView` generic
                // listener is suppressed while this cover is up — see
                // `ChatView.handleScreenshotDetected`.
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.userDidTakeScreenshotNotification
                )) { _ in
                    onScreenshot?(isVaultImage)
                    Haptics.warning()
                    withAnimation { showScreenshotToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        withAnimation { showScreenshotToast = false }
                    }
                }
                
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

                        // Forward button — hidden for vault images,
                        // since re-forwarding would re-export the
                        // cleartext and defeat the vault property.
                        if !isVaultImage {
                            Button {
                                showForwardSheet = true
                            } label: {
                                Image(systemName: "arrowshape.turn.up.forward.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .shadow(radius: 4)
                            }
                        }
                    }
                    .padding()
                    
                    Spacer()
                    
                    // Bottom toolbar — Markup / Save / Share.
                    // 🔴 2026-05-20 — a vault image must not be savable
                    // or re-exportable, so the toolbar is replaced with
                    // a lock chip: no Save-to-Photos, no share sheet,
                    // no markup-export of the decrypted cleartext.
                    if isVaultImage {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Vault image — saving and sharing are disabled")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.vertical, 14)
                        .padding(.horizontal, 22)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 30)
                    } else {
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

                // 🔴 2026-05-20 — screenshot-detected toast. Mirrors
                // the VaultScreenGuard toast: a brief courtesy ping
                // that the screenshot was caught and (for Vault
                // images) the sender notified.
                if showScreenshotToast {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(isVaultImage
                                 ? "Screenshot taken — the sender has been notified."
                                 : "Screenshot taken.")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.85), in: Capsule())
                        .padding(.bottom, 110)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
    
    // MARK: - Vault-aware loader (round 32)
    //
    // Single entry point for ALL image presentation paths in this
    // viewer.  Runs the URL through `VaultPayloadResolver` which
    // either passes plain JPEG/PNG bytes straight through, or
    // downloads → sniffs → decrypts a vault payload into a tmp
    // file with `.completeFileProtection`.
    //
    // Either way the result is bytes we can hand to UIImage(data:),
    // so the renderer above stays uniform.
    private func loadAndDecryptIfNeeded() async {
        loadError = nil
        let bearer = await KeychainService.shared.getToken()?.0
        do {
            let resolved = try await VaultPayloadResolver.resolve(
                remoteURL: imageURL,
                originalFileName: originalFileName,
                messageId: messageId,
                bearerToken: bearer
            )
            await MainActor.run {
                isVaultImage = resolved.isVault
                if resolved.isVault { resolvedTmpURL = resolved.localURL }
            }
            guard let data = try? Data(contentsOf: resolved.localURL, options: .mappedIfSafe),
                  let img = UIImage(data: data) else {
                await MainActor.run {
                    loadError = "Decoded bytes aren't a recognised image format."
                }
                return
            }
            await MainActor.run {
                loadedImage = img
            }
        } catch let e as VaultPayloadResolver.ResolverError {
            await MainActor.run { loadError = e.errorDescription }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
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

