//
//  LiquidGlassAttachmentSheet.swift
//  RAVEN
//
//  Telegram-style attachment composer with Raven's Liquid Glass language.
//  - Bottom sheet with two detents (compact / expanded) + drag-to-dismiss.
//  - Camera tab starts AVCaptureSession automatically when the sheet opens.
//  - Gallery tab loads recent PHAssets inline (no extra picker bounce).
//  - File / Contact / Location / Audio delegate to existing flows so the
//    underlying send pipeline stays untouched.
//

import SwiftUI
import AVFoundation
import Photos
import UIKit
import CoreImage
import MapKit
import CoreLocation
import VisionKit

// MARK: - Album picker items
//
// 🔴 ROUND 26 — Telegram-style multi-select.
// When the user multi-picks and hits Send, the picker emits an
// ORDERED list of `AlbumPickerItem` values. Each item is either an
// already-resolved `UIImage` (a single still photo, ready for
// compression) or a `URL` (a video / document the parent's send-file
// pipeline already knows how to handle). The parent (ChatView) stamps
// a shared `albumGroupKey` UUID across all items and POSTs them via
// `AttachmentService.sendAlbum`, which threads the same key into
// every per-item upload so the receiver groups them at render time.
enum AlbumPickerItem {
    /// A still image ready to compress + upload.
    case image(UIImage)
    /// A video or other file URL the parent should treat as a file
    /// message (mime detection happens in `AttachmentService`).
    case fileURL(URL)
}

// MARK: - Tabs

enum AttachmentTab: String, CaseIterable, Identifiable {
    case camera, gallery, file, contact, location, audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera:   return "Camera"
        case .gallery:  return "Gallery"
        case .file:     return "File"
        case .contact:  return "Contact"
        case .location: return "Location"
        case .audio:    return "Audio"
        }
    }

    var icon: String {
        switch self {
        case .camera:   return "camera.fill"
        case .gallery:  return "photo.on.rectangle.angled"
        case .file:     return "doc.fill"
        case .contact:  return "person.crop.circle.fill"
        case .location: return "location.fill"
        case .audio:    return "waveform"
        }
    }

    var tint: Color {
        switch self {
        case .camera:   return .pink
        case .gallery:  return .green
        case .file:     return .blue
        case .contact:  return .orange
        case .location: return .cyan
        case .audio:    return .purple
        }
    }
}

// MARK: - Sheet detent

private enum SheetDetent: CaseIterable {
    case compact, expanded

    func height(in screen: CGFloat) -> CGFloat {
        switch self {
        case .compact:  return max(360, screen * 0.55)
        case .expanded: return screen * 0.92
        }
    }
}

// MARK: - Liquid Glass Attachment Sheet

struct LiquidGlassAttachmentSheet: View {
    @Binding var isPresented: Bool

    /// Single-image picks (camera capture or single gallery tap) are
    /// handed to the parent BEFORE the network send so it can present
    /// the existing `MediaEditorView` (crop / draw / caption). The
    /// editor's "Send" button drops back into `onSendImage` below.
    /// When this is `nil`, single images are sent directly (legacy
    /// behaviour). Bug regression-fix: the previous Liquid Glass sheet
    /// dumped every image straight through `onSendImage`, which
    /// silently bypassed the editor preview the user expected to see.
    var onPickImage: ((UIImage) -> Void)? = nil

    /// Final image send (post-editor, or batch gallery picks where the
    /// editor isn't shown). Routed through the parent's `sendImage`
    /// so all existing compression / premium-limit logic kicks in.
    let onSendImage: (UIImage) -> Void

    /// Any URL the parent should treat as a file message — covers gallery
    /// videos, vCard exports, and scanned document PDFs. The parent forwards
    /// to `sendFile`, which already handles video/document MIME mapping.
    let onSendFile: (URL) -> Void

    /// 🔴 ROUND 26 — Telegram-style grouped album send.
    ///
    /// Carried as a Notification name rather than a stored closure
    /// because ChatView's body is already at the SwiftUI type-check
    /// budget — adding ANOTHER closure parameter to this sheet's
    /// init (already 9 closures) tips the parent past the limit
    /// and stops the whole file compiling. The sheet posts
    /// `albumPickerDidSelect` via NotificationCenter with the
    /// resolved `[AlbumPickerItem]` payload; ChatView observes the
    /// notification and dispatches `AttachmentService.sendAlbum`.
    /// Conceptually identical to a closure — just doesn't inflate
    /// the parent view's type signature.
    static let albumPickerDidSelect = Notification.Name("RavenAlbumPickerDidSelect")
    /// Delegates to the existing UIDocumentPicker flow when the user picks
    /// "Select from Files" inside the File tab.
    let onOpenFiles: () -> Void
    /// Inline current-location send from the Location tab.
    let onSendLocation: (CLLocation) -> Void
    /// Delegates to the existing LocationAttachSheet for live-location TTL
    /// configuration — that flow already owns the duration picker UI.
    let onStartLiveLocation: () -> Void
    /// Inline voice recording send (URL + duration in seconds).
    let onSendVoice: (URL, Int) -> Void
    /// Share a Raven friend's profile into the chat. Parent decides the wire
    /// format — typically an @username text message that the mention pipeline
    /// renders as a tappable link to the friend's profile.
    let onShareFriend: (GroupFriendInfo) -> Void

    var availableTabs: [AttachmentTab] = AttachmentTab.allCases

    /// (2026-05-15 — round 3) Fired whenever the user toggles the
    /// inline Vault Mode pill. The parent (ChatView) holds the
    /// authoritative flag and feeds it into `AttachmentService` so
    /// the next outbound payload is encrypted with `VaultFileCrypto`
    /// before upload. Optional — when nil, the toggle still works
    /// visually but the parent ignores it.
    var onVaultModeChange: ((Bool) -> Void)? = nil

    @State private var activeTab: AttachmentTab = .camera
    @State private var detent: SheetDetent = .compact
    @State private var dragOffset: CGFloat = 0
    @State private var appeared = false

    /// (2026-05-15 — round 3) When ON, the next file / image sent
    /// through this sheet is re-encrypted on the device (X25519
    /// ephemeral key agreement + AES-GCM via `VaultFileCrypto`) and
    /// uploaded as opaque ciphertext. The recipient's chat surface
    /// detects the magic bytes, decrypts on-device, and wraps the
    /// viewer in `VaultScreenGuard` so screen capture is blurred and
    /// screenshots trigger a sender notification.
    @State private var vaultMode: Bool = false

    @StateObject private var camera = CameraSessionController()
    @StateObject private var library = PhotoLibraryController()

    @Environment(\.colorScheme) private var colorScheme

    // Drag gesture state for horizontal tab swiping
    @GestureState private var tabSwipe: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let screenH = proxy.size.height
            let bottomInset = proxy.safeAreaInsets.bottom
            let baseH = detent.height(in: screenH) + bottomInset
            let h = clamp(baseH - dragOffset, min: 240, max: screenH * 0.95 + bottomInset)

