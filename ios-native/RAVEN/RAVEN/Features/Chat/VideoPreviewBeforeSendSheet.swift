//
//  VideoPreviewBeforeSendSheet.swift
//  RAVEN
//
//  Round 18 (2026-05-16) — completing the (d) preview-before-send
//  requirement.
//
//  Pre-send preview surface for video selections coming out of the
//  gallery / files picker. Before this round, videos went straight
//  from `PhotoLibraryController.exportVideo(...)` to
//  `AttachmentService.sendFile(...)` — the user got no chance to
//  watch, trim, or cancel before the upload kicked.
//
//  The sheet pairs an `AVPlayer`-backed preview with three actions:
//    • Send as-is — fires `onSend(originalURL)`.
//    • Trim / edit — opens `QLPreviewController` in `.createCopy`
//      editing mode; on save we swap the source URL to the edited
//      copy so the next "Send" tap ships the trimmed file.
//    • Cancel — drops both source and edited copies.
//
//  The actual upload pipeline is unchanged: the host hands the
//  resulting URL (original or edited) back to its existing
//  `sendFile(fileURL:)` call. This sheet is purely a UX gate.

import SwiftUI
import AVKit
import QuickLook
import UIKit

struct VideoPreviewBeforeSendSheet: View {
    let sourceURL: URL
    let onSend: (URL) -> Void
    let onCancel: () -> Void

    @State private var displayedURL: URL
    @State private var player: AVPlayer
    @State private var showEditor = false
    @State private var editedURL: URL? = nil
    @Environment(\.dismiss) private var dismiss

    init(sourceURL: URL, onSend: @escaping (URL) -> Void, onCancel: @escaping () -> Void = {}) {
        self.sourceURL = sourceURL
        self.onSend = onSend
        self.onCancel = onCancel
        self._displayedURL = State(initialValue: sourceURL)
        self._player = State(initialValue: AVPlayer(url: sourceURL))
    }

    var body: some View {
        // Round 20 — fix Bug A. Previous layout used
        // `aspectRatio(9/16, .fit)` on the VideoPlayer which on
        // landscape source video made the player box absurdly tall,
        // squeezing the Spacers and pushing the bottom dock below
        // the home indicator (where the user reports "Send button
        // isn't there"). New layout:
        //   • Bottom dock attached via `.safeAreaInset(edge: .bottom)`
        //     so it's guaranteed above the home indicator regardless
        //     of how much room the video takes.
        //   • Top bar attached via `.safeAreaInset(edge: .top)` so
        //     Cancel is always reachable.
        //   • The video lives in the center with `frame(maxHeight:)`
        //     capping it at 70% of screen height and `.fit` honoring
        //     the source aspect — no more pushy aspect override.
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let maxH = max(220, geo.size.height * 0.7)
                VStack {
                    Spacer(minLength: 8)
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: maxH)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 14)
                        .onAppear { player.play() }
                        .onDisappear { player.pause() }
                    Spacer(minLength: 8)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Always-visible title bar with cancel.
            HStack {
                Button {
                    cancelAndDismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("Send video")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Cancel")
                    .font(.system(size: 16, weight: .medium))
                    .opacity(0)  // symmetric layout spacer
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Color.black)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Always-visible action dock — Edit / Trim + Send.
            // Attached via safeAreaInset so it never overlaps the
            // home indicator and is never clipped by the video
            // preview's aspect ratio.
            VStack(spacing: 10) {
                if editedURL != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "scissors")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Edited copy ready")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.green.opacity(0.18)))
                }

                HStack(spacing: 12) {
                    Button {
                        showEditor = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "scissors")
                            Text("Edit / Trim")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.white.opacity(0.14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                                )
                        )
                    }

                    Button {
                        sendAndDismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "paperplane.fill")
                            Text("Send")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.blue)
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(Color.black)
        }
        .fullScreenCover(isPresented: $showEditor) {
            VideoTrimPresenter(url: displayedURL) { trimmed in
                if let trimmed {
                    // Round 18: swap displayed video to the edited
                    // copy. The next "Send" tap ships the trimmed
                    // file. We also retain the edited URL so
                    // `cancelAndDismiss` can clean it up.
                    editedURL = trimmed
                    displayedURL = trimmed
                    player.replaceCurrentItem(with: AVPlayerItem(url: trimmed))
                    player.play()
                }
                showEditor = false
            }
        }
    }

    // MARK: - Actions

    private func sendAndDismiss() {
        Haptics.success()
        let urlToShip = displayedURL
        // If we have an edited copy we don't need the original — but
        // delete cautiously: only clean up files inside the temp
        // directory so we never touch the user's library.
        if editedURL != nil, urlToShip != sourceURL {
            cleanupTmp(sourceURL)
        }
        onSend(urlToShip)
        dismiss()
    }

    private func cancelAndDismiss() {
        Haptics.light()
        // Round 18: clean up BOTH the original tmp copy and any
        // markup-edited tmp copy. The original was written by
        // `PhotoLibraryController.exportVideo` into the app's temp
        // dir; the edited copy was written by QLPreviewController.
        cleanupTmp(sourceURL)
        if let edited = editedURL {
            cleanupTmp(edited)
        }
        onCancel()
        dismiss()
    }

    private func cleanupTmp(_ url: URL) {
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - QLPreviewController bridge

/// Wraps `QLPreviewController` in `.createCopy` editing mode so the
/// user gets Apple's system video-trim UI. Returns the edited copy
/// URL (or nil if the user backed out without saving) via
/// `onComplete`.
struct VideoTrimPresenter: UIViewControllerRepresentable {
    let url: URL
    let onComplete: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        ql.delegate = context.coordinator
        let nav = UINavigationController(rootViewController: ql)
        nav.modalPresentationStyle = .fullScreen
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        let onComplete: (URL?) -> Void
        private var editedURL: URL? = nil

        init(url: URL, onComplete: @escaping (URL?) -> Void) {
            self.url = url
            self.onComplete = onComplete
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                                previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
        func previewController(_ controller: QLPreviewController,
                                editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .createCopy
        }
        func previewController(_ controller: QLPreviewController,
                                didSaveEditedCopyOf previewItem: QLPreviewItem,
                                at modifiedContentsURL: URL) {
            editedURL = modifiedContentsURL
        }
        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            onComplete(editedURL)
        }
    }
}
