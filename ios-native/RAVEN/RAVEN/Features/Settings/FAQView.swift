import SwiftUI

// MARK: - FAQ Data

struct FAQItem: Identifiable {
    let id: Int
    let question: String
    let answer: String
}

struct FAQSection: Identifiable {
    let id: Int
    let title: String
    let icon: String
    let items: [FAQItem]
}

// MARK: - FAQ View (Liquid Glass)

struct FAQView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    @State private var expandedItems: Set<Int> = []
    @State private var appeared = false
    
    private var lastUpdated: String { "faq.last_updated".localized }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Content (79 Q&A, 9 sections)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var sections: [FAQSection] {
        var id = 0
        func next() -> Int { defer { id += 1 }; return id }
        
        return [
            // A — Getting Started & Account (10)
            FAQSection(id: 0, title: "faq.section.0".localized, icon: "person.crop.circle", items: [
                FAQItem(id: next(), question: "faq.q1".localized, answer: "faq.a1".localized),
                FAQItem(id: next(), question: "faq.q2".localized, answer: "faq.a2".localized),
                FAQItem(id: next(), question: "faq.q3".localized, answer: "faq.a3".localized),
                FAQItem(id: next(), question: "faq.q4".localized, answer: "faq.a4".localized),
                FAQItem(id: next(), question: "faq.q5".localized, answer: "faq.a5".localized),
                FAQItem(id: next(), question: "faq.q6".localized, answer: "faq.a6".localized),
                FAQItem(id: next(), question: "faq.q7".localized, answer: "faq.a7".localized),
                FAQItem(id: next(), question: "faq.q8".localized, answer: "faq.a8".localized),
                FAQItem(id: next(), question: "faq.q9".localized, answer: "faq.a9".localized),
                FAQItem(id: next(), question: "faq.q10".localized, answer: "faq.a10".localized),
            ]),
            
            // B — Messaging (10)
            FAQSection(id: 1, title: "faq.section.1".localized, icon: "bubble.left.and.bubble.right", items: [
                FAQItem(id: next(), question: "faq.q11".localized, answer: "faq.a11".localized),
                FAQItem(id: next(), question: "faq.q12".localized, answer: "faq.a12".localized),
                FAQItem(id: next(), question: "faq.q13".localized, answer: "faq.a13".localized),
                FAQItem(id: next(), question: "faq.q14".localized, answer: "faq.a14".localized),
                FAQItem(id: next(), question: "faq.q15".localized, answer: "faq.a15".localized),
                FAQItem(id: next(), question: "faq.q16".localized, answer: "faq.a16".localized),
                FAQItem(id: next(), question: "faq.q17".localized, answer: "faq.a17".localized),
                FAQItem(id: next(), question: "faq.q18".localized, answer: "faq.a18".localized),
                FAQItem(id: next(), question: "faq.q19".localized, answer: "faq.a19".localized),
                FAQItem(id: next(), question: "faq.q20".localized, answer: "faq.a20".localized),
            ]),
            
            // C — Mesh / Offline (17: 2 new + 15 existing)
            FAQSection(id: 2, title: "faq.section.2".localized, icon: "antenna.radiowaves.left.and.right", items: [
                // New: Mesh expectation management
                FAQItem(id: next(), question: "faq.mesh_simple.q".localized, answer: "faq.mesh_simple.a".localized),
                FAQItem(id: next(), question: "faq.mesh_limits.q".localized, answer: "faq.mesh_limits.a".localized),
                // Existing mesh Q&As
                FAQItem(id: next(), question: "faq.q21".localized, answer: "faq.a21".localized),
                FAQItem(id: next(), question: "faq.q22".localized, answer: "faq.a22".localized),
                FAQItem(id: next(), question: "faq.q23".localized, answer: "faq.a23".localized),
                FAQItem(id: next(), question: "faq.q24".localized, answer: "faq.a24".localized),
                FAQItem(id: next(), question: "faq.q25".localized, answer: "faq.a25".localized),
                FAQItem(id: next(), question: "faq.q26".localized, answer: "faq.a26".localized),
                FAQItem(id: next(), question: "faq.q27".localized, answer: "faq.a27".localized),
                FAQItem(id: next(), question: "faq.q28".localized, answer: "faq.a28".localized),
                FAQItem(id: next(), question: "faq.q29".localized, answer: "faq.a29".localized),
                FAQItem(id: next(), question: "faq.q30".localized, answer: "faq.a30".localized),
                FAQItem(id: next(), question: "faq.q31".localized, answer: "faq.a31".localized),
                FAQItem(id: next(), question: "faq.q32".localized, answer: "faq.a32".localized),
                FAQItem(id: next(), question: "faq.q33".localized, answer: "faq.a33".localized),
                FAQItem(id: next(), question: "faq.q34".localized, answer: "faq.a34".localized),
                FAQItem(id: next(), question: "faq.q35".localized, answer: "faq.a35".localized),
            ]),
            
            // D — Groups (10)
            FAQSection(id: 3, title: "faq.section.3".localized, icon: "person.3", items: [
                FAQItem(id: next(), question: "faq.q36".localized, answer: "faq.a36".localized),
                FAQItem(id: next(), question: "faq.q37".localized, answer: "faq.a37".localized),
                FAQItem(id: next(), question: "faq.q38".localized, answer: "faq.a38".localized),
                FAQItem(id: next(), question: "faq.q39".localized, answer: "faq.a39".localized),
                FAQItem(id: next(), question: "faq.q40".localized, answer: "faq.a40".localized),
                FAQItem(id: next(), question: "faq.q41".localized, answer: "faq.a41".localized),
                FAQItem(id: next(), question: "faq.q42".localized, answer: "faq.a42".localized),
                FAQItem(id: next(), question: "faq.q43".localized, answer: "faq.a43".localized),
                FAQItem(id: next(), question: "faq.q44".localized, answer: "faq.a44".localized),
                FAQItem(id: next(), question: "faq.q45".localized, answer: "faq.a45".localized),
            ]),
            
            // E — Posts & Feed (10)
            FAQSection(id: 4, title: "faq.section.4".localized, icon: "square.stack", items: [
                FAQItem(id: next(), question: "faq.q46".localized, answer: "faq.a46".localized),
                FAQItem(id: next(), question: "faq.q47".localized, answer: "faq.a47".localized),
                FAQItem(id: next(), question: "faq.q48".localized, answer: "faq.a48".localized),
                FAQItem(id: next(), question: "faq.q49".localized, answer: "faq.a49".localized),
                FAQItem(id: next(), question: "faq.q50".localized, answer: "faq.a50".localized),
                FAQItem(id: next(), question: "faq.q51".localized, answer: "faq.a51".localized),
                FAQItem(id: next(), question: "faq.q52".localized, answer: "faq.a52".localized),
                FAQItem(id: next(), question: "faq.q53".localized, answer: "faq.a53".localized),
                FAQItem(id: next(), question: "faq.q54".localized, answer: "faq.a54".localized),
                FAQItem(id: next(), question: "faq.q55".localized, answer: "faq.a55".localized),
            ]),
            
            // F — RAVEN+ & Subscriptions (4)
            FAQSection(id: 5, title: "faq.section.5".localized, icon: "crown", items: [
                FAQItem(id: next(), question: "faq.q56".localized, answer: "faq.a56".localized),
                FAQItem(id: next(), question: "faq.q57".localized, answer: "faq.a57".localized),
                FAQItem(id: next(), question: "faq.q58".localized, answer: "faq.a58".localized),
                FAQItem(id: next(), question: "faq.q59".localized, answer: "faq.a59".localized),
            ]),
            
            // G — Security & Privacy (5)
            FAQSection(id: 6, title: "faq.section.6".localized, icon: "lock.shield", items: [
                FAQItem(id: next(), question: "faq.q60".localized, answer: "faq.a60".localized),
                FAQItem(id: next(), question: "faq.q61".localized, answer: "faq.a61".localized),
                FAQItem(id: next(), question: "faq.q62".localized, answer: "faq.a62".localized),
                FAQItem(id: next(), question: "faq.q63".localized, answer: "faq.a63".localized),
                FAQItem(id: next(), question: "faq.q64".localized, answer: "faq.a64".localized),
                // v1.6 capabilities (May 2026) — Helper Mode gateway,
                // identity rotation, Sealed Sender + OPAQUE shipped,
                // Double-AEAD + memory hygiene.
                FAQItem(id: next(), question: "faq.q64a".localized, answer: "faq.a64a".localized),
                FAQItem(id: next(), question: "faq.q64b".localized, answer: "faq.a64b".localized),
                FAQItem(id: next(), question: "faq.q64c".localized, answer: "faq.a64c".localized),
                FAQItem(id: next(), question: "faq.q64d".localized, answer: "faq.a64d".localized),
            ]),
            
            // H — Echo, Club & Vault (6)
            FAQSection(id: 7, title: "faq.section.7".localized, icon: "waveform.circle", items: [
                FAQItem(id: next(), question: "faq.q65".localized, answer: "faq.a65".localized),
                FAQItem(id: next(), question: "faq.q66".localized, answer: "faq.a66".localized),
                FAQItem(id: next(), question: "faq.q67".localized, answer: "faq.a67".localized),
                FAQItem(id: next(), question: "faq.q68".localized, answer: "faq.a68".localized),
                FAQItem(id: next(), question: "faq.q69".localized, answer: "faq.a69".localized),
                FAQItem(id: next(), question: "faq.q70".localized, answer: "faq.a70".localized),
            ]),
            
            // I — Stories, Discovery & More (9)
            FAQSection(id: 8, title: "faq.section.8".localized, icon: "sparkles", items: [
                FAQItem(id: next(), question: "faq.q71".localized, answer: "faq.a71".localized),
                FAQItem(id: next(), question: "faq.q72".localized, answer: "faq.a72".localized),
                FAQItem(id: next(), question: "faq.q73".localized, answer: "faq.a73".localized),
                FAQItem(id: next(), question: "faq.q74".localized, answer: "faq.a74".localized),
                FAQItem(id: next(), question: "faq.q75".localized, answer: "faq.a75".localized),
                FAQItem(id: next(), question: "faq.q76".localized, answer: "faq.a76".localized),
                FAQItem(id: next(), question: "faq.q77".localized, answer: "faq.a77".localized),
                FAQItem(id: next(), question: "faq.q78".localized, answer: "faq.a78".localized),
                FAQItem(id: next(), question: "faq.q79".localized, answer: "faq.a79".localized),
            ]),
        ]
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Filtered Content
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var filteredSections: [FAQSection] {
        guard !searchText.isEmpty else { return sections }
        let query = searchText.lowercased()
        return sections.compactMap { section in
            let matched = section.items.filter {
                $0.question.lowercased().contains(query) ||
                $0.answer.lowercased().contains(query)
            }
            guard !matched.isEmpty else { return nil }
            return FAQSection(id: section.id, title: section.title, icon: section.icon, items: matched)
        }
    }
    
    private var totalItemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Body
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: DS.space16) {
                    headerCard
                    searchBar
                    
                    // Sections
                    ForEach(Array(filteredSections.enumerated()), id: \.element.id) { index, section in
                        sectionCard(for: section)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 12)
                            .animation(
                                .easeOut(duration: 0.35).delay(Double(index) * 0.04),
                                value: appeared
                            )
                    }
                    
                    if filteredSections.isEmpty {
                        noResultsView
                    }
                    
                    contactCard
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, DS.space16)
                .padding(.bottom, DS.space32)
            }
        }
        .navigationTitle("FAQ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    shareFAQ()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { appeared = true }
        }
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Header
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var headerCard: some View {
        VStack(spacing: DS.space12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            
            Text("Frequently Asked Questions")
                .font(.title2.bold())
                .foregroundStyle(.primary)
            
            Text("Updated \(lastUpdated)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("\(totalItemCount) questions across \(sections.count) topics")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space24)
        .ravenCard()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.35), value: appeared)
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Search
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var searchBar: some View {
        HStack(spacing: DS.space8) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.tertiary)
            
            TextField("Search FAQ…", text: $searchText)
                .font(.body)
                .foregroundStyle(.primary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            
            if !searchText.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.25)) {
                        searchText = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, DS.space16)
        .padding(.vertical, DS.space12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(.primary.opacity(0.08), lineWidth: 0.6)
        )
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Section Card
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func sectionCard(for section: FAQSection) -> some View {
        VStack(spacing: 0) {
            // Section header
            HStack(spacing: DS.space8) {
                Image(systemName: section.icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                
                Spacer()
                
                Text("\(section.items.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(.primary.opacity(0.06))
                    )
            }
            .padding(.horizontal, DS.space16)
            .padding(.vertical, DS.space12)
            
            // Divider
            Rectangle()
                .fill(.primary.opacity(0.05))
                .frame(height: 0.5)
            
            // Items
            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                accordionRow(item: item)
                
                if index < section.items.count - 1 {
                    Rectangle()
                        .fill(.primary.opacity(0.03))
                        .frame(height: 0.5)
                        .padding(.leading, DS.space16)
                }
            }
        }
        .ravenCard(padding: 0)
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Accordion Row
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func accordionRow(item: FAQItem) -> some View {
        let isExpanded = expandedItems.contains(item.id)
        
        return VStack(alignment: .leading, spacing: 0) {
            // Question
            Button {
                Haptics.light()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    if isExpanded {
                        expandedItems.remove(item.id)
                    } else {
                        expandedItems.insert(item.id)
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: DS.space8) {
                    Text(highlightedText(item.question))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.9))
                        .multilineTextAlignment(.leading)
                    
                    Spacer(minLength: 8)
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
                .padding(.horizontal, DS.space16)
                .padding(.vertical, DS.space12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Answer
            if isExpanded {
                Text(highlightedText(item.answer))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, DS.space16)
                    .padding(.bottom, DS.space12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Highlight Helper
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func highlightedText(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !searchText.isEmpty else { return attributed }
        
        let query = searchText.lowercased()
        let lower = text.lowercased()
        var searchStart = lower.startIndex
        
        while let range = lower.range(of: query, range: searchStart..<lower.endIndex) {
            let attrStart = AttributedString.Index(range.lowerBound, within: attributed)
            let attrEnd = AttributedString.Index(range.upperBound, within: attributed)
            if let start = attrStart, let end = attrEnd {
                attributed[start..<end].backgroundColor = Color.yellow.opacity(0.3)
                attributed[start..<end].foregroundColor = .white
            }
            searchStart = range.upperBound
        }
        
        return attributed
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - No Results
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var noResultsView: some View {
        VStack(spacing: DS.space12) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.tertiary)
            
            Text("No results for \"\(searchText)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space32)
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Contact Card
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var contactCard: some View {
        VStack(spacing: DS.space12) {
            Text("Still have questions?")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            
            Button {
                if let url = URL(string: "mailto:privacy@raven-messager.com") {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack(spacing: DS.space8) {
                    Image(systemName: "envelope")
                        .font(.body)
                    Text("Contact Support")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.space24)
                .padding(.vertical, DS.space12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(.primary.opacity(0.1), lineWidth: 0.6)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space24)
        .ravenCard()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.35).delay(0.3), value: appeared)
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Share
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func shareFAQ() {
        let text = """
        RAVEN FAQ
        Last updated: \(lastUpdated)
        
        https://ravenapp.dev/faq
        """
        
        let av = UIActivityViewController(
            activityItems: [text],
            applicationActivities: nil
        )
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            // iPad requires popover source configuration
            if let popover = av.popoverPresentationController {
                popover.sourceView = root.view
                popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            root.present(av, animated: true)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FAQView()
    }
    .preferredColorScheme(.dark)
}
