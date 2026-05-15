import SwiftUI
import AVFoundation

// MARK: - TranscriptPill

/// Capsule button with animated state transitions for voice transcription.
/// States: none → "Transcribe" / pending → spinner / ready → "Transcript ▾" / failed → "Retry"
struct TranscriptPill: View {
    let contentId: String              // Post or Comment ID
    let contentType: TranscriptContentType
    
    @State private var status: TranscriptStatus = .none
    @State private var transcriptText: String?
    @State private var transcriptLanguage: String?
    @State private var showPanel = false
    @State private var showFullSheet = false
    @State private var showPaywall = false
    @State private var shimmer = false
    
    enum TranscriptContentType {
        case post, comment
        case message(isGroup: Bool, groupId: String?)
    }
    
    enum TranscriptStatus: Equatable {
        case none, pending, ready, failed
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Pill button
            pillButton
            
            // Expandable glass panel
            if showPanel, let text = transcriptText {
                TranscriptGlassPanel(
                    text: text,
                    language: transcriptLanguage,
                    onExpand: { showFullSheet = true },
                    onCopy: { copyToClipboard(text) }
                )
                .transition(.asymmetric(
                    insertion: .push(from: .bottom).combined(with: .opacity),
                    removal: .push(from: .top).combined(with: .opacity)
                ))
            }
        }
        .sheet(isPresented: $showFullSheet) {
            if let text = transcriptText {
                FullTranscriptSheet(
                    text: text,
                    language: transcriptLanguage
                )
            }
        }
        .sheet(isPresented: $showPaywall) {
            RavenPlusPaywallView()
        }
        .onAppear(perform: checkCache)
    }
    
    @ViewBuilder
    private var pillButton: some View {
        Button(action: handleTap) {
            HStack(spacing: 6) {
                switch status {
                case .none:
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Transcribe")
                        .font(.system(size: 12, weight: .medium))
                    
                case .pending:
                    WaveSpinner()
                        .frame(width: 16, height: 12)
                    Text("Transcribing…")
                        .font(.system(size: 12, weight: .medium))
                    
                case .ready:
                    Image(systemName: "doc.text")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Transcript")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: showPanel ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                    
                case .failed:
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Retry")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(pillForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(pillBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(pillBorder, lineWidth: 0.5)
            )
            .overlay(shimmerOverlay)
        }
        .buttonStyle(.plain)
        .disabled(status == .pending)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: status)
    }
    
    // MARK: - Appearance
    
    private var pillForeground: Color {
        switch status {
        case .none: return .secondary
        case .pending: return .blue
        case .ready: return .primary
        case .failed: return .red
        }
    }
    
    private var pillBackground: some ShapeStyle {
        .ultraThinMaterial
    }
    
    private var pillBorder: Color {
        switch status {
        case .none: return .primary.opacity(0.15)
        case .pending: return .blue.opacity(0.3)
        case .ready: return .primary.opacity(0.2)
        case .failed: return .red.opacity(0.3)
        }
    }
    
    @ViewBuilder
    private var shimmerOverlay: some View {
        if shimmer {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.clear, .primary.opacity(0.3), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .mask(Capsule())
                .transition(.opacity)
        }
    }
    
    // MARK: - Actions
    
    private func handleTap() {
        Haptics.light()
        
        switch status {
        case .none, .failed:
            requestTranscription()
        case .ready:
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                showPanel.toggle()
            }
        case .pending:
            break
        }
    }
    
    private func requestTranscription() {
        status = .pending
        
        Task {
            do {
                let response: TranscriptResponse
                switch contentType {
                case .post:
                    response = try await TranscriptionService.shared.transcribe(postId: contentId)
                case .comment:
                    response = try await TranscriptionService.shared.transcribe(commentId: contentId)
                case .message(let isGroup, let groupId):
                    response = try await TranscriptionService.shared.transcribe(messageId: contentId, isGroup: isGroup, groupId: groupId)
                }
                
                if response.status == "ready", let text = response.text {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        transcriptText = text
                        transcriptLanguage = response.language
                        status = .ready
                    }
                    
                    // Auto-expand panel
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.15)) {
                        showPanel = true
                    }
                    
                    // Celebration shimmer
                    triggerShimmer()
                    Haptics.success()
                } else {
                    #if DEBUG
                    print("🔴 [TranscriptPill] Not ready — status=\(response.status), text=\(response.text?.prefix(20) ?? "nil")")
                    #endif
                    withAnimation {
                        status = .failed
                    }
                    Haptics.error()
                }
            } catch {
                #if DEBUG
                print("🔴 [TranscriptPill] Error: \(error)")
                #endif
                withAnimation {
                    status = .failed
                }
                Haptics.error()
                
                if let limitError = error as? PremiumLimitError {
                    NotificationPipeline.shared.enqueue(ToastItem.appUpdate(
                        id: UUID().uuidString,
                        title: "Limit Reached",
                        message: limitError.localizedDescription
                    ))
                    // RAVEN+ upsell: open paywall when AI limit is reached
                    DispatchQueue.main.async {
                        showPaywall = true
                    }
                }
            }
        }
    }
    
    private func checkCache() {
        if TranscriptionService.shared.hasCachedTranscript(id: contentId) {
            transcriptText = TranscriptionService.shared.cachedText(for: contentId)
            transcriptLanguage = TranscriptionService.shared.cachedLanguage(for: contentId)
            status = .ready
        }
    }
    
    private func triggerShimmer() {
        withAnimation(.easeInOut(duration: 0.8)) {
            shimmer = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.3)) {
                shimmer = false
            }
        }
    }
    
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        Haptics.light()
    }
}


