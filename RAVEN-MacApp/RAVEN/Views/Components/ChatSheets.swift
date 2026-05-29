// ChatSheets — modal sheets surfaced from the chat thread / inbox.
//
// Each one is a single-purpose view backed by a couple of NetworkService
// calls. We keep them in one file so adding more (mute, ban, role
// management, etc.) doesn't require yet another tiny .swift file.

import SwiftUI
import AppKit

// MARK: - ChatDetailsView (info / mute / leave / delete)

/// Surfaces conversation-level actions:
///   • Mute / unmute (1:1 only — server only honors the DM endpoint)
///   • Mark all as read
///   • Group: leave
///   • DM:    delete conversation (one-sided)
struct ChatDetailsView: View {
    let conversationId: String
    let isGroup: Bool
    let peerName: String
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthService
    @State private var isMuted = false
    @State private var working = false
    @State private var error: String?
    @State private var details: GroupDetails?
    @State private var confirmingDelete = false
    @State private var confirmingLeave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isGroup ? "Group info" : "Conversation info")
                    .font(.system(size: 17, weight: .heavy))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        AvatarView(letter: String(peerName.prefix(1)).uppercased(), size: 48, urlString: nil)
                        VStack(alignment: .leading) {
                            Text(peerName).font(.system(size: 16, weight: .bold))
                            if isGroup, let count = details?.members?.count {
                                Text("\(count) members").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Toggle(isOn: $isMuted) {
                        Label("Mute notifications", systemImage: "bell.slash")
                    }
                    .onChange(of: isMuted) { newValue in
                        Task {
                            try? await NetworkService.shared.muteConversation(
                                peerId: conversationId, muted: newValue)
                        }
                    }

                    if isGroup, let members = details?.members, !members.isEmpty {
                        Divider()
                        Text("Members").font(.system(size: 13, weight: .semibold))
                        ForEach(members) { m in
                            HStack {
                                AvatarView(
                                    letter: String(m.username.prefix(1)).uppercased(),
                                    size: 28,
                                    urlString: m.avatarPath
                                )
                                Text(m.username)
                                Spacer()
                                if let role = m.role, role != "member" {
                                    Text(role.capitalized)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.06))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    Divider()

                    if isGroup {
                        Button(role: .destructive, action: { confirmingLeave = true }) {
                            Label("Leave group", systemImage: "rectangle.portrait.and.arrow.right")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(role: .destructive, action: { confirmingDelete = true }) {
                            Label("Delete conversation", systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }

                    if let error {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 540)
        .task { await load() }
        .alert("Delete conversation?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This deletes the conversation for you only. \(peerName) keeps it.")
        }
        .alert("Leave group?", isPresented: $confirmingLeave) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) { Task { await leave() } }
        } message: {
            Text("You'll stop receiving messages from this group.")
        }
    }

    @MainActor
    private func load() async {
        guard isGroup else { return }
        do {
            details = try await NetworkService.shared.groupDetails(groupId: conversationId)
        } catch {
            // non-fatal — info screen still works without the member list
        }
    }

    @MainActor
    private func delete() async {
        working = true
        defer { working = false }
        do {
            try await NetworkService.shared.deleteConversation(peerId: conversationId)
            onDeleted()
            dismiss()
        } catch {
            self.error = "Couldn't delete."
        }
    }

    @MainActor
    private func leave() async {
        working = true
        defer { working = false }
        do {
            try await NetworkService.shared.leaveGroup(groupId: conversationId)
            onDeleted()
            dismiss()
        } catch {
            self.error = "Couldn't leave."
        }
    }
}

// MARK: - PinnedMessagesSheet

struct PinnedMessagesSheet: View {
    let conversationId: String
    let isGroup: Bool
    let onJump: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pinned: [PinnedMessage] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pinned messages").font(.system(size: 17, weight: .heavy))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            if loading {
                Spacer(); ProgressView(); Spacer()
            } else if pinned.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "pin.slash").font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No pinned messages").foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pinned) { p in
                            Button(action: { onJump(p.id); dismiss() }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(p.senderName ?? p.senderUsername ?? "Unknown")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(RavenColors.logoStart)
                                        Spacer()
                                        Text(timeFormatted(p.timestamp))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(p.content ?? typeLabel(p.messageType))
                                        .font(.system(size: 13))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 540)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            pinned = try await (
                isGroup
                    ? NetworkService.shared.pinnedGroup(groupId: conversationId)
                    : NetworkService.shared.pinnedDM(peerId: conversationId)
            )
        } catch {
            pinned = []
        }
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "voice": return "🎤 Voice message"
        case "image": return "🖼️ Image"
        case "file":  return "📎 File"
        default:      return type.capitalized
        }
    }

    private func timeFormatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - SavedMessagesSheet

