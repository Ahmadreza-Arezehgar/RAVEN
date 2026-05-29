//
//  DeviceIdentity+E2EE.swift
//  RAVEN
//
//  Bridge between DeviceIdentityService (Ed25519 + X25519 device keys)
//  and the E2EE module. Exposes the X25519 *private* key bytes through
//  a narrowly-scoped accessor so X3DH can sign the initial handshake
//  with our identity-agreement key.
//
//  We deliberately keep this small and isolated — adding a property
//  directly to DeviceIdentityService would force a re-review of that
//  long-lived service. Restricting the accessor to this file keeps
//  the new attack surface obvious in code review.
//

import Foundation
import Security

extension DeviceIdentityService {

    /// Raw X25519 agreement-key *private* bytes from the Keychain.
    /// Loaded fresh on every call (no in-memory caching at this layer
    /// — the underlying `cachedAgreementPrivateKey` already caches the
    /// reconstructed CryptoKit key, which is what hot paths use).
    ///
    /// ⚠️ Treat the returned bytes as sensitive — never log, never
    /// transmit, never persist outside the Keychain.
    var agreementPrivateKeyData: Data? {
        return loadAgreementPrivateRaw()
    }

    private func loadAgreementPrivateRaw() -> Data? {
        // Match the format DeviceIdentityService.storeKey uses — tag
        // bytes, no kSecAttrKeyType filter (it stores raw key material
        // as a generic key blob).
        let tag = "app.raven.device.agreement.privatekey"
        let query: [String: Any] = [
            kSecClass as String:              kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? (result as? Data) : nil
    }
}
