//
//  VaultScreenGuard.swift
//  RAVEN
//
//  🔴 (2026-05-15 — round 3): companion to `VaultCrypto`. Wraps the
//  vault-document viewer in three guards:
//
//    1. Screenshot detection
//       UIApplication.userDidTakeScreenshotNotification fires AFTER
//       the screenshot was taken. We can't prevent it (Apple doesn't
//       expose that API), but we can warn the user that the sender
//       will be notified. Hook a callback so the chat surface can
//       fan-out the notification through its existing mesh / push
//       pipeline.
//
//    2. Screen recording / AirPlay mirroring
//       UIScreen.capturedDidChangeNotification + UIScreen.isCaptured
//       lets us know when ANY recording is active (even silent screen
//       recording or AirPlay mirror). When captured, blur the
//       content so the recording doesn't capture anything useful.
//
//    3. App-switcher snapshot
//       When the app moves to the background iOS takes a snapshot
//       used by the app switcher. That snapshot may then be retrieved
//       by another process. Hide the content on resign-active.
//
//  This is a SwiftUI overlay you put on top of the actual document
//  viewer. The viewer keeps rendering normally; the overlay just
//  swaps between transparent / blur / banner depending on state.
//
//  Honest UX copy: vault DOES NOT prevent screenshots. It detects
//  them, blurs during screen capture, and can notify the sender.
//  No claim is made that the document is "screenshot-proof".

import SwiftUI
import UIKit

/// Drop-in wrapper. Usage:
///
///     VaultScreenGuard(
///         onScreenshot: { sendScreenshotEventToSender() },
///         onScreenCaptureChange: { isCapturing in ... }
///     ) {
///         DocumentPreviewView(url: url, fileName: name)
///     }
///
struct VaultScreenGuard<Content: View>: View {
    let onScreenshot: (() -> Void)?
    let onScreenCaptureChange: ((Bool) -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var isCaptured = false
    @State private var showScreenshotWarning = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // Real content — always rendered, but covered when guarded.
            content()

            // Capture / AirPlay shield: heavy blur over the content so
            // the recorder gets glass + an explanation, not the doc.
            if isCaptured {
                ZStack {
                    // System material is opaque enough to defeat
                    // single-frame OCR while staying lightweight.
                    Rectangle()
                        .fill(.ultraThickMaterial)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("Vault content hidden")
                            .font(.headline)
                        Text("Screen recording or AirPlay is active. The document is hidden until capture stops.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
                .transition(.opacity)
            }

            // App switcher hide: when the scene resigns active, paint
            // a solid surface over the doc so the snapshot is empty.
            if scenePhase != .active {
                Rectangle()
                    .fill(Color(.systemBackground))
                    .ignoresSafeArea()
                    .overlay(
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                    )
            }

            // Screenshot warning toast.
            if showScreenshotWarning {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Screenshot taken — the sender has been notified.")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.85), in: Capsule())
                    .padding(.bottom, 40)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isCaptured)
        .animation(.easeInOut(duration: 0.18), value: showScreenshotWarning)
        .onAppear {
            // Pick up any recording that started before we appeared.
            isCaptured = UIScreen.main.isCaptured
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            let nowCaptured = UIScreen.main.isCaptured
            isCaptured = nowCaptured
            onScreenCaptureChange?(nowCaptured)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            onScreenshot?()
            showScreenshotWarning = true
            // Auto-hide the warning after a few seconds — it's a
            // courtesy ping, not a permanent banner.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                withAnimation { showScreenshotWarning = false }
            }
        }
    }
}
