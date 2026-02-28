// RAVEN - Chat View
// Converted from Flutter chat_page.dart

import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let recipientId: String
    let recipientName: String
    
    @State private var messageText = ""
    @State private var isLoading = false
    @State private var showAttachments = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isRecordingVoice = false
    
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.currentChatMessages) { message in
                            let isGroupChat = recipientId.hasPrefix("group_")
                            MessageBubble(
                                message: message,
                                isFromMe: message.senderId == AuthService.shared.currentUser?.id,
                                showSender: isGroupChat && message.senderId != AuthService.shared.currentUser?.id
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: appState.currentChatMessages.count) { _, _ in
                    if let lastMessage = appState.currentChatMessages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let lastMessage = appState.currentChatMessages.last {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Input Bar
            VStack(spacing: 0) {
                Divider()
                
                HStack(spacing: 12) {
                    // Attachments button
                    Button {
                        showAttachments.toggle()
                    } label: {
                        Image(systemName: showAttachments ? "xmark.circle.fill" : "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.ravenPrimary)
                    }
                    
                    // Text input
                    HStack {
                        TextField("Message...", text: $messageText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .focused($isInputFocused)
                        
                        if messageText.isEmpty {
                            // Voice button
                            Button {
                                isRecordingVoice.toggle()
                            } label: {
                                Image(systemName: isRecordingVoice ? "stop.circle.fill" : "mic.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(isRecordingVoice ? .red : .secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(20)
                    
                    // Send button
                    if !messageText.isEmpty {
                        Button {
                            sendMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title)
                                .foregroundColor(.ravenPrimary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(UIColor.systemBackground))
                
                // Attachments panel
                if showAttachments {
                    attachmentsPanel
                }
            }
        }
        .navigationTitle(recipientName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    ChatDetailsView(recipientId: recipientId, recipientName: recipientName)
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .onAppear {
            // Set active chat ID to suppress notifications for this chat
            NotificationService.shared.activeChatId = recipientId
            
            Task {
                await appState.loadMessages(for: recipientId)
            }
        }
        .onDisappear {
            // Clear active chat so future messages trigger notifications again
            NotificationService.shared.activeChatId = nil
            appState.currentChatId = nil
        }
        .onTapGesture {
            isInputFocused = false
        }
    }
    
    // MARK: - Attachments Panel
    var attachmentsPanel: some View {
        HStack(spacing: 24) {
            attachmentButton(icon: "photo", label: "Photo", color: .green) {
                // Photo picker
            }
            
            attachmentButton(icon: "camera", label: "Camera", color: .blue) {
                // Camera
            }
            
            attachmentButton(icon: "doc", label: "File", color: .orange) {
                // Document picker
            }
            
            attachmentButton(icon: "location", label: "Location", color: .red) {
                // Location
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
    }
    
    @ViewBuilder
    func attachmentButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(color)
                }
                
                Text(label)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
        }
    }
    
    // MARK: - Send Message
    func sendMessage() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        
        messageText = ""
        
        Haptics.impact(.light)
        
        Task {
            _ = await appState.sendMessage(to: recipientId, content: content)
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(recipientId: "123", recipientName: "John Doe")
            .environmentObject(AppState())
    }
    .preferredColorScheme(.dark)
}
