import SwiftUI

/// Bottom sheet for creating a new audio room
struct CreateRoomSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var roomService = RoomService.shared
    
    @State private var title = ""
    @State private var description = ""
    @State private var privacy: RoomPrivacy = .public
    @State private var allowAnonymous = true
    @State private var allowRaiseHand = true
    @State private var isCreating = false
    
    var onRoomCreated: ((AudioRoom) -> Void)?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Room Icon
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.linearGradient(
                                colors: [.purple, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    }
                    .padding(.top, 20)
                    
                    // Title Field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Room Title")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        TextField("What's the topic?", text: $title)
                            .textFieldStyle(.plain)
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // Description Field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description (Optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        TextField("Tell people what you'll discuss", text: $description, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3...6)
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // Privacy Picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Who can join?")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Picker("Privacy", selection: $privacy) {
                            Label("Local", systemImage: "location.circle")
                                .tag(RoomPrivacy.public)
                            Label("Friends", systemImage: "person.2")
                                .tag(RoomPrivacy.friends)
                            Label("Invite Only", systemImage: "link")
                                .tag(RoomPrivacy.invite)
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    // Toggles
                    VStack(spacing: 0) {
                        Toggle(isOn: $allowAnonymous) {
                            Label("Allow Anonymous Join", systemImage: "theatermasks")
                        }
                        .padding()
                        
                        Divider()
                            .padding(.horizontal)
                        
                        Toggle(isOn: $allowRaiseHand) {
                            Label("Allow Raise Hand", systemImage: "hand.raised")
                        }
                        .padding()
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal)
            }
            .navigationTitle("New Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: createRoom) {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Go Live")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(title.isEmpty || isCreating)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .sheet(isPresented: $showInviteSheet, onDismiss: { 
            dismiss()
            if let createdRoom = createdRoom {
                onRoomCreated?(createdRoom)
            }
        }) {
            if let createdRoom = createdRoom {
                InviteShareSheet(room: createdRoom)
            }
        }
    }
    
    @State private var showInviteSheet = false
    @State private var createdRoom: AudioRoom?
    
    private func createRoom() {

        isCreating = true
        
        Task {
            do {
                let request = CreateRoomRequest(
                    title: title,
                    description: description.isEmpty ? nil : description,
                    privacy: privacy,
                    allowAnonymous: allowAnonymous,
                    allowRaiseHand: allowRaiseHand
                )
                
                let room = try await roomService.createRoom(request)
                
                await MainActor.run {
                    isCreating = false  // Bug 8 fix: reset on success path
                    if privacy == .invite {
                        createdRoom = room
                        showInviteSheet = true
                    } else {
                        onRoomCreated?(room)
                        dismiss()
                    }
                }
            } catch {
                #if DEBUG
                print("❌ Failed to create room: \(error)")
                #endif
                isCreating = false
            }
        }
    }
}

#Preview {
    CreateRoomSheet()
}
