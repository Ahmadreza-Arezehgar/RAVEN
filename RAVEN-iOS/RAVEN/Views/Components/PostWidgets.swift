// RAVEN - Post Widgets
// Converted from Flutter post_card.dart, post_composer.dart, comments_sheet.dart

import SwiftUI
import PhotosUI

// MARK: - Post Composer Sheet
struct PostComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    
    @State private var content = ""
    @State private var selectedImages: [UIImage] = []
    @State private var isPosting = false
    @State private var showPhotoPicker = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Composer
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(url: nil, name: "You", size: 44)
                        
                        TextEditor(text: $content)
                            .font(.body)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                    }
                    
                    // Selected images
                    if !selectedImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 80, height: 80)
                                            .clipped()
                                            .cornerRadius(8)
                                        
                                        Button {
                                            if selectedImages.indices.contains(index) { // ✅ Prevent index out of bounds
                                                selectedImages.remove(at: index)
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.white)
                                                .background(Circle().fill(Color.black.opacity(0.5)))
                                        }
                                        .offset(x: 4, y: -4)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
                
                Spacer()
                
                // Toolbar
                HStack {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Image(systemName: "photo")
                            .font(.title3)
                    }
                    
                    Button {
                        // Camera
                    } label: {
                        Image(systemName: "camera")
                            .font(.title3)
                    }
                    
                    Button {
                        // Location
                    } label: {
                        Image(systemName: "location")
                            .font(.title3)
                    }
                    
                    Spacer()
                    
                    Text("\(280 - content.count)")
                        .font(.caption)
                        .foregroundColor(content.count > 280 ? .red : .secondary)
                }
                .padding()
                .background(Color(UIColor.systemGray6))
            }
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        submitPost()
                    } label: {
                        if isPosting {
                            ProgressView()
                        } else {
                            Text("Post")
                                .bold()
                        }
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPosting || content.count > 280)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker(selectedImages: $selectedImages, maxCount: 4)
            }
        }
    }
    
    func submitPost() {
        isPosting = true
        
        Task {
            do {
                if NetworkMonitor.shared.isConnected {
                    var mediaUrls: [String] = []
                    for image in selectedImages {
                        let url = try await MediaService.shared.uploadImage(image)
                        mediaUrls.append(url)
                    }
                    let _ = try await APIService.shared.createPost(content: content, mediaUrls: mediaUrls)
                    await appState.loadFeed()
                } else if MeshService.shared.isEnabled {
                    // ERSAL AZ TARIGH MESH (OFFLINE POST)
                    guard let user = AuthService.shared.currentUser else { return }
                    let post = Post(
                        id: UUID().uuidString, authorId: user.id, authorName: user.displayName,
                        authorUsername: user.username, authorAvatarUrl: user.avatarUrl,
                        content: content, mediaUrls: [], createdAt: Date()
                    )
                    
                    MeshService.shared.sendPost(post)
                    await MainActor.run {
                        appState.feedPosts.insert(post, at: 0)
                    }
                }
                dismiss()
            } catch {
                isPosting = false
            }
        }
    }
}

// MARK: - Photo Picker
struct PhotoPicker: UIViewControllerRepresentable {
    @Binding var selectedImages: [UIImage]
    var maxCount: Int = 4
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = maxCount - selectedImages.count
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        
        init(_ parent: PhotoPicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            
            for result in results {
                if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                    result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] image, error in
                        if let image = image as? UIImage {
                            DispatchQueue.main.async {
                                self?.parent.selectedImages.append(image)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Comments Sheet
struct CommentsSheet: View {
    let postId: String
    @State private var comments: [Comment] = []
    @State private var newComment = ""
    @State private var isLoading = true
    @State private var isSending = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if comments.isEmpty {
                    ContentUnavailableView("No Comments", systemImage: "bubble.left", description: Text("Be the first to comment"))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(comments) { comment in
                                CommentCell(comment: comment)
                                Divider()
                            }
                        }
                    }
                }
                
                // Input
                HStack(spacing: 12) {
                    TextField("Add a comment...", text: $newComment)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.systemGray6))
                        .cornerRadius(20)
                    
                    Button {
                        sendComment()
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title)
                                .foregroundColor(newComment.isEmpty ? .gray : .ravenPrimary)
                        }
                    }
                    .disabled(newComment.isEmpty || isSending)
                }
                .padding()
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadComments()
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    func loadComments() {
        Task {
            comments = (try? await APIService.shared.getComments(postId: postId)) ?? []
            isLoading = false
        }
    }
    
    func sendComment() {
        let text = newComment
        newComment = ""
        isSending = true
        
        Task {
            if let comment = try? await APIService.shared.addComment(postId: postId, content: text) {
                comments.insert(comment, at: 0)
            }
            isSending = false
        }
    }
}

// MARK: - Comment Cell
struct CommentCell: View {
    let comment: Comment
    @State private var isLiked = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(url: comment.authorAvatarUrl, name: comment.authorName, size: 36)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(comment.authorName)
                        .font(.subheadline.bold())
                    
                    Text("@\(comment.authorUsername)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(comment.createdAt.timeAgo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(comment.content)
                    .font(.subheadline)
                
                // Actions
                HStack(spacing: 16) {
                    Button {
                        isLiked.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isLiked ? "heart.fill" : "heart")
                                .foregroundColor(isLiked ? .red : .secondary)
                            if comment.likesCount > 0 {
                                Text("\(comment.likesCount)")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        // Reply
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .padding(.top, 4)
            }
        }
        .padding()
    }
}

// MARK: - Repost Sheet
struct RepostSheet: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @State private var quote = ""
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $quote)
                    .frame(height: 100)
                    .font(.body)
                
                // Original post preview
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        AvatarView(url: post.authorAvatarUrl, name: post.authorName, size: 24)
                        Text(post.authorName)
                            .font(.caption.bold())
                        Text("@\(post.authorUsername)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Text(post.content)
                        .font(.caption)
                        .lineLimit(3)
                }
                .padding()
                .background(Color(UIColor.systemGray6))
                .cornerRadius(12)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Repost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Repost") {
                        // Repost
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    PostComposerSheet()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
