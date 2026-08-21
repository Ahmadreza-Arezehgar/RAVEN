import Security
import XCTest

final class FullBraidNamespaceProvisioningTests: XCTestCase {
    private let dedicatedGroup = "group.app.raven.fullbraid"

    func testMainIOSHostOwnsDedicatedContainerAndKeychainGroup() throws {
#if targetEnvironment(macCatalyst)
        throw XCTSkip("The dedicated Full Braid namespace is intentionally unavailable to Catalyst.")
#else
        let fileManager = FileManager.default
        let container = try XCTUnwrap(
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: dedicatedGroup),
            "The signed main iOS host must resolve the dedicated Full Braid App Group."
        )

        let fileCanary = container.appendingPathComponent("namespace-canary-\(UUID().uuidString)")
        let filePayload = Data("raven-full-braid-container-canary".utf8)
        defer { try? fileManager.removeItem(at: fileCanary) }
        try filePayload.write(to: fileCanary, options: [.withoutOverwriting])
        XCTAssertEqual(try Data(contentsOf: fileCanary), filePayload)
        try fileManager.removeItem(at: fileCanary)
        XCTAssertFalse(fileManager.fileExists(atPath: fileCanary.path))

        let service = "app.raven.fullbraid.namespace-canary"
        let account = UUID().uuidString
        let keychainPayload = Data("raven-full-braid-keychain-canary".utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: dedicatedGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        defer { SecItemDelete(identity as CFDictionary) }

        var add = identity
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = keychainPayload
        XCTAssertEqual(
            SecItemAdd(add as CFDictionary, nil),
            errSecSuccess,
            "The signed host must be provisioned for the exact, unprefixed Full Braid access group."
        )

        var read = identity
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        read[kSecReturnAttributes as String] = kCFBooleanTrue
        read[kSecReturnData as String] = kCFBooleanTrue
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &result), errSecSuccess)
        let record = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(record[kSecAttrAccessGroup as String] as? String, dedicatedGroup)
        XCTAssertEqual(record[kSecValueData as String] as? Data, keychainPayload)

        XCTAssertEqual(SecItemDelete(identity as CFDictionary), errSecSuccess)
        var missing: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &missing), errSecItemNotFound)
#endif
    }

    func testCatalystKeychainDeniesDedicatedAccessGroup() throws {
#if targetEnvironment(macCatalyst)
        // Threat model: unsandboxed Catalyst App Group filesystem is untrusted
        // storage, not a confidentiality boundary. containerURL is informational
        // only and must not drive PASS/FAIL.
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: dedicatedGroup
        )
        if let container {
            print("INFO: Catalyst containerURL informational/untrusted=\(container.path)")
        } else {
            print("INFO: Catalyst containerURL informational=nil")
        }

        let canaryAccount = UUID().uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.raven.fullbraid.catalyst-negative-canary",
            kSecAttrAccount as String: canaryAccount,
            kSecAttrAccessGroup as String: dedicatedGroup,
            kSecValueData as String: Data("negative-canary".utf8),
        ]
        defer { SecItemDelete(query as CFDictionary) }
        XCTAssertEqual(
            SecItemAdd(query as CFDictionary, nil),
            errSecMissingEntitlement,
            "Catalyst must lack entitlement for exact Keychain access group \(dedicatedGroup)."
        )
#else
        throw XCTSkip("Catalyst-only Keychain deny probe.")
#endif
    }
}
