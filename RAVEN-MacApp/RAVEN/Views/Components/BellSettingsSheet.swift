// BellSettingsSheet — per-user notification toggles.
//
// Opens from the bell icon on `UserProfileSheet`. Mirrors the iOS-side
// `ProfileBellSettingsSheet.swift` so the two UIs feel like the same
// product. Two toggles, no other surprises:
//
//   • Posts          — push when this user publishes a post
//   • Audio rooms    — push when this user starts an audio room
//
// The server stores the pair in `user_notification_subscriptions`
// keyed on (subscriber, target). Flipping both toggles off DELETEs
// the row entirely — matches the iOS behavior so the two clients
// stay in sync.

import SwiftUI

struct BellSettingsSheet: View {
    let userId: String
    let displayName: String

    @Environment(\.dismiss) private var dismiss

    @State private var notifyPosts = false
    @State private var notifyAudioRooms = false
    @State private var loading = true
    @State private var syncing = false
    @State private var showSuccess = false
    @State private var error: String?

    /// Debounced sync — collapses rapid toggle taps into one POST.
    @State private var syncTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(LinearGradient.ravenBrand)
                    Text("Notifications").font(.title3.weight(.bold))
                }
                Spacer()
                if showSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else if syncing {
                    ProgressView().controlSize(.small)
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                if loading {
                    ProgressView()
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Push notifications from **\(displayName)**")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)

                        VStack(spacing: 0) {
                            toggleRow(
                                icon: "doc.text.fill",
                                title: "New posts",
                                subtitle: "Notify me when they publish a post.",
                                value: $notifyPosts
                            )
                            Divider().padding(.leading, 56)
                            toggleRow(
                                icon: "waveform.circle.fill",
                                title: "Audio rooms",
                                subtitle: "Notify me when they start an audio room.",
                                value: $notifyAudioRooms
                            )
                        }
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20)

                        Text("These settings only apply to \(displayName). Turn both off to stop all notifications from this account.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                            .padding(.bottom, 18)
                    }
                }
            }
        }
        .frame(width: 460, height: 360)
        .task { await load() }
        .animation(.easeInOut(duration: 0.18), value: showSuccess)
    }

    // MARK: - Toggle row

    @ViewBuilder
    private func toggleRow(
        icon: String,
        title: String,
        subtitle: String,
        value: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(LinearGradient.ravenBrand)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: value)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _ in scheduleSync() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Network

    @MainActor
    private func load() async {
        loading = true
        error = nil
        do {
            let sub = try await NetworkService.shared.bellSubscription(userId: userId)
            notifyPosts = sub.notifyPosts
            notifyAudioRooms = sub.notifyAudioRooms
        } catch {
            // Server returns 404 when no subscription exists yet — that's
            // fine, both toggles start off. Only surface real errors.
            if let api = error as? APIError, case .http(404, _) = api {
                notifyPosts = false
                notifyAudioRooms = false
            } else {
                #if DEBUG
                print("[bell] load failed: \(error)")
                #endif
                self.error = "Couldn't load notification settings."
            }
        }
        loading = false
    }

    /// Debounce burst toggles so we don't flood the server with
    /// POST+DELETE pairs when the user fiddles.
    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    @MainActor
    private func sync() async {
        syncing = true
        defer { syncing = false }
        do {
            if !notifyPosts && !notifyAudioRooms {
                // Both off → delete the row entirely. Matches iOS.
                try await NetworkService.shared.deleteBellSubscription(userId: userId)
            } else {
                _ = try await NetworkService.shared.setBellSubscription(
                    userId: userId,
                    notifyPosts: notifyPosts,
                    notifyAudioRooms: notifyAudioRooms
                )
            }
            // Brief visual confirmation.
            showSuccess = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showSuccess = false
        } catch {
            #if DEBUG
            print("[bell] sync failed: \(error)")
            #endif
            self.error = "Couldn't update notification settings."
        }
    }
}
