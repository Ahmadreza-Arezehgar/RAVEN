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
    private let version = "2.3"
    
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Content (74 Q&A, 10 sections)
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
                    honestDisclosuresCard
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
    // MARK: - Honest disclosures (radical-honesty banner)
    //
    // A privacy policy that overstates is worse than none. This card
    // sits above the searchable Q&A and lists, plainly, what we have
    // shipped vs what we have NOT shipped yet, with the version each
    // gap closes in. Mirrors the "Security commitments" section on
    // the marketing site so users see the same honest scoreboard
    // wherever they look.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var honestDisclosuresCard: some View {
        VStack(alignment: .leading, spacing: DS.space12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("Honest disclosures")
                    .font(.system(size: 17, weight: .semibold))
            }
            Text("What's true today, what's not yet:")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            // ━━━━━ Shipped in v1.5 ━━━━━
            disclosureRow(.shipped, "End-to-end encryption (Signal X3DH + Double Ratchet)",
                          "On every 1:1 conversation, on internet AND mesh.")
            disclosureRow(.shipped, "Safety Numbers (out-of-band identity verification)",
                          "60-digit fingerprint comparable in person, by voice, or QR.")
            disclosureRow(.shipped, "Hardware-bound keys (Secure Enclave + Keychain)",
                          "Identity, signing, ratchet keys never leave your device.")
            // ━━━━━ Shipped in v1.6 (May 2026) ━━━━━
            disclosureRow(.shipped, "OPAQUE PAKE (RFC 9497, first iteration)",
                          "Zero-knowledge password authentication — the server never receives your password, not even hashed. Full standards-compliant OPAQUE with a server-side OPRF round lands in v1.7.")
            disclosureRow(.shipped, "Sealed Sender",
                          "X25519 ephemeral + AES-GCM seals the inner envelope to the recipient's identity key — the relay layer no longer learns who sent a given envelope.")
            disclosureRow(.shipped, "Encrypted key backup & recovery",
                          "Opt-in: PBKDF2-SHA256 600 000 iterations + AES-256-GCM seals your identity + ratchet state with a passphrase the server never sees. Wrong passphrase fails AEAD authentication — there is no partial restore.")
            disclosureRow(.shipped, "180-day identity-key rotation with cross-signed transition certs",
                          "Both old and new keys sign each transition. Peers who only see the new key can prove provenance back to the old one and vice versa. Local chain log is forward and backward verifiable.")
            disclosureRow(.shipped, "Defence-in-depth Double-AEAD construction",
                          "Inner ChaCha20-Poly1305 wrapped in outer AES-256-GCM with a key-committing HMAC tag. Both ciphers must fall before plaintext leaks; commitment defeats the Salamander class of multi-key attacks.")
            disclosureRow(.shipped, "Memory hygiene primitives (mlock + triple-zeroise)",
                          "Sensitive byte buffers are page-locked so the OS can't write them to swap, and triple-zeroised on deinit (0x00 / 0xFF / 0x00 — alternation defeats compiler-eliding writes).")
            disclosureRow(.shipped, "Mesh-to-Internet Gateway (Helper Mode, opt-in)",
                          "An online RAVEN can opt in to relay opaque ciphertext envelopes for nearby offline neighbours over BLE. Cryptographically blind: only recipient hint + opaque blob cross the gateway. Token-bucket rate limit, replay-nonce dedup, auto-deactivates on heat / low battery / background.")
            disclosureRow(.shipped, "Reproducible builds (stage 1)",
                          "Every release ships a manifest of source SHA-256 + Mach-O SHA-256 + bundle SHA-256. Anyone can re-run our open verify-binary.sh and check the hashes match. Bit-for-bit reproducible IPAs target v1.7.")
            // ━━━━━ Next ━━━━━
            disclosureRow(.next, "Post-quantum identity (ML-DSA-65 + ML-KEM-768)",
                          "Hybrid signing + key agreement layered on top of the current Ed25519 / X25519 stack. Rolls in once Apple ships ML-KEM in CryptoKit (we won't take a third-party C-lib dependency for crypto).")
            disclosureRow(.next, "3-of-5 social key recovery",
                          "Shamir + Feldman VSS so a passphrase-loss user can recover with three trusted contacts instead of being permanently locked out — no copy of the key on our servers.")
            disclosureRow(.next, "Onion-style relay routing for mesh",
                          "Today the gateway sees the recipient hint. Sphinx-style layered encryption hides who-asked-whom-to-relay-what from the gateway and from any single mesh hop.")
            // ━━━━━ Committed ━━━━━
            disclosureRow(.committed, "Open source (cryptographic core)",
                          "X3DH / Double Ratchet / MeshEnvelope / BLE transport / desktop-login bridge — released under an audit-friendly license alongside the third-party audit. Committed 2026 H2.")
            disclosureRow(.committed, "Independent third-party audit",
                          "Cure53 / Trail of Bits / NCC Group-tier engagement, full report in the open. Committed 2026 H2. \"Designed to be reviewed\" is not the same as \"audited\" — we know.")
            disclosureRow(.committed, "MLS for groups (RFC 9420)",
                          "Today: per-group AES-256 keys with rotation on member-leave. MLS lands in v1.8 / 2026 H2 for proper continuous group key agreement at scale.")
            disclosureRow(.committed, "Mesh cover traffic + padding (Loopix-style)",
                          "BLE radio-traffic analysis can leak who-talks-to-whom today. Constant-rate cover traffic + decoy envelopes ship in 2026 H2.")
            disclosureRow(.committed, "Censorship-resistant transport",
                          "Mesh path is unaffected by network filters today. For online: domain fronting + obfs4 / Snowflake-style transports committed 2026 H2.")

            Text("If we miss a date, we will say so on this page. Trust earned by inspection is the only kind worth having.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, DS.space8)
        }
        .padding(DS.space16)
        .ravenCard()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.35).delay(0.05), value: appeared)
    }

    private enum DisclosureStatus {
        case shipped, next, committed, local
        var label: String {
            switch self {
            case .shipped:   return "✓ Shipped · v1.6"
            case .next:      return "→ Next · v1.7"
            case .committed: return "⚑ Committed · 2026 H2"
            case .local:     return "△ Local-only"
            }
        }
        var color: Color {
            switch self {
            case .shipped:   return .green
            case .next:      return .cyan
            case .committed: return .purple
            case .local:     return .orange
            }
        }
    }

    @ViewBuilder
    private func disclosureRow(_ status: DisclosureStatus, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(status.label)
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(status.color.opacity(0.10))
                            .overlay(Capsule().strokeBorder(status.color.opacity(0.30), lineWidth: 0.5))
                    )
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
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
