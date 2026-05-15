import SwiftUI

/// People management panel with 3 tabs: Requests, Speakers, Audience
struct PeoplePanel: View {
    let roomId: String
    let participants: [AudioRoomParticipant]
    let isHost: Bool
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var roomService = RoomService.shared
    @State private var selectedTab: PeopleTab = .speakers
    @State private var requests: [RaiseHandRequest] = []
    @State private var searchText = ""
    @State private var selectedParticipant: AudioRoomParticipant?
    @State private var isLoading = false
    
    enum PeopleTab: String, CaseIterable {
        case requests = "Requests"
        case speakers = "Speakers"
        case audience = "Audience"
    }
    
    var speakers: [AudioRoomParticipant] {
        participants.filter { $0.role.canSpeak }
    }
    
    var audience: [AudioRoomParticipant] {
        participants.filter { !$0.role.canSpeak }
    }
    
    var filteredAudience: [AudioRoomParticipant] {
        if searchText.isEmpty {
            return audience
        }
        return audience.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Glass background
                Color.black.opacity(0.3)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Segmented picker
                    glassSegmentedPicker
                        .padding(.horizontal)
                        .padding(.top)
                    
                    // Content based on selection
                    TabView(selection: $selectedTab) {
                        requestsView
                            .tag(PeopleTab.requests)
                        
                        speakersView
                            .tag(PeopleTab.speakers)
                        
                        audienceView
                            .tag(PeopleTab.audience)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .task {
            await loadRequests()
        }
        .sheet(item: $selectedParticipant) { participant in
            HostControlsView(roomId: roomId, participant: participant)
        }
    }
    
    // MARK: - Segmented Picker
    
    private var glassSegmentedPicker: some View {
        HStack(spacing: 4) {
            ForEach(PeopleTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(.medium))
                        
                        if tab == .requests && !requests.isEmpty {
                            Text("\(requests.count)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.red)
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.5))
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selectedTab == tab {
                            Capsule()
                                .fill(.white.opacity(0.2))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }
    
    // MARK: - Requests View
    
    private var requestsView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if requests.isEmpty {
                    emptyStateView(
                        icon: "hand.raised",
                        title: "No Requests",
                        subtitle: "When someone raises their hand, they'll appear here"
                    )
                } else {
                    ForEach(requests, id: \.requestId) { request in
                        requestCard(request)
                    }
                }
            }
            .padding()
        }
    }
    
    private func requestCard(_ request: RaiseHandRequest) -> some View {
        HStack(spacing: 12) {
            // Avatar
            Circle()
                .fill(.linearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 50, height: 50)
                .overlay {
                    Text("✋")
                        .font(.title2)
                }
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(request.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)
                
                Text("Wants to speak")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            
            Spacer()
            
            // Actions
            if isHost {
                HStack(spacing: 8) {
                    Button {
                        acceptRequest(request)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                    }
                    
                    Button {
                        declineRequest(request)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Speakers View
    
    private var speakersView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if speakers.isEmpty {
                    emptyStateView(
                        icon: "mic.fill",
                        title: "No Speakers",
                        subtitle: "Speakers will appear here"
                    )
                } else {
                    ForEach(speakers) { speaker in
                        participantCard(speaker, showMicStatus: true)
                    }
                }
            }
            .padding()
        }
    }
    
    // MARK: - Audience View
    
    private var audienceView: some View {
        VStack(spacing: 0) {
            // Search bar for large rooms
            if audience.count > 10 {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.5))
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top)
            }
            
            ScrollView {
                LazyVStack(spacing: 12) {
                    if filteredAudience.isEmpty {
                        emptyStateView(
                            icon: "person.2.fill",
                            title: "No Listeners",
                            subtitle: "Listeners will appear here"
                        )
                    } else {
                        ForEach(filteredAudience) { listener in
                            participantCard(listener, showMicStatus: false)
                        }
                    }
                }
                .padding()
            }
        }
    }
    
    // MARK: - Participant Card
    
    private func participantCard(_ participant: AudioRoomParticipant, showMicStatus: Bool) -> some View {
        Button {
            if isHost {
                selectedParticipant = participant
            }
        } label: {
            HStack(spacing: 12) {
                // Avatar with speaking indicator
                ZStack {
                    if participant.displayMode == .anonymous {
                        Circle()
                            .fill(.linearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 50, height: 50)
                            .overlay {
                                Text("🎭")
                                    .font(.title2)
                            }
                    } else {
                        AsyncImage(url: URL(string: participant.avatarUrl ?? "")) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle()
                                .fill(.linearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay {
                                    Text(String(participant.safeDisplayName.prefix(1)).uppercased())
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                }
                        }
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                    }
                }
                
                // Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(participant.safeDisplayName)
                            .font(.headline)
                            .foregroundStyle(.white)
                        
                        // Role badge
                        if participant.role == .host {
                            Text("HOST")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.gradient)
                                .clipShape(Capsule())
                        } else if participant.role == .cohost {
                            Text("MOD")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.purple.gradient)
                                .clipShape(Capsule())
                        }
                    }
                    
                    if participant.displayMode == .anonymous {
                        Text("Anonymous")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                
                Spacer()
                
                // Mic status for speakers
                if showMicStatus {
                    Image(systemName: participant.isMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(participant.isMuted ? .red : .green)
                        .font(.title3)
                }
                
                // Chevron for host
                if isHost {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Empty State
    
    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.3))
            
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
            
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    // MARK: - Actions
    
    private func loadRequests() async {
        do {
            requests = try await roomService.getRequests(roomId: roomId)
        } catch {
            #if DEBUG
            print("❌ Failed to load requests: \(error)")
            #endif
        }
    }
    
    private func acceptRequest(_ request: RaiseHandRequest) {
        Task {
            do {
                try await roomService.acceptRequest(roomId: roomId, userId: request.userId)
                requests.removeAll { $0.requestId == request.requestId }
            } catch {
                #if DEBUG
                print("❌ Failed to accept request: \(error)")
                #endif
            }
        }
    }
    
    private func declineRequest(_ request: RaiseHandRequest) {
        Task {
            do {
                try await roomService.declineRequest(roomId: roomId, userId: request.userId)
                requests.removeAll { $0.requestId == request.requestId }
            } catch {
                #if DEBUG
                print("❌ Failed to decline request: \(error)")
                #endif
            }
        }
    }
}

#Preview {
    PeoplePanel(
        roomId: "test",
        participants: [
            AudioRoomParticipant(
                id: "1", userId: "u1", displayName: "Ahmad", avatarUrl: nil,
                displayMode: .real, role: .host, isMuted: false, isHandRaised: false, joinedAt: Date()
            ),
            AudioRoomParticipant(
                id: "2", userId: "u2", displayName: "Sara", avatarUrl: nil,
                displayMode: .real, role: .speaker, isMuted: true, isHandRaised: false, joinedAt: Date()
            ),
            AudioRoomParticipant(
                id: "3", userId: "u3", displayName: "Anonymous Fox", avatarUrl: nil,
                displayMode: .anonymous, role: .listener, isMuted: true, isHandRaised: false, joinedAt: Date()
            )
        ],
        isHost: true
    )
    .preferredColorScheme(.dark)
}
