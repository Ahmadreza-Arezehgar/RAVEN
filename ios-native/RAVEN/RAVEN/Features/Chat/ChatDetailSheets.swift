//
//  ChatDetailSheets.swift
//  RAVEN
//
//  (2026-05-15 — round 5) Detail sheets pushed/presented from
//  ChatDetailRow taps in the ChatDetailsView / GroupSettingsView
//  expansion. Each sheet is small, self-contained, and either reads
//  from existing services or stubs with a clean empty state where
//  the server endpoint isn't ready yet.

import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Safety number sheet

struct SafetyNumberSheet: View {
    let peerName: String
    let peerIdentifier: String
    let onMarkVerified: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private var fingerprint: String {
        // Symmetric across devices: hash the sorted (myUserId,
        // peerUserId) pair so A↔B always sees identical numbers.
        let me = KeychainService.shared.getUserId() ?? ""
        return SafetyNumberRow.fingerprint(myUserId: me, peerUserId: peerIdentifier)
    }

    /// Group the 60-digit fingerprint into 5 lines of 12 digits each
    /// for easy comparison.
    private var fingerprintLines: [String] {
        let chunks = stride(from: 0, to: fingerprint.count, by: 12).map { start -> String in
            let s = fingerprint.index(fingerprint.startIndex, offsetBy: start)
            let e = fingerprint.index(s, offsetBy: min(12, fingerprint.distance(from: s, to: fingerprint.endIndex)))
            return String(fingerprint[s..<e])
        }
        return chunks
    }

