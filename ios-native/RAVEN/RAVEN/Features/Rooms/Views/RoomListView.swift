import SwiftUI

/// List of live audio rooms with Liquid Glass design
struct RoomListView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var roomService = RoomService.shared
    @State private var showCreateSheet = false
    @State private var selectedRoom: AudioRoom?
    @State private var selectedTab: RoomTab = .publicRooms
    @State private var fetchError: String?  // Bug 14 fix: surface error to user
    private var feedStateManager: FeedStateManager { .shared }
    
    enum RoomTab: String, CaseIterable {
        case publicRooms = "Public"
        case friends = "Friends"
    }
    
    // Gradient colors for room cards
    private let cardGradients: [[Color]] = [
        [Color(hex: "667eea"), Color(hex: "764ba2")],  // Purple-Violet
        [Color(hex: "f093fb"), Color(hex: "f5576c")],  // Pink-Rose
        [Color(hex: "4facfe"), Color(hex: "00f2fe")],  // Blue-Cyan
        [Color(hex: "43e97b"), Color(hex: "38f9d7")],  // Green-Teal
        [Color(hex: "fa709a"), Color(hex: "fee140")],  // Pink-Yellow
        [Color(hex: "a8edea"), Color(hex: "fed6e3")],  // Mint-Pink
        [Color(hex: "ff0844"), Color(hex: "ffb199")],  // Red-Peach
        [Color(hex: "30cfd0"), Color(hex: "330867")],  // Cyan-Indigo
    ]
    
    /// Rooms to display based on selected tab
    private var displayedRooms: [AudioRoom] {
        switch selectedTab {
        case .publicRooms:
            return uniqueRooms(from: roomService.liveRooms)
        case .friends:
            return uniqueRooms(from: roomService.friendsRooms)
        }
    }
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(UIColor.systemBackground),
                    Color(UIColor.systemBackground).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Segmented picker
                Picker("Room Type", selection: $selectedTab) {
                    ForEach(RoomTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
                
                ScrollView {
                    LazyVStack(spacing: 16) {
                        // Bug 14 fix: show error banner when fetch fails
                        if let fetchError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(fetchError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Retry") {
                                    Task { await fetchRooms() }
                                }
                                .font(.caption.bold())
                            }
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        
                        if displayedRooms.isEmpty && !roomService.isLoading && fetchError == nil {
                            emptyState
                        } else {
                            ForEach(Array(displayedRooms.enumerated()), id: \.element.id) { index, room in
                                GlassRoomCard(
                                    room: room,
                                    gradient: cardGradients[index % cardGradients.count]
                                )
                                .onTapGesture {
                                    Haptics.selection()
                                    selectedRoom = room
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 100)
                }
                .refreshable {
                    await fetchRooms()
                }
            }
        }
        .navigationTitle("Live Rooms")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.selection()
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .blue)
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateRoomSheet { room in
                if room.privacy == .friends {
                    feedStateManager.selectedFeedTab = .friends
                } else if room.privacy == .public {
                    feedStateManager.selectedFeedTab = .local
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    selectedRoom = room
                }
            }
        }
        .fullScreenCover(item: $selectedRoom) { room in
            LiveRoomView(roomId: room.id)
        }
        .task {
            await fetchRooms()
        }
    }
    
    /// Fetch rooms for both tabs
    private func fetchRooms() async {
        fetchError = nil
        do {
            try await roomService.fetchLiveRooms()
            try await roomService.fetchFriendsRooms()
        } catch {
            fetchError = "Couldn't load rooms. Pull to retry."
            #if DEBUG
            print("❌ Failed to fetch rooms: \(error)")
            #endif
        }
    }
    
    // Filter duplicates by ID
    private func uniqueRooms(from rooms: [AudioRoom]) -> [AudioRoom] {
        var seen = Set<String>()
        return rooms.filter { room in
            if seen.contains(room.id) {
                return false
            }
            seen.insert(room.id)
            return true
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 24) {
            // Animated waveform
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.3), .blue.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                    .blur(radius: 20)
                
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 70))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.purple)
            }
            
            VStack(spacing: 8) {
                Text("No Live Rooms")
                    .font(.title2.bold())
                
                Text("Start a conversation by creating a new room")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button {
                Haptics.selection()
                showCreateSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Create Room")
                        .fontWeight(.semibold)
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [.purple, .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .shadow(color: .purple.opacity(0.4), radius: 12, y: 6)
            }
        }
        .padding(.top, 80)
    }
}

/// Glassmorphic room card with gradient accent
struct GlassRoomCard: View {
    let room: AudioRoom
    let gradient: [Color]
    
    @State private var isPressed = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header row
            HStack(spacing: 14) {
                // Host avatar with gradient ring
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: gradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                    
                    if let avatarUrl = room.hostAvatar, !avatarUrl.isEmpty {
                        AsyncImage(url: URL(string: avatarUrl)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                    } else {
                        Text(hostInitial)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.title)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Text(displayHostName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Live indicator
                LiveBadge()
            }
            
            // Description (if any)
            if let description = room.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            // Bottom row with stats
            HStack(spacing: 16) {
                // Participant count
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                    Text("\(room.participantCount)")
                        .font(.caption.bold())
                }
                .foregroundStyle(gradient[0])
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    gradient[0].opacity(0.15),
                    in: Capsule()
                )
                
                // Anonymous badge
                if room.allowAnonymous {
                    HStack(spacing: 4) {
                        Image(systemName: "theatermasks.fill")
                            .font(.caption)
                        Text("Anonymous")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Color.orange.opacity(0.15),
                        in: Capsule()
                    )
                }
                
                Spacer()
                
                // Join button
                HStack(spacing: 4) {
                    Text("Join")
                        .font(.caption.bold())
                    Image(systemName: "arrow.right")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: gradient,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
            }
        }
        .padding(18)
        .background(
            ZStack {
                // Gradient accent on left edge
                HStack {
                    LinearGradient(
                        colors: gradient,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: 4)
                    .clipShape(Capsule())
                    
                    Spacer()
                }
                
                // Glass background
                RoundedRectangle(cornerRadius: 22)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.primary.opacity(0.3),
                                        Color.primary.opacity(0.1),
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: gradient[0].opacity(0.2), radius: 15, y: 8)
        .scaleEffect(isPressed ? 0.98 : 1)
        .animation(.spring(response: 0.3), value: isPressed)
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity) {
            // Never triggers
        } onPressingChanged: { pressing in
            isPressed = pressing
        }
    }
    
    private var hostInitial: String {
        let name = room.hostName ?? room.title
        return String(name.prefix(1)).uppercased()
    }
    
    private var displayHostName: String {
        guard let hostName = room.hostName else {
            return "Host"
        }
        // If it looks like encoded data, show generic name
        if hostName.contains("==") || hostName.count > 30 {
            return "Host"
        }
        return hostName
    }
}

/// Pulsing live indicator badge
struct LiveBadge: View {
    @State private var isPulsing = false
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .scaleEffect(isPulsing ? 1.3 : 1)
                .animation(
                    .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                    value: isPulsing
                )
            
            Text("LIVE")
                .font(.caption.bold())
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.red.opacity(0.15))
        )
        .onAppear {
            isPulsing = true
        }
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#Preview {
    NavigationStack {
        RoomListView()
    }
}
