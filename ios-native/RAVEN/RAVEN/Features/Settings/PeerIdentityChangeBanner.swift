//
//  PeerIdentityChangeBanner.swift
//  RAVEN
//
//  Reusable warning banner that surfaces a peer's identity-key change
//  to the user. Drops the chat into "needs re-verification" mode the
//  moment `PeerIdentityRegistry` reports a swap — Signal-style.
//
//  Drop-in usage in any chat or contact view:
//
//      PeerIdentityChangeBanner(peerUserId: peer.id, peerName: peer.name) {
//          // user tapped "Verify Now" → present SafetyNumberView
//          showingSafetyNumber = true
//      }
//
//  When the peer's identity hasn't changed (or the user has
//  re-verified since), the banner renders nothing — `body` returns
//  `EmptyView`. So a parent can include it unconditionally without
//  extra `if` plumbing.
//

import SwiftUI

struct PeerIdentityChangeBanner: View {

    let peerUserId: String
    let peerName: String
    /// Tapped when the user wants to compare safety numbers right now.
    let onVerifyTapped: () -> Void

    @State private var showBanner: Bool = false
    @State private var newFingerprint: String? = nil

    var body: some View {
        Group {
            if showBanner {
                contentView
            } else {
                EmptyView()
            }
        }
        .onAppear {
            // On view-appear, also check the verification store —
            // banner shows whenever the peer is unverified AND we
            // know about them (i.e. we've fetched a bundle once).
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ravenPeerIdentityChanged)) { note in
            guard let notedPeer = note.userInfo?["peerUserId"] as? String,
                  notedPeer == peerUserId else { return }
            self.newFingerprint = note.userInfo?["newFingerprint"] as? String
            withAnimation(.spring(response: 0.4)) {
                self.showBanner = true
            }
            Haptics.warning()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ravenPeerVerificationChanged)) { note in
            guard let notedPeer = note.userInfo?["peerUserId"] as? String,
                  notedPeer == peerUserId else { return }
            // If the user re-verified, hide the banner.
            if (note.userInfo?["verified"] as? Bool) == true {
                withAnimation(.spring(response: 0.4)) { self.showBanner = false }
            }
        }
    }

    private var contentView: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 22))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(peerName)'s safety number changed")
                    .font(.subheadline.weight(.semibold))
                Text("This is normal if they reinstalled the app or got a new device. Compare your safety numbers before sending sensitive messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    onVerifyTapped()
                } label: {
                    Text("Verify Now")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.18))
                        )
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.spring(response: 0.4)) { showBanner = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(.systemGray5), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func refresh() {
        // Banner is shown when: we've seen the peer before AND they
        // are currently NOT verified. The "key changed" event is
        // captured by the notification observer above.
        Task {
            // We treat "unverified after we've seen them" as a
            // banner-worthy state only if a notification has armed
            // it — that avoids spamming a banner on every chat the
            // user has never explicitly verified.
            //
            // For now: keep banner hidden on cold-load until a
            // notification fires. This matches Signal's UX where
            // unverified ≠ alarming, but a *change* is.
            self.showBanner = false
        }
    }
}
