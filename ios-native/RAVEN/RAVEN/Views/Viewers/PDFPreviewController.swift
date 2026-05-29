import SwiftUI
import QuickLook
import UIKit
import PDFKit

// MARK: - Document Preview Controller (QuickLook Wrapper)
//
// 🔴 Bug fix (2026-05-15): Phase-4 chat surface only exposed QL in
// read-only mode, so the user had no way to highlight a PDF page,
// strike text, or pencil over an image attachment before forwarding
// it. Switch the editing mode to `.createCopy` (saves a *new* file
// back, leaves the original untouched) and forward the edited
// payload up to the host via `onEdited` so the chat UI can offer a
// "Send edited copy" action if it wants to.
//
// Edit mode also gives the user the system markup palette — colour
// picker, pen / highlighter / signature / shapes, page rotate — for
// free.
struct DocumentPreviewController: UIViewControllerRepresentable {
    let url: URL
    /// Optional callback fired when QL writes a markup-edited copy
    /// back to a temporary URL. The host typically previews the
    /// edited file or offers to re-send it as a new attachment.
    var onEdited: ((URL) -> Void)? = nil
    /// 🔴 2026-05-20 — when false, QuickLook markup/editing is
    /// disabled. Vault payloads pass false so the QL "Markup" →
    /// save-a-copy export path is closed. (QuickLook's own Share
    /// button cannot be removed via public API — vault PDFs avoid
    /// that entirely by rendering through `VaultPDFView` instead.)
    var allowEditing: Bool = true
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> QLPreviewController {
        // No outer UINavigationController — `DocumentPreviewView`
        // already paints its own glass header on top of QL. Nesting a
        // navigation bar inside the sheet body produces a double bar
        // (the QL "Markup" / "Share" buttons stack under our title)
        // which the user noticed when reviewing the bridge .mp4
        // bubble. QLPreviewController by itself draws a single
        // toolbar that respects safe-area insets cleanly.
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.previewController = controller
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, dismiss: dismiss, onEdited: onEdited, allowEditing: allowEditing)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        let dismiss: DismissAction
        let onEdited: ((URL) -> Void)?
        let allowEditing: Bool
        weak var previewController: QLPreviewController?

        init(url: URL, dismiss: DismissAction, onEdited: ((URL) -> Void)?, allowEditing: Bool) {
            self.url = url
            self.dismiss = dismiss
            self.onEdited = onEdited
            self.allowEditing = allowEditing
            super.init()
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
        func previewControllerDidDismiss(_ controller: QLPreviewController) { dismiss() }

        /// Enable markup / annotation toolbar for any item QL knows
        /// how to edit (PDF / image / video trim). `.createCopy`
        /// leaves the cached attachment untouched and writes a fresh
        /// file at `updatedContentsURL` that we forward to the host.
        func previewController(_ controller: QLPreviewController,
                                editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            // 🔴 2026-05-20 — vault payloads pass allowEditing=false so
            // QuickLook's Markup → "save a copy" export path is closed.
            return allowEditing ? .createCopy : .disabled
        }

        func previewController(_ controller: QLPreviewController,
                                didSaveEditedCopyOf previewItem: QLPreviewItem,
                                at modifiedContentsURL: URL) {
            onEdited?(modifiedContentsURL)
        }
    }
}

// MARK: - Vault PDF Viewer (PDFKit — no sharing chrome)
//
// 🔴 2026-05-20 — QLPreviewController ALWAYS draws its own built-in
// Share button (and, in editing mode, a Markup button that can
// "save a copy"). There is no public API to remove it — so a
// vaulted PDF rendered through QuickLook was still one tap away from
// AirDrop / Save to Files / Mail / Print, which defeats the whole
// point of Vault. The custom glass header could only hide its OWN
// share button, not QuickLook's.
//
// PDFKit's `PDFView` has no sharing/export chrome whatsoever — the
// app supplies 100% of the surrounding UI. Rendering vault PDFs
// through it (instead of QuickLook) means the recipient genuinely
// cannot save or re-export the document from inside RAVEN.

