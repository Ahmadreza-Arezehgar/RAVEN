import SwiftUI
import Foundation

// MARK: - String Localization Extension
extension String {
    /// Returns the localized version of the string using the current app language
    /// Usage: "settings.title".localized
    var localized: String {
        AppLanguageManager.shared.localizedString(key: self)
    }
    
    /// Returns the localized version with format arguments
    /// Usage: "welcome.message".localized(with: userName)
    func localized(with arguments: CVarArg...) -> String {
        String(format: self.localized, arguments: arguments)
    }
}

// MARK: - Supported Language
struct SupportedLanguage: Identifiable {
    let id: String  // Language code
    let code: String
    let nativeName: String  // Name in native script
    let englishName: String // Name in English
    let flag: String
    let isRTL: Bool
    
    init(code: String, nativeName: String, englishName: String, flag: String, isRTL: Bool = false) {
        self.id = code
        self.code = code
        self.nativeName = nativeName
        self.englishName = englishName
        self.flag = flag
        self.isRTL = isRTL
    }
}

// MARK: - App Language Manager
@Observable
final class AppLanguageManager {
    static let shared = AppLanguageManager()
    
    /// Cached bundle for current language
    private var cachedBundle: Bundle?
    private var cachedLanguageCode: String?
    
    /// Current language code
    var currentLanguage: String {
        get {
            UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "appLanguage")
            // Clear cache to force reload
            cachedBundle = nil
            cachedLanguageCode = nil
            // Force UI refresh
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }
    
    /// Current locale for date/number formatting
    var locale: Locale {
        Locale(identifier: currentLanguage)
    }
    
    /// Layout direction based on current language
    var layoutDirection: LayoutDirection {
        isRTL ? .rightToLeft : .leftToRight
    }
    
    /// Whether current language is RTL
    var isRTL: Bool {
        let rtlCodes = ["fa", "he", "ar"]
        return rtlCodes.contains(currentLanguage)
    }
    
    /// Get the current language details
    var currentLanguageDetails: SupportedLanguage? {
        Self.supportedLanguages.first { $0.code == currentLanguage }
    }
    
    /// Supported languages with all metadata
    static let supportedLanguages: [SupportedLanguage] = [
        SupportedLanguage(code: "en", nativeName: "English", englishName: "English", flag: "🇺🇸"),
        SupportedLanguage(code: "zh-Hans", nativeName: "中文（简体）", englishName: "Chinese (Simplified)", flag: "🇨🇳"),
        SupportedLanguage(code: "de", nativeName: "Deutsch", englishName: "German", flag: "🇩🇪"),
        SupportedLanguage(code: "es", nativeName: "Español", englishName: "Spanish", flag: "🇪🇸"),
        SupportedLanguage(code: "fa", nativeName: "فارسی", englishName: "Persian", flag: "🇮🇷", isRTL: true),
        SupportedLanguage(code: "ja", nativeName: "日本語", englishName: "Japanese", flag: "🇯🇵"),
        SupportedLanguage(code: "he", nativeName: "עברית", englishName: "Hebrew", flag: "🇮🇱", isRTL: true),
        SupportedLanguage(code: "ru", nativeName: "Русский", englishName: "Russian", flag: "🇷🇺")
    ]
    
    /// Get the bundle for the current language
    private func bundle(for languageCode: String) -> Bundle {
        // Return cached bundle if available
        if let cached = cachedBundle, cachedLanguageCode == languageCode {
            return cached
        }
        
        // Try to find the language bundle
        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            cachedBundle = bundle
            cachedLanguageCode = languageCode
            return bundle
        }
        
