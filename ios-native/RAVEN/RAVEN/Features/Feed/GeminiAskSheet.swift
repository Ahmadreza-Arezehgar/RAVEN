import SwiftUI

/// Bottom sheet for Gemini AI questions
struct GeminiAskSheet: View {
    let postId: String
    let postContent: String
    
    private var realPostId: String {
        postId.components(separatedBy: "-loop-")[0]
    }
    
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var isLoading = false
    @State private var response: String?
    @State private var error: String?
    @State private var showPaywall = false
    
    private let networkService = NetworkService.shared
    
    // Preset question chips
    private let presets = [
        ("Summarize", "Summarize this post in 2-3 sentences"),
        ("Explain", "Explain this post in simple terms"),
        ("Translate", "Translate this post to English"),
        ("Pros/Cons", "What are the pros and cons of what this post is saying?"),
        ("Fact Check", "Is the information in this post accurate?")
    ]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Post preview
                VStack(alignment: .leading, spacing: 8) {
                    Text("About this post:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(postContent)
                        .font(.subheadline)
                        .lineLimit(3)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
                
                // Preset chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(presets, id: \.0) { preset in
                            Button {
                                question = preset.1
                                Task {
                                    await askGemini()
                                }
                            } label: {
                                Text(preset.0)
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule()
                                            .fill(Color(.systemGray5))
                                    )
                                    .foregroundColor(.primary)
                            }
                            .disabled(isLoading)
                        }
                    }
                    .padding(.horizontal)
                }
                
                // Custom question input
                HStack {
                    TextField("Ask something...", text: $question)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    Button {
                        Task {
                            await askGemini()
                        }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }
                .padding(.horizontal)
                
                // Response area
                if let response = response {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundColor(.purple)
                                Text("Gemini AI")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            Text(response)
                                .font(.body)
                                .foregroundColor(.primary)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.purple.opacity(0.1),
                                            Color.blue.opacity(0.1)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.purple.opacity(0.3), .blue.opacity(0.3)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                    }
                    .padding(.horizontal)
                }
                
                if let error = error {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }
                
                Spacer()
            }
            .padding(.top)
            .navigationTitle("Ask Gemini")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            RavenPlusPaywallView()
        }
        .presentationDetents([.medium, .large])
    }
    
    // MARK: - Ask Gemini
    private func askGemini() async {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        
        // RAVEN+ rate limit: Free 5/day, RAVEN+ unlimited
        guard PremiumLimits.canUseGemini() else {
            self.error = "Daily AI limit reached. Upgrade to RAVEN+ for unlimited."
            showPaywall = true
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            struct AskRequest: Encodable {
                let postId: String
                let question: String
                let context: String
                let lang: String
                
                enum CodingKeys: String, CodingKey {
                    case postId = "post_id"
                    case question, context, lang
                }
            }
            
            struct AskResponse: Decodable {
                let answer: String
                let model: String?
                let tokensUsed: Int?
                
                enum CodingKeys: String, CodingKey {
                    case answer, model
                    case tokensUsed = "tokens_used"
                }
            }
            
            let askResponse: AskResponse = try await networkService.post(
                path: "/api/ai/ask",
                body: AskRequest(
                    postId: realPostId,
                    question: question,
                    context: postContent,
                    lang: "en"
                )
            )
            
            response = askResponse.answer
            
        } catch {
            PremiumLimits.refundGemini()
            self.error = "Failed to get AI response: \(error.localizedDescription)"
            #if DEBUG
            print("❌ Gemini Ask error: \(error)")
            #endif
        }
        
        isLoading = false
    }
}

#Preview {
    GeminiAskSheet(postId: "test", postContent: "This is a sample post content for testing the Gemini AI feature.")
}
