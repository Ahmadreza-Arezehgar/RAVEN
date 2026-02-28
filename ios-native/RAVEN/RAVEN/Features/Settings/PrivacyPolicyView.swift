import SwiftUI

// MARK: - Privacy Policy Data

struct PPItem: Identifiable {
    let id: Int
    let question: String
    let answer: String
}

struct PPSection: Identifiable {
    let id: Int
    let title: String
    let icon: String
    let items: [PPItem]
}

// MARK: - Privacy Policy View (Liquid Glass)

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    @State private var expandedItems: Set<Int> = []
    @State private var appeared = false
    
    // Data export state
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportFileURL: URL?
    @State private var showShareSheet = false

    
    private var lastUpdated: String { "pp.last_updated".localized }
    private let version = "2.2"
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Content (64 Q&A, 9 sections)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var sections: [PPSection] {
        var id = 0
        func next() -> Int { defer { id += 1 }; return id }
        
        return [
            // A — General & Transparency (1–10)
            PPSection(id: 0, title: "pp.section.0".localized, icon: "shield.lefthalf.filled", items: [
                PPItem(id: next(), question: "pp.q1".localized, answer: "pp.a1".localized),
                PPItem(id: next(), question: "pp.q2".localized, answer: "pp.a2".localized),
                PPItem(id: next(), question: "pp.q3".localized, answer: "pp.a3".localized),
                PPItem(id: next(), question: "pp.q4".localized, answer: "pp.a4".localized),
                PPItem(id: next(), question: "pp.q5".localized, answer: "pp.a5".localized),
                PPItem(id: next(), question: "pp.q6".localized, answer: "pp.a6".localized),
                PPItem(id: next(), question: "pp.q7".localized, answer: "pp.a7".localized),
                PPItem(id: next(), question: "pp.q8".localized, answer: "pp.a8".localized),
                PPItem(id: next(), question: "pp.q9".localized, answer: "pp.a9".localized),
                PPItem(id: next(), question: "pp.q10".localized, answer: "pp.a10".localized),
            ]),
            
            // B — Account & Registration (11–21)
            PPSection(id: 1, title: "pp.section.1".localized, icon: "person.crop.circle", items: [
                PPItem(id: next(), question: "pp.q11".localized, answer: "pp.a11".localized),
                PPItem(id: next(), question: "pp.q12".localized, answer: "pp.a12".localized),
                PPItem(id: next(), question: "pp.q13".localized, answer: "pp.a13".localized),
                PPItem(id: next(), question: "pp.q14".localized, answer: "pp.a14".localized),
                PPItem(id: next(), question: "pp.q15".localized, answer: "pp.a15".localized),
                PPItem(id: next(), question: "pp.q16".localized, answer: "pp.a16".localized),
                PPItem(id: next(), question: "pp.q17".localized, answer: "pp.a17".localized),
                PPItem(id: next(), question: "pp.q18".localized, answer: "pp.a18".localized),
                PPItem(id: next(), question: "pp.q19".localized, answer: "pp.a19".localized),
                PPItem(id: next(), question: "pp.q20".localized, answer: "pp.a20".localized),
                PPItem(id: next(), question: "pp.q21".localized, answer: "pp.a21".localized),
            ]),
            
            // C — Messages & Chats (22–31)
            PPSection(id: 2, title: "pp.section.2".localized, icon: "bubble.left.and.bubble.right", items: [
                PPItem(id: next(), question: "pp.q22".localized, answer: "pp.a22".localized),
                PPItem(id: next(), question: "pp.q23".localized, answer: "pp.a23".localized),
                PPItem(id: next(), question: "pp.q24".localized, answer: "pp.a24".localized),
                PPItem(id: next(), question: "pp.q25".localized, answer: "pp.a25".localized),
                PPItem(id: next(), question: "pp.q26".localized, answer: "pp.a26".localized),
                PPItem(id: next(), question: "pp.q27".localized, answer: "pp.a27".localized),
                PPItem(id: next(), question: "pp.q28".localized, answer: "pp.a28".localized),
                PPItem(id: next(), question: "pp.q29".localized, answer: "pp.a29".localized),
                PPItem(id: next(), question: "pp.q30".localized, answer: "pp.a30".localized),
                PPItem(id: next(), question: "pp.q31".localized, answer: "pp.a31".localized),
            ]),
            
            // D — Groups (32–39)
            PPSection(id: 3, title: "pp.section.3".localized, icon: "person.3", items: [
                PPItem(id: next(), question: "pp.q32".localized, answer: "pp.a32".localized),
                PPItem(id: next(), question: "pp.q33".localized, answer: "pp.a33".localized),
                PPItem(id: next(), question: "pp.q34".localized, answer: "pp.a34".localized),
                PPItem(id: next(), question: "pp.q35".localized, answer: "pp.a35".localized),
                PPItem(id: next(), question: "pp.q36".localized, answer: "pp.a36".localized),
                PPItem(id: next(), question: "pp.q37".localized, answer: "pp.a37".localized),
                PPItem(id: next(), question: "pp.q38".localized, answer: "pp.a38".localized),
                PPItem(id: next(), question: "pp.q39".localized, answer: "pp.a39".localized),
            ]),
            
            // E — Contacts (40–47)
            PPSection(id: 4, title: "pp.section.4".localized, icon: "person.crop.rectangle.stack", items: [
                PPItem(id: next(), question: "pp.q40".localized, answer: "pp.a40".localized),
                PPItem(id: next(), question: "pp.q41".localized, answer: "pp.a41".localized),
                PPItem(id: next(), question: "pp.q42".localized, answer: "pp.a42".localized),
                PPItem(id: next(), question: "pp.q43".localized, answer: "pp.a43".localized),
                PPItem(id: next(), question: "pp.q44".localized, answer: "pp.a44".localized),
                PPItem(id: next(), question: "pp.q45".localized, answer: "pp.a45".localized),
                PPItem(id: next(), question: "pp.q46".localized, answer: "pp.a46".localized),
                PPItem(id: next(), question: "pp.q47".localized, answer: "pp.a47".localized),
            ]),
            
            // F — Posts & Feed (48–53)
            PPSection(id: 5, title: "pp.section.5".localized, icon: "square.stack", items: [
                PPItem(id: next(), question: "pp.q48".localized, answer: "pp.a48".localized),
                PPItem(id: next(), question: "pp.q49".localized, answer: "pp.a49".localized),
                PPItem(id: next(), question: "pp.q50".localized, answer: "pp.a50".localized),
                PPItem(id: next(), question: "pp.q51".localized, answer: "pp.a51".localized),
                PPItem(id: next(), question: "pp.q52".localized, answer: "pp.a52".localized),
                PPItem(id: next(), question: "pp.q53".localized, answer: "pp.a53".localized),
            ]),
            
            // G — Mesh / Offline / Bridge (54–60)
            PPSection(id: 6, title: "pp.section.6".localized, icon: "antenna.radiowaves.left.and.right", items: [
                PPItem(id: next(), question: "pp.q54".localized, answer: "pp.a54".localized),
                PPItem(id: next(), question: "pp.q55".localized, answer: "pp.a55".localized),
                PPItem(id: next(), question: "pp.q56".localized, answer: "pp.a56".localized),
                PPItem(id: next(), question: "pp.q57".localized, answer: "pp.a57".localized),
                PPItem(id: next(), question: "pp.q58".localized, answer: "pp.a58".localized),
                PPItem(id: next(), question: "pp.q59".localized, answer: "pp.a59".localized),
                // New: Mesh relay privacy
                PPItem(id: next(), question: "pp.mesh.privacy.q".localized, answer: "pp.mesh.privacy.a".localized),
            ]),
            
            // H — Third Parties & AI (61–63)
            PPSection(id: 7, title: "pp.section.7".localized, icon: "globe", items: [
                PPItem(id: next(), question: "pp.q61".localized, answer: "pp.a61".localized),
                PPItem(id: next(), question: "pp.q62".localized, answer: "pp.a62".localized),
                PPItem(id: next(), question: "pp.q63".localized, answer: "pp.a63".localized),
            ]),
            
            // I — Security & Data Retention (64–65)
            PPSection(id: 8, title: "pp.section.8".localized, icon: "lock.shield", items: [
                PPItem(id: next(), question: "pp.q64".localized, answer: "pp.a64".localized),
                PPItem(id: next(), question: "pp.q65".localized, answer: "pp.a65".localized),
            ]),
        ]
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Filtered Content
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var filteredSections: [PPSection] {
        guard !searchText.isEmpty else { return sections }
        let query = searchText.lowercased()
        return sections.compactMap { section in
            let matched = section.items.filter {
                $0.question.lowercased().contains(query) ||
                $0.answer.lowercased().contains(query)
            }
            guard !matched.isEmpty else { return nil }
            return PPSection(id: section.id, title: section.title, icon: section.icon, items: matched)
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
                    
                    footerCard
                    
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, DS.space16)
                .padding(.bottom, DS.space32)
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sharePolicy()
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
        .sheet(isPresented: $showShareSheet) {
            if let fileURL = exportFileURL {
                ShareSheet(items: [fileURL])
            }
        }
        .alert("Export Failed", isPresented: .init(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportError ?? "")
        }
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Header
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var headerCard: some View {
        VStack(spacing: DS.space12) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            
            Text("Privacy Policy")
                .font(.title2.bold())
                .foregroundStyle(.primary)
            
            HStack(spacing: DS.space8) {
                GlassChip(label: "v\(version)")
                
                Text("Updated \(lastUpdated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Text("\(totalItemCount) items across \(sections.count) sections")
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
            
            TextField("Search privacy policy…", text: $searchText)
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
    
    private func sectionCard(for section: PPSection) -> some View {
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
    
    private func accordionRow(item: PPItem) -> some View {
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
    // MARK: - Footer
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private var footerCard: some View {
        VStack(spacing: DS.space12) {
            footerLink(icon: "envelope", label: "Contact Privacy Team", action: {
                if let url = URL(string: "mailto:privacy@raven-messager.com") {
                    UIApplication.shared.open(url)
                }
            })
            
            Rectangle()
                .fill(.primary.opacity(0.05))
                .frame(height: 0.5)
            
            footerLink(icon: isExporting ? "hourglass" : "arrow.down.circle", label: isExporting ? "Exporting…" : "Download My Data", action: {
                guard !isExporting else { return }
                Task { await downloadDataExport() }
            })
            
            Rectangle()
                .fill(.primary.opacity(0.05))
                .frame(height: 0.5)
            
            footerLink(icon: "exclamationmark.triangle", label: "Report a Privacy Issue", action: {
                if let url = URL(string: "mailto:privacy@raven-messager.com?subject=Privacy%20Issue%20Report") {
                    UIApplication.shared.open(url)
                }
            })
        }
        .ravenCard()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.35).delay(0.35), value: appeared)
    }
    
    private func footerLink(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.space12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Share
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func sharePolicy() {
        let text = """
        RAVEN Privacy Policy v\(version)
        Last updated: \(lastUpdated)
        
        https://ravenapp.dev/privacy
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
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Data Export
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    
    private func downloadDataExport() async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        
        guard let url = AppConfig.apiURL(path: "/api/users/me/data-export") else {
            exportError = "Invalid server URL"
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            exportError = "Not authenticated"
            return
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                exportError = "Invalid response"
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                exportError = "Server error (\(httpResponse.statusCode))"
                return
            }
            
            // Save to temp file
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "raven_data_export.json"
            let fileURL = tempDir.appendingPathComponent(fileName)
            try data.write(to: fileURL)
            
            await MainActor.run {
                Haptics.success()
                exportFileURL = fileURL
                showShareSheet = true
            }
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
    .preferredColorScheme(.dark)
}
