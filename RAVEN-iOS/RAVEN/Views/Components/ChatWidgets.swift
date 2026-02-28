// RAVEN - Chat Widgets
// Converted from Flutter modern_chat_bubble.dart, message_status_widgets.dart

import SwiftUI

// MARK: - Message Bubble
struct MessageBubble: View {
    let message: ChatMessage
    let isFromMe: Bool
    var showSender: Bool = false
    var onReply: (() -> Void)?
    var onReaction: ((String) -> Void)?
    
    @State private var showActions = false
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isFromMe { Spacer(minLength: 60) }
            
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                // Sender name (for groups)
                if showSender && !isFromMe {
                    Text(message.senderName)
                        .font(.caption.bold())
                        .foregroundColor(.ravenPrimary)
                }
                
                // Reply preview
                if let replyId = message.replyToMessageId {
                    replyPreview(replyId)
                }
                
                // Content
                Group {
                    switch message.type {
                    case .text:
                        textBubble
                    case .image:
                        imageBubble
                    case .voice:
                        VoiceMessageBubble(message: message, isFromMe: isFromMe)
                    case .file:
                        fileBubble
                    case .location:
                        locationBubble
                    }
                }
                .contextMenu {
                    contextMenuItems
                }
                
                // Status & time
                HStack(spacing: 4) {
                    // Delivery method
                    if message.via == "mesh" {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    
                    Text(message.timestamp.messageTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if isFromMe {
                        MessageStatusIcon(status: message.status)
                    }
                }
            }
            
            if !isFromMe { Spacer(minLength: 60) }
        }
    }
    
    // MARK: - Text Bubble
    var textBubble: some View {
        Text(message.text)
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isFromMe ? Color.ravenPrimary : Color(UIColor.systemGray6))
            .foregroundColor(isFromMe ? .white : .primary)
            .clipShape(BubbleShape(isFromMe: isFromMe))
    }
    
    // MARK: - Image Bubble
    var imageBubble: some View {
        Group {
            if let urlString = message.imageUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: 250, maxHeight: 300)
                            .clipped()
                    case .failure:
                        placeholderImage
                    case .empty:
                        ProgressView()
                            .frame(width: 200, height: 150)
                    @unknown default:
                        placeholderImage
                    }
                }
            } else {
                placeholderImage
            }
        }
        .cornerRadius(16)
    }
    
    var placeholderImage: some View {
        Rectangle()
            .fill(Color(UIColor.systemGray5))
            .frame(width: 200, height: 150)
            .overlay(
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundColor(.secondary)
            )
    }
    
    // MARK: - File Bubble
    var fileBubble: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.ravenPrimary.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                Image(systemName: "doc.fill")
                    .foregroundColor(.ravenPrimary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(message.fileName ?? "File")
                    .font(.subheadline)
                    .lineLimit(1)
                
                if let size = message.fileSize {
                    Text(formatFileSize(size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.ravenPrimary)
        }
        .padding(12)
        .background(Color(UIColor.systemGray6))
        .cornerRadius(16)
    }
    
    // MARK: - Location Bubble
    var locationBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Map placeholder
            Rectangle()
                .fill(Color(UIColor.systemGray5))
                .frame(width: 200, height: 120)
                .overlay(
                    Image(systemName: "map")
                        .font(.title)
                        .foregroundColor(.secondary)
                )
            
            HStack {
                Image(systemName: "location.fill")
                    .foregroundColor(.ravenPrimary)
                Text("Location")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Color(UIColor.systemGray6))
        .cornerRadius(16)
    }
    
    // MARK: - Reply Preview
    @ViewBuilder
    func replyPreview(_ replyId: String) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.ravenPrimary)
                .frame(width: 3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(message.replyToSenderName ?? "User")
                    .font(.caption.bold())
                    .foregroundColor(.ravenPrimary)
                
                Text(message.replyToText ?? "Message")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(Color(UIColor.systemGray6).opacity(0.5))
        .cornerRadius(8)
    }
    
    // MARK: - Context Menu
    @ViewBuilder
    var contextMenuItems: some View {
        Button {
            onReply?()
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        
        Button {
            UIPasteboard.general.string = message.text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        
        Button {
            // Forward
        } label: {
            Label("Forward", systemImage: "arrowshape.turn.up.right")
        }
        
        Divider()
        
        Button(role: .destructive) {
            // Delete
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
    
    func formatFileSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Bubble Shape
struct BubbleShape: Shape {
    let isFromMe: Bool
    
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailWidth: CGFloat = 8
        
        var path = Path()
        
        if isFromMe {
            // Bottom right tail
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX - tailWidth, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            // Bottom left tail
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        
        path.closeSubpath()
        return path
    }
}

// MARK: - Message Status Icon
struct MessageStatusIcon: View {
    let status: MessageStatus
    
    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .sending:
            ProgressView()
                .scaleEffect(0.5)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.ravenPrimary)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption2)
                .foregroundColor(.red)
        case .scheduled:
            Image(systemName: "calendar.badge.clock")
                .font(.caption2)
                .foregroundColor(.orange)
        default:
            EmptyView()
        }
    }
}

// MARK: - Typing Indicator
struct TypingIndicator: View {
    @State private var dotIndex = 0
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(dotIndex == i ? 1.3 : 1.0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(UIColor.systemGray6))
        .cornerRadius(16)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.5)) {
                    dotIndex = (dotIndex + 1) % 3
                }
            }
        }
    }
}

// MARK: - Date Separator
struct DateSeparator: View {
    let date: Date
    
    var body: some View {
        HStack {
            line
            
            Text(date.chatTimestamp)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(12)
            
            line
        }
        .padding(.vertical, 16)
    }
    
    var line: some View {
        Rectangle()
            .fill(Color(UIColor.systemGray5))
            .frame(height: 1)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 8) {
            MessageBubble(
                message: ChatMessage(
                    id: "1",
                    roomId: "room",
                    senderId: "other",
                    senderName: "John",
                    recipientId: "me",
                    text: "Hey, how are you?",
                    timestamp: Date(),
                    status: .delivered
                ),
                isFromMe: false
            )
            
            MessageBubble(
                message: ChatMessage(
                    id: "2",
                    roomId: "room",
                    senderId: "me",
                    senderName: "Me",
                    recipientId: "other",
                    text: "I'm good! Just testing the mesh network 📡",
                    timestamp: Date(),
                    via: "mesh",
                    status: .read
                ),
                isFromMe: true
            )
            
            TypingIndicator()
        }
        .padding()
    }
    .background(Color.black)
    .preferredColorScheme(.dark)
}
