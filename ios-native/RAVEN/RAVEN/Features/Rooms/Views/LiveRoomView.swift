import SwiftUI
import AVFoundation
import Combine

// MARK: - Design Tokens

private enum RoomDesign {
    static let accent = Color(hue: 0.55, saturation: 0.35, brightness: 0.55)       // muted teal
    static let accentBright = Color(hue: 0.55, saturation: 0.45, brightness: 0.7)
    static let speakingGlow = Color(hue: 0.42, saturation: 0.5, brightness: 0.6)    // soft green
    static let dangerSoft = Color(red: 0.75, green: 0.2, blue: 0.2)
    static let cardBg = Color.white.opacity(0.06)
    static let border = Color.white.opacity(0.12)
    static let labelPrimary = Color.white
    static let labelSecondary = Color.white.opacity(0.55)
    static let labelTertiary = Color.white.opacity(0.35)
    
    static let pulseDuration: Double = 0.25
    static let pulseSpring = Animation.spring(response: 0.25, dampingFraction: 0.7)
}

// MARK: - Live Room View

/// Full-screen live audio room view with modern premium design
struct LiveRoomView: View {
    let roomId: String
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var roomService = RoomService.shared
    @ObservedObject private var audioManager = AudioRoomManager.shared

    
    @State private var showLeaveAlert = false
    @State private var showRequests = false
    @State private var showPeoplePanel = false
    @State private var showRoomStatus = false
    @State private var showJoinOptions = false
    @State private var joinAnonymous = false
    @State private var hasJoined = false
    @State private var myParticipant: AudioRoomParticipant?
    @State private var showMicPermissionAlert = false
    @State private var connectionError: String?
    @State private var loadError: String? = nil
    @State private var livePulse = false

    
    // ⚡ Audit fix: Use a connect-on-demand publisher we can cancel on view exit.
    // Previously `.autoconnect()` started the timer the moment the view was
    // initialised AND kept firing until the view's value-type was deallocated,
    // wasting CPU after dismiss. We now connect in `.onAppear` and cancel in
    // `.onDisappear` via `timerCancellable`.
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common)
    @State private var timerCancellable: Cancellable?
    
    // Gradient palette for participant avatars
    private let gradients: [[Color]] = [
        [Color(hue: 0.75, saturation: 0.35, brightness: 0.45), Color(hue: 0.85, saturation: 0.3, brightness: 0.5)],
        [Color(hue: 0.55, saturation: 0.3, brightness: 0.45), Color(hue: 0.5, saturation: 0.35, brightness: 0.5)],
        [Color(hue: 0.08, saturation: 0.35, brightness: 0.5), Color(hue: 0.12, saturation: 0.3, brightness: 0.55)],
        [Color(hue: 0.35, saturation: 0.3, brightness: 0.4), Color(hue: 0.42, saturation: 0.25, brightness: 0.5)],
        [Color(hue: 0.65, saturation: 0.3, brightness: 0.45), Color(hue: 0.7, saturation: 0.35, brightness: 0.5)],
        [Color(hue: 0.95, saturation: 0.3, brightness: 0.45), Color(hue: 0.0, saturation: 0.35, brightness: 0.5)],
    ]
    
    var body: some View {
        ZStack {
            // Dark mesh gradient background (with iOS 18 check)
            if #available(iOS 18.0, *) {
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [0.5, 0.5], [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1]
                    ],
                    colors: [
                        Color(white: 0.04), Color(red: 0.06, green: 0.04, blue: 0.1), Color(white: 0.03),
                        Color(red: 0.04, green: 0.03, blue: 0.08), Color(red: 0.08, green: 0.05, blue: 0.12), Color(red: 0.05, green: 0.04, blue: 0.09),
                        Color(white: 0.03), Color(red: 0.04, green: 0.03, blue: 0.07), Color(white: 0.04)
                    ]
                )
                .ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [Color(white: 0.04), Color(red: 0.08, green: 0.05, blue: 0.12), Color(white: 0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            
            if let detail = roomService.currentRoom {
                if hasJoined {
                    joinedContent(detail)
                } else {
                    joinGate
                }
            } else if let error = loadError {
                // Error state — shown when room fetch fails (invalid link, deleted room, etc.)
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Room Unavailable")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Go Back") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.white.opacity(0.2))
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                }
            } else {
                loadingState
            }
        }
        .task { await loadRoom() }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                livePulse = true
            }
        }
        .alert("Leave Room?", isPresented: $showLeaveAlert) {
            Button("Stay", role: .cancel) {}
            Button("Leave", role: .destructive) {
                Task {
                    await AudioRoomManager.shared.disconnect()
                    try? await roomService.leaveRoom(roomId: roomId)
                    AudioRoomActivityManager.shared.endActivity()
                    dismiss()
                }
            }
        }
        .alert("Microphone Access Required", isPresented: $showMicPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audio rooms require microphone access. Please enable it in Settings.")
        }
        .alert("Connection Error", isPresented: .constant(connectionError != nil)) {
            Button("OK") { connectionError = nil }
        } message: {
            Text(connectionError ?? "Unknown error")
        }

        .sheet(isPresented: $showRequests) {
            RequestsSheet(roomId: roomId)
        }
        .sheet(isPresented: $showPeoplePanel, onDismiss: {
            Task { await refreshParticipants() }
        }) {
            if let detail = roomService.currentRoom {
                PeoplePanel(
                    roomId: roomId,
                    participants: detail.participants,
                    isHost: myParticipant?.role == .host || myParticipant?.role == .cohost
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showRoomStatus) {
            if let detail = roomService.currentRoom {
                RoomStatusSheet(
                    room: detail.room,
                    participantCount: detail.participants.count,
                    speakerCount: detail.participants.filter { $0.role.canSpeak }.count,
                    requestCount: detail.pendingRequests,
                    isHost: myParticipant?.role == .host || myParticipant?.role == .cohost
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .onReceive(refreshTimer) { _ in
            if hasJoined {
                Task { await refreshParticipants() }
            }
        }
        // ⚡ Real-time room events from /ws/inbox.
        // Server fans out join/leave/raise-hand/role/mute/kick/end via the
        // existing WebSocket; RealtimeEngine routes them as
        // `RoomEventReceived`. Reacting here makes raise-hand → host accept
        // → speaker promotion appear INSTANT instead of up to 5 s late.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RoomEventReceived"))) { note in
            guard hasJoined,
                  let info = note.userInfo as? [String: Any],
                  let eventRoomId = info["room_id"] as? String,
                  eventRoomId == roomId else { return }
            let event = info["event"] as? String ?? "?"
            #if DEBUG
            print("⚡ [LiveRoomView] WS room_event: \(event)")
            #endif
            // Refresh local state immediately. For role_changed events that
            // affect *us* we additionally refresh the LiveKit token so the
            // new publish grant kicks in without an audio drop.
            Task {
                await refreshParticipants()
                if event == "role_changed",
                   let uid = info["user_id"] as? String,
                   uid == AuthService.shared.currentUser?.id,
                   info["needs_token_refresh"] as? Bool == true,
                   let me = myParticipant {
                    try? await audioManager.refreshToken(
                        roomId: roomId, participantName: me.safeDisplayName
                    )
                }
                if event == "ended" {
                    // Host ended the room — clean up and dismiss
                    await audioManager.disconnect()
                    hasJoined = false
                    connectionError = "The host ended this room."
                }
            }
        }
        .onAppear {
            timerCancellable = refreshTimer.connect()
        }
        .onDisappear {
            // ⚡ Audit fix: cancel the polling timer so it stops firing once
            // the user has minimised / left the room view. Saves CPU and
            // matches the heartbeat cleanup pattern already used in
            // AudioRoomManager.stopHeartbeat().
            timerCancellable?.cancel()
            timerCancellable = nil
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Joined Content
    
    private func joinedContent(_ detail: AudioRoomDetail) -> some View {
        VStack(spacing: 0) {
            headerCard(detail)
            
            if let asset = detail.activeAsset {
                presentationView(asset)
            } else {
                participantSections(detail.participants)
            }
            
            Spacer(minLength: 0)
            

            
            controlPanel(detail)
        }
    }
    
    // MARK: - Header Card
    
    private func headerCard(_ detail: AudioRoomDetail) -> some View {
        let room = detail.room
        let speakers = detail.participants.filter { $0.role.canSpeak }
        let listeners = detail.participants.filter { !$0.role.canSpeak }
        
        return VStack(spacing: 14) {
            // Top row — navigation + live badge + actions
            HStack(spacing: 12) {
                // Minimize
                Button {
                    // Minimize — just close the sheet. Audio persists via AudioRoomManager singleton.
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(RoomDesign.border, lineWidth: 0.5))
                }
                
                Spacer()
                
                // LIVE indicator
                Button { showRoomStatus = true } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                            .overlay(
                                Circle()
                                    .stroke(.red.opacity(0.4), lineWidth: 1.5)
                                    .scaleEffect(livePulse ? 2.0 : 1.0)
                                    .opacity(livePulse ? 0 : 0.8)
                            )
                        
                        Text("LIVE")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(.red.opacity(0.25))
                            .overlay(Capsule().stroke(.red.opacity(0.35), lineWidth: 0.5))
                    )
                }
                

                
                // Share
                ShareLink(item: "Join my room on RAVEN: \(room.title)") {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(RoomDesign.border, lineWidth: 0.5))
                }
            }
            
            // Title + description
            VStack(spacing: 4) {
                Text(room.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                
                if let desc = room.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 13))
                        .foregroundStyle(RoomDesign.labelSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
            }
            
            // Stats
            HStack(spacing: 16) {
                Label("\(speakers.count)", systemImage: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RoomDesign.accentBright)
                
                Rectangle()
                    .fill(RoomDesign.border)
                    .frame(width: 1, height: 12)
                
                Label("\(listeners.count + speakers.count)", systemImage: "person.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RoomDesign.labelSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(RoomDesign.border, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
    
    // MARK: - Participant Sections
    
    private func participantSections(_ participants: [AudioRoomParticipant]) -> some View {
        let speakers = participants.filter { $0.role.canSpeak }
        let listeners = participants.filter { !$0.role.canSpeak }
        
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                // Speakers
                if !speakers.isEmpty {
                    sectionBlock(
                        title: "Speakers",
                        icon: "waveform",
                        iconColor: RoomDesign.accentBright,
                        columns: 3
                    ) {
                        ForEach(Array(speakers.enumerated()), id: \.element.id) { idx, p in
                            SpeakerBubble(
                                participant: p,
                                gradient: gradients[idx % gradients.count],
                                // 🐛 FIX: was keyed by `safeDisplayName` but
                                // `speakingParticipants` is populated from
                                // `participant.identity?.stringValue` which is
                                // the user_id (the LiveKit JWT sets sub=user.id).
                                // Display names rarely matched identities → the
                                // speaking-now glow never fired.
                                isSpeaking: audioManager.speakingParticipants.contains(p.userId),
                                // ⚡ Continuous waveform meter — drives the ring
                                // scale + 3-bar visualizer below the avatar.
                                audioLevel: audioManager.audioLevels[p.userId] ?? 0
                            )
                        }
                    }
                }
                
                // Listeners
                if !listeners.isEmpty {
                    sectionBlock(
                        title: "Listening",
                        icon: "headphones",
                        iconColor: Color(hue: 0.75, saturation: 0.3, brightness: 0.55),
                        columns: 4
                    ) {
                        ForEach(Array(listeners.enumerated()), id: \.element.id) { idx, p in
                            ListenerBubble(
                                participant: p,
                                gradient: gradients[(idx + 2) % gradients.count]
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 24)
        }
    }
    
    private func sectionBlock<Content: View>(
        title: String, icon: String, iconColor: Color, columns: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(RoomDesign.labelTertiary)
                    .tracking(1.2)
            }
            .padding(.horizontal, 20)
            
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns),
                spacing: 20
            ) {
                content()
            }
            .padding(.horizontal, 20)
        }
    }
    
    // MARK: - Presentation View
    
    private func presentationView(_ asset: AudioRoomAsset) -> some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(RoomDesign.border, lineWidth: 0.5)
                    )
                
                if asset.type == .image {
                    AsyncImage(url: URL(string: asset.url)) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } placeholder: {
                        ProgressView().tint(.white)
                    }
                    .padding(8)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.richtext.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(
                                LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom)
                            )
                        Text(asset.fileName ?? "Document")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(maxHeight: 400)
            .padding()
        }
    }
    
    // MARK: - Control Panel
    
    private func controlPanel(_ detail: AudioRoomDetail) -> some View {
        let myRole = myParticipant?.role ?? .listener
        let isMuted = !audioManager.isMicEnabled
        let isHandRaised = myParticipant?.isHandRaised ?? false
        let allowRaiseHand = detail.room.allowRaiseHand
        
        return HStack(spacing: 14) {
            // Primary action — Mic or Raise Hand
            if myRole.canSpeak {
                Button {
                    Task {
                        try? await AudioRoomManager.shared.toggleMicrophone()
                        // After toggle, isMicEnabled reflects actual track state
                        let currentlyMuted = !AudioRoomManager.shared.isMicEnabled
                        if let me = myParticipant {
                            try? await roomService.muteParticipant(
                                roomId: roomId,
                                userId: me.userId,
                                muted: currentlyMuted
                            )
                        }
                        updateLiveActivity(detail)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(isMuted
                                ? RoomDesign.dangerSoft.opacity(0.25)
                                : RoomDesign.speakingGlow.opacity(0.25)
                            )
                            .frame(width: 54, height: 54)
                            .overlay(
                                Circle().stroke(
                                    isMuted ? RoomDesign.dangerSoft.opacity(0.5) : RoomDesign.speakingGlow.opacity(0.5),
                                    lineWidth: 1.5
                                )
                            )
                        
                        Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(isMuted ? RoomDesign.dangerSoft : RoomDesign.speakingGlow)
                    }
                }
            } else {
                // Raise hand
                Button {
                    guard allowRaiseHand else { return }
                    Task { try? await roomService.raiseHand(roomId: roomId, raised: !isHandRaised) }
                } label: {
                    VStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .fill(isHandRaised ? Color.yellow.opacity(0.2) : RoomDesign.cardBg)
                                .frame(width: 54, height: 54)
                                .overlay(
                                    Circle().stroke(
                                        isHandRaised ? Color.yellow.opacity(0.4) : RoomDesign.border,
                                        lineWidth: 1
                                    )
                                )
                            
                            Image(systemName: isHandRaised ? "hand.raised.fill" : "hand.raised")
                                .font(.system(size: 20))
                                .foregroundStyle(isHandRaised ? .yellow : RoomDesign.labelSecondary)
                        }
                        .opacity(allowRaiseHand ? 1 : 0.35)
                        
                        if isHandRaised {
                            Text("Raised")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.yellow.opacity(0.8))
                        }
                    }
                }
                .disabled(!allowRaiseHand)
            }
            
            // Listening indicator — subtle waveform when not speaking
            if !myRole.canSpeak || isMuted {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(RoomDesign.accent.opacity(0.5))
                            .frame(width: 2, height: livePulse ? CGFloat(6 + i * 3) : CGFloat(4 + i * 1))
                            .animation(
                                .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.15),
                                value: livePulse
                            )
                    }
                }
                .frame(width: 20, height: 14)
            }
            
            Spacer()
            
            // People (moderator)
            if myRole.canModerate {
                Button { showPeoplePanel = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(RoomDesign.labelSecondary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(RoomDesign.border, lineWidth: 0.5))
                        
                        if detail.pendingRequests > 0 {
                            Text("\(detail.pendingRequests)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(.red))
                                .offset(x: 4, y: -4)
                        }
                    }
                }
            }
            
            // Leave
            Button { showLeaveAlert = true } label: {
                Text(myRole == .host ? "End" : "Leave")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(
                        Capsule()
                            .fill(RoomDesign.dangerSoft.opacity(0.35))
                            .overlay(Capsule().stroke(RoomDesign.dangerSoft.opacity(0.4), lineWidth: 0.5))
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(RoomDesign.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
    
    // MARK: - Join Gate
    
    private var joinGate: some View {
        VStack(spacing: 32) {
            Spacer()
            
            if let room = roomService.currentRoom?.room {
                VStack(spacing: 22) {
                    // Room icon
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [RoomDesign.accent, Color(hue: 0.7, saturation: 0.35, brightness: 0.5)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 96, height: 96)
                        
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .overlay(
                        Circle()
                            .stroke(RoomDesign.accent.opacity(0.3), lineWidth: 2)
                            .scaleEffect(livePulse ? 1.2 : 1.0)
                            .opacity(livePulse ? 0 : 0.5)
                    )
                    
                    Text(room.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(RoomDesign.accent)
                        Text("\(room.participantCount) listening")
                            .foregroundStyle(RoomDesign.labelSecondary)
                    }
                    .font(.subheadline)
                }
                .padding(36)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(RoomDesign.border, lineWidth: 0.5)
                        )
                )
                .padding(.horizontal, 28)
            }
            
            Spacer()
            
            // Join buttons
            VStack(spacing: 14) {
                Button { joinRoom(anonymous: false) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.fill")
                        Text("Join with Profile")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [RoomDesign.accent, Color(hue: 0.65, saturation: 0.35, brightness: 0.5)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    )
                    .foregroundStyle(.white)
                }
                
                if roomService.currentRoom?.room.allowAnonymous == true {
                    Button { joinRoom(anonymous: true) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "theatermasks.fill")
                            Text("Join Anonymously")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Capsule().stroke(
                                        LinearGradient(
                                            colors: [RoomDesign.accent.opacity(0.6), Color(hue: 0.75, saturation: 0.3, brightness: 0.5).opacity(0.6)],
                                            startPoint: .leading, endPoint: .trailing
                                        ),
                                        lineWidth: 1.5
                                    )
                                )
                        )
                        .foregroundStyle(.white)
                    }
                }
                
                Button { dismiss() } label: {
                    Text("Cancel")
                        .foregroundStyle(RoomDesign.labelTertiary)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }
    
    // MARK: - Loading State
    
    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.3)
                .tint(.white)
            Text("Loading room…")
                .font(.subheadline)
                .foregroundStyle(RoomDesign.labelSecondary)
        }
    }
    
    // MARK: - Actions
    
    private func loadRoom() async {
        do {
            let detail = try await roomService.fetchRoomDetail(roomId: roomId)
            if let currentUserId = AuthService.shared.currentUser?.id,
               let existing = detail.participants.first(where: { $0.userId == currentUserId }) {
                myParticipant = existing
                hasJoined = true
                await autoConnectToLiveKit(participant: existing)
                startLiveActivity(detail)
            }

        } catch {
            #if DEBUG
            print("❌ Failed to load room: \(error)")
            #endif
            await MainActor.run {
                self.loadError = "This room is unavailable or the link is invalid."
            }
        }
    }
    

    
    private func joinRoom(anonymous: Bool) {
        Task {
            let micGranted = await requestMicrophonePermission()
            if !micGranted { showMicPermissionAlert = true; return }
            
            do {
                let participant = try await roomService.joinRoom(roomId: roomId, anonymous: anonymous)
                myParticipant = participant
                hasJoined = true
                
                try await AudioRoomManager.shared.connect(
                    roomId: roomId,
                    participantName: participant.safeDisplayName
                )
                
                if participant.role.canSpeak {
                    try? await AudioRoomManager.shared.setMicrophone(enabled: true)
                }
                
                // Start Live Activity
                if let detail = roomService.currentRoom {
                    startLiveActivity(detail)
                }
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }
    
    private func refreshParticipants() async {
        do {
            let detail = try await roomService.fetchRoomDetail(roomId: roomId)
            
            if let currentUserId = AuthService.shared.currentUser?.id,
               let updatedMe = detail.participants.first(where: { $0.userId == currentUserId }) {
                
                let wasListener = myParticipant?.role == .listener
                let nowSpeaker = updatedMe.role.canSpeak
                
                // Check if user was previously a speaker and is now demoted to listener
                let wasSpeakerBefore = myParticipant?.role.canSpeak == true
                let nowListenerOnly = !updatedMe.role.canSpeak
                
                if wasListener && nowSpeaker {
                    // 🚀 PROMOTION FIX: previously this did disconnect+reconnect
                    // (1-2 second audio outage; everyone else saw the speaker
                    // disappear and rejoin). Instead we refresh the LiveKit
                    // token in place — the new token has `canPublish:true`
                    // grants, after which `setMicrophone(true)` actually
                    // publishes the audio track WITHOUT dropping the room
                    // membership or audio output.
                    do {
                        try await audioManager.refreshToken(
                            roomId: roomId,
                            participantName: updatedMe.safeDisplayName
                        )
                        try? await audioManager.setMicrophone(enabled: true)
                    } catch {
                        #if DEBUG
                        print("❌ Failed to refresh token after promotion: \(error)")
                        #endif
                    }
                }
                // If demoted from speaker to listener, immediately disable microphone in LiveKit
                else if wasSpeakerBefore && nowListenerOnly {
                    Task {
                        try? await audioManager.setMicrophone(enabled: false)
                        Haptics.warning()
                    }
                }
                
                myParticipant = updatedMe
            }
            
            // Update Live Activity
            updateLiveActivity(detail)
        } catch {
            #if DEBUG
            print("❌ Failed to refresh: \(error)")
            #endif
        }
    }
    
    private func autoConnectToLiveKit(participant: AudioRoomParticipant) async {
        let micGranted = await requestMicrophonePermission()
        if !micGranted { showMicPermissionAlert = true; return }
        
        do {
            try await AudioRoomManager.shared.connect(
                roomId: roomId,
                participantName: participant.safeDisplayName
            )
            if participant.role.canSpeak {
                try await Task.sleep(nanoseconds: 500_000_000)
                try await AudioRoomManager.shared.setMicrophone(enabled: true)
            }
        } catch {
            connectionError = error.localizedDescription
        }
    }
    
    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    // MARK: - Live Activity Helpers
    
    private func startLiveActivity(_ detail: AudioRoomDetail) {
        let speakers = detail.participants.filter { $0.role.canSpeak }.count
        let total = detail.participants.count
        AudioRoomActivityManager.shared.startActivity(
            roomId: roomId,
            roomTitle: detail.room.title,
            state: .init(listenersCount: total, speakersCount: speakers, isMuted: !audioManager.isMicEnabled)
        )
    }
    
    private func updateLiveActivity(_ detail: AudioRoomDetail) {
        let speakers = detail.participants.filter { $0.role.canSpeak }.count
        let total = detail.participants.count
        AudioRoomActivityManager.shared.updateActivity(
            state: .init(listenersCount: total, speakersCount: speakers, isMuted: !audioManager.isMicEnabled)
        )
    }
}

// MARK: - Speaker Bubble

struct SpeakerBubble: View {
    let participant: AudioRoomParticipant
    let gradient: [Color]
    let isSpeaking: Bool
    /// Continuous audio level [0…1] from LiveKit. Drives the ring scale +
    /// the 3-bar waveform meter below the avatar. 0 = silent.
    var audioLevel: Float = 0

    @State private var pulse = false

    /// Smooth the raw audio level: the LiveKit value jitters per 100 ms
    /// sample. We expand the range a bit so even quiet talking pushes the
    /// ring noticeably (audioLevel rarely exceeds ~0.6 in practice).
    private var ringScale: CGFloat {
        guard isSpeaking else { return 1.0 }
        let amp = min(1.0, CGFloat(audioLevel) * 1.6)
        return 1.0 + amp * 0.10  // up to +10% scale
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Speaking glow
                if isSpeaking {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [RoomDesign.speakingGlow.opacity(0.4), .clear],
                                center: .center, startRadius: 0, endRadius: 55
                            )
                        )
                        .frame(width: 100, height: 100)
                        .scaleEffect(ringScale)
                        .animation(.easeOut(duration: 0.1), value: ringScale)
                }

                // Avatar
                avatarView(size: 72)

                // Speaking ring — driven by real audioLevel, not just a fixed pulse
                if isSpeaking {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [RoomDesign.speakingGlow, RoomDesign.accentBright],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 2.5
                        )
                        .frame(width: 78, height: 78)
                        .scaleEffect(ringScale)
                        .animation(.easeOut(duration: 0.1), value: ringScale)
                } else if participant.role.canSpeak && !participant.isMuted {
                    Circle()
                        .stroke(RoomDesign.speakingGlow.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 78, height: 78)
                }
                
                // Muted badge
                if participant.isMuted && participant.role.canSpeak {
                    Circle()
                        .fill(Color(white: 0.1).opacity(0.85))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Image(systemName: "mic.slash.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(RoomDesign.dangerSoft)
                        )
                        .offset(x: 26, y: 26)
                }
                
                // Hand raised
                if participant.isHandRaised {
                    Text("✋")
                        .font(.caption)
                        .offset(x: -26, y: -26)
                }
                
                // Role badge
                if participant.role == .host {
                    Text("👑").font(.system(size: 12)).offset(x: 26, y: -26)
                } else if participant.role == .cohost {
                    Text("⭐️").font(.system(size: 10)).offset(x: 26, y: -26)
                }
            }
            
            // Name + mic icon
            HStack(spacing: 3) {
                if participant.isMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(RoomDesign.labelTertiary)
                }
                Text(participant.safeDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            // 🎙️ 3-bar waveform meter — visible whenever the speaker has
            // any audio level. Each bar samples a different "frequency
            // band" of the smoothed level for a Discord-style look.
            if !participant.isMuted && participant.role.canSpeak {
                WaveformBars(level: audioLevel)
                    .frame(height: 8)
                    .opacity(audioLevel > 0.02 ? 1 : 0.25)
                    .animation(.easeOut(duration: 0.12), value: audioLevel > 0.02)
            }
        }
        .onAppear {
            if isSpeaking {
                withAnimation(RoomDesign.pulseSpring.repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .onChange(of: isSpeaking) { _, speaking in
            if speaking {
                withAnimation(RoomDesign.pulseSpring.repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            }
        }
    }

    @ViewBuilder
    private func avatarView(size: CGFloat) -> some View {
        if participant.displayMode == .anonymous {
            Circle()
                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay { Text("🎭").font(.title2) }
        } else {
            AsyncImage(url: URL(string: participant.avatarUrl ?? "")) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle()
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Text(participant.avatarInitial)
                            .font(.system(size: size * 0.35, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        }
    }
}

// MARK: - Waveform Bars (Discord-style 3-bar mic level meter)

/// Animated 3-bar mic-level visualizer.
/// Each bar represents a slightly different "frequency band" of the same
/// underlying audioLevel — driven by phase-shifted sin waves so the bars
/// don't all bounce in lockstep. Cheap to render: just 3 rounded rects
/// whose height interpolates with the level.
struct WaveformBars: View {
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.04, paused: level <= 0.02)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                bar(scale: barScale(t: t, phase: 0.0))
                bar(scale: barScale(t: t, phase: 0.5))
                bar(scale: barScale(t: t, phase: 1.0))
            }
        }
    }

    private func barScale(t: TimeInterval, phase: Double) -> CGFloat {
        // amp envelope from audioLevel (clamped + smoothed)
        let amp = CGFloat(min(1.0, max(0.05, Double(level) * 1.6)))
        // small time-varying jitter so bars feel alive
        let jitter = (sin(t * 6 + phase * .pi) + 1) / 2  // 0…1
        return 0.20 + amp * (0.55 + 0.45 * CGFloat(jitter))
    }

    private func bar(scale: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [RoomDesign.speakingGlow, RoomDesign.accentBright],
                    startPoint: .bottom, endPoint: .top
                )
            )
            .frame(width: 3)
            .scaleEffect(y: scale, anchor: .center)
            .animation(.linear(duration: 0.05), value: scale)
    }
}