            ZStack(alignment: .bottom) {
                // Backdrop — frosted glass blur over the chat, with a subtle
                // dim so the sheet has contrast. Tap to dismiss.
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    Color.black
                        .opacity(colorScheme == .dark ? 0.25 : 0.10)
                }
                .ignoresSafeArea()
                .opacity(appeared ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .animation(.easeOut(duration: 0.25), value: appeared)

                sheet(height: h, screenWidth: proxy.size.width, bottomInset: bottomInset)
                    .frame(height: h)
                    .frame(maxWidth: .infinity)
                    .offset(y: appeared ? 0 : screenH + bottomInset)
                    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: appeared)
            }
            .ignoresSafeArea(edges: .bottom)
            .ignoresSafeArea(.keyboard)
        }
        .onAppear {
            appeared = true
            library.requestAccessAndLoad()
            if activeTab == .camera { camera.start() }
        }
        .onDisappear {
            camera.stop()
        }
    }

    // MARK: Sheet body

    @ViewBuilder
    private func sheet(height: CGFloat, screenWidth: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            dragHandle
                .padding(.top, 8)

            // Active content — Camera / Gallery render inline, others render a
            // delegating glass card that punts to the existing picker chain.
            ZStack {
                switch activeTab {
                case .camera:
                    CameraTabContent(
                        camera: camera,
                        isExpanded: detent == .expanded,
                        onCaptured: { image in
                            commitImage(image)
                        }
                    )
                    .transition(.opacity)
                case .gallery:
                    GalleryTabContent(
                        library: library,
                        isExpanded: detent == .expanded,
                        onSelect: { assets in
                            sendAssets(assets)
                        },
                        // 🔴 ROUND 26 — Telegram tap-thumb-to-edit.
                        // For a single asset, route through the
                        // parent's editor pipeline (`onPickImage`) so
                        // the user gets crop + caption + send. For
                        // multi-select the user is expected to tap
                        // the circles instead; if they DO tap a body
                        // mid-multi-select, we still open the editor
                        // for just that one item — which is what
                        // Telegram does too.
                        onEditAsset: { asset in
                            if asset.mediaType == .image, let onPickImage {
                                PhotoLibraryController.loadFullImage(asset) { image in
                                    guard let image else { return }
                                    Haptics.success()
                                    onPickImage(image.downscaled(maxDimension: PremiumLimits.maxImageDimension))
                                    dismiss()
                                }
                            } else if asset.mediaType == .video {
                                // Video editor route: export then hand
                                // the URL to the parent which gates it
                                // through VideoPreviewBeforeSendSheet
                                // (trim / preview / caption).
                                PhotoLibraryController.exportVideo(asset) { url in
                                    guard let url else {
                                        Haptics.error()
                                        return
                                    }
                                    Haptics.success()
                                    onSendFile(url)
                                    dismiss()
                                }
                            }
                        }
                    )
                    .transition(.opacity)
                case .file:
                    FileTabContent(
                        onPickGallery: { switchTab(to: .gallery) },
                        onPickFiles: { fire(onOpenFiles) },
                        onScanned: { url in
                            Haptics.success()
                            onSendFile(url)
                            dismiss()
                        }
                    )
                case .contact:
                    FriendsTabContent(
                        onPick: { friend in
                            Haptics.success()
                            onShareFriend(friend)
                            dismiss()
                        }
                    )
                case .location:
                    LocationTabContent(
                        isExpanded: detent == .expanded,
                        onSendCurrent: { location in
                            Haptics.success()
                            onSendLocation(location)
                            dismiss()
                        },
                        onStartLive: { fire(onStartLiveLocation) }
                    )
                case .audio:
                    AudioTabContent(
                        onSendVoice: { url, duration in
                            Haptics.success()
                            onSendVoice(url, duration)
                            dismiss()
                        }
                    )
                }
            }
            .animation(.easeInOut(duration: 0.18), value: activeTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                AttachmentTabBar(
                    tabs: availableTabs,
                    active: $activeTab,
                    onChange: { newTab in
                        switchTab(to: newTab)
                    }
                )

                // (2026-05-15 — round 3) Vault toggle. Tap to flip
                // the next outbound attachment between standard
                // (transport-encrypted) and vault (re-encrypted with
                // a per-file ephemeral keypair, opens in a screen-
                // capture-aware viewer on the recipient's side).
                vaultToggle
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, max(10, bottomInset))
        }
        .background(sheetBackground)
        .clipShape(SheetShape(cornerRadius: 28))
        .overlay(
            SheetShape(cornerRadius: 28)
                .stroke(strokeColor, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.18), radius: 24, y: -6)
        .gesture(verticalDrag)
    }

    private var sheetBackground: some View {
        ZStack {
            // Base material — the real glass.
            Rectangle()
                .fill(.ultraThinMaterial)
            // Subtle tint to push warmth toward the active tab color.
            LinearGradient(
                colors: [
                    activeTab.tint.opacity(colorScheme == .dark ? 0.10 : 0.06),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var strokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Color.primary.opacity(0.22))
            .frame(width: 38, height: 5)
    }

    // MARK: Gestures

    private var verticalDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                // Only respond to vertical translations.
                let dy = value.translation.height
                // While expanded, allow drag down (positive) to shrink; ignore further pull-up.
                if detent == .expanded {
                    dragOffset = max(0, dy)
                } else {
                    // Compact — allow pull-up (negative) to expand, and pull-down to dismiss.
                    dragOffset = dy * 0.85
                }
            }
            .onEnded { value in
                let dy = value.translation.height
                let velocity = value.predictedEndTranslation.height - value.translation.height

                withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                    if detent == .compact {
                        if dy + velocity < -90 {
                            detent = .expanded
                        } else if dy + velocity > 120 {
                            dismiss()
                        }
                    } else {
                        if dy + velocity > 110 {
                            detent = .compact
                        }
                    }
                    dragOffset = 0
                }
            }
    }

    // MARK: Actions

    private func switchTab(to tab: AttachmentTab) {
        Haptics.selection()
        activeTab = tab
        if tab == .camera {
            camera.start()
        } else {
            camera.stop()
        }
    }

    /// Capsule lock pill that drives `vaultMode`. Visually mirrors
    /// the tab pills next to it (ultraThinMaterial, hairline stroke)
    /// but uses an accent fill when active so the user can see at a
    /// glance that the next send will be vaulted.
    private var vaultToggle: some View {
        Button {
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.18)) {
                vaultMode.toggle()
            }
            onVaultModeChange?(vaultMode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: vaultMode ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(vaultMode ? "Vault" : "Lock")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(vaultMode ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Group {
                    if vaultMode {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
            )
            .overlay(
                Capsule().stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.10)
                        : Color.black.opacity(0.05),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(vaultMode ? "Vault mode on" : "Vault mode off")
    }

    private func fire(_ action: @escaping () -> Void) {
        Haptics.light()
        // Let the existing picker chain present once the sheet animates away,
        // otherwise iOS rejects the second presentation.
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            action()
        }
    }

    private func dismiss() {
        Haptics.soft()
        appeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            isPresented = false
        }
    }

    /// Camera capture — always single, always preview-worthy. Hand to
    /// the parent's editor (`onPickImage`) when wired; fall back to
    /// the direct send path for older callers that haven't adopted it.
    private func commitImage(_ image: UIImage) {
        Haptics.success()
        let processed = image.downscaled(maxDimension: PremiumLimits.maxImageDimension)
        if let onPickImage {
            onPickImage(processed)
        } else {
            onSendImage(processed)
        }
        dismiss()
    }

    /// Multi-select / gallery batch flow.
    ///
    /// 🔴 ROUND 26 — Telegram-style grouped album send.
    /// • Single image → still routed through `onPickImage` (editor).
    ///   Single item never becomes a 1-element album — it's just a
    ///   regular image message.
    /// • 2+ items (any mix of images + videos) → resolved IN ORDER
    ///   into `[AlbumPickerItem]` and handed to `onSendAlbum`. The
    ///   parent stamps a shared `albumGroupKey` so they render as one
    ///   bubble on both sides of the conversation.
    /// • If `onSendAlbum` is nil (legacy host that hasn't migrated)
    ///   we degrade gracefully to N independent sends — same as
    ///   before round 26.
    private func sendAssets(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }

        // Single image — always routes through the editor for the
        // crop/draw/caption experience.
        if assets.count == 1, assets[0].mediaType == .image, let onPickImage {
            PhotoLibraryController.loadFullImage(assets[0]) { [self] image in
                guard let image else { return }
                Haptics.success()
                onPickImage(image.downscaled(maxDimension: PremiumLimits.maxImageDimension))
                dismiss()
            }
            return
        }

        // Multi-select (or single non-image, which is exotic) — collect
        // every item in order, then dispatch via the album path.
        Haptics.success()
        let toResolve = assets

        // Round 26 — Telegram-style grouped album send.
        // Resolve serially so order is preserved (PhotoKit's
        // exportVideo can take seconds and we want item N to land
        // after item N-1's resolve completes, not before).
        // We POST a Notification rather than calling a closure
        // because adding another closure param to this sheet's
        // already-9-closure init pushes ChatView past its SwiftUI
        // type-check budget. The Notification carries the resolved
        // `[AlbumPickerItem]` payload; ChatView's observer hands
        // it to `AttachmentService.sendAlbum` (which stamps the
        // shared albumGroupKey).
        Task.detached {
            var resolved: [AlbumPickerItem] = []
            resolved.reserveCapacity(toResolve.count)
            for asset in toResolve {
                if let item = await Self.resolveToAlbumItem(asset) {
                    resolved.append(item)
                }
            }
            guard !resolved.isEmpty else {
                await MainActor.run { Haptics.error() }
                return
            }
            let captured = resolved
            await MainActor.run {
                NotificationCenter.default.post(
                    name: LiquidGlassAttachmentSheet.albumPickerDidSelect,
                    object: nil,
                    userInfo: ["items": captured]
                )
            }
        }
        dismiss()
    }

    /// Round 26 helper. Resolves a PHAsset into an `AlbumPickerItem`,
    /// applying the same downscale / export hooks the legacy single-
    /// send path uses. Returns nil on DRM / export failure so the
    /// caller can skip + continue.
    private static func resolveToAlbumItem(_ asset: PHAsset) async -> AlbumPickerItem? {
        switch asset.mediaType {
        case .image:
            let image: UIImage? = await withCheckedContinuation { cont in
                PhotoLibraryController.loadFullImage(asset) { img in cont.resume(returning: img) }
            }
            guard let image else { return nil }
            return .image(image.downscaled(maxDimension: PremiumLimits.maxImageDimension))
        case .video:
            let url: URL? = await withCheckedContinuation { cont in
                PhotoLibraryController.exportVideo(asset) { cont.resume(returning: $0) }
            }
            guard let url else { return nil }
            return .fileURL(url)
        default:
            return nil
        }
    }

    /// Async wrapper around the PhotoKit callback APIs so multi-select
    /// can serialize sends. Each call awaits its resolver, so the
    /// caller-side `for await` loop produces N sends in order — no
    /// callback storms.
    private func resolveAssetAsync(_ asset: PHAsset) async {
        switch asset.mediaType {
        case .image:
            let image: UIImage? = await withCheckedContinuation { cont in
                PhotoLibraryController.loadFullImage(asset) { img in cont.resume(returning: img) }
            }
            guard let image else { return }
            await MainActor.run {
                onSendImage(image.downscaled(maxDimension: PremiumLimits.maxImageDimension))
            }
        case .video:
            let url: URL? = await withCheckedContinuation { cont in
                PhotoLibraryController.exportVideo(asset) { exported in cont.resume(returning: exported) }
            }
            guard let url else {
                // 2026-05-16 — round 12: don't silently drop the
                // selection. The export pipeline returns nil when the
                // user picks a DRM-protected clip, an iCloud asset we
                // couldn't fetch, or any export-session failure. Fire
                // an error haptic + log so the user actually feels
                // that the send didn't happen.
                #if DEBUG
                print("[resolveAssetAsync] video export returned nil for asset \(asset.localIdentifier)")
                #endif
                await MainActor.run { Haptics.error() }
                return
            }
            await MainActor.run { onSendFile(url) }
        default:
            return
        }
    }

    private func resolveAsset(_ asset: PHAsset) {
        switch asset.mediaType {
        case .image:
            PhotoLibraryController.loadFullImage(asset) { [self] image in
                guard let image else { return }
                onSendImage(image.downscaled(maxDimension: PremiumLimits.maxImageDimension))
            }
        case .video:
            PhotoLibraryController.exportVideo(asset) { [self] url in
                guard let url else {
                    #if DEBUG
                    print("[resolveAsset] video export returned nil for asset \(asset.localIdentifier)")
                    #endif
                    Haptics.error()
                    return
                }
                onSendFile(url)
            }
        default:
            break
        }
    }
}

