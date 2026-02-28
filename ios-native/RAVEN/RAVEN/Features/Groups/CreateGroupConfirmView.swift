import SwiftUI

// MARK: - Create Group Confirm View (Step 3)

/// Final confirmation before group creation
struct CreateGroupConfirmView: View {
    let members: [GroupFriendInfo]
    let name: String
    let avatar: UIImage?
    @Binding var isCreating: Bool
    var onCreate: () -> Void
    var onBack: () -> Void
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Group preview
                groupPreview
                
                Divider()
                
                // Members list
                membersSection
                
                Spacer(minLength: 32)
            }
            .padding(.horizontal)
            .padding(.top, 24)
        }
        .safeAreaInset(edge: .bottom) {
            buttonsSection
        }
    }
    
    // MARK: - Subviews
    
    private var groupPreview: some View {
        VStack(spacing: 12) {
            // Group avatar
            ZStack {
                if let avatar {
                    Image(uiImage: avatar)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Circle()
                        .fill(Color.blue.opacity(0.2))
                    
                    Image(systemName: "person.3.fill")
                        .font(.title)
                        .foregroundStyle(.blue)
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(Circle())
            
            // Group name
            Text(name)
                .font(.title2.bold())
            
            // Member count
            Text("\(members.count + 1) members")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Members")
                .font(.headline)
            
            // You (creator)
            HStack(spacing: 12) {
                Circle()
                    .fill(.blue.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.blue)
                    }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("You")
                        .font(.body)
                    
                    Text("Admin")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
            
            // Other members
            ForEach(members) { member in
                HStack(spacing: 12) {
                    AsyncImage(url: member.avatarUrl.flatMap { URL(string: $0) }) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle()
                            .fill(.gray.opacity(0.3))
                            .overlay {
                                Text(String(member.safeDisplayName.prefix(1)).uppercased())
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.safeDisplayName)
                            .font(.body)
                        
                        Text("Member")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private var buttonsSection: some View {
        VStack(spacing: 12) {
            // Create button
            Button {
                onCreate()
            } label: {
                HStack {
                    if isCreating {
                        ProgressView()
                            .tint(.white)
                    }
                    
                    Text(isCreating ? "Creating..." : "Create Group")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isCreating ? Color.gray : Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isCreating)
            
            // Back button
            Button {
                onBack()
            } label: {
                Text("Back")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .disabled(isCreating)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    NavigationStack {
        CreateGroupConfirmView(
            members: [],
            name: "Test Group",
            avatar: nil,
            isCreating: .constant(false),
            onCreate: {},
            onBack: {}
        )
        .navigationTitle("Confirm")
    }
}
