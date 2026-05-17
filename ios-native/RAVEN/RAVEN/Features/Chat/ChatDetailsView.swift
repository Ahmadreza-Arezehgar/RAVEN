import SwiftUI

// MARK: - Nickname Storage (UserDefaults based)
/// Simple local nickname storage - persists nicknames per userId
actor NicknameStorage {
    static let shared = NicknameStorage()
    
    private let userDefaults = UserDefaults.standard
    private let key = "contact_nicknames"
    
    private init() {}
    
    func getNickname(for userId: String) async -> String? {
        guard let data = userDefaults.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict[userId]
    }
    
    func setNickname(_ nickname: String?, for userId: String) async {
        var dict: [String: String] = [:]
        if let data = userDefaults.data(forKey: key),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = existing
        }
        
        if let nickname = nickname, !nickname.isEmpty {
            dict[userId] = nickname
        } else {
            dict.removeValue(forKey: userId)
        }
        
        if let data = try? JSONEncoder().encode(dict) {
            userDefaults.set(data, forKey: key)
        }
    }
}

// MARK: - Section Enum
/// Type-safe section for the capsule switcher
enum ChatDetailSection: Int, CaseIterable, Identifiable {
    case media = 0
    case files = 1
    case voice = 2
    
    var id: Int { rawValue }
    
    var title: String {
        switch self {
        case .media: return "Media"
        case .files: return "Files"
        case .voice: return "Voice"
        }
    }
    
    var icon: String {
        switch self {
        case .media: return "photo.on.rectangle"
        case .files: return "doc"
        case .voice: return "waveform"
        }
    }
    
    var emptyTitle: String {
        switch self {
        case .media: return "No Photos"
        case .files: return "No Files"
        case .voice: return "No Voice Messages"
        }
    }
}

// MARK: - Chat Details View (Redesigned — Liquid Glass)
struct ChatDetailsView: View {
    let roomId: String
    let peer: Conversation.Peer
    
    @State private var selectedSection: ChatDetailSection = .media
    @State private var sharedMedia: [ChatMessage] = []
    @State private var isLoading = true
    @State private var showNicknameEditor = false
    @State private var displayName: String = ""
    @State private var appeared = false

    // 🆕 Mute toggle state. Hydrated from the in-memory ConversationStore on
    // appear (the UserDefaults-backed source of truth) and committed back to
    // both stores + the server when the user flips it.
    @State private var isMuted: Bool = false
    @State private var muteInFlight: Bool = false

    @Namespace private var switcherNamespace
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Fixed Header ──────────────────────────────────
                headerView
                    .padding(.top, DS.space16)
                    .padding(.bottom, DS.space12)
                
                // ── Fixed Capsule Section Switcher ────────────────
                capsuleSwitcher
                    .padding(.horizontal, DS.space16)
                    .padding(.bottom, DS.space12)
                
                // ── Scrollable Content (gesture-safe) ─────────────
                // BUG FIX: ScrollView ONLY wraps content, not header/switcher.
                // This prevents ScrollView from stealing tap gestures
                // from the capsule switcher segments.
                ScrollView {
                    contentArea
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
        }
        .sheet(isPresented: $showNicknameEditor) {
            EditNicknameView(
                userId: peer.userId,
                username: peer.username,
                currentName: displayName
            )
        }
        .task {
            // Load display name with nickname priority
            if let nickname = await NicknameStorage.shared.getNickname(for: peer.userId) {
                displayName = nickname
            } else {
                displayName = peer.displayName
            }
            // Hydrate mute state from the local conversation cache.
            isMuted = ConversationStore.shared.conversations
                .first(where: { $0.roomId == roomId })?.isMuted ?? false
            await loadSharedMedia()
            // Entrance animation
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }
    
    // MARK: - Floating Glass Header
    
