import SwiftUI
import PhotosUI

// MARK: - Group Details View (Step 2)

/// Group name and avatar configuration
struct GroupDetailsView: View {
    @Binding var name: String
    @Binding var avatar: UIImage?
    var onNext: () -> Void
    var onBack: () -> Void
    
    @State private var selectedItem: PhotosPickerItem?
    @State private var showNameError = false
    
    private var isValidName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 2 && trimmed.count <= 40
    }
    
    private var canProceed: Bool {
        isValidName
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Avatar picker
                avatarSection
                
                // Name input
                nameSection
                
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
    
    private var avatarSection: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $selectedItem, matching: .images) {
                ZStack {
                    if let avatar {
                        Image(uiImage: avatar)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Circle()
                            .fill(.gray.opacity(0.2))
                        
                        Image(systemName: "camera.fill")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 100, height: 100)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.quaternary, lineWidth: 2)
                }
            }
            
            Text("Add Group Photo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .onChange(of: selectedItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    avatar = image
                }
            }
        }
    }
    
    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group Name")
                .font(.headline)
            
            TextField("Enter group name", text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(showNameError ? .red : .clear, lineWidth: 1)
                }
                .onChange(of: name) { _, _ in
                    showNameError = false
                }
            
            HStack {
                if showNameError {
                    Text("Name must be 2-40 characters")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                Spacer()
                
                Text("\(name.count)/40")
                    .font(.caption)
                    .foregroundStyle(name.count > 40 ? .red : .secondary)
            }
        }
    }
    
    private var buttonsSection: some View {
        VStack(spacing: 12) {
            // Next button
            Button {
                if canProceed {
                    onNext()
                } else {
                    showNameError = true
                }
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canProceed ? Color.blue : Color.gray.opacity(0.3))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            // Back button
            Button {
                onBack()
            } label: {
                Text("Back")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    NavigationStack {
        GroupDetailsView(
            name: .constant(""),
            avatar: .constant(nil),
            onNext: {},
            onBack: {}
        )
        .navigationTitle("Group Details")
    }
}
