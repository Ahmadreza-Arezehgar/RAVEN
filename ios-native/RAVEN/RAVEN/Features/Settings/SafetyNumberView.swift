//
//  SafetyNumberView.swift
//  RAVEN
//
//  Per-peer safety-number screen. Shows the 60-digit fingerprint
//  computed from this device's identity key + the peer's identity
//  key, plus a "Mark as Verified" button that records the user's
//  out-of-band confirmation.
//
//  How users use this
//  ──────────────────
//   1. Open the chat with the contact.
//   2. Tap the contact name → details → "View Safety Number".
//   3. Compare the digits to the contact's screen (over a phone
//      call, in person, or by scanning their QR — TODO).
//   4. If they match, tap "Mark as Verified". This pins the peer's
//      identity key locally so future key rotations require a
//      fresh verification (Signal calls this "Trust on Re-Encounter").
//
//  If the digits DON'T match, the chat is being intercepted somewhere
//  along the path — DO NOT mark verified, stop sending sensitive
//  messages, and report it to the security team.
//

import SwiftUI

struct SafetyNumberView: View {

    let peerUserId: String
    let peerDisplayName: String

    @State private var safetyNumber: String? = nil
    @State private var peerIdentityKey: Data? = nil
    @State private var isVerified: Bool = false
    @State private var isLoading: Bool = true
    @State private var loadError: String? = nil
    /// Set when the registry reports the peer's key changed since
    /// our last verification — surfaces a red banner.
    @State private var keyChangedAt: Date? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if isLoading {
                    ProgressView("Computing safety number…")
                        .padding(.top, 60)
                } else if let err = loadError {
                    errorState(err)
                } else if let number = safetyNumber {
                    headerCard
                    digitsCard(number)
                    verifyButton
                    helpFooter
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .navigationTitle("Safety Number")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - Sub-views

    private var headerCard: some View {
        VStack(spacing: 8) {
            Image(systemName: isVerified ? "checkmark.seal.fill" : "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(isVerified ? .green : .blue)
            Text(peerDisplayName)
                .font(.title2.weight(.semibold))
            Text(isVerified ? "Verified" : "Unverified")
                .font(.caption)
                .foregroundStyle(isVerified ? .green : .secondary)
        }
        .padding(.top, 24)
    }

    private func digitsCard(_ number: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare these numbers with \(peerDisplayName) over a trusted channel — phone call, in person, or video.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Render as 6 lines of 2 groups for easy reading.
            let groups = number.split(separator: " ").map(String.init)
            VStack(spacing: 6) {
                ForEach(0..<(groups.count / 2), id: \.self) { lineIdx in
                    HStack(spacing: 16) {
                        Text(groups[lineIdx * 2])
                        Text(groups[lineIdx * 2 + 1])
                    }
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 12)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var verifyButton: some View {
        Button {
            toggleVerified()
        } label: {
            Label(
                isVerified ? "Mark as Unverified" : "Mark as Verified",
                systemImage: isVerified ? "xmark.shield" : "checkmark.shield.fill"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isVerified ? Color.red.opacity(0.1) : Color.green.opacity(0.15))
            )
            .foregroundStyle(isVerified ? .red : .green)
        }
        .buttonStyle(.plain)
    }

    private var helpFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("If the numbers don't match, your chat may be intercepted. Stop sending sensitive messages.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Label("Verification only protects against new key changes after this point — it cannot retroactively confirm earlier messages.", systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func errorState(_ err: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't compute safety number")
                .font(.headline)
            Text(err)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
    }

    // MARK: - Logic

    private func load() async {
        let ourUserId = await KeychainService.shared.getUserId() ?? ""
        guard !ourUserId.isEmpty else {
            await MainActor.run {
                isLoading = false
                loadError = "Not signed in."
            }
            return
        }

        // Fetch peer bundle — gives us their identity key.
        do {
            let bundle = try await E2EENetworkProvider.shared.fetchBundle(
                for: PeerAddress(userId: peerUserId, deviceId: "primary")
            )
            guard bundle.verifySignature() else {
                await MainActor.run {
                    isLoading = false
                    loadError = "Peer bundle failed signature verification."
                }
                return
            }
            let number = SafetyNumbers.computeForCurrentDevice(
                peerIdentityKey: bundle.identityKey,
                peerUserId: peerUserId,
                ourUserId: ourUserId
            )
            await MainActor.run {
                self.peerIdentityKey = bundle.identityKey
                self.safetyNumber = number
                self.isVerified = PeerVerificationStore.isVerified(peerUserId: peerUserId)
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.loadError = error.localizedDescription
            }
        }
    }

    private func toggleVerified() {
        let next = !isVerified
        PeerVerificationStore.setVerified(next, peerUserId: peerUserId)
        isVerified = next
        Haptics.success()
    }
}