// MARK: - Sheet shape (top-rounded only)

private struct SheetShape: Shape {
    let cornerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = cornerRadius
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: r), control: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Tab bar (capsule)

struct AttachmentTabBar: View {
    let tabs: [AttachmentTab]
    @Binding var active: AttachmentTab
    let onChange: (AttachmentTab) -> Void

    @Namespace private var indicator
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        tabPill(tab)
                            .id(tab)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .background(
                Capsule().fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule().stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.10)
                        : Color.black.opacity(0.05),
                    lineWidth: 0.5
                )
            )
            .onChange(of: active) { _, new in
                withAnimation(.easeOut(duration: 0.2)) {
                    scroller.scrollTo(new, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func tabPill(_ tab: AttachmentTab) -> some View {
        let isActive = tab == active
        Button {
            guard tab != active else { return }
            onChange(tab)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .semibold))
                if isActive {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.72))
            .padding(.horizontal, isActive ? 14 : 12)
            .padding(.vertical, 9)
            .background(
                Group {
                    if isActive {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [tab.tint, tab.tint.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .matchedGeometryEffect(id: "active", in: indicator)
                            .shadow(color: tab.tint.opacity(0.35), radius: 8, y: 3)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isActive)
    }
}

// MARK: - Camera Tab Content

private struct CameraTabContent: View {
    @ObservedObject var camera: CameraSessionController
    let isExpanded: Bool
    let onCaptured: (UIImage) -> Void

    var body: some View {
        VStack(spacing: 10) {
            cameraSurface
                .frame(maxWidth: .infinity)
                .frame(height: isExpanded ? 460 : 240)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .overlay(alignment: .bottom) {
                    if camera.permission == .authorized && camera.deviceAvailable {
                        captureButton
                            .padding(.bottom, 14)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if camera.permission == .authorized && camera.deviceAvailable {
                        flipCameraButton
                            .padding(.top, 12)
                            .padding(.trailing, 24)
                    }
                }

            // Camera tab is capture-only. Photo selection lives in the
            // Gallery tab (removed by request 2026-05-22).
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder
    private var cameraSurface: some View {
        switch camera.permission {
        case .authorized:
            if camera.deviceAvailable {
                CameraPreviewLayerView(session: camera.session)
                    .overlay(alignment: .topLeading) {
                        flashButton
                            .padding(.top, 12)
                            .padding(.leading, 12)
                    }
            } else {
                // Simulator path — AVCaptureDevice discovery is empty, so the
                // preview layer would render a flat gray surface. Show a clear
                // placeholder instead of leaving the user staring at nothing.
                permissionPlaceholder(
                    icon: "camera.fill",
                    title: "Camera unavailable",
                    subtitle: "This device or simulator has no camera. Pick from Gallery to send a photo."
                )
            }
        case .denied, .restricted:
            permissionPlaceholder(
                icon: "camera.metering.unknown",
                title: "Camera access is off",
                subtitle: "Enable camera in Settings to capture from here."
            )
        case .notDetermined:
            permissionPlaceholder(
                icon: "camera",
                title: "Camera ready",
                subtitle: "Grant access to start the live preview."
            )
            .onAppear { camera.requestAccess() }
        }
    }

    private var captureButton: some View {
        Button {
            Haptics.medium()
            camera.capturePhoto { image in
                guard let image else { return }
                onCaptured(image)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 72, height: 72)
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 68, height: 68)
                Circle()
                    .fill(Color.white)
                    .frame(width: 54, height: 54)
            }
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture photo")
    }

    private var flipCameraButton: some View {
        Button {
            Haptics.light()
            camera.flip()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var flashButton: some View {
        Button {
            Haptics.light()
            camera.toggleFlash()
        } label: {
            Image(systemName: camera.flashOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(camera.flashOn ? .yellow : .white)
                .padding(9)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func permissionPlaceholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}

// MARK: - Recent media strip (compact horizontal row)

private struct RecentMediaStrip: View {
    let assets: [PHAsset]
    let onSelect: (PHAsset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(assets.prefix(20), id: \.localIdentifier) { asset in
                    AssetThumbnail(asset: asset, size: 80, selected: false)
                        .frame(width: 80, height: 80)
                        .onTapGesture {
                            Haptics.light()
                            onSelect(asset)
                        }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 88)
    }
}

// MARK: - Gallery Tab Content

private struct GalleryTabContent: View {
    @ObservedObject var library: PhotoLibraryController
    let isExpanded: Bool
    let onSelect: ([PHAsset]) -> Void
    /// 🔴 ROUND 26 — Telegram-style "tap thumbnail = edit" path.
    /// When non-nil, tapping the photo BODY (not the selection circle)
    /// fires this closure with the tapped asset so the parent can
    /// open the editor / preview sheet. Tapping the circle still
    /// toggles selection (unchanged). When nil, the body tap falls
    /// back to the legacy "tap to select" behaviour for surfaces
    /// that don't need the editor.
    var onEditAsset: ((PHAsset) -> Void)? = nil

    @State private var selected: [PHAsset] = []

    private var columns: [GridItem] {
        let count = isExpanded ? 4 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: count)
    }

    /// 1-based position of `asset` in the selection (nil if not
    /// selected). Used by the AssetThumbnail's numbered badge so
    /// the album's send order is visible at a glance.
    private func selectionOrder(for asset: PHAsset) -> Int? {
        guard let idx = selected.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) else {
            return nil
        }
        return idx + 1
    }

    var body: some View {
        VStack(spacing: 0) {
            switch library.permission {
            case .authorized, .limited:
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(library.recent, id: \.localIdentifier) { asset in
                            AssetThumbnail(
                                asset: asset,
                                size: 240,
                                selected: selected.contains(where: { $0.localIdentifier == asset.localIdentifier }),
                                // 🔴 ROUND 26 — Telegram numbered badge.
                                // Order index is 1-based; the badge
                                // hides the checkmark when set.
                                selectionOrder: selectionOrder(for: asset),
                                // Dedicated top-right circle is the
                                // canonical select target — it ONLY
                                // toggles selection, never opens the
                                // editor (round 26 spec).
                                onToggleSelection: { toggle(asset) },
                                // 🔴 ROUND 26 — body tap routes
                                // INSIDE AssetThumbnail so the
                                // selection indicator's Button can
                                // suppress the gesture in its corner.
                                // See AssetThumbnail.onTapBody doc.
                                onTapBody: {
                                    if let onEditAsset {
                                        Haptics.selection()
                                        onEditAsset(asset)
                                    } else {
                                        toggle(asset)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 80)
                }
                if library.permission == .limited {
                    limitedAccessFooter
                }
            case .denied, .restricted:
                emptyState(
                    icon: "photo.badge.exclamationmark",
                    title: "Photos access is off",
                    subtitle: "Enable in Settings to browse media here."
                )
            case .notDetermined:
                emptyState(
                    icon: "photo",
                    title: "Photos ready",
                    subtitle: "Grant access to load your recent media."
                )
                .onAppear { library.requestAccessAndLoad() }
            }
        }
        .overlay(alignment: .bottom) {
            if !selected.isEmpty {
                sendBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: selected.count)
    }

    private var sendBar: some View {
        Button {
            Haptics.success()
            onSelect(selected)
        } label: {
            HStack(spacing: 8) {
                Text("Send \(selected.count) item\(selected.count == 1 ? "" : "s")")
                    .font(.system(size: 16, weight: .semibold))
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [.blue, .blue.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .blue.opacity(0.4), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }

    private var limitedAccessFooter: some View {
        Button {
            Haptics.light()
            PhotoLibraryController.presentLimitedPicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                Text("Manage selected photos")
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
    }

    private func toggle(_ asset: PHAsset) {
        Haptics.selection()
        if let idx = selected.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) {
            selected.remove(at: idx)
        } else {
            // Soft cap to stay aligned with PremiumLimits / message batching.
            guard selected.count < 10 else { return }
            selected.append(asset)
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }
}

// MARK: - Asset thumbnail

private struct AssetThumbnail: View {
    let asset: PHAsset
    let size: CGFloat
    let selected: Bool
    /// 🔴 ROUND 26 — Telegram-style numbered badge.
    /// When this asset is selected, the indicator shows its 1-based
    /// position in the selection order (1, 2, 3, …) instead of a
    /// checkmark. Pass nil when the indicator should fall back to
    /// the checkmark (e.g. single-select contexts).
    var selectionOrder: Int? = nil
    /// When non-nil, an always-visible top-right selection circle is
    /// rendered and tapping it fires this closure WITHOUT bubbling up to
    /// the parent's tap gesture. When nil (e.g. the RecentMediaStrip
    /// quick-pick row), the indicator is suppressed entirely.
    ///
    /// 2026-05-16 — added at user request: "ghesmat gallery hatman bayad
    /// bala rast aks entekhab kard ke on aks select kone, bezar tamam
    /// noghat on aks ro" — every photo gets a dedicated tappable circle
    /// in the corner so multi-select is discoverable.
    var onToggleSelection: (() -> Void)? = nil
    /// 🔴 ROUND 26 — Telegram-style "tap photo body to edit".
    /// Attached to the IMAGE LAYER directly (NOT as an outer
    /// `.onTapGesture` on the caller side) so the selection
    /// indicator's Button can consume taps in its top-right
    /// corner without the parent gesture firing too. SwiftUI's
    /// gesture chain doesn't bubble through Buttons, but it DOES
    /// fire both when a Button sits inside a view that itself has
    /// `.onTapGesture` — moving the gesture INSIDE this view's
    /// background prevents the duplicate trigger that was opening
    /// the editor every time a user tried to tap the circle.
    var onTapBody: (() -> Void)? = nil

    @State private var image: UIImage?

    var body: some View {
        // Color.clear is the load-bearing trick: it sizes to whatever the
        // parent (LazyVGrid column or HStack frame) hands it, and the
        // aspectRatio modifier squares it off. The Image as an overlay
        // can't push the size around because overlays don't participate
        // in layout — without this, .scaledToFill on the Image lets each
        // cell grow to the photo's natural aspect ratio.
        Color.primary.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // 🔴 ROUND 26 — body tap MUST be on the image layer only,
            // NOT on the outer view that includes the indicator
            // overlay. SwiftUI fires BOTH a child Button action and
            // the parent's onTapGesture when they share a hit zone,
            // which made every "tap circle to select" attempt also
            // open the editor. Scoping the gesture to the image
            // (the layer BEFORE the indicator overlay) lets the
            // Button cleanly consume taps in its 40pt corner.
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { onTapBody?() }
            .overlay(alignment: .topTrailing) {
                if onToggleSelection != nil {
                    selectionIndicator
                }
            }
        .overlay(alignment: .bottomTrailing) {
            if asset.mediaType == .video {
                Text(formatDuration(asset.duration))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(5)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.blue : Color.white.opacity(0.08), lineWidth: selected ? 2 : 0.5)
        )
        .scaleEffect(selected ? 0.95 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: selected)
        .task(id: asset.localIdentifier) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let target = CGSize(width: size * UIScreen.main.scale, height: size * UIScreen.main.scale)
        let result = await PhotoLibraryController.thumbnail(for: asset, target: target)
        await MainActor.run { self.image = result }
    }

    /// Top-right selection indicator. Hollow capsule-rimmed circle when
    /// unselected; filled liquid-glass blue with a **numbered badge**
    /// (1, 2, 3, …) showing the selection order when selected — the
    /// Telegram convention so the user knows the order their album
    /// will appear in. Falls back to a checkmark when `selectionOrder`
    /// is nil (single-select contexts).
    ///
    /// Wrapped in a Button so its tap area is independent of the
    /// parent's whole-tile gesture — tapping the circle toggles
    /// selection only, NEVER opens the editor. Tapping the photo body
    /// is what opens the editor (round 26).
    @ViewBuilder
    private var selectionIndicator: some View {
        Button {
            Haptics.light()
            onToggleSelection?()
        } label: {
            ZStack {
                // Soft glass disc that floats above any photo color.
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                if selected {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 22, height: 22)
                    if let n = selectionOrder {
                        // Telegram-style 1-based ordinal. Monospaced
                        // digits keep "9" and "10" centered.
                        Text("\(n)")
                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    Circle()
                        .stroke(Color.white.opacity(0.95), lineWidth: 1.6)
                        .frame(width: 22, height: 22)
                }
            }
            // Generous hit area so the user doesn't have to be pixel-
            // perfect — the visible circle is 26pt but the tap target
            // extends to 40pt with .contentShape.
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(2)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: selected)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: selectionOrder)
    }

    private func formatDuration(_ sec: TimeInterval) -> String {
        let total = Int(sec.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Shared glass primitives

private struct GlassActionCapsule: View {
    let title: String
    let icon: String?
    let tint: Color
    let style: Style
    let action: () -> Void

    enum Style { case filled, glass }

    init(_ title: String, icon: String? = nil, tint: Color, style: Style = .filled, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.style = style
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(style == .filled ? Color.white : Color.primary)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background(background)
            .overlay(
                Capsule().stroke(
                    Color.white.opacity(style == .filled ? 0.18 : 0.05),
                    lineWidth: 0.5
                )
            )
            .shadow(color: style == .filled ? tint.opacity(0.4) : .black.opacity(0.08),
                    radius: style == .filled ? 14 : 6, y: style == .filled ? 6 : 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .filled:
            Capsule().fill(
                LinearGradient(
                    colors: [tint, tint.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .glass:
            Capsule().fill(.ultraThinMaterial)
        }
    }
}

private struct PermissionCard: View {
    let tab: AttachmentTab
    let title: String
    let message: String
    let actionTitle: String
    let onAction: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 88, height: 88)
                    .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: tab.tint.opacity(0.32), radius: 18, y: 8)
                Image(systemName: tab.icon)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(tab.tint)
            }
            VStack(spacing: 6) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            GlassActionCapsule(actionTitle, tint: tab.tint, action: onAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - File Tab Content

private struct FileTabContent: View {
    let onPickGallery: () -> Void
    let onPickFiles: () -> Void
    let onScanned: (URL) -> Void

    @State private var presentScanner = false
    @State private var scannerError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                fileCard(
                    icon: "photo.on.rectangle.angled",
                    tint: .green,
                    title: "Select from Gallery",
                    subtitle: "Pick photos or videos from your library",
                    action: onPickGallery
                )
                fileCard(
                    icon: "folder.fill",
                    tint: .blue,
                    title: "Select from Files",
                    subtitle: "Browse PDFs, documents, and any other file",
                    action: onPickFiles
                )
                fileCard(
                    icon: "doc.viewfinder.fill",
                    tint: .purple,
                    title: "Scan Document",
                    subtitle: "Capture a document and send it as a PDF",
                    action: {
                        if VNDocumentCameraViewController.isSupported {
                            presentScanner = true
                        } else {
                            scannerError = "Document scanning isn't available on this device."
                        }
                    }
                )
                if let scannerError {
                    Text(scannerError)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .fullScreenCover(isPresented: $presentScanner) {
            DocumentScannerView { result in
                presentScanner = false
                switch result {
                case .success(let url): onScanned(url)
                case .failure: break
                }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func fileCard(icon: String, tint: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.18)).frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Document Scanner (VisionKit)

private struct DocumentScannerView: UIViewControllerRepresentable {
    enum Result { case success(URL), failure }
    let completion: (Result) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result) -> Void
        init(_ completion: @escaping (Result) -> Void) { self.completion = completion }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            controller.dismiss(animated: true)
            DispatchQueue.global(qos: .userInitiated).async {
                let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("scan-\(UUID().uuidString).pdf")
                do {
                    try pdf.writePDF(to: url) { context in
                        for i in 0..<scan.pageCount {
                            let image = scan.imageOfPage(at: i)
                            context.beginPage()
                            let rect = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(x: 0, y: 0, width: 612, height: 792))
                            image.draw(in: rect)
                        }
                    }
                    DispatchQueue.main.async { self.completion(.success(url)) }
                } catch {
                    DispatchQueue.main.async { self.completion(.failure) }
                }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
            completion(.failure)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
            completion(.failure)
        }
    }
}

// MARK: - Friends Tab Content (share a Raven friend)

private struct FriendsTabContent: View {
    let onPick: (GroupFriendInfo) -> Void

    @StateObject private var controller = FriendsListController()
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 14)
                .padding(.top, 8)
            content
        }
        .onAppear { controller.loadIfNeeded() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search friends", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private var filtered: [GroupFriendInfo] {
        guard !search.isEmpty else { return controller.friends }
        let needle = search.lowercased()
        return controller.friends.filter {
            $0.safeDisplayName.lowercased().contains(needle) ||
            $0.username.lowercased().contains(needle)
        }
    }

    @ViewBuilder
    private var content: some View {
        if controller.isLoading && controller.friends.isEmpty {
            VStack { Spacer(); ProgressView(); Spacer() }
        } else if let error = controller.errorMessage, controller.friends.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Couldn't load friends").font(.system(size: 14, weight: .medium))
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                GlassActionCapsule("Try again", tint: .orange) { controller.reload() }
                Spacer()
            }
        } else if controller.friends.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "person.2.slash")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No friends yet").font(.system(size: 14, weight: .medium))
                Text("Add friends on RAVEN to share their profile here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filtered) { friend in
                        friendRow(friend)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func friendRow(_ friend: GroupFriendInfo) -> some View {
        Button {
            Haptics.selection()
            onPick(friend)
        } label: {
            HStack(spacing: 12) {
                avatar(for: friend)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.safeDisplayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("@\(friend.username)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange.opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func avatar(for friend: GroupFriendInfo) -> some View {
        if let path = friend.avatarUrl, !path.isEmpty,
           let url = AppConfig.mediaURL(from: path) {
            CachedAsyncImage(url: url) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                initialsCircle(friend.safeDisplayName)
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            initialsCircle(friend.safeDisplayName)
                .frame(width: 40, height: 40)
        }
    }

    private func initialsCircle(_ name: String) -> some View {
        let initials = name.split(separator: " ").compactMap { $0.first }.prefix(2).map(String.init).joined()
        return ZStack {
            Circle().fill(.ultraThinMaterial)
            Text(initials.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Friends List Controller

@MainActor
private final class FriendsListController: ObservableObject {
    @Published private(set) var friends: [GroupFriendInfo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var hasLoaded = false

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    func reload() {
        isLoading = true
        errorMessage = nil
        Task {
            // 1) Always fold in the user's existing 1:1 chat partners — the
            //    real-world bug surfaced when the test account had open
            //    conversations but zero entries from `/api/users/friends`,
            //    so the share list was empty even though shareable people
            //    were obviously visible in the inbox a tap away.
            let chatPartners = ConversationStore.shared.conversations
                .filter { !$0.isGroup && !$0.isChannel }
                .map { conv -> GroupFriendInfo in
                    let p = conv.peer
                    return GroupFriendInfo(
                        id: p.userId,
                        username: p.username,
                        displayName: p.displayName,
                        avatarUrl: p.avatarPath
                    )
                }

            // 2) Try the canonical friends endpoint. A failure here is no
            //    longer fatal — we still surface the chat partners so the
            //    user can share at least them.
            var apiFriends: [GroupFriendInfo] = []
            var apiError: String?
            do {
                apiFriends = try await GroupService.shared.fetchFriends()
            } catch {
                apiError = (error as? LocalizedError)?.errorDescription
                    ?? "Check your connection and try again."
            }

            // 3) Union by user id. API friends take precedence so canonical
            //    avatar/display name wins when both sides have an entry.
            var byId: [String: GroupFriendInfo] = [:]
            for partner in chatPartners { byId[partner.id] = partner }
            for friend in apiFriends { byId[friend.id] = friend }

            let merged = byId.values.sorted {
                $0.safeDisplayName.localizedCaseInsensitiveCompare($1.safeDisplayName) == .orderedAscending
            }

            self.friends = merged
            // Only surface an error if the union is *also* empty — otherwise
            // chat partners alone are good enough and an error banner would
            // be misleading.
            self.errorMessage = (apiError != nil && merged.isEmpty) ? apiError : nil
            self.isLoading = false
        }
    }
}

// MARK: - Location Tab Content

private struct LocationTabContent: View {
    let isExpanded: Bool
    let onSendCurrent: (CLLocation) -> Void
    let onStartLive: () -> Void

    @StateObject private var locator = LocationPickerController()

    var body: some View {
        switch locator.permission {
        case .authorized, .limited:
            authorizedBody
                .onAppear { locator.start() }
                .onDisappear { locator.stop() }
        case .notDetermined:
            PermissionCard(
                tab: .location,
                title: "Share location",
                message: "Allow access so RAVEN can show your current spot on the map.",
                actionTitle: "Allow Location",
                onAction: { locator.requestAccess() }
            )
        case .denied, .restricted:
            PermissionCard(
                tab: .location,
                title: "Location is off",
                message: "Enable location in Settings to share your spot.",
                actionTitle: "Open Settings",
                onAction: { LocationPickerController.openSettings() }
            )
        }
    }

    @ViewBuilder
    private var authorizedBody: some View {
        VStack(spacing: 12) {
            MapPreviewView(coordinate: locator.coordinate, isExpanded: isExpanded)
                .frame(height: isExpanded ? 420 : 220)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
                .padding(.horizontal, 14)
                .padding(.top, 10)

            VStack(spacing: 8) {
                GlassActionCapsule(
                    "Send my current location",
                    icon: "location.fill",
                    tint: .cyan
                ) {
                    guard let location = locator.lastLocation else { return }
                    onSendCurrent(location)
                }
                GlassActionCapsule(
                    "Share live location",
                    icon: "dot.radiowaves.left.and.right",
                    tint: .cyan,
                    style: .glass,
                    action: onStartLive
                )
            }
            .padding(.horizontal, 14)
            Spacer(minLength: 4)
        }
    }
}

private struct MapPreviewView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D?
    let isExpanded: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        guard let coordinate else { return }
        let span = MKCoordinateSpan(
            latitudeDelta: isExpanded ? 0.01 : 0.005,
            longitudeDelta: isExpanded ? 0.01 : 0.005
        )
        map.setRegion(MKCoordinateRegion(center: coordinate, span: span), animated: false)
    }
}

@MainActor
private final class LocationPickerController: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Permission { case notDetermined, authorized, limited, denied, restricted }

    @Published private(set) var permission: Permission = .notDetermined
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        permission = map(manager.authorizationStatus)
    }

    func requestAccess() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        guard permission == .authorized || permission == .limited else { return }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async { [weak self] in
            self?.lastLocation = loc
            self?.coordinate = loc.coordinate
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.permission = self.map(status)
            if self.permission == .authorized || self.permission == .limited {
                manager.startUpdatingLocation()
            }
        }
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func map(_ status: CLAuthorizationStatus) -> Permission {
        switch status {
        case .notDetermined:                  return .notDetermined
        case .authorizedAlways,
             .authorizedWhenInUse:            return .authorized
        case .denied:                         return .denied
        case .restricted:                     return .restricted
        @unknown default:                     return .denied
        }
    }
}

// MARK: - Audio Tab Content

private struct AudioTabContent: View {
    let onSendVoice: (URL, Int) -> Void

    @StateObject private var recorder = AudioRecorderController()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch recorder.permission {
        case .authorized:
            recorderBody
        case .denied:
            PermissionCard(
                tab: .audio,
                title: "Microphone is off",
                message: "Enable microphone in Settings to record a voice message.",
                actionTitle: "Open Settings",
                onAction: { AudioRecorderController.openSettings() }
            )
        case .notDetermined, .undetermined:
            PermissionCard(
                tab: .audio,
                title: "Voice messages",
                message: "Allow microphone access to record a quick voice note.",
                actionTitle: "Allow Microphone",
                onAction: { recorder.requestAccess() }
            )
        }
    }

    @ViewBuilder
    private var recorderBody: some View {
        VStack(spacing: 18) {
            Spacer()
            // Waveform / placeholder area
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                if recorder.isRecording || recorder.hasRecording {
                    RecordingWaveform(levels: recorder.levels, isLive: recorder.isRecording)
                        .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.purple)
                        Text("Tap to record")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 130)
            .padding(.horizontal, 14)

            Text(formattedTime(recorder.elapsed))
                .font(.system(size: 32, weight: .light, design: .monospaced))
                .foregroundStyle(recorder.isRecording ? .red : .primary)
                .contentTransition(.numericText())

            HStack(spacing: 26) {
                if recorder.hasRecording && !recorder.isRecording {
                    GlassActionCapsule("Discard", icon: "xmark", tint: .red, style: .glass) {
                        recorder.discard()
                    }
                }

                Button {
                    Haptics.medium()
                    if recorder.isRecording {
                        recorder.stop()
                    } else if recorder.hasRecording {
                        if let url = recorder.recordedURL {
                            onSendVoice(url, recorder.elapsed)
                        }
                    } else {
                        recorder.start()
                    }
                } label: {
                    ZStack {
                        Circle().fill(.ultraThinMaterial).frame(width: 78, height: 78)
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: recorder.isRecording
                                        ? [.red, .red.opacity(0.8)]
                                        : (recorder.hasRecording
                                            ? [.green, .green.opacity(0.8)]
                                            : [.purple, .purple.opacity(0.8)]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 62, height: 62)
                        Image(systemName: iconForState)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: tintForState.opacity(0.4), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var iconForState: String {
        if recorder.isRecording { return "stop.fill" }
        if recorder.hasRecording { return "arrow.up" }
        return "mic.fill"
    }

    private var tintForState: Color {
        if recorder.isRecording { return .red }
        if recorder.hasRecording { return .green }
        return .purple
    }

    private func formattedTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

private struct RecordingWaveform: View {
    let levels: [CGFloat]
    let isLive: Bool

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 3) {
                ForEach(0..<levels.count, id: \.self) { idx in
                    let normalized = max(0.1, min(1.0, levels[idx]))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.purple, .purple.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .frame(width: max(2, proxy.size.width / CGFloat(max(levels.count, 1)) - 3),
                               height: proxy.size.height * normalized)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(isLive ? .easeOut(duration: 0.1) : .default, value: levels)
        }
    }
}

// MARK: - Audio Recorder Controller

@MainActor
private final class AudioRecorderController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum Permission { case notDetermined, undetermined, authorized, denied }

    @Published private(set) var permission: Permission = .notDetermined
    @Published private(set) var isRecording = false
    @Published private(set) var hasRecording = false
    @Published private(set) var elapsed: Int = 0
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0.15, count: 36)
    @Published private(set) var recordedURL: URL?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var tickTimer: Timer?

    override init() {
        super.init()
        permission = currentPermission()
    }

    func requestAccess() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.permission = granted ? .authorized : .denied
            }
        }
    }

    func start() {
        guard permission == .authorized else {
            if permission == .notDetermined || permission == .undetermined { requestAccess() }
            return
        }
        configureSession()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            r.isMeteringEnabled = true
            r.record()
            recorder = r
            recordedURL = url
            isRecording = true
            hasRecording = false
            elapsed = 0
            startTimers()
        } catch {
            #if DEBUG
            print("Audio recorder failed: \(error)")
            #endif
        }
    }

    func stop() {
        recorder?.stop()
        stopTimers()
        isRecording = false
        if let url = recordedURL, FileManager.default.fileExists(atPath: url.path) {
            hasRecording = true
            // Replace timer-based duration with the real one from the file.
            if let player = try? AVAudioPlayer(contentsOf: url) {
                elapsed = max(1, Int(player.duration))
            }
        }
    }

    func discard() {
        recorder?.stop()
        stopTimers()
        isRecording = false
        if let url = recordedURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedURL = nil
        hasRecording = false
        elapsed = 0
        levels = Array(repeating: 0.15, count: levels.count)
    }

    // MARK: Private

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
    }

    private func startTimers() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed += 1 }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleMeter() }
        }
    }

    private func stopTimers() {
        tickTimer?.invalidate(); tickTimer = nil
        meterTimer?.invalidate(); meterTimer = nil
    }

    private func sampleMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        // Map [-60, 0] dB to [0.1, 1.0]
        let clamped = max(-60, min(0, db))
        let normalized = CGFloat((clamped + 60) / 60) * 0.9 + 0.1
        levels.removeFirst()
        levels.append(normalized)
    }

    private func currentPermission() -> Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: return .notDetermined
        case .denied:       return .denied
        case .granted:      return .authorized
        @unknown default:   return .denied
        }
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

private struct CameraPreviewLayerView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            return layer as! AVCaptureVideoPreviewLayer
        }
    }
}

// MARK: - Camera Session Controller

@MainActor
final class CameraSessionController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum Permission { case notDetermined, authorized, denied, restricted }

    @Published private(set) var permission: Permission = .notDetermined
    @Published private(set) var flashOn = false
    /// False once we've tried to configure the session and found no usable
    /// video input — e.g. running on the iOS Simulator where AVCaptureDevice
    /// returns an empty discovery list. The view shows a placeholder in that
    /// case instead of an unexplained gray rectangle.
    @Published private(set) var deviceAvailable = true
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "raven.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var isConfigured = false
    private var photoCallback: ((UIImage?) -> Void)?

    override init() {
        super.init()
        permission = mapAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .video))
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.permission = granted ? .authorized : .denied
                if granted { self?.start() }
            }
        }
    }

    func start() {
        guard permission == .authorized else {
            if permission == .notDetermined { requestAccess() }
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured { self.configureSession() }
            // AVCaptureSession.startRunning throws an Objective-C exception
            // (uncatchable in Swift) when the session has no inputs — e.g.
            // on the iOS Simulator where AVCaptureDevice.DiscoverySession
            // returns nothing. Bail early so the UI shows the placeholder
            // instead of taking down the process.
            guard self.currentInput != nil else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func flip() {
        let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let current = self.currentInput { self.session.removeInput(current) }
            self.currentPosition = newPosition
            if let input = self.makeInput(position: newPosition), self.session.canAddInput(input) {
                self.session.addInput(input)
                self.currentInput = input
            }
            self.session.commitConfiguration()
        }
    }

    func toggleFlash() {
        flashOn.toggle()
    }

    func capturePhoto(_ completion: @escaping (UIImage?) -> Void) {
        guard permission == .authorized, session.isRunning else {
            completion(nil); return
        }
        photoCallback = completion
        let settings = AVCapturePhotoSettings()
        settings.flashMode = (flashOn && photoOutput.supportedFlashModes.contains(.on)) ? .on : .off
        sessionQueue.async { [weak self] in
            self?.photoOutput.capturePhoto(with: settings, delegate: self!)
        }
    }

    // MARK: AVCapturePhotoCaptureDelegate

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        let image = data.flatMap { UIImage(data: $0) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Mirror front-camera captures so the user sees what they previewed.
            let final: UIImage?
            if let image, self.currentPosition == .front, let cg = image.cgImage {
                final = UIImage(cgImage: cg, scale: image.scale, orientation: .leftMirrored)
            } else {
                final = image
            }
            self.photoCallback?(final)
            self.photoCallback = nil
        }
    }

    // MARK: Private

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        if let input = makeInput(position: currentPosition), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()
        isConfigured = true

        let available = currentInput != nil
        DispatchQueue.main.async { [weak self] in
            self?.deviceAvailable = available
        }
    }

    private func makeInput(position: AVCaptureDevice.Position) -> AVCaptureDeviceInput? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        guard let device = discovery.devices.first else { return nil }
        return try? AVCaptureDeviceInput(device: device)
    }

    private func mapAuthorizationStatus(_ status: AVAuthorizationStatus) -> Permission {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:    return .denied
        }
    }
}

