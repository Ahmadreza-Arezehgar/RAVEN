import SwiftUI

// MARK: - Quick Reply Sheet
/// A Liquid Glass styled quick reply composer that slides up from bottom
struct QuickReplySheet: View {
    @ObservedObject var pipeline: NotificationPipeline
    
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        if let state = pipeline.quickReplyState {
            VStack(spacing: 0) {
                Spacer()
                
                VStack(spacing: 16) {
                    // MARK: - Header
                    HStack {
                        // Recipient info
                        HStack(spacing: 10) {
                            // Avatar
                            if let url = state.toastItem.avatarURL {
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Circle().fill(.gray.opacity(0.3))
                                }
                                .frame(width: 32, height: 32)
                                .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(.blue.opacity(0.3))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Text(String(state.toastItem.senderName?.prefix(1) ?? "?").uppercased())
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                    )
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reply to")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(state.toastItem.senderName ?? "Unknown")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        
                        Spacer()
                        
                        // Cancel button
                        Button {
                            pipeline.closeQuickReply()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // MARK: - Text Input
                    HStack(spacing: 12) {
                        // Text field
                        TextField("Type a message...", text: Binding(
                            get: { pipeline.quickReplyState?.replyText ?? "" },
                            set: { pipeline.updateReplyText($0) }
                        ))
                        .focused($isTextFieldFocused)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.15), lineWidth: 0.5)
                        )
                        
                        // Send button
                        Button {
                            Task {
                                await pipeline.sendQuickReply()
                            }
                        } label: {
                            Group {
                                if state.isSending {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.title)
                                }
                            }
                            .foregroundStyle(canSend ? .blue : .gray)
                            .frame(width: 44, height: 44)
                        }
                        .disabled(!canSend || state.isSending)
                    }
                    
                    // MARK: - Delivery Indicator
                    HStack(spacing: 6) {
                        Circle()
                            .fill(NetworkMonitor.shared.isOnline ? .blue : .purple)
                            .frame(width: 8, height: 8)
                        
                        Text(NetworkMonitor.shared.isOnline ? "Will send via server" : "Will send via mesh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
                .padding(20)
                .background(
                    ZStack {
                        // Frosted glass
                        RoundedRectangle(cornerRadius: 28)
                            .fill(.ultraThinMaterial)
                        
                        // Top border highlight
                        RoundedRectangle(cornerRadius: 28)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.3), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .shadow(color: .black.opacity(0.2), radius: 30, y: -10)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                isTextFieldFocused = true
            }
        }
    }
    
    private var canSend: Bool {
        guard let text = pipeline.quickReplyState?.replyText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// NetworkMonitor is now in Core/Mesh/NetworkMonitor.swift

// MARK: - Preview
#Preview {
    ZStack {
        Color.black.opacity(0.5).ignoresSafeArea()
        
        QuickReplySheet(pipeline: {
            let p = NotificationPipeline.shared
            p.quickReplyState = QuickReplyState(
                toastItem: .message(
                    senderName: "Sarah",
                    preview: "Hey!",
                    chatId: "123",
                    senderId: "456"
                )
            )
            return p
        }())
    }
}
