// ComposeSheet — global "new post" sheet, opened from the rail's Post
// button. Mirrors ComposeCard (the inline composer in FeedView) but lives
// in a sheet so the user can post from any tab without flipping back to
// Home first. Supports text + up to 4 image attachments.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ComposeSheet: View {
    var onPosted: (Post) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthService

    @State private var text: String = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var posting = false
    @State private var error: String?

    /// Disable Post when there's nothing to send AND no attachments still
    /// uploading or successfully attached.
    private var canPost: Bool {
        !posting
            && !attachments.contains(where: { $0.state == .uploading })
            && (!text.trimmingCharacters(in: .whitespaces).isEmpty
                || attachments.contains(where: { $0.state.uploadedURL != nil }))
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    Text(posting ? "Posting…" : "Post")
                        .font(.system(size: 14, weight: .heavy))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(LinearGradient.ravenBrand)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canPost)
                .opacity(canPost ? 1 : 0.5)
            }

            HStack(alignment: .top, spacing: 12) {
                AvatarView(letter: auth.currentUser?.initials ?? "?",
                           size: 44,
                           urlString: auth.currentUser?.avatarPath)
                TextField("What's happening?", text: $text, axis: .vertical)
                    .font(.system(size: 17))
                    .textFieldStyle(.plain)
                    .lineLimit(3...10)
            }

            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await pickImages() }
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(RavenColors.logoStart)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(attachments.count >= 4)
                .help("Attach up to 4 images")

                Spacer()
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }

    @MainActor
    private func pickImages() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.jpeg, .png, .image, .heic]
        panel.message = "Attach images (max 4)"
        guard panel.runModal() == .OK else { return }

        let remaining = max(0, 4 - attachments.count)
        let urls = Array(panel.urls.prefix(remaining))
        for url in urls {
            let placeholder = PendingAttachment(localURL: url, state: .uploading)
            attachments.append(placeholder)
            Task { await upload(placeholder) }
        }
    }

    @MainActor
    private func upload(_ pending: PendingAttachment) async {
        do {
            let data = try Data(contentsOf: pending.localURL)
            let url = try await NetworkService.shared.uploadImage(
                data: data,
                filename: pending.localURL.lastPathComponent,
                mimeType: mimeType(for: pending.localURL.lastPathComponent)
            )
            mutate(pending.id) { $0.state = .uploaded(url: url) }
        } catch {
            mutate(pending.id) { $0.state = .failed(message: error.localizedDescription) }
            print("📝 [compose] upload failed: \(error)")
        }
    }

    @MainActor
    private func mutate(_ id: UUID, _ body: (inout PendingAttachment) -> Void) {
        guard let i = attachments.firstIndex(where: { $0.id == id }) else { return }
        var a = attachments[i]
        body(&a)
        attachments[i] = a
    }

    private func mimeType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".heic") || lower.hasSuffix(".heif") { return "image/heic" }
        return "image/jpeg"
    }

    @MainActor
    private func submit() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = attachments.compactMap { $0.state.uploadedURL }
        guard !trimmed.isEmpty || !urls.isEmpty else { return }
        posting = true
        error = nil
        do {
            let new: Post
            if urls.isEmpty {
                new = try await NetworkService.shared.createPost(content: trimmed)
            } else {
                new = try await NetworkService.shared.createPostWithImages(
                    content: trimmed, imageUrls: urls)
            }
            onPosted(new)
            dismiss()
        } catch {
            self.error = "Couldn't post. Try again."
            print("📝 [compose] sheet post failed: \(error)")
        }
        posting = false
    }
}

// MARK: - Attachment model + thumbnail strip

struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let localURL: URL
    var state: State

    enum State: Equatable {
        case uploading
        case uploaded(url: String)
        case failed(message: String)

        var uploadedURL: String? {
            if case let .uploaded(url) = self { return url }
            return nil
        }
    }
}

private struct AttachmentStrip: View {
    @Binding var attachments: [PendingAttachment]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { a in
                AttachmentThumb(attachment: a) {
                    attachments.removeAll { $0.id == a.id }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 90)
    }
}

private struct AttachmentThumb: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AsyncImage(url: attachment.localURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Color.white.opacity(0.06)
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            switch attachment.state {
            case .uploading:
                ZStack {
                    Color.black.opacity(0.45)
                    ProgressView().tint(.white).controlSize(.small)
                }
                .frame(width: 90, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            case .uploaded:
                EmptyView()
            case .failed(let message):
                ZStack {
                    Color.red.opacity(0.5)
                    VStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.white)
                        Text(message)
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .padding(.horizontal, 4)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(width: 90, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(4)
        }
    }
}
