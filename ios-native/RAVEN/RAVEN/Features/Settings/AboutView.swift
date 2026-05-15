import SwiftUI
import StoreKit

// MARK: - About View
struct AboutView: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App Icon
                VStack(spacing: 12) {
                    Image("RavenLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 60)
                        .frame(width: 100, height: 100)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                        )
                        .accessibilityLabel("RAVEN app icon")
                    
                    Text("app_name".localized)
                        .font(.system(size: 24, weight: .bold))
                    
                    Text("\("version".localized) \(appVersion) (\(buildNumber))")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)
                
                // Description
                Text("about.description".localized)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                
                // Links
                VStack(spacing: 12) {
                    SettingsSection(title: "links".localized) {
                        NavigationLink {
                            PrivacyPolicyView()
                        } label: {
                            SettingsNavigationRow(
                                title: "privacy_policy".localized,
                                icon: "doc.text.fill",
                                iconColor: .blue
                            )
                        }
                        .buttonStyle(.plain)
                        
                        NavigationLink {
                            TermsOfServiceView()
                        } label: {
                            SettingsNavigationRow(
                                title: "terms_of_service".localized,
                                icon: "doc.plaintext.fill",
                                iconColor: .purple
                            )
                        }
                        .buttonStyle(.plain)
                        
                        NavigationLink {
                            FAQView()
                        } label: {
                            SettingsNavigationRow(
                                title: "faq".localized,
                                icon: "questionmark.circle.fill",
                                iconColor: .orange
                            )
                        }
                        .buttonStyle(.plain)
                        
                        NavigationLink {
                            AcknowledgementsView()
                        } label: {
                            SettingsNavigationRow(
                                title: "acknowledgements".localized,
                                icon: "heart.fill",
                                iconColor: .pink
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                
                // Rate Button
                Button {
                    Haptics.light()
                    openAppStore()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill")
                        Text("rate_app".localized)
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                }
                .padding(.top, 16)
                
                // Copyright
                Text("copyright".localized)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("about".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func openAppStore() {
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
    }
}


// NOTE: PrivacyPolicyView is in its own file: PrivacyPolicyView.swift

// MARK: - Terms of Service View
struct TermsOfServiceView: View {
    @State private var expandedSection: Int?
    
    // TOS uses numbered keys: tos.s1.title, tos.s1.content, etc.
    private let sectionCount = 19
    
    /// Build sections with localized content
    private var sections: [(title: String, content: String)] {
        (1...sectionCount).map { i in
            ("tos.s\(i).title".localized, "tos.s\(i).content".localized)
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("terms_of_service.title".localized)
                        .font(.system(size: 28, weight: .bold))
                    Text("terms_of_service.last_updated".localized)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                
                // Sections
                ForEach(Array(sections.enumerated()), id: \.0) { index, section in
                    TOSSectionView(
                        title: section.title,
                        content: section.content,
                        isExpanded: expandedSection == index,
                        onTap: {
                            Haptics.selection()
                            withAnimation(.spring(response: 0.3)) {
                                expandedSection = expandedSection == index ? nil : index
                            }
                        }
                    )
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("terms_of_service.title".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - TOS Section View
struct TOSSectionView: View {
    let title: String
    let content: String
    let isExpanded: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(14)
                
                if isExpanded {
                    Text(content)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// NOTE: FAQView is in its own file: FAQView.swift

// MARK: - Acknowledgements View
struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("acknowledgements.title".localized)
                    .font(.system(size: 24, weight: .bold))
                
                Text("acknowledgements.description".localized)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("• SwiftUI")
                    Text("• Combine")
                    Text("• CoreData")
                    Text("• MultipeerConnectivity")
                }
                .font(.system(size: 15))
                .padding(.top, 8)
            }
            .padding(20)
        }
        .background(Color(.systemBackground))
        .navigationTitle("acknowledgements".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - Preview
#Preview {
    NavigationStack {
        AboutView()
    }
}
