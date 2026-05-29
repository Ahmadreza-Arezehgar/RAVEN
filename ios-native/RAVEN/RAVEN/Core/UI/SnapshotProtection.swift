//
//  SnapshotProtection.swift
//  RAVEN
//
//  2026-05-16 — round 13, hacker-audit finding S8.
//
//  When iOS backgrounds the app it grabs a screenshot of whatever's
//  on screen and writes it to `Library/Caches/Snapshots/` for the
//  app switcher. That file lives on disk and survives until iOS
//  prunes it (not guaranteed to be soon, and it ships in encrypted
//  backups). If the user happened to have a chat open or a vault
//  document on screen, the snapshot is a forensic gift.
//
//  This modifier overlays an opaque branded splash over the whole
//  window the moment the scene leaves the active phase. Returns to
//  normal as soon as it's active again. The cost is one solid color
//  + a single Image — invisible in CPU terms — and it runs on every
//  view in the app because we apply it at the WindowGroup root.

import SwiftUI

extension View {
    /// Cover the screen with an opaque splash while the scene is
    /// not active so the app-switcher snapshot doesn't capture
    /// chat content / vault contents / recovery codes.
    func snapshotProtected() -> some View {
        modifier(SnapshotProtectionModifier())
    }
}

private struct SnapshotProtectionModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    /// 🔴 ROUND 71 phase 3 — UIKit pre-snapshot trigger.
    ///
    /// SwiftUI `scenePhase` transitions are delivered to the modifier
    /// AFTER iOS has already taken the app-switcher snapshot — even
    /// the briefly-`.inactive` phase fires post-snapshot on iOS 17+.
    /// On top of that the original `.easeInOut(0.18)` animation
    /// added another frame of delay before the overlay appeared in
    /// the rendered tree. Result: one frame of chat / vault content
    /// landed in `Library/Caches/Snapshots/` despite this modifier.
    ///
    /// `UIApplication.willResignActiveNotification` fires
    /// SYNCHRONOUSLY before the snapshot is captured, so observing it
    /// guarantees we flip the overlay on first. We keep the
    /// `scenePhase` check as a fallback for the `.background` /
    /// `.inactive` transitions that don't always pair with a
    /// willResignActive notification (e.g. Slide Over on iPad).
    @State private var willResign: Bool = false

    func body(content: Content) -> some View {
        ZStack {
            content
            if willResign || scenePhase != .active {
                Color.black
                    .ignoresSafeArea()
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 56, weight: .light))
                                .foregroundStyle(.white.opacity(0.6))
                            Text("RAVEN")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                                .tracking(2)
                        }
                    )
                    .zIndex(99999)
                    .accessibilityHidden(true)
            }
        }
        // 🔴 NO animation on the overlay appear — the easeInOut
        // delayed the rendered tree by one frame, defeating the
        // willResignActive head-start. The overlay must appear
        // synchronously on the same runloop tick as the resign
        // notification.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            willResign = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            willResign = false
        }
    }
}
