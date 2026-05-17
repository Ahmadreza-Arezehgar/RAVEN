import SwiftUI
import AVKit
import QuickLook

// MARK: - Shared Media View
struct SharedMediaView: View {
    let roomId: String
    let peerName: String
    
    @State private var selectedTab = 0
    @State private var photos: [MediaItem] = []
    @State private var files: [MediaItem] = []
    @State private var voices: [MediaItem] = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var selectedPhoto: MediaItem?
    @State private var selectedFile: MediaItem?
    @State private var playingVoice: MediaItem?
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("Media Type", selection: $selectedTab) {
                    Text("Photos").tag(0)
                    Text("Files").tag(1)
                    Text("Voice").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                
                // Content
                if isLoading {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.2)
                    Spacer()
                } else if let loadError {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("Couldn't load shared media")
                            .font(.headline)
                        Text(loadError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button {
                            Task { await loadMedia() }
                        } label: {
                            Label("Try again", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                } else {
                    TabView(selection: $selectedTab) {
                        PhotosGridView(
                            photos: photos,
                            onSelect: { item in
                                selectedPhoto = item
                            }
                        )
                        .tag(0)
                        
                        FilesListView(
                            files: files,
                            onSelect: { selectedFile = $0 }
                        )
                        .tag(1)
                        
                        VoiceListView(
                            voices: voices,
                            playingVoice: $playingVoice
                        )
                        .tag(2)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .navigationTitle("Shared Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(item: $selectedPhoto) { photo in
                PhotoViewerView(item: photo)
            }
            .sheet(item: $selectedFile) { file in
                FilePreviewView(item: file)
            }
        }
        .task {
            await loadMedia()
        }
    }
    
    // MARK: - Load Media from DB
    
    private func loadMedia() async {
        isLoading = true
        loadError = nil

        let messageRepo = MessageRepository.shared

        // Fetch all media messages for this room (both directions). Surface
        // failures so the user gets a retry instead of a silently empty grid.
        let allMessages: [[String: Any]]
        do {
            allMessages = try await messageRepo.getMessages(roomId: roomId, limit: 500)
        } catch {
            #if DEBUG
            print("❌ [SharedMedia] load failed: \(error)")
            #endif
            loadError = error.localizedDescription
            isLoading = false
            return
        }

        var photoItems: [MediaItem] = []
        var fileItems: [MediaItem] = []
        var voiceItems: [MediaItem] = []

        for row in allMessages {
            guard let typeStr = row["type"] as? String,
                  let id = row["client_message_id"] as? String,
                  let timestampStr = row["timestamp"] as? String,
                  let timestamp = PerformanceConstants.iso8601.date(from: timestampStr) else {
                continue
            }
            let type = MessageType.from(name: typeStr)
            
            let item = MediaItem(
                id: id,
                type: type,
                localPath: row["local_path"] as? String,
                remoteUrl: row["remote_url"] as? String,
                thumbnailUrl: row["thumbnail_url"] as? String,
                fileName: row["file_name"] as? String,
                fileSize: (row["file_size"] as? Int64).map { Int($0) },
                mimeType: row["mime_type"] as? String,
                duration: (row["audio_duration_seconds"] as? Int64).map { Int($0) },
                timestamp: timestamp,
                senderName: row["sender_name"] as? String ?? ""
            )
            
            switch type {
            case .image:
                photoItems.append(item)
            case .file:
                fileItems.append(item)
            case .voice:
                voiceItems.append(item)
            default:
                break
            }
        }
        
        // Sort by timestamp descending (newest first)
        photos = photoItems.sorted { $0.timestamp > $1.timestamp }
        files = fileItems.sorted { $0.timestamp > $1.timestamp }
        voices = voiceItems.sorted { $0.timestamp > $1.timestamp }
        
        isLoading = false
    }
}

// MARK: - Media Item Model

struct MediaItem: Identifiable {
    let id: String
    let type: MessageType
    let localPath: String?
    let remoteUrl: String?
    let thumbnailUrl: String?
    let fileName: String?
    let fileSize: Int?
    let mimeType: String?
    let duration: Int?
    let timestamp: Date
    let senderName: String
    
    var thumbnailDisplayURL: URL? {
        if let thumb = thumbnailUrl, !thumb.isEmpty {
            return AppConfig.mediaURL(from: thumb)
        }
        return displayURL
    }
    
    var displayURL: URL? {
        if let localPath = localPath {
            let fileName = URL(fileURLWithPath: localPath).lastPathComponent
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let localURL = docs.appendingPathComponent("attachments").appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
        }
        if let remote = remoteUrl {
            return AppConfig.mediaURL(from: remote)
        }
        return nil
    }
}

// MARK: - Photos Grid

struct PhotosGridView: View {
    let photos: [MediaItem]
    let onSelect: (MediaItem) -> Void
    
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    
    var body: some View {
        if photos.isEmpty {
            EmptyMediaView(icon: "photo", message: "No photos shared yet")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos) { photo in
                        PhotoThumbnailView(item: photo)
                            .onTapGesture { onSelect(photo) }
                    }
                }
            }
        }
    }
}