/// `PDFView` subclass that suppresses the Copy / Share / Look-Up
/// selection menu, so vault PDF text can't be lifted out via the
/// edit menu either.
final class NonExportingPDFView: PDFView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}

/// Renders a (decrypted) vault PDF with PDFKit. No share, no markup,
/// no "open in", no copy — read-only by construction.
struct VaultPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SecureContainerUIView {
        let pdf = NonExportingPDFView()
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.backgroundColor = .systemBackground
        pdf.document = PDFDocument(url: url)
        context.coordinator.pdfView = pdf

        // 🔴 2026-05-20 — render the PDF inside a secure-text-entry
        // layer so iOS excludes it from screenshots & screen
        // recordings (the mechanism banking apps use to blank card
        // numbers). On-device viewing is unaffected; a screenshot of
        // a vault PDF comes back blank.
        let container = SecureContainerUIView()
        container.host(pdf)
        return container
    }

    func updateUIView(_ uiView: SecureContainerUIView, context: Context) {
        if context.coordinator.pdfView?.document == nil {
            context.coordinator.pdfView?.document = PDFDocument(url: url)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var pdfView: PDFView?
    }
}

// MARK: - Universal Document Preview Loading View
//
// 🔴 Bug fix (2026-05-15): the user asked for the document viewer
// to match the in-app browser (capsule glass header, soft
// bottom-up presentation) and to surface edit options. This rewrite:
//
//   • Drops the plain NavigationStack header in favour of a custom
//     capsule glass top bar — same Liquid Glass treatment the
//     SafariSheet uses. Title in the middle, close pill on the left,
//     edit + share icons on the right.
//   • Keeps the QLPreviewController under the bar, now in
//     `.createCopy` editing mode (see `DocumentPreviewController`)
//     so the system markup palette is available.
//   • Surfaces a "Share" sheet via `UIActivityViewController` for
//     any local file (PDFs, edited copies, etc.).
//   • Tracks an edited-copy URL so the user can re-share the marked-
//     up version without leaving the viewer.
struct DocumentPreviewView: View {
    let url: URL
    let fileName: String?
    /// 🟥 ROUND 32 (2026-05-17) — vault AAD binding.
    ///
    /// The sender's `AttachmentService.sendImage / sendFile` calls
    /// `VaultFileCrypto.encrypt(..., additionalAuthenticatedData:
    /// Data(clientId.utf8))`.  Until this round the receive-side
    /// `decryptVaultPayload` defaulted to EMPTY AAD, so every AES-GCM
    /// open() raised a tag-mismatch and the user saw "Failed to load
    /// document" on every vault PDF/file.
    ///
    /// We accept it as `nil`-by-default so non-chat callers (legacy
    /// preview entries, share-sheet handoff, debug taps) still
    /// compile and behave unchanged — they'll skip the AAD on
    /// decrypt, which is exactly what the previous behaviour was.
    let messageId: String?

    init(url: URL, fileName: String? = nil, messageId: String? = nil) {
        self.url = url
        self.fileName = fileName
        self.messageId = messageId
    }

    @State private var isLoading = true
    @State private var localURL: URL?
    @State private var editedURL: URL?
    @State private var error: Error?
    @State private var showShareSheet = false
    /// (2026-05-15 — round 3) Set when the loaded payload starts
    /// with the `VaultFileCrypto` magic. Drives:
    ///   • decryption to a tmp file before handing off to QL
    ///   • removal of share / save controls in the glass header
    ///   • wrapping the QL surface in `VaultScreenGuard`
    @State private var isVaultPayload = false
    @Environment(\.dismiss) private var dismiss

    /// Title-bar display name. Prefers the originally supplied name,
    /// falls back to the URL's last path component, and finally to a
    /// generic "Document" label so the bar never reads "Untitled".
    private var displayName: String {
        if let name = fileName, !name.isEmpty { return name }
        return url.lastPathComponent.isEmpty ? "Document" : url.lastPathComponent
    }

