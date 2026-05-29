//
//  EncryptionStatusBadge.swift
//  RAVEN
//
//  Tiny lock-icon view that surfaces the E2EE state of a 1-on-1
//  chat in the navigation bar. Three visual states:
//
//      ● Active + verified peer     →  green filled lock
//      ● Active + unverified peer   →  blue lock outline
//      ● Disabled / group / channel →  hidden (renders EmptyView)
//
//  Tappable — calls back so the parent (ChatView) can present the
//  SafetyNumberView for the same peer. We deliberately don't push
//  a view directly from here because the surrounding navigation
//  stack lives in ChatView.
//

import SwiftUI

struct EncryptionStatusBadge: View {

    let peerUserId: String
    let peerDisplayName: String
    let isGroupOrChannel: Bool
    let onTap: () -> Void

    @State private var isVerified: Bool = false

    var body: some View {
        Group {
            if shouldShow {
                Button {
                    Haptics.light()
                    onTap()
                } label: {
                    Image(systemName: iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(4)
                        .background(
                            Circle().fill(tint.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
            } else {
                EmptyView()
            }
        }
        .onAppear { refreshVerified() }
        .onReceive(NotificationCenter.default.publisher(for: .ravenPeerVerificationChanged)) { note in
            guard (note.userInfo?["peerUserId"] as? String) == peerUserId else { return }
            refreshVerified()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ravenPeerIdentityChanged)) { note in
            guard (note.userInfo?["peerUserId"] as? String) == peerUserId else { return }
            // Identity-change observer in PeerVerificationStore will
            // wipe the flag; just re-read after that lands.
            DispatchQueue.main.async { self.refreshVerified() }
        }
    }

    // MARK: - Visual logic

    private var shouldShow: Bool {
        guard !isGroupOrChannel else { return false }
        return E2EEMessageGateway.isEnabled
    }

    private var iconName: String {
        isVerified ? "lock.shield.fill" : "lock.fill"
    }

    private var tint: Color {
        isVerified ? .green : .blue
    }

    private var accessibilityLabel: String {
        isVerified
            ? "Encrypted, identity verified"
            : "Encrypted, identity not yet verified"
    }

    private func refreshVerified() {
        isVerified = PeerVerificationStore.isVerified(peerUserId: peerUserId)
    }
}
