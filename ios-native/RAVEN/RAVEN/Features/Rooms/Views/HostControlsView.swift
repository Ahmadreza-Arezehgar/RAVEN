import SwiftUI

/// Host controls for managing room participants
struct HostControlsView: View {
    let roomId: String
    let participant: AudioRoomParticipant
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var roomService = RoomService.shared
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Participant info
                    HStack {
                        if participant.displayMode == .anonymous {
                            Circle()
                                .fill(.purple.gradient)
                                .frame(width: 60, height: 60)
                                .overlay {
                                    Text("🎭")
                                        .font(.title)
                                }
                        } else {
                            AsyncImage(url: URL(string: participant.avatarUrl ?? "")) { image in
                                image.resizable()
                            } placeholder: {
                                Circle().fill(.gray.opacity(0.3))
                            }
                            .frame(width: 60, height: 60)
                            .clipShape(Circle())
                        }
                        
                        VStack(alignment: .leading) {
                            Text(participant.safeDisplayName)
                                .font(.headline)
                            
                            Text(participant.role.rawValue.capitalized)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Section("Role") {
                    Button {
                        changeRole(.speaker)
                    } label: {
                        Label("Make Speaker", systemImage: "mic.fill")
                    }
                    .disabled(participant.role == .speaker)
                    
                    Button {
                        changeRole(.cohost)
                    } label: {
                        Label("Make Co-Host", systemImage: "star.fill")
                    }
                    .disabled(participant.role == .cohost)
                    
                    Button {
                        changeRole(.listener)
                    } label: {
                        Label("Move to Listeners", systemImage: "person.fill")
                    }
                    .disabled(participant.role == .listener)
                }
                
                Section("Audio") {
                    Button {
                        toggleMute()
                    } label: {
                        Label(
                            participant.isMuted ? "Unmute" : "Mute",
                            systemImage: participant.isMuted ? "mic.fill" : "mic.slash.fill"
                        )
                    }
                    .disabled(!participant.role.canSpeak)
                }
                
                Section {
                    Button(role: .destructive) {
                        kickUser()
                    } label: {
                        Label("Remove from Room", systemImage: "person.badge.minus")
                    }
                }
            }
            .navigationTitle("Manage Participant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    private func changeRole(_ role: ParticipantRole) {
        Task {
            do {
                try await roomService.changeRole(roomId: roomId, userId: participant.userId, role: role)
                dismiss()
            } catch {
                #if DEBUG
                print("❌ Failed to change role: \(error)")
                #endif
            }
        }
    }
    
    private func toggleMute() {
        Task {
            do {
                try await roomService.muteParticipant(
                    roomId: roomId,
                    userId: participant.userId,
                    muted: !participant.isMuted
                )
                dismiss()
            } catch {
                #if DEBUG
                print("❌ Failed to toggle mute: \(error)")
                #endif
            }
        }
    }
    
    private func kickUser() {
        Task {
            do {
                try await roomService.kickParticipant(roomId: roomId, userId: participant.userId)
                dismiss()
            } catch {
                #if DEBUG
                print("❌ Failed to kick user: \(error)")
                #endif
            }
        }
    }
}

#Preview {
    HostControlsView(
        roomId: "test",
        participant: AudioRoomParticipant(
            id: "1",
            userId: "user1",
            displayName: "John Doe",
            avatarUrl: nil,
            displayMode: .real,
            role: .listener,
            isMuted: true,
            isHandRaised: false,
            joinedAt: Date()
        )
    )
}
