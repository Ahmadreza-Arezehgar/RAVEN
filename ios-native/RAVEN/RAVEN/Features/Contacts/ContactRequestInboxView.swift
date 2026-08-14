//
//  ContactRequestInboxView.swift
//  RAVEN — PairInit friend-request inbox (behind ravenEnvelopeV1 + lab gate).
//

import SwiftUI

struct ContactRequestInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = ContactRequestInboxViewModel()
    @State private var actionError: String?

    private var serverless: Bool { FeatureFlag.isRavenEnvelopeV1Enabled }

    var body: some View {
        NavigationStack {
            Group {
                if serverless {
                    inboxBody
                } else {
                    ContentUnavailableView(
                        "Contact Requests",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Enable RavenEnvelopeV1 for serverless PairInit inbox.")
                    )
                }
            }
            .navigationTitle("Friend Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { model.reload() }
            .onReceive(NotificationCenter.default.publisher(for: .ravenPairInitReceived)) { note in
                guard let wire = note.userInfo?["wire"] as? Data else { return }
                _ = model.ingestPairInitWire(wire)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ravenEnvelopeV1EndpointIngest)) { note in
                // Sealed chat bodies are not friend requests.
                _ = note
            }
        }
    }

    private var inboxBody: some View {
        List {
            if let status = model.statusMessage {
                Section {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let actionError {
                Section {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if model.pending.isEmpty {
                Section {
                    Text("PairInit friend requests appear here after a LAN pull while the app is open. Legacy rootless contact ciphertext is never opened.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ForEach(model.pending) { item in
                    Section {
                        pairInitRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func pairInitRow(_ item: PendingPairInitRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.initiatorAddress)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
            Text("PairInit · \(item.initID.prefix(4).map { String(format: "%02x", $0) }.joined())…")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Accept") {
                    Task {
                        do {
                            try await model.accept(requestId: item.initID)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
                Button("Decline", role: .destructive) {
                    do {
                        try model.decline(requestId: item.initID)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
