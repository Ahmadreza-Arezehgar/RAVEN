import SwiftUI

// MARK: - New Group View (Wizard Container)

/// 3-step wizard for creating group chats
struct NewGroupView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentStep = 0
    @State private var selectedMembers: [GroupFriendInfo] = []
    @State private var groupName = ""
    @State private var groupAvatar: UIImage?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var createdGroup: ChatGroup?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Step indicator
                stepIndicator
                
                // Step content
                TabView(selection: $currentStep) {
                    SelectMembersView(selectedMembers: $selectedMembers, onNext: { goToStep(1) })
                        .tag(0)
                    
                    GroupDetailsView(
                        name: $groupName,
                        avatar: $groupAvatar,
                        onNext: { goToStep(2) },
                        onBack: { goToStep(0) }
                    )
                    .tag(1)
                    
                    CreateGroupConfirmView(
                        members: selectedMembers,
                        name: groupName,
                        avatar: groupAvatar,
                        isCreating: $isCreating,
                        onCreate: createGroup,
                        onBack: { goToStep(1) }
                    )
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentStep)
            }
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
            }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var stepTitle: String {
        switch currentStep {
        case 0: return "Select Members"
        case 1: return "Group Details"
        case 2: return "Confirm"
        default: return "New Group"
        }
    }
    
    // MARK: - Subviews
    
    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { step in
                Capsule()
                    .fill(step <= currentStep ? Color.blue : Color.gray.opacity(0.3))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Actions
    
    private func goToStep(_ step: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentStep = step
        }
        
        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }
    
    private func createGroup() {
        guard !isCreating else { return }
        
        isCreating = true
        
        Task {
            do {
                // Upload group avatar if one was selected
                var avatarUrl: String? = nil
                if let avatar = groupAvatar,
                   let data = avatar.jpegData(compressionQuality: 0.8) {
                    struct AvatarUploadResponse: Decodable {
                        let imageUrl: String
                    }
                    let response: AvatarUploadResponse = try await NetworkService.shared.uploadMultipart(
                        path: "/api/uploads/image",
                        fileData: data,
                        fileName: "group_avatar.jpg",
                        mimeType: "image/jpeg"
                    )
                    avatarUrl = response.imageUrl
                    #if DEBUG
                    print("✅ [NewGroupView] Group avatar uploaded: \(avatarUrl ?? "")")
                    #endif
                }
                
                let group = try await GroupService.shared.createGroup(
                    name: groupName,
                    memberIds: selectedMembers.map { $0.id },
                    avatarUrl: avatarUrl,
                    description: nil
                )
                
                // 🔄 Refresh ConversationStore so group appears in inbox
                await ConversationStore.shared.loadFromDB()
                
                // Success feedback
                let feedback = UINotificationFeedbackGenerator()
                feedback.notificationOccurred(.success)
                
                createdGroup = group
                
                // Dismiss and navigate to group chat
                await MainActor.run {
                    dismiss()
                }
                
                #if DEBUG
                print("✅ [NewGroupView] Created group: \(group.name)")
                #endif
                
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
                
                let feedback = UINotificationFeedbackGenerator()
                feedback.notificationOccurred(.error)
            }
        }
    }
}

#Preview {
    NewGroupView()
}