// MARK: - Listener Bubble

struct ListenerBubble: View {
    let participant: AudioRoomParticipant
    let gradient: [Color]
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if participant.displayMode == .anonymous {
                    Circle()
                        .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 50, height: 50)
                        .overlay { Text("🎭").font(.body) }
                } else {
                    AsyncImage(url: URL(string: participant.avatarUrl ?? "")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Circle()
                            .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay {
                                Text(participant.avatarInitial)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                    }
                    .frame(width: 50, height: 50)
                    .clipShape(Circle())
                }
                
                if participant.isHandRaised {
                    Text("✋").font(.system(size: 10)).offset(x: -18, y: -18)
                }
            }
            
            Text(participant.safeDisplayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(RoomDesign.labelSecondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Requests Sheet

struct RequestsSheet: View {
    let roomId: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var roomService = RoomService.shared
    @State private var requests: [RaiseHandRequest] = []
    
    var body: some View {
        NavigationStack {
            List {
                if requests.isEmpty {
                    ContentUnavailableView(
                        "No Requests",
                        systemImage: "hand.raised.slash",
                        description: Text("No one has raised their hand yet")
                    )
                } else {
                    ForEach(requests, id: \.requestId) { request in
                        HStack {
                            Text(request.displayName).font(.headline)
                            Spacer()
                            Button { acceptRequest(request) } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green).font(.title2)
                            }
                            Button { declineRequest(request) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red).font(.title2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Raise Hand Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .task { await loadRequests() }
    }
    
    private func loadRequests() async {
        do { requests = try await roomService.getRequests(roomId: roomId) }
        catch {
            #if DEBUG
            print("❌ Failed to load requests: \(error)")
            #endif
        }
    }
    
    private func acceptRequest(_ r: RaiseHandRequest) {
        Task { try? await roomService.acceptRequest(roomId: roomId, userId: r.userId); await loadRequests() }
    }
    
    private func declineRequest(_ r: RaiseHandRequest) {
        Task { try? await roomService.declineRequest(roomId: roomId, userId: r.userId); await loadRequests() }
    }
}

#Preview {
    LiveRoomView(roomId: "test-room-id")
}
