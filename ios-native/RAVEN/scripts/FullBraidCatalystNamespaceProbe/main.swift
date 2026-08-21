import Foundation
import Security

/// Hermetic Mac Catalyst Keychain-deny probe for `group.app.raven.fullbraid`.
/// No RAVEN / RavenLibp2p / network / package dependencies.
///
/// Frozen security invariant (Task 0A.0C):
/// - Process is not entitled to the dedicated App Group / Keychain access group.
/// - `SecItemAdd` with exact `kSecAttrAccessGroup = group.app.raven.fullbraid`
///   must return `errSecMissingEntitlement`.
///
/// Non-security / informational only:
/// - `containerURL(forSecurityApplicationGroupIdentifier:)` may return nil or a
///   synthetic Group Containers URL on unsandboxed macabi. That is NOT a
///   confidentiality boundary and MUST NOT drive PASS/FAIL.
@main
enum FullBraidCatalystNamespaceProbe {
    static let dedicatedGroup = "group.app.raven.fullbraid"

    static func main() {
        let canary = "fb-ns-canary-\(ProcessInfo.processInfo.globallyUniqueString)"
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.raven.fullbraid.hermetic-catalyst-negative",
            kSecAttrAccount as String: canary,
            kSecAttrAccessGroup as String: dedicatedGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        defer {
            SecItemDelete(identity as CFDictionary)
        }

        // Informational only — never PASS/FAIL on filesystem App Group behavior.
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: dedicatedGroup
        )
        if let container {
            fputs(
                "INFO: containerURL synthetic/untrusted=\(container.path) (not a security verdict; unsandboxed App Group FS is untrusted storage)\n",
                stderr
            )
        } else {
            fputs(
                "INFO: containerURL=nil (informational only; not a security verdict)\n",
                stderr
            )
        }

        var add = identity
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = Data(canary.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecMissingEntitlement else {
            fputs(
                "FAIL: expected errSecMissingEntitlement (\(errSecMissingEntitlement)) for access group \(dedicatedGroup), got \(status)\n",
                stderr
            )
            exit(1)
        }

        _ = SecItemDelete(identity as CFDictionary)

        fputs(
            "PASS: Catalyst Keychain deny for exact group \(dedicatedGroup) (errSecMissingEntitlement)\n",
            stdout
        )
        exit(0)
    }
}