struct PhotoThumbnailView: View {
    let item: MediaItem
    
    var body: some View {
        GeometryReader { geo in
            let targetURL = item.displayURL
                
            if let url = targetURL {
                ZStack {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.width)
                            .clipped()
                    } placeholder: {
                        Rectangle()
                            .fill(.gray.opacity(0.2))
                            .overlay {
                                ProgressView()
                            }
                    }
                    

                }
            } else {
                Rectangle()
                    .fill(.gray.opacity(0.2))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Photo Viewer (Fullscreen with Zoom)

struct PhotoViewerView: View {
    let item: MediaItem
    
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let url = item.displayURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = lastScale * value
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                    if scale < 1 {
                                        withAnimation { scale = 1 }
                                        lastScale = 1
                                    }
                                }
                        )
                        .gesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    withAnimation {
                                        if scale > 1 {
                                            scale = 1
                                            lastScale = 1
                                        } else {
                                            scale = 2
                                            lastScale = 2
                                        }
                                    }
                                }
                        )
                } placeholder: {
                    ProgressView()
                        .tint(.white)
                }
            }
            
            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding()
                }
                Spacer()
                
                // Info bar
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.senderName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(item.timestamp, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    
                    // Share button
                    if let url = item.displayURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding()
                .background(.ultraThinMaterial)
            }
        }
    }
}

// MARK: - Files List

struct FilesListView: View {
    let files: [MediaItem]
    let onSelect: (MediaItem) -> Void
    
    var body: some View {
        if files.isEmpty {
            EmptyMediaView(icon: "doc", message: "No files shared yet")
        } else {
            List(files) { file in
                FileRowView(item: file)
                    .onTapGesture { onSelect(file) }
            }
            .listStyle(.plain)
        }
    }
}

struct FileRowView: View {
    let item: MediaItem
    
