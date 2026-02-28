import Foundation
import Observation
import Contacts
import CryptoKit

// MARK: - Contacts Service
/// Service for contact syncing and friend discovery on Raven
@Observable
class ContactsService {
    static let shared = ContactsService()
    
    // Contact permission state
    enum PermissionStatus {
        case notDetermined
        case authorized
        case denied
        case restricted
    }
    
    var permissionStatus: PermissionStatus = .notDetermined
    var isLoading = false
    var contacts: [LocalContact] = []
    var matches: [MatchedContact] = []
    var hasSyncedThisSession = false
    var error: String?
    
    // HMAC salt — dynamically fetched from server, cached in Keychain.
    // Fallback to hardcoded value if server endpoint is unavailable.
    private let fallbackSalt = "raven_contact_sync_v1"
    private var phoneSalt: String {
        _cachedSalt ?? fallbackSalt
    }
    private var _cachedSalt: String?
    
    private init() {
        updatePermissionStatus()
    }
    
    // MARK: - Permission Handling
    
    func updatePermissionStatus() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .notDetermined:
            permissionStatus = .notDetermined
        case .authorized, .limited:
            permissionStatus = .authorized
        case .denied:
            permissionStatus = .denied
        case .restricted:
            permissionStatus = .restricted
        @unknown default:
            permissionStatus = .notDetermined
        }
    }
    
    func requestPermission() async -> Bool {
        let store = CNContactStore()
        do {
            let granted = try await store.requestAccess(for: .contacts)
            await MainActor.run {
                permissionStatus = granted ? .authorized : .denied
            }
            return granted
        } catch {
            await MainActor.run {
                permissionStatus = .denied
                self.error = error.localizedDescription
            }
            return false
        }
    }
    
    // MARK: - Load Contacts
    
    func loadContacts() async {
        guard permissionStatus == .authorized else { return }
        
        await MainActor.run { isLoading = true }
        
        // 💡 Move heavy synchronous contact enumeration to a detached task
        // to avoid blocking the cooperative thread pool (which would freeze UI)
        let fetchResult = await Task.detached(priority: .userInitiated) { [weak self] () -> Result<[LocalContact], Error> in
            let store = CNContactStore()
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactImageDataAvailableKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor
            ]
            
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            request.sortOrder = .givenName
            
            var results: [LocalContact] = []
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    let phone = contact.phoneNumbers.first?.value.stringValue
                    
                    // Normalize phone independently (no self reference needed)
                    let cleaned = phone?.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    var normalizedPhone: String? = nil
                    if let p = phone, let c = cleaned, !c.isEmpty {
                        normalizedPhone = p.hasPrefix("+") ? "+" + c : (c.count >= 10 ? "+" + c : nil)
                    }
                    
                    let email = contact.emailAddresses.first?.value as String?
                    if normalizedPhone == nil && email == nil { return }
                    
                    results.append(LocalContact(
                        id: contact.identifier,
                        firstName: contact.givenName,
                        lastName: contact.familyName,
                        phone: phone,
                        phoneNormalized: normalizedPhone,
                        email: email,
                        thumbnailData: contact.thumbnailImageData
                    ))
                }
                return .success(results)
            } catch {
                return .failure(error)
            }
        }.value
        
        await MainActor.run {
            switch fetchResult {
            case .success(let loadedContacts):
                self.contacts = loadedContacts
            case .failure(let error):
                self.error = "Failed to load contacts: \(error.localizedDescription)"
            }
            self.isLoading = false
        }
    }
    
    // MARK: - Sync with Server
    
    func syncWithServer() async {
        // ✅ Offline fast-path: skip salt fetch + hashing entirely, load from cache
        if !NetworkMonitor.shared.isOnline {
            await loadCachedMatchesDirect()
            return
        }
        
        // Fix 10: Fetch salt from server before hashing
        await fetchSaltFromServer()
        
        if contacts.isEmpty {
            await loadContacts()
        }
        guard !contacts.isEmpty else { return }
        
        await MainActor.run { isLoading = true }
        
        let currentSalt = phoneSalt
        let contactsToHash = contacts
        
        // 🚀 Move HMAC hashing to background thread (prevents UI freeze with thousands of contacts)
        let (computedHashes, computedMap) = await Task.detached(priority: .userInitiated) {
            var hashes: [String] = []
            var map: [String: LocalContact] = [:]
            
            for contact in contactsToHash {
                guard let phone = contact.phoneNormalized else { continue }
                
                let key = SymmetricKey(data: Data(currentSalt.utf8))
                let signature = HMAC<SHA256>.authenticationCode(for: Data(phone.utf8), using: key)
                let hash = signature.map { String(format: "%02x", $0) }.joined()
                
                hashes.append(hash)
                map[hash] = contact
            }
            return (hashes, map)
        }.value
        
        let hashes: [String] = computedHashes
        let hashToContact: [String: LocalContact] = computedMap

        // Call server
        do {
            let response: ContactSyncResponse = try await NetworkService.shared.post(
                path: "/api/contacts/sync",
                body: ContactSyncRequest(hashes: hashes)
            )
            
            if let data = try? JSONEncoder().encode(response.matches) {
                UserDefaults.standard.set(data, forKey: "raven_contact_matches_cache")
            }
            
            await MainActor.run {
                self.matches = response.matches.map { match in
                    let localContact = hashToContact[match.hash]
                    return MatchedContact(
                        userId: match.userId,
                        username: match.username,
                        displayName: match.displayName,
                        avatarUrl: match.avatarUrl,
                        localContact: localContact
                    )
                }
                isLoading = false
            }
        } catch {
            await loadCachedMatches(hashToContact: hashToContact, error: error)
        }
    }
    
    @MainActor
    private func loadCachedMatches(hashToContact: [String: LocalContact], error: Error? = nil) {
        if let data = UserDefaults.standard.data(forKey: "raven_contact_matches_cache"),
           let cachedMatches = try? JSONDecoder().decode([ContactMatch].self, from: data) {
            self.matches = cachedMatches.map { match in
                let localContact = hashToContact[match.hash]
                return MatchedContact(
                    userId: match.userId,
                    username: match.username,
                    displayName: match.displayName,
                    avatarUrl: match.avatarUrl,
                    localContact: localContact
                )
            }
            if error == nil { self.error = nil }
        } else if let error = error {
            self.error = "Sync failed: \(error.localizedDescription)"
        }
        self.isLoading = false
    }
    
    /// Offline fast-path: load cached matches WITHOUT hash mapping (skips salt + hashing entirely)
    @MainActor
    private func loadCachedMatchesDirect() {
        isLoading = true
        if let data = UserDefaults.standard.data(forKey: "raven_contact_matches_cache"),
           let cachedMatches = try? JSONDecoder().decode([ContactMatch].self, from: data) {
            self.matches = cachedMatches.map { match in
                MatchedContact(
                    userId: match.userId,
                    username: match.username,
                    displayName: match.displayName,
                    avatarUrl: match.avatarUrl,
                    localContact: nil  // No local contact mapping available offline without salt
                )
            }
            self.error = nil
            #if DEBUG
            print("  [ContactsService] Loaded \(cachedMatches.count) matches from offline cache")
            #endif
        } else {
            self.error = "You're offline. Connect to the internet to find contacts on Raven."
        }
        self.isLoading = false
    }
    
    // MARK: - Phone Normalization (E.164)
    
    func normalizePhone(_ phone: String?) -> String? {
        guard let phone = phone else { return nil }
        
        // Remove all non-digit characters except leading +
        let cleaned = phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        
        guard !cleaned.isEmpty else { return nil }
        
        // If original had +, keep it
        if phone.hasPrefix("+") {
            return "+" + cleaned
        }
        
        // Handle international "00" prefix (e.g. 0044... → +44...)
        if cleaned.hasPrefix("00") {
            return "+" + String(cleaned.dropFirst(2))
        }
        
        // Otherwise assume local number (would need country code logic)
        // For now, return with + prefix if 10+ digits
        if cleaned.count >= 10 {
            return "+" + cleaned
        }
        
        return nil
    }
    
    // MARK: - Dynamic Salt
    
    /// Fetch HMAC salt from server and cache in Keychain.
    /// Falls back to hardcoded salt if endpoint is unavailable.
    private func fetchSaltFromServer() async {
        // Check Keychain cache first
        if let cached = await KeychainService.shared.getContactSyncSalt() {
            _cachedSalt = cached
            return
        }
        
        do {
            let response: SaltResponse = try await NetworkService.shared.get(
                path: "/api/contacts/salt"
            )
            _cachedSalt = response.salt
            // Cache in Keychain for future use
            await KeychainService.shared.saveContactSyncSalt(response.salt)
            #if DEBUG
            print("[Contacts] ✅ Salt fetched from server")
            #endif
        } catch {
            // Server endpoint may not exist yet — use fallback
            #if DEBUG
            print("[Contacts] ⚠️ Salt endpoint unavailable, using fallback: \(error.localizedDescription)")
            #endif
        }
    }
    
    // MARK: - HMAC-SHA256 Hash
    
    func computeHash(_ phoneE164: String) -> String {
        let salt = phoneSalt
        let key = SymmetricKey(data: Data(salt.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(phoneE164.utf8), using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Invite Tracking
    
    private let invitedKey = "contacts_invited"
    private let inviteCooldown: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    
    func isInvited(_ contact: LocalContact) -> Bool {
        guard let phone = contact.phoneNormalized else { return false }
        let invited = UserDefaults.standard.dictionary(forKey: invitedKey) as? [String: TimeInterval] ?? [:]
        guard let inviteEpoch = invited[phone] else { return false }
        return Date().timeIntervalSince1970 - inviteEpoch < inviteCooldown
    }
    
    func markInvited(_ contact: LocalContact) {
        guard let phone = contact.phoneNormalized else { return }
        var invited = UserDefaults.standard.dictionary(forKey: invitedKey) as? [String: TimeInterval] ?? [:]
        invited[phone] = Date().timeIntervalSince1970
        UserDefaults.standard.set(invited, forKey: invitedKey)
    }
    
    func loadInvited() -> [String: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: invitedKey) as? [String: TimeInterval] ?? [:]
        return stored.mapValues { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - Models

struct LocalContact: Identifiable {
    let id: String
    let firstName: String
    let lastName: String
    let phone: String?
    let phoneNormalized: String?
    let email: String?
    let thumbnailData: Data?
    
    var displayName: String {
        let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? (phone ?? email ?? "Unknown") : name
    }
    
    var initials: String {
        let first = firstName.first.map(String.init) ?? ""
        let last = lastName.first.map(String.init) ?? ""
        return (first + last).isEmpty ? "?" : (first + last)
    }
}

struct MatchedContact: Identifiable {
    let userId: String
    let username: String
    let displayName: String
    let avatarUrl: String?
    let localContact: LocalContact?
    
    var id: String { userId }
}

// MARK: - API Models

struct ContactSyncRequest: Encodable {
    let hashes: [String]
}

struct ContactSyncResponse: Decodable {
    let matches: [ContactMatch]
}

struct ContactMatch: Codable {
    let userId: String
    let username: String
    let displayName: String
    let avatarUrl: String?
    let hash: String
}

struct SaltResponse: Decodable {
    let salt: String
}
