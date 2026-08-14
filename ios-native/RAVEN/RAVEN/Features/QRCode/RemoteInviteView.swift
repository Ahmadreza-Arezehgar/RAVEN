//
//  RemoteInviteView.swift
//  RAVEN
//
//  UI for remote contact add. Two halves:
//    • Create — publish a rendezvous and share a `raven://i/<token>` link.
//    • Redeem — paste a link someone sent you.
//
//  The copy here is deliberately explicit that the link is safe to send over
//  any messenger. That is the whole point of the feature and users will not
//  infer it: the token carries no identity and no keys, and it dies in minutes.
//

import SwiftUI

struct RemoteInviteView: View {

    @State private var service = RemoteInviteService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var token: String?
    @State private var redeemInput: String = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var acceptedName: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    createSection
                    Divider().opacity(0.3)
                    redeemSection
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding()
            }
            .navigationTitle("Add remotely")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // An invite that outlives its sheet is a rendezvous nobody is watching.
        .onDisappear { service.cancelActiveInvite() }
        // A pending redeemer means the invite is finished advertising; clear
        // the waiting UI so the approval gate is the only thing on screen.
        .onChange(of: service.pendingApproval?.userId) { _, newValue in
            if newValue != nil { token = nil }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text("Connect with someone who isn't with you")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Send the invite link over any app — a call, SMS, anything. It contains no identity and no keys, and it expires in 10 minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Create

    /// Approval gate for whoever redeemed our invite.
    ///
    /// The identity shown is the **derived fingerprint**, not the card's
    /// display name: the name is outside the signed transcript and is entirely
    /// attacker-chosen, so presenting it as the thing to verify would invite
    /// exactly the name-confusion this step exists to prevent.
    @ViewBuilder
    private var approvalSection: some View {
        if let pending = service.pendingApproval {
            VStack(alignment: .leading, spacing: 12) {
                Label("Someone redeemed your invite", systemImage: "person.badge.questionmark")
                    .font(.subheadline.weight(.semibold))
                Text("Confirm this is the person you sent the link to before adding them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Their identity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pending.fingerprint ?? pending.userId)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))

                if let name = pending.displayName ?? pending.username {
                    Text("They call themselves “\(name)” — this name is not verified.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        Task {
                            await service.approvePending()
                            acceptedName = service.lastAcceptedPeer.map {
                                $0.fingerprint ?? $0.userId
                            }
                        }
                    } label: {
                        Text("Add contact").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        service.rejectPending()
                        token = nil
                    } label: {
                        Text("Reject").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .glassSurface(in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private var createSection: some View {
        VStack(spacing: 12) {
            approvalSection
            if let accepted = acceptedName {
                Label("\(accepted) added", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 16))
            } else if let token {
                VStack(spacing: 10) {
                    Text("Waiting for them to open the link…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView()
                    Text(RemoteInviteService.link(for: token))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.thinMaterial))
                    HStack {
                        ShareLink(item: RemoteInviteService.link(for: token)) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(role: .destructive) {
                            service.cancelActiveInvite()
                            self.token = nil
                        } label: {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .glassSurface(in: RoundedRectangle(cornerRadius: 16))
            } else {
                Button {
                    Task { await createInvite() }
                } label: {
                    Label("Create an invite link", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
    }

    // MARK: - Redeem

    private var redeemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Got a link?")
                .font(.subheadline.weight(.semibold))
            TextField("raven://i/…", text: $redeemInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))
            Button {
                Task { await redeem() }
            } label: {
                Label("Connect", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || redeemInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Actions

    private func createInvite() async {
        busy = true
        defer { busy = false }
        errorText = nil
        acceptedName = nil
        do {
            token = try await service.createInvite()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func redeem() async {
        busy = true
        defer { busy = false }
        errorText = nil
        do {
            let peer = try await service.redeem(redeemInput)
            acceptedName = peer.displayName ?? peer.username ?? peer.userId
            redeemInput = ""
        } catch {
            errorText = error.localizedDescription
        }
    }
}

#Preview {
    RemoteInviteView()
}