// MARK: - Photo Library Controller

@MainActor
final class PhotoLibraryController: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    enum Permission { case notDetermined, authorized, limited, denied, restricted }

    @Published private(set) var recent: [PHAsset] = []
    @Published private(set) var permission: Permission = .notDetermined

    private let manager = PHCachingImageManager()
    private var didObserve = false

    func requestAccessAndLoad() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        permission = map(status)

        switch status {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] new in
                DispatchQueue.main.async {
                    self?.permission = self?.map(new) ?? .denied
                    if new == .authorized || new == .limited { self?.load() }
                }
            }
        case .authorized, .limited:
            load()
        default:
            break
        }
    }

    private func load() {
        if !didObserve {
            PHPhotoLibrary.shared().register(self)
            didObserve = true
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 120
        let fetch = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        self.recent = assets
    }

    deinit {
        if didObserve {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    // MARK: PHPhotoLibraryChangeObserver

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            self?.load()
        }
    }

    // MARK: Static helpers

    static func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    static func thumbnail(for asset: PHAsset, target: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // Only resume on the final delivery to avoid double-resume.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                continuation.resume(returning: image)
            }
        }
    }

    static func loadFullImage(_ asset: PHAsset, completion: @escaping (UIImage?) -> Void) {
        // 🔴 ROUND 20 — Bug B/D fix.
        //
        // Previously this passed `PHImageManagerMaximumSize` which
        // tells PhotoKit "give me the full original resolution,
        // please decode every pixel" — for a modern iPhone shooting
        // 48 MP ProRAW that's a 100 MB+ Data + full ImageIO decode
        // on the main thread. The user's gallery tap → editor delay
        // was measured at multiple seconds because of this.
        //
        // The chat send pipeline always downscales again at line
        // ~144 (`image.downscaled(maxDimension:)`), so requesting
        // a target ≥ the final downscale dimension preserves output
        // quality while cutting the PhotoKit decode time by ~10×.
        //
        // We multiply by the screen scale so the editor preview
        // stays sharp on Retina-3x displays.
        let cap = PremiumLimits.maxImageDimension * UIScreen.main.scale
        let target = CGSize(width: cap, height: cap)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast      // accept PhotoKit's fast resize — we're going to re-encode anyway
        options.isSynchronous = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if isDegraded { return }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Export a PHAsset video to a sandbox-accessible MP4 the
    /// AttachmentService can upload.
    ///
    /// 🐞 BUG FIX (2026-05-16 — round 12): the user reported "nemitonm
    /// video ro ersal konm" (can't send video). The previous
    /// implementation cast `requestAVAsset`'s result to `AVURLAsset`
    /// and bailed silently when that failed — which is exactly what
    /// happens for:
    ///   • Slow-motion clips (returned as `AVComposition`)
    ///   • Photos.app edits (returned as `AVComposition`)
    ///   • iCloud-only originals whose local material isn't an MP4
    ///   • HEVC HDR videos on some device classes
    /// In all four cases the bubble was never posted and the sheet
    /// just closed. We now go through `requestExportSession`, which
    /// internally fetches the iCloud original, flattens compositions,
    /// and hands us a ready-to-export AVAssetExportSession. We export
    /// to a stable `.mp4` in the app temp dir so the AttachmentService
    /// upload path has a file it can actually open without
    /// security-scoped-resource gymnastics.
    static func exportVideo(_ asset: PHAsset, completion: @escaping (URL?) -> Void) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true              // pull from iCloud if needed
        options.deliveryMode = .mediumQualityFormat        // we're going to re-encode anyway
        options.version = .current                         // honour user edits in Photos

        PHImageManager.default().requestExportSession(
            forVideo: asset,
            options: options,
            exportPreset: AVAssetExportPresetHighestQuality
        ) { session, info in
            if let err = info?[PHImageErrorKey] as? Error {
                #if DEBUG
                print("[exportVideo] requestExportSession returned error: \(err.localizedDescription)")
                #endif
            }
            guard let session else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mp4")
            session.outputURL = dst
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            session.exportAsynchronously {
                DispatchQueue.main.async {
                    if session.status == .completed,
                       FileManager.default.fileExists(atPath: dst.path) {
                        completion(dst)
                    } else {
                        #if DEBUG
                        if let err = session.error {
                            print("[exportVideo] export failed status=\(session.status.rawValue) error=\(err.localizedDescription)")
                        } else {
                            print("[exportVideo] export failed status=\(session.status.rawValue) (no error)")
                        }
                        #endif
                        try? FileManager.default.removeItem(at: dst)
                        completion(nil)
                    }
                }
            }
        }
    }

    private func map(_ status: PHAuthorizationStatus) -> Permission {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized:    return .authorized
        case .limited:       return .limited
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:    return .denied
        }
    }
}

// MARK: - Helpers

private func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
    Swift.max(lo, Swift.min(hi, value))
}

#Preview {
    LiquidGlassAttachmentSheet(
        isPresented: .constant(true),
        onSendImage: { _ in },
        onSendFile: { _ in },
        onOpenFiles: {},
        onSendLocation: { _ in },
        onStartLiveLocation: {},
        onSendVoice: { _, _ in },
        onShareFriend: { _ in }
    )
}