struct SavedMessagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var router: ShellRouter
    @State private var items: [SavedMessageItem] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Saved messages").font(.system(size: 17, weight: .heavy))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            if loading {
                Spacer(); ProgressView(); Spacer()
            } else if items.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bookmark").font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No saved messages yet").foregroundStyle(.secondary)
                    Text("Right-click a message and pick Save for later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            SavedRow(item: item, onUnsave: { Task { await unsave(item) } })
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 600)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        items = (try? await NetworkService.shared.savedMessages()) ?? []
    }

    @MainActor
    private func unsave(_ item: SavedMessageItem) async {
        try? await NetworkService.shared.unsaveMessage(messageId: item.messageId, isGroup: item.isGroup)
        items.removeAll { $0.id == item.id }
    }
}

private struct SavedRow: View {
    let item: SavedMessageItem
    let onUnsave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.senderName ?? item.senderUsername ?? "Unknown")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(timeFormatted(item.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.content ?? typeLabel(item.messageType))
                    .font(.system(size: 13))
                    .lineLimit(3)
            }
            Button(action: onUnsave) {
                Image(systemName: "bookmark.slash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func typeLabel(_ type: String) -> String {
        switch type {
        case "voice": return "🎤 Voice message"
        case "image": return "🖼️ Image"
        case "file":  return "📎 File"
        default:      return type.capitalized
        }
    }

    private func timeFormatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - SharedMediaSheet

struct SharedMediaSheet: View {
    let messages: [Message]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shared media").font(.system(size: 17, weight: .heavy))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            if mediaURLs.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No shared media yet").foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                        ForEach(mediaURLs, id: \.self) { url in
                            AsyncImage(url: URL(string: url)) { phase in
                                switch phase {
                                case .success(let img): img.resizable().scaledToFill()
                                case .empty: ZStack { Color.white.opacity(0.06); ProgressView() }
                                case .failure: Color.white.opacity(0.06)
                                @unknown default: Color.white.opacity(0.06)
                                }
                            }
                            .frame(height: 130)
                            .clipped()
                            .cornerRadius(6)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 540, height: 600)
    }

    private var mediaURLs: [String] {
        messages.compactMap { m in
            guard m.isImage, let u = m.audioUrl, !u.isEmpty else { return nil }
            return u
        }
    }
}

// MARK: - ForwardSheet

struct ForwardSheet: View {
    let source: Message
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthService
    @State private var conversations: [ConversationSummary] = []
    @State private var loading = true
    @State private var sending = false
    @State private var search: String = ""
    @State private var error: String?
    @State private var sent: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Forward to…").font(.system(size: 17, weight: .heavy))
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .clipShape(Capsule())
            .padding(10)

            if loading {
                Spacer(); ProgressView(); Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { c in
                            Button(action: { Task { await forward(to: c) } }) {
                                HStack {
                                    AvatarView(
                                        letter: String((c.peer.username).prefix(1)).uppercased(),
                                        size: 32,
                                        urlString: c.isGroup ? c.groupAvatarUrl : c.peer.avatarPath
                                    )
                                    Text(c.isGroup ? (c.groupName ?? "Group") : c.peer.username)
                                    Spacer()
                                    if sent.contains(c.id) {
                                        Image(systemName: "checkmark").foregroundStyle(.green)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .disabled(sending)
                            Divider()
                        }
                    }
                }
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.caption).padding(8)
            }
        }
        .frame(width: 420, height: 520)
        .task { await load() }
    }

    private var filtered: [ConversationSummary] {
        let q = search.lowercased()
        guard !q.isEmpty else { return conversations }
        return conversations.filter { c in
            (c.peer.username.lowercased().contains(q)) ||
            (c.groupName?.lowercased().contains(q) ?? false)
        }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        conversations = (try? await NetworkService.shared.inbox()) ?? []
    }

    @MainActor
    private func forward(to c: ConversationSummary) async {
        sending = true
        defer { sending = false }
        let body = source.displayContent
        do {
            if c.isGroup {
                _ = try await NetworkService.shared.sendGroupMessage(
                    groupId: c.roomId, content: body)
            } else {
                _ = try await NetworkService.shared.sendMessage(
                    recipientId: c.peer.userId, content: body)
            }
            sent.insert(c.id)
        } catch {
            self.error = "Couldn't forward."
        }
    }
}

// MARK: - MessageInfoSheet

struct MessageInfoSheet: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Message info").font(.system(size: 17, weight: .heavy))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain)
            }
            Divider()

            row("Sent", value: format(message.timestamp))
            if let d = message.deliveredAt {
                row("Delivered", value: format(d))
            }
            if let r = message.readAt {
                row("Read", value: format(r))
            }
            if let e = message.editedAt {
                row("Edited", value: format(e))
            }
            if message.isPinned {
                row("Pinned", value: format(message.pinnedAt ?? Date()))
            }
            row("Type", value: (message.messageType ?? "text").capitalized)
            row("Message ID", value: message.id)

            Spacer()
        }
        .padding(16)
        .frame(width: 380, height: 380)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 13).monospacedDigit())
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: d)
    }
}
