// FriendRequestsSheet — pending incoming friend requests with
// Accept / Reject buttons. Opened from the Profile tile so the user can
// triage pending invites without leaving the macOS app.

import SwiftUI

struct FriendRequestsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var router: ShellRouter

    @State private var requests: [FriendRequestDTO] = []
    @State private var loading = true
    @State private var processing: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Friend requests").font(.title3.weight(.bold))
                Spacer()
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
                    ProgressView().padding(40).frame(maxWidth: .infinity)
                } else if requests.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No pending requests.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(60)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(requests) { req in
                            RequestRow(
                                request: req,
                                processing: processing.contains(req.id),
                                onAccept: { Task { await act(req, accept: true) } },
                                onReject: { Task { await act(req, accept: false) } },
                                onTapUser: {
                                    router.presentedProfileUserId = req.requesterId
                                }
                            )
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 520)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        do {
            requests = try await NetworkService.shared.friendRequests()
        } catch {
            print("👥 [requests] load failed: \(error)")
        }
        loading = false
    }

    @MainActor
    private func act(_ req: FriendRequestDTO, accept: Bool) async {
        processing.insert(req.id)
        defer { processing.remove(req.id) }
        do {
            if accept {
                try await NetworkService.shared.acceptFriendRequest(id: req.id)
            } else {
                try await NetworkService.shared.rejectFriendRequest(id: req.id)
            }
            requests.removeAll { $0.id == req.id }
        } catch {
            print("👥 [requests] action failed: \(error)")
        }
    }
}

private struct RequestRow: View {
    let request: FriendRequestDTO
    let processing: Bool
    let onAccept: () -> Void
    let onReject: () -> Void
    let onTapUser: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTapUser) {
                AvatarView(
                    letter: String(request.requesterUsername.prefix(1)).uppercased(),
                    size: 40,
                    urlString: request.requesterAvatar
                )
            }
            .buttonStyle(.plain)

            Button(action: onTapUser) {
                Text(request.requesterUsername)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onReject) {
                Text("Reject")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(processing)

            Button(action: onAccept) {
                Text(processing ? "…" : "Accept")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(LinearGradient.ravenBrand)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(processing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
