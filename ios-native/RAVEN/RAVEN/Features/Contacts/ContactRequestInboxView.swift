//
//  ContactRequestInboxView.swift
//  RAVEN — inbox UI for inbound RavenContactRequestV1 (behind ravenEnvelopeV1).
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
                        description: Text("Enable RavenEnvelopeV1 for serverless contact-request inbox.")
                    )
                }
            }
            .navigationTitle("Contact Requests")
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
            .onReceive(NotificationCenter.default.publisher(for: .ravenEnvelopeV1BleReceived)) { note in
                guard let body = note.userInfo?["sealedBody"] as? Data else { return }
                _ = model.ingestWire(body)
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
                    Text("Incoming RavenContactRequestV1 messages appear here after LAN/BLE delivery. Bridge never decrypts.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ForEach(model.pending) { item in
                    Section {
                        requestRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func requestRow(_ item: PendingContactRequest) -> some View {
        let hex = item.outer.requestId.ravenHex
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.inner.senderDisplayName.isEmpty
                         ? shortId(item.inner.senderRavenId)
                         : item.inner.senderDisplayName)
                        .font(.headline)
                    if !item.inner.senderAliases.isEmpty {
                        Text(item.inner.senderAliases.map { "@\($0)" }.joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.inner.senderRavenId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            if !item.inner.optionalMessage.isEmpty {
                Text(item.inner.optionalMessage)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            TextField("Petname (required to Accept)", text: bindingPetname(hex))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Button("Accept") {
                    Task {
                        actionError = nil
                        model.isBusy = true
                        defer { model.isBusy = false }
                        do {
                            try await model.accept(requestId: item.outer.requestId)
                        } catch RavenContactRequestError.petnameRequired {
                            actionError = "Enter a petname before Accept"
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)

                Button("Decline") {
                    actionError = nil
                    do {
                        try model.decline(requestId: item.outer.requestId)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)

                Button("Block", role: .destructive) {
                    actionError = nil
                    do {
                        try model.block(requestId: item.outer.requestId)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 4)
    }

    private func bindingPetname(_ hex: String) -> Binding<String> {
        Binding(
            get: { model.petnameDraft[hex] ?? "" },
            set: { model.petnameDraft[hex] = $0 }
        )
    }

    private func shortId(_ id: String) -> String {
        if id.count <= 16 { return id }
        return String(id.prefix(10)) + "…" + String(id.suffix(4))
    }
}

#Preview {
    ContactRequestInboxView()
}
