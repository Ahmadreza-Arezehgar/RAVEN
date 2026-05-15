import SwiftUI

/// Room status sheet showing stats and host controls
struct RoomStatusSheet: View {
    let room: AudioRoom
    let participantCount: Int
    let speakerCount: Int
    let requestCount: Int
    let isHost: Bool
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var roomService = RoomService.shared
    @ObservedObject var audioManager = AudioRoomManager.shared
    
    @State private var isLocked = false
    @State private var allowRaiseHand = true
    @State private var allowAnonymous = true
    @State private var showEndRoomAlert = false
    @State private var showReportSheet = false  // UGC compliance
    @State private var roomUptime: TimeInterval = 0
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Glass background
                Color.black.opacity(0.3)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Stats Grid
                        statsGrid
                        
                        // Connection Quality
                        connectionQualityCard
                        
                        // Host Controls
                        if isHost {
                            hostControlsSection
                        }
                        
                        // Danger Zone
                        if isHost {
                            dangerZoneSection
                        }
                        
                        // Report button (non-hosts only — UGC compliance)
                        if !isHost {
                            Button {
                                showReportSheet = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Report Room")
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                                .padding()
                            }
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Room Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .onAppear {
            isLocked = room.isLocked ?? false
            allowRaiseHand = room.allowRaiseHand
            allowAnonymous = room.allowAnonymous
            roomUptime = Date().timeIntervalSince(room.createdAt)
        }
        .onReceive(timer) { _ in
            roomUptime = Date().timeIntervalSince(room.createdAt)
        }
        .alert("End Room?", isPresented: $showEndRoomAlert) {
            Button("Cancel", role: .cancel) {}
            Button("End Room", role: .destructive) {
                endRoom()
            }
        } message: {
            Text("This will remove all participants and close the room permanently.")
        }
        // Report Sheet (UGC compliance — required for App Store)
        .sheet(isPresented: $showReportSheet) {
            ReportView(
                targetType: .room,
                targetId: room.id,
                targetName: room.title,
                reportedUserId: room.hostUserId
            )
        }
    }
    
    // MARK: - Stats Grid
    
    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            statCard(icon: "person.2.fill", value: "\(participantCount)", label: "Participants", color: .blue)
            statCard(icon: "mic.fill", value: "\(speakerCount)", label: "Speakers", color: .green)
            statCard(icon: "hand.raised.fill", value: "\(requestCount)", label: "Requests", color: .orange)
            statCard(icon: "clock.fill", value: formatUptime(roomUptime), label: "Uptime", color: .purple)
        }
    }
    
    private func statCard(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(value)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    // MARK: - Connection Quality
    
    private var connectionQualityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.headline)
                .foregroundStyle(.white)
            
            HStack {
                // Quality indicator
                HStack(spacing: 4) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(qualityColor(for: i))
                            .frame(width: 6, height: 8 + CGFloat(i * 4))
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionQualityText)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    
                    if audioManager.isConnected {
                        Text("Connected to LiveKit")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                
                Spacer()
                
                // Status dot
                Circle()
                    .fill(audioManager.isConnected ? .green : .red)
                    .frame(width: 10, height: 10)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    private var connectionQualityText: String {
        audioManager.isConnected ? "Excellent" : "Disconnected"
    }
    
    private func qualityColor(for index: Int) -> Color {
        if !audioManager.isConnected {
            return .gray.opacity(0.3)
        }
        // Connection quality based on WebRTC state
        return .green
    }
    
    // MARK: - Host Controls
    
    private var hostControlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Room Settings")
                .font(.headline)
                .foregroundStyle(.white)
            
            VStack(spacing: 0) {
                Toggle(isOn: $isLocked) {
                    Label("Lock Room", systemImage: "lock.fill")
                        .foregroundStyle(.white)
                }
                .toggleStyle(SwitchToggleStyle(tint: .orange))
                .padding()
                .onChange(of: isLocked) { _, newValue in
                    updateRoomSetting("is_locked", newValue)
                }
                
                Divider().background(.white.opacity(0.2))
                
                Toggle(isOn: $allowRaiseHand) {
                    Label("Allow Raise Hand", systemImage: "hand.raised.fill")
                        .foregroundStyle(.white)
                }
                .toggleStyle(SwitchToggleStyle(tint: .green))
                .padding()
                .onChange(of: allowRaiseHand) { _, newValue in
                    updateRoomSetting("allow_raise_hand", newValue)
                }
                
                Divider().background(.white.opacity(0.2))
                
                Toggle(isOn: $allowAnonymous) {
                    Label("Allow Anonymous", systemImage: "person.fill.questionmark")
                        .foregroundStyle(.white)
                }
                .toggleStyle(SwitchToggleStyle(tint: .purple))
                .padding()
                .onChange(of: allowAnonymous) { _, newValue in
                    updateRoomSetting("allow_anonymous", newValue)
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
    
    // MARK: - Danger Zone
    
    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Danger Zone")
                .font(.headline)
                .foregroundStyle(.red)
            
            VStack(spacing: 0) {
                Button {
                    muteAllSpeakers()
                } label: {
                    HStack {
                        Label("Mute All Speakers", systemImage: "speaker.slash.fill")
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding()
                }
                
                Divider().background(.white.opacity(0.2))
                
                Button {
                    showEndRoomAlert = true
                } label: {
                    HStack {
                        Label("End Room for Everyone", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding()
                }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
    
    // MARK: - Helper Functions
    
    private func formatUptime(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    private func updateRoomSetting(_ key: String, _ value: Bool) {
        Task {
            do {
                try await roomService.updateSettings(roomId: room.id, key: key, value: value)
                #if DEBUG
                print("✅ Updated room \(room.id): \(key) = \(value)")
                #endif
            } catch {
                #if DEBUG
                print("❌ Failed to update room setting: \(error)")
                #endif
            }
        }
    }
    
    private func muteAllSpeakers() {
        Task {
            do {
                try await roomService.muteAll(roomId: room.id)
            } catch {
                #if DEBUG
                print("❌ Failed to mute all: \(error)")
                #endif
            }
        }
    }
    
    private func endRoom() {
        Task {
            do {
                try await roomService.endRoom(roomId: room.id)
                dismiss()
            } catch {
                #if DEBUG
                print("❌ Failed to end room: \(error)")
                #endif
            }
        }
    }
}

#Preview {
    RoomStatusSheet(
        room: AudioRoom(
            id: "1",
            title: "Test Room",
            description: nil,
            hostUserId: "host",
            hostName: "Ahmad",
            hostAvatar: nil,
            roomImageUrl: nil,
            privacy: .public,
            allowAnonymous: true,
            allowRaiseHand: true,
            isLocked: false,
            isLive: true,
            participantCount: 12,
            maxParticipants: 100,
            createdAt: Date().addingTimeInterval(-3600),
            shareSlug: "test-room"
        ),
        participantCount: 12,
        speakerCount: 3,
        requestCount: 2,
        isHost: true
    )
    .preferredColorScheme(.dark)
}
