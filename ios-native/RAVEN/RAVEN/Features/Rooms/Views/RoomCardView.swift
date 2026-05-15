import SwiftUI

/// Room card for display in feed (as a post_type="room")
/// Uses matchedGeometryEffect for smooth transition to LiveRoomView
struct RoomCardView: View {
    let room: AudioRoom
    let namespace: Namespace.ID
    
    var onJoin: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Host info
            HStack(spacing: 10) {
                // Host avatar
                AsyncImage(url: URL(string: room.hostAvatar ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(.gray.opacity(0.3))
                        .overlay {
                            Text(String(room.hostName?.prefix(1) ?? "?"))
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.hostName ?? "Unknown")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        
                        Text("LIVE")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.green)
                    }
                }
                
                Spacer()
                
                // Participant count
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                    Text("\(room.participantCount)")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
            }
            
            // Room title + icon
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.linearGradient(
                            colors: [.purple.opacity(0.8), .blue.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .matchedGeometryEffect(id: "roomIcon_\(room.id)", in: namespace)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.title)
                        .font(.headline)
                        .lineLimit(2)
                        .matchedGeometryEffect(id: "roomTitle_\(room.id)", in: namespace)
                    
                    if let description = room.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            
            // Join button
            Button(action: onJoin) {
                HStack {
                    Image(systemName: "phone.fill")
                    Text("Join Room")
                }
                .font(.subheadline)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview {
    @Namespace var namespace
    
    return RoomCardView(
        room: AudioRoom(
            id: "preview-id",
            title: "iOS Development Tips",
            description: "Discussing SwiftUI best practices",
            hostUserId: "user1",
            hostName: "Sarah",
            hostAvatar: nil,
            roomImageUrl: nil,
            privacy: .public,
            allowAnonymous: true,
            allowRaiseHand: true,
            isLocked: false,
            isLive: true,
            participantCount: 12,
            maxParticipants: 100,
            createdAt: Date(),
            shareSlug: "ios12345"
        ),
        namespace: namespace,
        onJoin: {}
    )
    .padding()
}