        // Fallback to main bundle (English)
        return Bundle.main
    }
    
    /// Hardcoded English fallbacks for settings UI (when bundle fails to load)
    private static let englishFallbacks: [String: String] = [
        "edit_profile": "Edit Profile",
        "friend_requests": "Friend Requests",
        "notifications": "Notifications",
        "privacy": "Privacy",
        "security": "Security",
        "storage": "Storage",
        "language": "Language",
        "design": "Design",
        "about": "About RAVEN",
        "privacy_policy": "Privacy Policy",
        "faq": "FAQ",
        "contact_support": "Contact Support",
        "sign_out": "Sign Out",
        "close_account": "Close Account",
        "cancel": "Cancel",
        "save": "Save",
        "done": "Done",
        "section.social": "Social",
        "section.general": "General",
        "section.about": "About",
        "section.account": "Account",
        "sign_out_confirm": "Are you sure you want to sign out?",
        "close_account_confirm": "This will permanently delete your account and all data. This action cannot be undone.",
        // Tab bar quick actions
        "scan_qr_code": "Scan QR Code",
        "my_qr_code": "My QR Code",
        "search_users": "Search Users",
        "refresh": "Refresh",
        "local": "Local",
        "friends": "Friends",
        "mark_all_read": "Mark All Read",
        "new_message": "New Message",
        "new_group": "New Group",
        "settings": "Settings",
        "add_account": "Add Account",
        // Tabs
        "home": "Home",
        "messages": "Messages",
        "discover": "Discover",
        "account": "Account",
        "verification": "Verification",
        "moderation_inbox": "Moderation Inbox",
        "find_friends": "Find Friends",
        "section.appearance": "Appearance",
        "mesh_settings": "Mesh Settings",
        "device_identity": "Device Identity"
    ]
    
    /// Get localized string for a key
    func localizedString(key: String) -> String {
        // Get the bundle for current language
        let langCode = currentLanguage
        
        // First try to find language-specific bundle
        if let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            let result = NSLocalizedString(key, tableName: "Localizable", bundle: langBundle, value: "", comment: "")
            if !result.isEmpty && result != key {
                return result
            }
        }
        
        // Fallback to English bundle
        if langCode != "en" {
            if let enPath = Bundle.main.path(forResource: "en", ofType: "lproj"),
               let enBundle = Bundle(path: enPath) {
                let result = NSLocalizedString(key, tableName: "Localizable", bundle: enBundle, value: "", comment: "")
                if !result.isEmpty && result != key {
                    return result
                }
            }
        }
        
        // Try main bundle
        let mainResult = NSLocalizedString(key, tableName: "Localizable", bundle: Bundle.main, value: "", comment: "")
        if !mainResult.isEmpty && mainResult != key {
            return mainResult
        }
        
        // Last resort: hardcoded English fallbacks
        return Self.englishFallbacks[key] ?? key
    }
    
    private init() {}
}

// MARK: - Notification Name
extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
}

// MARK: - Language Settings View
struct LanguageSettingsView: View {
    @State private var languageManager = AppLanguageManager.shared
    @State private var selectedLanguage: String = AppLanguageManager.shared.currentLanguage
    @State private var searchText: String = ""
    
    private var filteredLanguages: [SupportedLanguage] {
        if searchText.isEmpty {
            return AppLanguageManager.supportedLanguages
        }
        return AppLanguageManager.supportedLanguages.filter { lang in
            lang.nativeName.localizedCaseInsensitiveContains(searchText) ||
            lang.englishName.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Search bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    
                    TextField("search".localized, text: $searchText)
                        .font(.system(size: 16))
                        .textInputAutocapitalization(.never)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                
                // Language list
                VStack(spacing: 0) {
                    ForEach(filteredLanguages) { lang in
                        LanguageRow(
                            language: lang,
                            isSelected: selectedLanguage == lang.code,
                            onSelect: {
                                Haptics.selection()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedLanguage = lang.code
                                    languageManager.currentLanguage = lang.code
                                }
                            }
                        )
                        
                        if lang.code != filteredLanguages.last?.code {
                            Divider()
                                .padding(.leading, 64)
                        }
                    }
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                
                // Info text
                VStack(spacing: 8) {
                    Text("language.info".localized)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    if languageManager.isRTL {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 12))
                            Text("language.rtl_notice".localized)
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("language".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Language Row
struct LanguageRow: View {
    let language: SupportedLanguage
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 14) {
                // Flag
                Text(language.flag)
                    .font(.system(size: 28))
                
                // Language names
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.nativeName)
                        .font(.system(size: 16, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                    
                    if language.nativeName != language.englishName {
                        Text(language.englishName)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                // RTL indicator
                if language.isRTL {
                    Text("RTL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                }
                
                // Checkmark
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        LanguageSettingsView()
    }
}