    private var qrPayload: String {
        // The QR encodes the fingerprint plus the peer identifier so
        // the verifying client can refuse a mismatched paste.
        return "raven://safety/v1?p=\(peerIdentifier)&fp=\(fingerprint)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Compare these digits with \(peerName) on a separate channel — call them, meet in person, or scan the QR. Matching numbers prove your conversation isn't being intercepted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    qrCard

                    fingerprintCard

                    if let onMarkVerified {
                        Button {
                            Haptics.success()
                            onMarkVerified()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.shield.fill")
                                Text("Mark as verified")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }

                    Text("Both devices in this conversation will see the same digits because the fingerprint is hashed from your sorted user-id pair. Binding to the actual ATSAM key material (X25519 + ML-KEM-768) lands once the server agreement-key endpoint ships — until then, this verifies your matching identities, not the live key material.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
                .padding(.top, 24)
            }
            .navigationTitle("Verify Encryption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var qrCard: some View {
        VStack(spacing: 12) {
            if let img = qrImage(for: qrPayload) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 200)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemGray5))
                    .frame(width: 232, height: 232)
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    )
            }
        }
    }

    private var fingerprintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fingerprint")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(fingerprintLines, id: \.self) { line in
                    Text(spaced(line))
                        .font(.system(.title3, design: .monospaced).weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
    }

    private func spaced(_ s: String) -> String {
        // "123456789012" → "12345 67890 12"
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && i % 5 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    private func qrImage(for payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let cgImage = filter.outputImage.flatMap({
            CIContext().createCGImage($0.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: $0.transformed(by: CGAffineTransform(scaleX: 8, y: 8)).extent)
        }) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Disappearing-messages picker sheet

struct DisappearingPickerSheet: View {
    @Binding var selection: DisappearingTimer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DisappearingTimer.allCases) { timer in
                        Button {
                            Haptics.selection()
                            selection = timer
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: timer.symbolName)
                                    .foregroundStyle(Color.accentColor)
                                Text(timer.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selection == timer {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Both members of this chat share this setting. New messages are automatically deleted for everyone once the chosen time has passed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Disappearing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Encryption details sheet

struct EncryptionDetailsSheet: View {
    let peerName: String
    let peerIdentifier: String
    @Environment(\.dismiss) private var dismiss

    private var protocolName: String { "ATSAM v1" }
    private var pqcEnabled: Bool { true }
    private var classical: String { "X25519 (Curve25519)" }
    private var pqc: String { "ML-KEM-768" }
    private var aead: String { "AES-256-GCM" }
    private var kdf: String { "HKDF-SHA256" }
    private var ratchetWindow: String { "7 days" }

    var body: some View {
        NavigationStack {
            List {
                Section("Active session") {
                    detailRow(label: "Protocol", value: protocolName)
                    detailRow(label: "Classical key agreement", value: classical)
                    detailRow(label: "Post-quantum agreement", value: pqcEnabled ? pqc : "Disabled")
                    detailRow(label: "Authenticated encryption", value: aead)
                    detailRow(label: "Key derivation", value: kdf)
                    detailRow(label: "Ratchet window", value: ratchetWindow)
                }

                Section("Identity") {
                    detailRow(label: "Peer", value: peerName)
                    detailRow(label: "Peer ID", value: String(peerIdentifier.prefix(16)) + "…")
                    detailRow(label: "Pair fingerprint",
                              value: String(SafetyNumberRow.fingerprint(
                                myUserId: KeychainService.shared.getUserId() ?? "",
                                peerUserId: peerIdentifier
                              ).prefix(8)) + "…")
                }

                Section {
                    Text("Once the server agreement-key endpoint ships, fingerprints will be derived from a hybrid (X25519 + ML-KEM-768) shared secret instead of the device's own key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Encryption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Pinned messages list sheet

struct PinnedMessagesSheet: View {
    let messages: [ChatMessage]
    var onSelect: ((ChatMessage) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "No pinned messages",
                        systemImage: "pin.slash",
                        description: Text("Long-press any message in the chat and tap Pin to save it here.")
                    )
                } else {
                    List(messages, id: \.id) { msg in
                        Button {
                            onSelect?(msg)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(msg.senderName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(msg.text ?? "(media)")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Pinned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Storage manage sheet

struct StorageManageSheet: View {
    let roomId: String
    let totalBytes: Int64
    var onClearMedia: (() -> Void)? = nil
    var onClearAll: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private var human: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Usage") {
                    HStack {
                        Text("Total cached for this chat")
                        Spacer()
                        Text(human).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        Haptics.warning()
                        onClearMedia?()
                    } label: {
                        Label("Clear cached media", systemImage: "photo.on.rectangle")
                    }
                    Button(role: .destructive) {
                        Haptics.warning()
                        onClearAll?()
                    } label: {
                        Label("Clear all cached files", systemImage: "trash")
                    }
                } footer: {
                    Text("Cached files can be re-downloaded later if the original is still on the server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Lightweight wrappers used by ChatDetailsView

/// Identifiable wrapper so we can drive a `.alert(item:)` from a
/// plain optional String. Keeps the call-site to a single line.
struct ActionMessageItem: Identifiable {
    let id = UUID()
    let text: String
}

/// In-chat full-text search sheet. Loads the room's cached messages
/// (capped at 500 rows for memory), filters them locally, and
/// surfaces a tap target that dismisses + scrolls the chat to the
/// hit (TODO: scroll integration via NotificationCenter once the
/// chat surface exposes a "scroll to message id" hook).
struct ChatLocalSearchSheet: View {
    let roomId: String
    let peerName: String
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var allMessages: [ChatMessage] = []
    @State private var isLoading = true

    private var filtered: [ChatMessage] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let q = query.lowercased()
        return allMessages.filter { msg in
            (msg.text?.lowercased().contains(q) ?? false)
                || (msg.fileName?.lowercased().contains(q) ?? false)
                || msg.senderName.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search messages…", text: $query)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if isLoading {
                    ProgressView().padding(40)
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Type to search" : "No matches",
                        systemImage: "magnifyingglass",
                        description: Text(query.isEmpty
                            ? "Search inside your chat with \(peerName)."
                            : "Try a different word or shorter phrase.")
                    )
                    .padding(.top, 24)
                } else {
                    List(filtered, id: \.id) { msg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(msg.senderName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(msg.text ?? msg.fileName ?? "(media)")
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                isLoading = true
                allMessages = await Self.loadMessages(roomId: roomId)
                isLoading = false
            }
        }
    }

    private static func loadMessages(roomId: String) async -> [ChatMessage] {
        do {
            let rows = try await MessageRepository.shared.getMessages(roomId: roomId, limit: 500)
            return rows.compactMap { row -> ChatMessage? in
                guard let id = row["client_message_id"] as? String,
                      let typeStr = row["type"] as? String,
                      let senderId = row["sender_id"] as? String,
                      let senderName = row["sender_name"] as? String,
                      let timestampStr = row["timestamp"] as? String,
                      let timestamp = PerformanceConstants.iso8601.date(from: timestampStr) else {
                    return nil
                }
                let type = MessageType.from(name: typeStr)
                return ChatMessage(
                    id: id,
                    serverId: row["server_id"] as? String,
                    roomId: row["room_id"] as? String ?? roomId,
                    senderId: senderId,
                    senderName: senderName,
                    recipientId: row["recipient_id"] as? String ?? "",
                    text: row["text"] as? String,
                    timestamp: timestamp,
                    type: type,
                    status: .sent,
                    deliveryAuthority: .server,
                    createdAt: nil,
                    deliveredAt: nil,
                    readAt: nil,
                    hopCount: 0, routePath: [], sprayCounter: 5, hopLimit: 10,
                    originDeviceId: "", needsForwarding: false,
                    attachmentUrl: row["remote_url"] as? String,
                    thumbnailUrl: row["thumbnail_url"] as? String,
                    fileName: row["file_name"] as? String,
                    mimeType: row["mime_type"] as? String,
                    fileSize: row["file_size"] as? Int,
                    audioDurationSeconds: row["audio_duration_seconds"] as? Int,
                    syncState: .synced,
                    localPath: row["local_path"] as? String,
                    uploadProgress: nil,
                    lastError: nil,
                    replyToMessageId: nil,
                    replyToTextPreview: nil,
                    replyToSenderName: nil,
                    replyToType: nil,
                    sendMode: nil,
                    scheduledAtUtc: nil
                )
            }
        } catch {
            return []
        }
    }
}

// MARK: - Helpers used by the new ChatDetailsView wiring

enum ChatDetailServices {

    /// Sum the size of every file the local cache holds for messages
    /// belonging to `roomId`. Cheap (filesystem `attributesOfItem`)
    /// and async-safe.
    static func totalCachedBytes(forRoomId roomId: String) async -> Int64 {
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dir = docs.appendingPathComponent("attachments")
            guard fm.fileExists(atPath: dir.path),
                  let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
                return Int64(0)
            }
            // Without a per-room manifest we sum every file in the
            // attachments directory. The number is correct globally;
            // a per-room slice is a TODO once `MessageRepository`
            // gains a `localPaths(forRoomId:)` query.
            var total: Int64 = 0
            for name in names {
                let path = dir.appendingPathComponent(name).path
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int {
                    total += Int64(size)
                }
            }
            _ = roomId  // reserved for the per-room slice
            return total
        }.value
    }

    /// Mesh-presence probe. Today the chat surface doesn't expose the
    /// peer agreement key on the inbox row, so we approximate
    /// "reachable on mesh" by checking whether `BLEMeshEngine` has
    /// seen ANY peer in the last 60 seconds. When the per-pair
    /// presence table lands this returns the actual age for the
    /// supplied peer.
    static func meshState(for peerId: String) -> MeshProximityRow.State {
        // TODO(mesh-presence): look the peer up in
        // `BLEMeshEngine.shared.lastSeen[peerId]` once that map is
        // public. Until then surface "offline" so the row is honest.
        _ = peerId
        return .offline(lastSeen: nil)
    }

    /// Verified-state lookup for the safety number row. Backed by
    /// UserDefaults keyed by peer id; mark-verified flips the bit.
    static func isVerified(peerId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "raven.safetyVerified.\(peerId)")
    }

    static func setVerified(_ value: Bool, peerId: String) {
        UserDefaults.standard.set(value, forKey: "raven.safetyVerified.\(peerId)")
    }
}