    private var headerView: some View {
        VStack(spacing: DS.space12) {
            GlassAvatar(
                name: peer.displayName,
                path: peer.avatarPath,
                size: 80,
                showGlow: true,
                // Presence isn't fetched on the details screen — caller
                // shouldn't render a "fake" green dot. The chat view's
                // header already exposes the live online state next to
                // the peer name.
                showOnlineIndicator: false
            )
            
            VStack(spacing: DS.space4) {
                Text(displayName.isEmpty ? peer.displayName : displayName)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("@\(peer.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            // Action capsules row — mirror Apple Messages' contact card.
            HStack(spacing: 8) {
                // Edit nickname
                Button {
                    Haptics.selection()
                    showNicknameEditor = true
                } label: {
                    Label("Nickname", systemImage: "pencil")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )

                // Mute toggle (1:1 chats — server endpoint takes peer_id)
                Button {
                    toggleMute()
                } label: {
                    Label(isMuted ? "Muted" : "Mute",
                          systemImage: isMuted ? "bell.slash.fill" : "bell")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(isMuted ? Color.accentColor : .primary.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .contentTransition(.symbolEffect(.replace))
                }
                .background(
                    Capsule().fill(isMuted ? Color.accentColor.opacity(0.14) : .clear)
                )
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(
                        isMuted ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.10),
                        lineWidth: 0.5
                    )
                )
                .disabled(muteInFlight)
                .animation(.spring(response: 0.30, dampingFraction: 0.78), value: isMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.space16)
    }

    // MARK: - Mute toggle

    private func toggleMute() {
        Haptics.selection()
        let next = !isMuted
        // Optimistic flip — actual local + server sync handled by
        // ConversationStore.toggleMute (which also routes group vs DM).
        isMuted = next
        muteInFlight = true
        Task {
            await ConversationStore.shared.toggleMute(roomId: roomId)
            await MainActor.run { muteInFlight = false }
        }
    }
    
    // MARK: - Capsule Glass Section Switcher
    
    private var capsuleSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(ChatDetailSection.allCases) { section in
                // Each segment is an explicit tappable area
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedSection = section
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: section.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(section.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(selectedSection == section ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    // Reliable hit-testing for each segment
                    .contentShape(Rectangle())
                    .background {
                        if selectedSection == section {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .shadow(color: DS.shadowColor, radius: 4, y: 2)
                                .matchedGeometryEffect(id: "activeTab", in: switcherNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            Capsule()
                .fill(.primary.opacity(0.06))
        }
        // Ensure the entire switcher receives touch events
        .allowsHitTesting(true)
    }
    
    // MARK: - Content Area
    
    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            ProgressView()
                .padding(.top, 60)
        } else if filteredMedia.isEmpty {
            ContentUnavailableView(
                selectedSection.emptyTitle,
                systemImage: selectedSection.icon,
                description: Text("Shared media will appear here")
            )
            .padding(.top, 40)
            .transition(.opacity)
        } else {
            Group {
                switch selectedSection {
                case .media:
                    ChatMediaGridView(media: filteredMedia)
                case .files:
                    ChatFilesListView(files: filteredMedia)
                case .voice:
                    ChatVoiceListView(voiceMessages: filteredMedia)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedSection)
        }
    }
    
    // MARK: - Filtered Media
    
    private var filteredMedia: [ChatMessage] {
        switch selectedSection {
        case .media:
            return sharedMedia.filter { $0.type == .image }
        case .files:
            return sharedMedia.filter { $0.type == .file }
        case .voice:
            return sharedMedia.filter { $0.type == .voice }
        }
    }
    
    // MARK: - Load Shared Media
    
    private func loadSharedMedia() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let rows = try await MessageRepository.shared.getMessages(roomId: roomId, limit: 500)
            sharedMedia = rows.compactMap { row -> ChatMessage? in
                guard let typeStr = row["type"] as? String else { return nil }
                let type = MessageType.from(name: typeStr)
                guard [.image, .voice, .file].contains(type),
                      let id = row["client_message_id"] as? String,
                      let roomId = row["room_id"] as? String,
                      let senderId = row["sender_id"] as? String,
                      let senderName = row["sender_name"] as? String,
                      let timestampStr = row["timestamp"] as? String,
                      let timestamp = PerformanceConstants.iso8601.date(from: timestampStr) else {
                    return nil
                }
                
                return ChatMessage(
                    id: id,
                    serverId: row["server_id"] as? String,
                    roomId: roomId,
                    senderId: senderId,
                    senderName: senderName,
                    recipientId: row["recipient_id"] as? String ?? "",
                    text: row["text"] as? String,
                    timestamp: timestamp,
                    type: type,
                    status: MessageStatus(rawValue: row["status"] as? String ?? "") ?? .sent,
                    deliveryAuthority: DeliveryAuthority(rawValue: row["delivery_authority"] as? String ?? "") ?? .server,
                    createdAt: nil,
                    deliveredAt: nil,
                    readAt: nil,
                    hopCount: 0,
                    routePath: [],
                    sprayCounter: PremiumLimits.meshSprayBudget,
                    hopLimit: PremiumLimits.meshHopLimit,
                    originDeviceId: "",
                    needsForwarding: false,
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
            #if DEBUG
            print("Failed to load shared media: \\(error)")
            #endif
        }
    }
}

// MARK: - Chat Media Grid View (Liquid Glass)
struct ChatMediaGridView: View {
    let media: [ChatMessage]
    
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(media) { message in
                if let url = message.attachmentUrl {
                    ZStack(alignment: .bottomTrailing) {
                        AsyncImage(url: URL(string: url)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle()
                                .fill(.primary.opacity(0.06))
                                .overlay {
                                    ProgressView()
                                        .tint(.secondary)
                                }
                        }
                        // BUG FIX (2026-05-10): pin AsyncImage identity
                        // to the URL so cell reuse during scroll
                        // invalidates the cached phase and triggers a
                        // fresh load — without this, recycled tiles
                        // briefly show the previous cell's image until
                        // the new download settles.
                        .id(url)
                        .frame(height: 120)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous))
                        
                        // Video badge
                        if message.mimeType?.contains("video") == true {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.55))
                                .clipShape(Circle())
                                .padding(6)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DS.space16)
    }
}

// MARK: - Chat Files List View (Liquid Glass)
struct ChatFilesListView: View {
    let files: [ChatMessage]
    
    var body: some View {
        LazyVStack(spacing: DS.space8) {
            ForEach(files) { message in
                GlassCard {
                    HStack(spacing: 12) {
                        // File icon
                        Image(systemName: fileIcon(for: message.mimeType))
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 40, height: 40)
                            .background(.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: DS.radiusInner))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.fileName ?? "File")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            
                            HStack(spacing: 8) {
                                if let size = message.fileSize {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Text(message.timestamp, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        // Download/Open button
                        Button {
                            if let urlString = message.attachmentUrl,
                               let url = URL(string: urlString),
                               ["https", "http"].contains(url.scheme?.lowercased()) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.title3)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DS.space16)
    }
    
    private func fileIcon(for mimeType: String?) -> String {
        guard let mime = mimeType else { return "doc" }
        if mime.contains("pdf") { return "doc.text.fill" }
        if mime.contains("zip") || mime.contains("archive") { return "doc.zipper" }
        if mime.contains("word") || mime.contains("document") { return "doc.richtext" }
        if mime.contains("excel") || mime.contains("sheet") { return "tablecells" }
        return "doc.fill"
    }
}

// MARK: - Chat Voice List View (Liquid Glass)
struct ChatVoiceListView: View {
    let voiceMessages: [ChatMessage]
    
    @State private var playingId: String?
    
    var body: some View {
        LazyVStack(spacing: DS.space8) {
            ForEach(voiceMessages) { message in
                GlassCard {
                    HStack(spacing: 12) {
                        // Play button
                        Button {
                            Haptics.light()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                if playingId == message.id {
                                    playingId = nil
                                } else {
                                    playingId = message.id
                                }
                            }
                        } label: {
                            Image(systemName: playingId == message.id ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title)
                                .foregroundStyle(.blue)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        
                        // Waveform
                        ChatWaveformView(
                            isPlaying: playingId == message.id,
                            progress: 0.0
                        )
                        .frame(height: 30)
                        
                        // Duration
                        if let duration = message.audioDurationSeconds {
                            Text(formatDuration(duration))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 40)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DS.space16)
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Chat Waveform View
struct ChatWaveformView: View {
    let isPlaying: Bool
    let progress: Double
    
    @State private var animationPhase = 0.0
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<30, id: \.self) { i in
                    let height = barHeight(for: i, width: geo.size.width)
                    let isActive = Double(i) / 30.0 < progress
                    
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(isActive ? Color.blue : Color.secondary.opacity(0.3))
                        .frame(width: 3, height: height)
                        .animation(.easeInOut(duration: 0.15), value: isPlaying)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .onAppear {
            if isPlaying {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: true)) {
                    animationPhase = 1.0
                }
            }
        }
    }
    
    private func barHeight(for index: Int, width: CGFloat) -> CGFloat {
        let normalized = sin(Double(index) * 0.3 + animationPhase * .pi * 2)
        let base: CGFloat = isPlaying ? 8 : 6
        let variance: CGFloat = isPlaying ? 16 : 10
        return base + CGFloat(abs(normalized)) * variance
    }
}

// MARK: - Edit Nickname View
struct EditNicknameView: View {
    let userId: String
    let username: String
    let currentName: String
    
    @State private var nickname: String = ""
    @State private var isSaving = false
    @State private var currentNickname: String = ""
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nickname", text: $nickname)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                } header: {
                    Text("Custom Name")
                } footer: {
                    Text("This nickname is only visible to you. It will replace \"\(currentName)\" in your chats and messages.")
                }
                
                Section {
                    Button(role: .destructive) {
                        clearNickname()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Remove Nickname")
                        }
                    }
                    .disabled(currentNickname.isEmpty)
                }
            }
            .navigationTitle("Edit Nickname")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveNickname()
                    }
                    .disabled(nickname == currentNickname || isSaving)
                }
            }
        }
        .task {
            // Load existing nickname
            if let existing = await NicknameStorage.shared.getNickname(for: userId) {
                nickname = existing
                currentNickname = existing
            }
        }
    }
    
    private func saveNickname() {
        isSaving = true
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        
        Task {
            await NicknameStorage.shared.setNickname(trimmed.isEmpty ? nil : trimmed, for: userId)
            Haptics.success()
            
            await MainActor.run {
                dismiss()
            }
        }
    }
    
    private func clearNickname() {
        Task {
            await NicknameStorage.shared.setNickname(nil, for: userId)
            Haptics.success()
            
            await MainActor.run {
                dismiss()
            }
        }
    }
}

#Preview {
    ChatDetailsView(
        roomId: "test_room",
        peer: .init(
            userId: "123",
            username: "testuser",
            firstName: "Test",
            lastName: "User",
            avatarPath: nil
        )
    )
}