    /// URL the share sheet / activity controller should hand out —
    /// prefers the markup-edited copy when present.
    private var shareURL: URL? { editedURL ?? localURL }

    var body: some View {
        ZStack(alignment: .top) {
            // Backdrop is opaque so the QL surface (white PDF, dark
            // video) doesn't bleed through during the slide-up
            // animation.
            Color(.systemBackground)
                .ignoresSafeArea()

            // Preview content. Vault payloads run through the
            // VaultScreenGuard overlay so the user sees the standard
            // QL viewer + a screen-capture / screenshot watcher.
            Group {
                if let localURL {
                    if isVaultPayload {
                        // 🔴 2026-05-20 — a vaulted document must not be
                        // savable or re-exportable. Vault PDFs render
                        // through PDFKit's VaultPDFView (NO sharing
                        // chrome at all). Vault non-PDF files still
                        // need QuickLook, but with markup disabled so
                        // the Markup→"save a copy" path is closed.
                        // (QuickLook's own Share button can't be
                        // removed — non-PDF vault files keep a residual
                        // export path; PDFs are fully locked down.)
                        VaultScreenGuard(
                            onScreenshot: {
                                // TODO(vault-notify): fan out a mesh /
                                // push event so the sender learns the
                                // recipient screenshotted this payload.
                                // The "sender has been notified" toast
                                // is NOT backed by anything yet.
                                #if DEBUG
                                print("[Vault] screenshot detected on \(displayName)")
                                #endif
                            },
                            onScreenCaptureChange: { _ in }
                        ) {
                            Group {
                                if localURL.pathExtension.lowercased() == "pdf" {
                                    VaultPDFView(url: localURL)
                                } else {
                                    DocumentPreviewController(url: localURL, allowEditing: false)
                                }
                            }
                            .ignoresSafeArea()
                            .padding(.top, 56)  // make room for the glass header
                        }
                    } else {
                        DocumentPreviewController(url: editedURL ?? localURL) { updated in
                            editedURL = updated
                        }
                        .ignoresSafeArea()
                        .padding(.top, 56)  // make room for the glass header
                    }
                } else if error != nil {
                    errorState
                } else {
                    loadingState
                }
            }

            // Capsule glass header — same style as `SafariSheet`'s
            // navigation bar. Sits over the QL view so the user
            // always has a close affordance.
            glassHeader
        }
        .task { await loadDocument() }
        .onDisappear {
            // Clean up temp files to avoid filling device storage.
            cleanupTempFile(localURL)
            cleanupTempFile(editedURL)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
                    .presentationDetents([.medium, .large])
            }
        }
        .presentationDragIndicator(.visible)
        // Soft bottom-up reveal that matches the in-app browser
        // capsule. SwiftUI sheets present bottom-up by default; the
        // detent set gives the user the same "swipe down to dismiss"
        // affordance SafariSheet has, plus an intermediate height.
        .presentationDetents([.large])
        .presentationBackgroundInteraction(.disabled)
    }

    // MARK: - Glass header
    private var glassHeader: some View {
        HStack(spacing: 10) {
            // Close button (capsule, glass)
            Button {
                Haptics.selection()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Title pill
            Text(displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .frame(maxWidth: .infinity)

            // Share button — opens the system activity sheet on the
            // (possibly markup-edited) local file.
            // (2026-05-15 — round 3) Vault payloads strip the share
            // affordance entirely; routing the decrypted file
            // through UIActivityViewController would let the user
            // re-export the cleartext to Photos / Mail / iCloud,
            // defeating the vault property. Show a lock chip in its
            // place so the user understands why share is missing.
            if isVaultPayload {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .accessibilityLabel("Vaulted document — sharing disabled")
            } else {
                Button {
                    Haptics.selection()
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(shareURL == nil ? .secondary : .primary)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(shareURL == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            // Soft fade so the QL toolbar that sits just below
            // doesn't crash visually into the title.
            LinearGradient(
                colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 70)
            .ignoresSafeArea(edges: .top),
            alignment: .top
        )
    }

    // MARK: - States
    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.5)
            Text("Loading document…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Failed to load document").foregroundStyle(.secondary)
            Button("Retry") { Task { await loadDocument() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load
    private func loadDocument() async {
        isLoading = true
        error = nil

        // 1. If local file, sniff for vault magic + maybe decrypt.
        if url.isFileURL {
            if let resolved = await Self.maybeDecryptVault(at: url, originalFileName: fileName, messageId: messageId) {
                await MainActor.run {
                    self.localURL = resolved.url
                    self.isVaultPayload = resolved.wasVault
                    self.isLoading = false
                }
                return
            }
            await MainActor.run { self.localURL = url; self.isLoading = false }
            return
        }

        // 2. Download from remote securely
        do {
            var request = URLRequest(url: url)
            if let (token, _) = await KeychainService.shared.getToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (tempURL, response) = try await URLSession.shared.download(for: request)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            // Reattach original file extension so QuickLook knows how to render it properly
            var safeName = fileName ?? url.lastPathComponent
            if !safeName.contains(".") {
                let ext = url.pathExtension.isEmpty ? "pdf" : url.pathExtension
                safeName = "\(safeName).\(ext)"
            }
            let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_\(safeName)")

            if FileManager.default.fileExists(atPath: destURL.path) { try? FileManager.default.removeItem(at: destURL) }
            try FileManager.default.moveItem(at: tempURL, to: destURL)

            // (2026-05-15 — round 3) Vault detection on remote
            // payloads. We re-check the file we just wrote because
            // the sender may have uploaded an encrypted blob
            // through the standard /api/uploads/file path.
            if let resolved = await Self.maybeDecryptVault(at: destURL, originalFileName: fileName, messageId: messageId) {
                await MainActor.run {
                    self.localURL = resolved.url
                    self.isVaultPayload = resolved.wasVault
                    self.isLoading = false
                }
                return
            }

            await MainActor.run { self.localURL = destURL; self.isLoading = false }
        } catch {
            await MainActor.run { self.error = error; self.isLoading = false }
        }
    }

    /// Sniff the first bytes for `VaultFileCrypto.magic`; when
    /// matched, decrypt the payload to a sibling tmp file and
    /// surface it. Returns nil only when the read itself fails —
    /// non-vault payloads come back with `wasVault = false` so the
    /// caller still gets a usable URL.
    ///
    /// (2026-05-15 — round 6) Carries `originalFileName` through so
    /// the decrypted tmp file keeps its real extension (`.pdf`,
    /// `.mp4`, `.jpg`). Without this QuickLook saw `.bin` and
    /// rendered the file as raw "data" — the user reported
    /// "ye dokme encrypt mizanm file dige baz nemishe".
    ///
    /// 🟥 ROUND 32 (2026-05-17) — `messageId` is the vault AAD.
    ///   The sender bound `clientId.utf8` into the AES-GCM AAD; we
    ///   thread it through here so AEAD verify passes.  When the
    ///   caller doesn't have a messageId (legacy preview path) we
    ///   try the AAD-bound decrypt FIRST and fall back to the
    ///   empty-AAD path so files uploaded by older builds (which
    ///   had a TODO for this) still open.
    private static func maybeDecryptVault(at url: URL, originalFileName: String? = nil, messageId: String? = nil) async -> (url: URL, wasVault: Bool)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        guard VaultFileCrypto.looksLikeVaultPayload(data) else {
            return (url: url, wasVault: false)
        }

        // Vault payload — pull our X25519 private key and decrypt.
        // Try with the AAD the sender actually bound (clientMessageId),
        // fall back to empty AAD for back-compat with pre-round-32
        // uploads that shipped before this fix.
        let plaintext: Data? = await {
            if let messageId = messageId, !messageId.isEmpty {
                if let pt = await Self.decryptVaultPayload(data, aad: Data(messageId.utf8)) {
                    return pt
                }
                #if DEBUG
                print("[Vault] AAD=msgId decrypt failed for \(messageId.prefix(8)); falling back to empty AAD (pre-round-32 upload).")
                #endif
            }
            return await Self.decryptVaultPayload(data, aad: Data())
        }()
        guard let plaintext else {
            // Decryption failure surfaces through `error` so the user
            // sees the retry button + a "couldn't decrypt" caption.
            return nil
        }

        // Pick a sensible extension: prefer the supplied filename's
        // extension, then sniff the first bytes for known magic
        // numbers, then fall back to `.bin`.
        let ext = Self.extensionForVaultPlaintext(
            originalFileName: originalFileName,
            data: plaintext
        )
        let stem = (originalFileName as NSString?)?.deletingPathExtension ?? "vault"
        let safeStem = stem.replacingOccurrences(of: "/", with: "_")
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)_\(safeStem).\(ext)")
        do {
            // Round 13 (2026-05-16) — hacker-audit finding S6.
            // `.completeFileProtection` means the decrypted vault
            // payload is unreadable any time the device is locked
            // and gets wiped from kernel caches as soon as the file
            // descriptor is released. Without this, the plaintext
            // sat in /tmp at the OS-default protection level (file-
            // protection-complete-until-first-user-auth) until iOS
            // reclaimed tmp — which is not promptly guaranteed and
            // is recoverable from an iOS backup.
            //
            // The cleanup is handled by `DocumentPreviewView`'s
            // `cleanupTempFile(_:)` on disappear, but we belt-and-
            // suspender it here against an early dismiss / crash by
            // requesting the strongest protection class up front.
            try plaintext.write(to: destURL, options: [.atomic, .completeFileProtection])
            return (url: destURL, wasVault: true)
        } catch {
            return nil
        }
    }

    /// Pick an extension for the decrypted vault payload. Order:
    ///   1. user-supplied filename's extension if present + sane
    ///   2. magic-byte sniff for the common formats
    ///   3. `bin` as the inert default
    private static func extensionForVaultPlaintext(originalFileName: String?, data: Data) -> String {
        if let name = originalFileName {
            let ext = (name as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 5 {
                return ext
            }
        }
        // Magic-byte sniff.
        if data.count >= 4 {
            let header = data.prefix(8)
            // %PDF
            if header.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
            // ÿØÿ — JPEG
            if header.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
            // ‰PNG
            if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
            // GIF8
            if header.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
            // PK ZIP / OOXML
            if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
            // ftypMP4 / ftypqt → MP4 / QT (offsets 4..7)
            if data.count >= 12 {
                let ftyp = data.subdata(in: 4..<8)
                if ftyp == Data("ftyp".utf8) { return "mp4" }
            }
        }
        return "bin"
    }

    /// Decrypt a vault wire payload with the device's X25519 private
    /// key + a caller-supplied AAD.  Round 32 (2026-05-17): the AAD
    /// argument was added; callers MUST pass the AAD the sender
    /// bound (currently the chat-message clientId) or AEAD verify
    /// will fail.  Pass `Data()` for the back-compat path.
    private static func decryptVaultPayload(_ data: Data, aad: Data = Data()) async -> Data? {
        return await withCheckedContinuation { cont in
            DeviceIdentityService.shared.withAgreementPrivateKey { priv in
                let raw = priv.rawRepresentation
                if let plain = try? VaultFileCrypto.decrypt(
                    wirePayload: data,
                    recipientIdentityPrivKey: raw,
                    additionalAuthenticatedData: aad
                ) {
                    cont.resume(returning: plain)
                } else {
                    cont.resume(returning: nil)
                }
            } ?? cont.resume(returning: nil)
        }
    }

    private func cleanupTempFile(_ url: URL?) {
        guard let url, url.path.contains(FileManager.default.temporaryDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// `ShareSheet` is defined alongside `FullScreenImageViewer` and
// re-used here so the doc viewer doesn't introduce a duplicate symbol.

// MARK: - Legacy Alias (keeps old references compiling)
typealias PDFPreviewView = DocumentPreviewView