    var body: some View {
        HStack(spacing: 12) {
            // File icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName ?? "File")
                    .font(.subheadline)
                    .lineLimit(1)
                
                HStack {
                    if let size = item.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    Text("•")
                    Text(item.timestamp, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    var iconName: String {
        guard let mime = item.mimeType else { return "doc" }
        if mime.contains("pdf") { return "doc.text" }
        if mime.contains("word") || mime.contains("document") { return "doc.richtext" }
        if mime.contains("spreadsheet") || mime.contains("excel") { return "tablecells" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.stack" }
        return "doc"
    }
    
    var iconColor: Color {
        guard let mime = item.mimeType else { return .blue }
        if mime.contains("pdf") { return .red }
        if mime.contains("word") { return .blue }
        if mime.contains("spreadsheet") || mime.contains("excel") { return .green }
        if mime.contains("presentation") { return .orange }
        return .blue
    }
}

// MARK: - File Preview (QuickLook)

struct FilePreviewView: View {
    let item: MediaItem
    
    @State private var previewURL: URL?
    @State private var isDownloading = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Group {
                if isDownloading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Downloading...")
                            .foregroundStyle(.secondary)
                    }
                } else if let url = previewURL {
                    QuickLookPreview(url: url)
                } else {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "doc.questionmark",
                        description: Text("This file cannot be previewed")
                    )
                }
            }
            .navigationTitle(item.fileName ?? "File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                
                if let url = previewURL {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: url)
                    }
                }
            }
        }
        .task {
            await loadFile()
        }
        .onDisappear {
            // Clean up temp file to avoid filling device storage
            if let url = previewURL, url.path.contains(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    
    private func loadFile() async {
        // Check local first
        if let localPath = item.localPath {
            let fileName = URL(fileURLWithPath: localPath).lastPathComponent
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let localURL = docs.appendingPathComponent("attachments").appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: localURL.path) {
                previewURL = localURL
                return
            }
        }
        
        // Download from remote
        guard let remote = item.remoteUrl, let url = AppConfig.mediaURL(from: remote) else { return }
        
        isDownloading = true
        
        do {
            // FIX: Build authenticated request — media server requires Bearer token
            var request = URLRequest(url: url)
            if let (token, _) = await KeychainService.shared.getToken() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            // Disk-based download — avoids loading entire file into RAM (OOM for 2GB files)
            let (tempLocalUrl, response) = try await URLSession.shared.download(for: request)
            
            // Validate HTTP response
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }
            
            var safeName = URL(fileURLWithPath: item.fileName ?? "file").lastPathComponent
            if !safeName.contains(".") {
                if item.mimeType?.contains("pdf") == true {
                    safeName += ".pdf"
                } else if item.mimeType?.contains("word") == true {
                    safeName += ".docx"
                } else if item.mimeType?.contains("excel") == true {
                    safeName += ".xlsx"
                }
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(item.id)_\(safeName)")
            
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.moveItem(at: tempLocalUrl, to: tempURL)
            
            previewURL = tempURL
        } catch {
            #if DEBUG
            print("[SharedMedia] Download failed: \(error)")
            #endif
        }
        
        isDownloading = false
    }
}

// MARK: - QuickLook Wrapper

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        
        init(url: URL) {
            self.url = url
        }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

// MARK: - Voice List

struct VoiceListView: View {
    let voices: [MediaItem]
    @Binding var playingVoice: MediaItem?
    
    var body: some View {
        if voices.isEmpty {
            EmptyMediaView(icon: "mic", message: "No voice messages yet")
        } else {
            List(voices) { voice in
                VoiceRowView(
                    item: voice,
                    isPlaying: playingVoice?.id == voice.id,
                    onPlayPause: {
                        if playingVoice?.id == voice.id {
                            playingVoice = nil
                        } else {
                            playingVoice = voice
                        }
                    }
                )
            }
            .listStyle(.plain)
        }
    }
}

struct VoiceRowView: View {
    let item: MediaItem
    let isPlaying: Bool
    let onPlayPause: () -> Void
    
    // Bug 8 fix: Use global AudioPlaybackStore instead of local VoicePlayer
    // This prevents multiple voice messages from playing simultaneously
    private var playbackStore: AudioPlaybackStore { AudioPlaybackStore.shared }
    
    private var audioItem: AudioItem {
        AudioItem(
            id: item.id,
            voiceUrl: item.displayURL?.absoluteString ?? "",
            duration: item.duration ?? 0,
            waveform: nil,
            senderName: item.senderName.looksEncrypted ? "Voice Message" : item.senderName,
            senderAvatar: nil,
            contentId: item.id,
            contentType: "dm"
        )
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Play button
            Button(action: {
                onPlayPause()
                playbackStore.play(item: audioItem)
            }) {
                ZStack {
                    Circle()
                        .fill(.blue.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: playbackStore.isCurrentlyPlaying(itemId: item.id) ? "pause.fill" : "play.fill")
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 4) {
                // Waveform / Progress
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(.gray.opacity(0.2))
                        
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(.blue)
                            .frame(width: geo.size.width * playbackStore.progressFor(itemId: item.id))
                    }
                }
                .frame(height: 20)
                
                HStack {
                    Text(item.senderName)
                        .font(.caption)
                    Spacer()
                    if let duration = item.duration {
                        Text("\(duration)s")
                            .font(.caption)
                    }
                    Text(item.timestamp, style: .time)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// VoicePlayer class removed — Bug 8 fix: all playback now goes through AudioPlaybackStore.shared

// MARK: - Empty State

struct EmptyMediaView: View {
    let icon: String
    let message: String
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SharedMediaView(roomId: "test_123", peerName: "Test User")
}
