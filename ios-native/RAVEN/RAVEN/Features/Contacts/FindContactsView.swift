import SwiftUI

// MARK: - Find Contacts View
/// Discovery V1 search UI when `ravenEnvelopeV1` is ON.
/// QR add path remains available. Never FastAPI when serverless discovery is ON.
struct FindContactsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = DiscoverySearchViewModel()
    @State private var showScanner = false
    @State private var showMyQR = false
    @State private var showPasteWhoami = false
    @State private var isSending = false
    @State private var sendError: String?
    @State private var nearbyConfirmPeer: (deviceId: String, displayName: String, userId: String?)?
    @State private var nearbyPhraseInput = ""
    @State private var nearbyConfirmError: String?

    // Paste-from-terminal sheet fields
    @State private var pasteAddress = ""
    @State private var pastePubHex = ""
    @State private var pastePetname = ""
    @State private var pasteError: String?
    @State private var pasteOK: String?

    private var serverless: Bool { FeatureFlag.isRavenEnvelopeV1Enabled }

    var body: some View {
        NavigationStack {
            Group {
                if serverless {
                    discoveryBody
                } else {
                    meshEnvelopeFallback
                }
            }
            .navigationTitle(serverless ? "Discover" : "Find Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if serverless {
                            Button {
                                pasteError = nil
                                pasteOK = nil
                                showPasteWhoami = true
                            } label: {
                                Label("Paste ash whoami", systemImage: "doc.on.clipboard")
                            }
                        }
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            showMyQR = true
                        } label: {
                            Label("My QR Code", systemImage: "qrcode")
                        }
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                ScanQRCodeView()
            }
            .sheet(isPresented: $showMyQR) {
                MyQRCodeView()
            }
            .sheet(isPresented: $showPasteWhoami) {
                pasteWhoamiSheet
            }
            .alert(
                "Confirm nearby",
                isPresented: Binding(
                    get: { nearbyConfirmPeer != nil },
                    set: { if !$0 { nearbyConfirmPeer = nil } }
                )
            ) {
                TextField("Safety phrase", text: $nearbyPhraseInput)
                Button("Bind") {
                    guard let peer = nearbyConfirmPeer else { return }
                    do {
                        try model.confirmNearbyPeer(
                            deviceId: peer.deviceId,
                            displayName: peer.displayName,
                            userId: peer.userId,
                            enteredPhrase: nearbyPhraseInput
                        )
                        nearbyConfirmPeer = nil
                    } catch {
                        nearbyConfirmError = "Phrase mismatch or missing peer key — verify OOB first"
                    }
                }
                Button("Cancel", role: .cancel) {
                    nearbyConfirmPeer = nil
                }
            } message: {
                if let peer = nearbyConfirmPeer {
                    Text("Show phrase on both devices, then type it to bind:\n\(model.nearbySafetyPhrase(forDeviceId: peer.deviceId))\nFinding nearby ≠ verifying a person.")
                } else {
                    Text("Confirm safety phrase before pin.")
                }
            }
        }
        .task {
            if serverless {
                await model.refreshAndSearch()
            }
        }
    }

    // MARK: - Paste ash whoami

    private var pasteWhoamiSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("From Mac Terminal run `ash whoami` (or `ash init`). Paste address + pub_hex below — never a seed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("از ترمینال مک: ash whoami — فقط address و pub_hex را بچسبانید، هرگز seed را نه.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Raven address (rvn1…)") {
                    TextField("rvn1… or whole whoami block", text: $pasteAddress, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3...8)
                }
                Section("pub_hex (64 chars)") {
                    TextField("64 hex from whoami", text: $pastePubHex, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...6)
                }
                Section("Local petname") {
                    TextField("e.g. Ahmad Mac", text: $pastePetname)
                }
                if let pasteError {
                    Section {
                        Text(pasteError).foregroundStyle(.red).font(.footnote)
                    }
                }
                if let pasteOK {
                    Section {
                        Text(pasteOK).foregroundStyle(.green).font(.footnote)
                    }
                }
                Section {
                    Button("Save contact") {
                        do {
                            let c = try model.addContactFromWhoami(
                                addressOrBlob: pasteAddress,
                                pubHexOrBlob: pastePubHex,
                                petname: pastePetname
                            )
                            pasteError = nil
                            pasteOK = "Saved \(c.petname). You can message them after LAN/QR pairing."
                            pasteAddress = ""
                            pastePubHex = ""
                            pastePetname = ""
                        } catch {
                            pasteOK = nil
                            pasteError = error.localizedDescription
                        }
                    }
                    .disabled(pasteAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && pastePubHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Paste whoami")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showPasteWhoami = false }
                }
            }
        }
    }

    // MARK: - Serverless discovery

    private var discoveryBody: some View {
        VStack(spacing: 0) {
            scopePicker
            searchField
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            resultsList
            requestBar
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $model.scope) {
            ForEach(DiscoveryUIScope.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .onChange(of: model.scope) { _, _ in
            model.runSearch()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search @alias, rvn1…, or petname", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    Task { await model.refreshAndSearch() }
                }
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: model.query) { _, _ in
            model.runSearch()
        }
    }

    private var resultsList: some View {
        List {
            Section {
                Button {
                    pasteError = nil
                    pasteOK = nil
                    showPasteWhoami = true
                } label: {
                    Label("Paste from ash whoami / QR fields", systemImage: "doc.on.clipboard")
                }
                Text("Tip: Account → Serverless LAN to keep RavenEnvelopeV1 ON for Discover + LAN.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if model.requiresExplicitPick {
                Section {
                    Text("Multiple @alias claims — pick explicitly. Finding a name ≠ verifying a person.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if !model.results.isEmpty {
                Section {
                    ForEach(model.results, id: \.ravenId) { hit in
                        candidateRow(hit)
                    }
                } header: {
                    Text("Candidates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.scope == .nearby || model.scope == .all {
                if !model.liveNearbyPeers.isEmpty {
                    Section {
                        ForEach(model.liveNearbyPeers, id: \.deviceId) { peer in
                            Button {
                                nearbyPhraseInput = ""
                                nearbyConfirmError = nil
                                nearbyConfirmPeer = peer
                            } label: {
                                HStack {
                                    Image(systemName: "wave.3.right")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.displayName)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        Text("Ephemeral BLE — confirm safety phrase before binding")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "hand.raised")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Nearby (live)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text(model.scope.hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    private func candidateRow(_ hit: DiscoveryResult) -> some View {
        let selected = model.selectedRavenId == hit.ravenId
            || (!model.requiresExplicitPick && model.results.count == 1)
        return Button {
            model.selectCandidate(hit)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(hit.verificationState == .aliasConflict
                          ? Color.orange.opacity(0.25)
                          : Color.blue.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Text(String(hit.primaryLabel.prefix(1)).uppercased())
                            .font(.headline)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.primaryLabel)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let sub = hit.aliasSubtitle {
                        Text(sub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(hit.provenanceLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    Text(hit.ravenId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                } else if hit.verificationState == .aliasConflict {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private var requestBar: some View {
        VStack(spacing: 8) {
            if model.canSendRequest || model.requiresExplicitPick {
                TextField("Optional note", text: $model.requestNote)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
            }
            if let sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            Button {
                Task {
                    isSending = true
                    sendError = nil
                    defer { isSending = false }
                    do {
                        try await model.sendContactRequest()
                    } catch RavenContactRequestError.ambiguousPick {
                        sendError = "Pick a candidate first — never silent select on conflicts"
                    } catch RavenContactRequestError.missingKeys {
                        sendError = "Need a pubkey (local contact or signed alias claim) to seal"
                    } catch RavenContactRequestError.sessionRequired {
                        sendError = "Security hold: establish an authenticated ATSAM session before sending contact requests"
                    } catch RavenContactRequestError.blocked {
                        sendError = "Target is blocked locally"
                    } catch {
                        sendError = error.localizedDescription
                    }
                }
            } label: {
                HStack {
                    if isSending { ProgressView().tint(.white) }
                    Text(model.lastRequestIdHex == nil ? "Send Contact Request" : "Request Sent")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSendRequest || isSending)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(.bar)
    }

    // MARK: - Flag OFF: MeshEnvelope default — QR only + tip to enable flag

    private var meshEnvelopeFallback: some View {
        ContentUnavailableView {
            Label("Add via QR", systemImage: "qrcode.viewfinder")
        } description: {
            Text("Turn on RavenEnvelopeV1 for Discover + paste ash whoami.\n\nAccount → Serverless LAN · enable flag.\n\nبرای Discover فلگ RavenEnvelopeV1 را در Serverless LAN روشن کنید.")
        } actions: {
            Button {
                showScanner = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.ravenPrimary)
            Button {
                showMyQR = true
            } label: {
                Label("My QR Code", systemImage: "qrcode")
            }
        }
    }
}

#Preview {
    FindContactsView()
}