// MARK: - TranscriptGlassPanel

/// Expandable glass card showing transcript text with typewriter animation.
struct TranscriptGlassPanel: View {
    let text: String
    let language: String?
    let onExpand: () -> Void
    let onCopy: () -> Void
    
    @State private var visibleText = ""
    @State private var isAnimating = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: language badge + actions
            HStack {
                // Language badge
                if let lang = language, !lang.isEmpty {
                    Text(lang.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.1))
                        .clipShape(Capsule())
                }
                
                HStack(spacing: 2) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8))
                    Text("AI Transcript")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.secondary)
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 12) {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Transcript text with typewriter effect
            Text(isAnimating ? visibleText : text)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.primary.opacity(0.9))
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(6)
        }
        .padding(14)
        .background(
            ZStack {
                // Glass background
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                
                // Light tint for contrast safety
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.primary.opacity(0.05))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .padding(.top, 6)
        .onAppear(perform: startTypewriter)
    }
    
    private func startTypewriter() {
        guard isAnimating else { return }
        visibleText = ""
        
        let chars = Array(text)
        let totalChars = chars.count
        let maxDuration: Double = 1.5  // Max animation duration
        let charDelay = min(0.02, maxDuration / Double(totalChars))
        
        for (index, char) in chars.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + charDelay * Double(index)) {
                if index < totalChars {
                    visibleText.append(char)
                    
                    if index == totalChars - 1 {
                        isAnimating = false
                    }
                }
            }
        }
    }
}


// MARK: - FullTranscriptSheet

/// Full-screen glass modal for reading complete transcripts.
struct FullTranscriptSheet: View {
    let text: String
    let language: String?
    
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Language badge
                    if let lang = language, !lang.isEmpty {
                        HStack(spacing: 8) {
                            Text(lang.uppercased())
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.8))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.primary.opacity(0.1))
                                .clipShape(Capsule())
                            
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                                Text("AI Transcript")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                    
                    // Full transcript text
                    Text(text)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(.primary.opacity(0.9))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                }
                .padding(20)
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                        Haptics.light()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
        .presentationDragIndicator(.visible)
    }
}


// MARK: - WaveSpinner

/// Animated wave bars for the "Transcribing…" loading state.
struct WaveSpinner: View {
    @State private var animate = false
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.blue)
                    .frame(width: 2)
                    .scaleEffect(y: animate ? 1.0 : 0.3, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

