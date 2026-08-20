//
//  ATSAMLabTrustStore.swift
//  RAVEN — DEBUG lab trust material for Test A (cert + prekey OOB paste).
//
//  Release: unused (labTestAEnabled == false). Never exports private keys.
//

import CryptoKit
import Foundation
import Security

private let labTrustPeerCertAccountPrefix = "lab.peer.cert."
private let labBlockDevicePrefix = "lab.block.v1.dev."
private let labBlockIdentityPrefix = "lab.block.v1.id."
private let labBlockNoisePrefix = "lab.block.v1.noise."
private let labRevokedDevicePrefix = "lab.revoked.v1.dev."
private let labRevokedIdentityPrefix = "lab.revoked.v1.id."

@MainActor
enum ATSAMLabTrustStore {

    private static let deviceID = "ios-lab-primary"
    private static let certAccount = "lab.local.device_cert"
    private static let prekeyPrivAccount = "lab.local.prekey_hybrid_secret"
    private static let prekeyPubAccount = "lab.local.prekey_bundle_json"
    private static let peerCertAccountPrefix = labTrustPeerCertAccountPrefix
    private static let peerPrekeyAccountPrefix = "lab.peer.prekey."
    private static let service = "app.raven.ios.atsam.lab.trust"

    struct LabCertJSON: Codable {
        var device_ed_pub: String
        var device_x_pub: String
        var device_id: String
        var not_before_ms: UInt64
        var not_after_ms: UInt64
        var capabilities: UInt64
        var signature: String
        var user_ed_pub: String
    }

    struct LabPrekeyJSON: Codable {
        var version: UInt8
        var identity_ed25519_pub_hex: String
        var device_id: String
        var x25519_pub_hex: String
        var mlkem768_ek_hex: String
        var signed_prekey_id: UInt32
        var one_time_prekey_id: UInt32
        var one_time_x25519_pub_hex: String?
        var created_at_ms: UInt64
        var expires_at_ms: UInt64
        var signature_hex: String
    }

    enum TrustError: Error, LocalizedError {
        case identityMissing
        case mlkemUnavailable
        case persistFailed
        case peerCertMissing
        case badJSON
        case badHex
        case signFailed

        var errorDescription: String? {
            switch self {
            case .identityMissing: return "Device identity not loaded"
            case .mlkemUnavailable: return "ML-KEM unavailable (need iOS 26+)"
            case .persistFailed: return "Keychain persist failed"
            case .peerCertMissing: return "Peer device cert missing — paste Mac lab cert JSON"
            case .badJSON: return "Invalid JSON"
            case .badHex: return "Invalid hex"
            case .signFailed: return "Signing failed"
            }
        }
    }

    // MARK: - Ensure local material

    @discardableResult
    static func ensureLocalMaterial() throws -> (
        cert: ATSAMPairInitV1.SignedDeviceCertificate,
        prekey: ATSAMPairInitV1.SignedPrekeyBundle,
        xSecret: Data,
        mlkemSeed: Data
    ) {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else {
            throw TrustError.persistFailed
        }
        guard let idPub = DeviceIdentityService.shared.publicKeyData,
              DeviceIdentityService.shared.deviceSigningSeed != nil else {
            throw TrustError.identityMissing
        }
        guard ATSAMMLKem.isAvailable else { throw TrustError.mlkemUnavailable }

        let cert = try loadOrIssueLocalCert(identityPub: idPub)
        let (prekey, xSecret, mlkemSeed) = try loadOrPublishLocalPrekey(identityPub: idPub)
        return (cert, prekey, xSecret, mlkemSeed)
    }

    /// §6.3.1 — Terminal `contacts.json` `pub_hex` must be this device Ed25519 (32-byte hex).
    static func localDeviceEdPubHex() throws -> String {
        let (cert, _, _, _) = try ensureLocalMaterial()
        return try parseCertFields(cert).deviceEd.ravenHex
    }

    static func localUserEdPubHex() throws -> String {
        let cert = try localCertificate()
        return cert.identityEd25519PublicKey.ravenHex
    }

    /// Peer device Ed25519 from imported lab cert (Noise `expected_pub` source).
    static func peerDeviceEdPub(forIdentityPub identityPub: Data) throws -> Data {
        let dto = try peerCertDTO(forIdentityPub: identityPub)
        return try LabHex.data(dto.device_ed_pub)
    }

    static func peerDeviceEdPubHex(forIdentityPub identityPub: Data) throws -> String {
        try peerDeviceEdPub(forIdentityPub: identityPub).ravenHex
    }

    static func importedPeerDeviceEdPubs() throws -> [Data] {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return [] }
        let entries = try listPeerCertDTOs()
        return try entries.map { try LabHex.data($0.device_ed_pub) }
    }

    static func removeImportedPeer(deviceEd: Data) throws {
        let devKey = peerCertAccountPrefix + "dev." + deviceEd.ravenHex
        if let raw = try readKeychain(account: devKey),
           let dto = try? JSONDecoder().decode(LabCertJSON.self, from: raw) {
            let userKey = peerCertAccountPrefix + dto.user_ed_pub
            try deleteKeychain(account: devKey)
            try deleteKeychain(account: userKey)
        } else {
            try deleteKeychain(account: devKey)
        }
    }

    static func exportLocalCertJSON() throws -> String {
        let (cert, _, _, _) = try ensureLocalMaterial()
        let parsed = try parseCertFields(cert)
        let dto = LabCertJSON(
            device_ed_pub: parsed.deviceEd.ravenHex,
            device_x_pub: parsed.deviceX.ravenHex,
            device_id: parsed.deviceID,
            not_before_ms: parsed.notBefore,
            not_after_ms: parsed.notAfter,
            capabilities: parsed.capabilities,
            signature: cert.signature.ravenHex,
            user_ed_pub: cert.identityEd25519PublicKey.ravenHex
        )
        let data = try JSONEncoder().encode(dto)
        guard let s = String(data: data, encoding: .utf8) else { throw TrustError.badJSON }
        return s
    }

    static func exportLocalPrekeyJSON() throws -> String {
        let (_, prekey, _, _) = try ensureLocalMaterial()
        let parsed = try parsePrekeyFields(prekey)
        let dto = LabPrekeyJSON(
            version: 1,
            identity_ed25519_pub_hex: parsed.identity.ravenHex,
            device_id: parsed.deviceID,
            x25519_pub_hex: parsed.xPub.ravenHex,
            mlkem768_ek_hex: parsed.mlkemEK.ravenHex,
            signed_prekey_id: parsed.signedPrekeyID,
            one_time_prekey_id: parsed.oneTimePrekeyID,
            one_time_x25519_pub_hex: parsed.oneTimeX.map(\.ravenHex),
            created_at_ms: parsed.createdAt,
            expires_at_ms: parsed.expiresAt,
            signature_hex: prekey.signature.ravenHex
        )
        let data = try JSONEncoder().encode(dto)
        guard let s = String(data: data, encoding: .utf8) else { throw TrustError.badJSON }
        return s
    }

    static func importPeerCertJSON(_ json: String) throws {
        guard let data = json.data(using: .utf8) else { throw TrustError.badJSON }
        let dto = try JSONDecoder().decode(LabCertJSON.self, from: data)
        let userEd = try LabHex.data(dto.user_ed_pub)
        let deviceEd = try LabHex.data(dto.device_ed_pub)
        let deviceX = try LabHex.data(dto.device_x_pub)
        let sig = try LabHex.data(dto.signature)
        var signing = Data("rvn1/devcert".utf8)
        signing.appendUInt16BE(UInt16(deviceEd.count))
        signing.append(deviceEd)
        signing.appendUInt16BE(UInt16(deviceX.count))
        signing.append(deviceX)
        let idBytes = Data(dto.device_id.utf8)
        signing.appendUInt16BE(UInt16(idBytes.count))
        signing.append(idBytes)
        signing.appendUInt64BE(dto.not_before_ms)
        signing.appendUInt64BE(dto.not_after_ms)
        signing.appendUInt64BE(dto.capabilities)
        let cert = ATSAMPairInitV1.SignedDeviceCertificate(
            identityEd25519PublicKey: userEd,
            signingBytes: signing,
            signature: sig
        )
        _ = try ATSAMPairInitV1.deviceCertificateHash(cert)
        let key = peerCertAccountPrefix + userEd.ravenHex
        try writeKeychain(account: key, data: try JSONEncoder().encode(dto))
        // Also index by device ed (PairInit binds device keys).
        try writeKeychain(
            account: peerCertAccountPrefix + "dev." + deviceEd.ravenHex,
            data: try JSONEncoder().encode(dto)
        )
    }

    static func importPeerPrekeyJSON(_ json: String) throws {
        guard let data = json.data(using: .utf8) else { throw TrustError.badJSON }
        let dto = try JSONDecoder().decode(LabPrekeyJSON.self, from: data)
        _ = try prekeyFromDTO(dto)
        let identity = try LabHex.data(dto.identity_ed25519_pub_hex)
        let deviceEd: Data
        if let cert = try? peerCertificate(forIdentityPub: identity) {
            deviceEd = try labCertFields(cert).deviceEd
        } else if let resolved = try? peerDeviceEdForPrekeyImport(dto: dto) {
            deviceEd = resolved
        } else {
            deviceEd = identity
        }
        let key = peerPrekeyAccountPrefix + deviceEd.ravenHex
        try writeKeychain(account: key, data: data)
    }

    static func peerSignedPrekey(forDeviceEd deviceEd: Data) throws -> ATSAMPairInitV1.SignedPrekeyBundle {
        let key = peerPrekeyAccountPrefix + deviceEd.ravenHex
        guard let raw = try readKeychain(account: key) else { throw TrustError.peerCertMissing }
        let dto = try JSONDecoder().decode(LabPrekeyJSON.self, from: raw)
        return try prekeyFromDTO(dto)
    }

    struct LabCertFields {
        var deviceEd: Data
        var deviceX: Data
        var deviceID: String
        var notBefore: UInt64
        var notAfter: UInt64
        var capabilities: UInt64
    }

    struct LabPrekeyFields {
        var identity: Data
        var deviceID: String
        var xPub: Data
        var mlkemEK: Data
        var signedPrekeyID: UInt32
        var oneTimePrekeyID: UInt32
        var oneTimeX: Data?
        var createdAt: UInt64
        var expiresAt: UInt64
    }

    static func labCertFields(_ cert: ATSAMPairInitV1.SignedDeviceCertificate) throws -> LabCertFields {
        let parsed = try parseCertFields(cert)
        return LabCertFields(
            deviceEd: parsed.deviceEd,
            deviceX: parsed.deviceX,
            deviceID: parsed.deviceID,
            notBefore: parsed.notBefore,
            notAfter: parsed.notAfter,
            capabilities: parsed.capabilities
        )
    }

    static func labPrekeyFields(_ prekey: ATSAMPairInitV1.SignedPrekeyBundle) throws -> LabPrekeyFields {
        let parsed = try parsePrekeyFields(prekey)
        return LabPrekeyFields(
            identity: parsed.identity,
            deviceID: parsed.deviceID,
            xPub: parsed.xPub,
            mlkemEK: parsed.mlkemEK,
            signedPrekeyID: parsed.signedPrekeyID,
            oneTimePrekeyID: parsed.oneTimePrekeyID,
            oneTimeX: parsed.oneTimeX,
            createdAt: parsed.createdAt,
            expiresAt: parsed.expiresAt
        )
    }

    private static func peerDeviceEdForPrekeyImport(dto: LabPrekeyJSON) throws -> Data {
        let certs = try listPeerCertDTOs()
        if let match = certs.first(where: { $0.device_id == dto.device_id }) {
            return try LabHex.data(match.device_ed_pub)
        }
        if certs.count == 1, let only = certs.first {
            return try LabHex.data(only.device_ed_pub)
        }
        throw TrustError.peerCertMissing
    }

    static func peerCertificate(forIdentityPub identityPub: Data) throws
        -> ATSAMPairInitV1.SignedDeviceCertificate {
        let key = peerCertAccountPrefix + identityPub.ravenHex
        guard let raw = try readKeychain(account: key),
              let dto = try? JSONDecoder().decode(LabCertJSON.self, from: raw) else {
            throw TrustError.peerCertMissing
        }
        return try certFromDTO(dto)
    }

    static func peerCertificate(forDeviceEd deviceEd: Data) throws
        -> ATSAMPairInitV1.SignedDeviceCertificate {
        let key = peerCertAccountPrefix + "dev." + deviceEd.ravenHex
        if let raw = try readKeychain(account: key),
           let dto = try? JSONDecoder().decode(LabCertJSON.self, from: raw) {
            return try certFromDTO(dto)
        }
        // Lab exports often set device_ed == user_ed; accept identity-keyed paste too.
        if let cert = try? peerCertificate(forIdentityPub: deviceEd) {
            return cert
        }
        throw TrustError.peerCertMissing
    }

    /// §4.9 contact gate — durable peer cert import counts as local contact trust.
    /// Revoked / blocked peers are never trusted even if a cert blob remains.
    /// Keychain probe errors fail closed (not trusted).
    nonisolated static func peerIsTrusted(deviceEd: Data) -> Bool {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return false }
        if isAdmissionDenied(deviceEd: deviceEd, identityPub: nil, noiseEd: nil) {
            return false
        }
        let key = labTrustPeerCertAccountPrefix + "dev." + deviceEd.ravenHex
        switch ATSAMLabTrustKeychain.probe(account: key) {
        case .present: return true
        case .absent, .error: return false
        }
    }

    nonisolated static func peerIsTrusted(identityPub: Data) -> Bool {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return false }
        if isAdmissionDenied(deviceEd: nil, identityPub: identityPub, noiseEd: nil) {
            return false
        }
        let key = labTrustPeerCertAccountPrefix + identityPub.ravenHex
        switch ATSAMLabTrustKeychain.probe(account: key) {
        case .present: return true
        case .absent, .error: return false
        }
    }

    // MARK: - Lab block list + sticky revocation deny (Secure LAN admission)

    /// Explicit lab block (BlockList). Survives relaunch via Keychain.
    /// Does **not** clear sticky revocation markers.
    static func blockPeer(deviceEd: Data? = nil, identityPub: Data? = nil, noiseEd: Data? = nil) throws {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { throw TrustError.persistFailed }
        if let deviceEd, !deviceEd.isEmpty {
            try writeKeychain(account: labBlockDevicePrefix + deviceEd.ravenHex, data: Data([0x01]))
        }
        if let identityPub, !identityPub.isEmpty {
            try writeKeychain(account: labBlockIdentityPrefix + identityPub.ravenHex, data: Data([0x01]))
        }
        if let noiseEd, !noiseEd.isEmpty {
            try writeKeychain(account: labBlockNoisePrefix + noiseEd.ravenHex, data: Data([0x01]))
        }
    }

    /// Removes lab BlockList entries only. Sticky revocation denies are retained.
    static func unblockPeer(deviceEd: Data? = nil, identityPub: Data? = nil, noiseEd: Data? = nil) throws {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { throw TrustError.persistFailed }
        if let deviceEd, !deviceEd.isEmpty {
            try deleteKeychain(account: labBlockDevicePrefix + deviceEd.ravenHex)
        }
        if let identityPub, !identityPub.isEmpty {
            try deleteKeychain(account: labBlockIdentityPrefix + identityPub.ravenHex)
        }
        if let noiseEd, !noiseEd.isEmpty {
            try deleteKeychain(account: labBlockNoisePrefix + noiseEd.ravenHex)
        }
    }

    /// Sticky deny after an accepted `RavenDeviceRevocationV1` for a device lineage.
    static func recordRevocationDeny(deviceEd: Data, identityPub: Data) throws {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { throw TrustError.persistFailed }
        guard !deviceEd.isEmpty, !identityPub.isEmpty else { throw TrustError.badHex }
        try writeKeychain(account: labRevokedDevicePrefix + deviceEd.ravenHex, data: Data([0x01]))
        try writeKeychain(account: labRevokedIdentityPrefix + identityPub.ravenHex, data: Data([0x01]))
    }

    /// Verify + apply an imported RVDR1 wire into sticky Secure LAN denial.
    /// Callsite for lab Settings / host after a successful revocation paste.
    @discardableResult
    static func applyImportedRevocation(wire: Data, identityEdPub: Data) throws
        -> RavenDeviceRevocationV1.Record {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { throw TrustError.persistFailed }
        let rec = try RavenDeviceRevocationV1.decode(wire)
        try RavenDeviceRevocationV1.verify(rec, identityEdPub: identityEdPub)
        try recordRevocationDeny(deviceEd: rec.deviceEdPub, identityPub: identityEdPub)
        return rec
    }

    /// BlockList **or** sticky revocation deny for Secure LAN / PairInit admission.
    /// Any Keychain probe `.error` fails closed as denied.
    nonisolated static func isAdmissionDenied(
        deviceEd: Data?,
        identityPub: Data?,
        noiseEd: Data?
    ) -> Bool {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return false }
        func denied(_ account: String) -> Bool {
            switch ATSAMLabTrustKeychain.probe(account: account) {
            case .present, .error: return true
            case .absent: return false
            }
        }
        if let deviceEd, !deviceEd.isEmpty {
            let hex = deviceEd.ravenHex
            if denied(labBlockDevicePrefix + hex) || denied(labRevokedDevicePrefix + hex) {
                return true
            }
        }
        if let identityPub, !identityPub.isEmpty {
            let hex = identityPub.ravenHex
            if denied(labBlockIdentityPrefix + hex) || denied(labRevokedIdentityPrefix + hex) {
                return true
            }
        }
        if let noiseEd, !noiseEd.isEmpty {
            if denied(labBlockNoisePrefix + noiseEd.ravenHex) {
                return true
            }
        }
        return false
    }

    static func localSignedPrekey() throws -> ATSAMPairInitV1.SignedPrekeyBundle {
        try ensureLocalMaterial().prekey
    }

    static func localHybridSecrets() throws -> (xSecret: Data, mlkemSeed: Data) {
        let m = try ensureLocalMaterial()
        return (m.xSecret, m.mlkemSeed)
    }

    static func localCertificate() throws -> ATSAMPairInitV1.SignedDeviceCertificate {
        try ensureLocalMaterial().cert
    }

    /// RLB1 offer wire bytes for secure LAN session (parity with encode_local_offer).
    static func encodeLocalRlb1Offer() throws -> Data {
        let cert = try localCertificate()
        let prekey = try localSignedPrekey()
        let bundle = try rlb1BundleFromLabMaterial(cert: cert, prekey: prekey)
        return try RavenSecureLanRlb1V1.encodeOffer(bundle)
    }

    static func rlb1BundleFromLabMaterial(
        cert: ATSAMPairInitV1.SignedDeviceCertificate,
        prekey: ATSAMPairInitV1.SignedPrekeyBundle
    ) throws -> RavenSecureLanRlb1V1.LanBundle {
        let certFields = try parseCertFields(cert)
        let prekeyFields = try parsePrekeyFields(prekey)
        let lanCert = RavenSecureLanRlb1V1.LanDeviceCertificate(
            deviceEdPub: certFields.deviceEd,
            deviceXPub: certFields.deviceX,
            deviceID: certFields.deviceID,
            notBeforeMs: certFields.notBefore,
            notAfterMs: certFields.notAfter,
            capabilities: certFields.capabilities,
            signature: cert.signature,
            userEdPub: cert.identityEd25519PublicKey
        )
        let lanPrekey = RavenSecureLanRlb1V1.LanPrekeyBundle(
            version: 1,
            identityEd25519Pub: prekeyFields.identity,
            deviceID: prekeyFields.deviceID,
            x25519Pub: prekeyFields.xPub,
            mlkem768EK: prekeyFields.mlkemEK,
            signedPrekeyID: prekeyFields.signedPrekeyID,
            oneTimePrekeyID: prekeyFields.oneTimePrekeyID,
            oneTimeX25519Pub: prekeyFields.oneTimeX,
            createdAtMs: prekeyFields.createdAt,
            expiresAtMs: prekeyFields.expiresAt,
            signature: prekey.signature
        )
        let bundle = RavenSecureLanRlb1V1.LanBundle(cert: lanCert, prekey: lanPrekey)
        try RavenSecureLanRlb1V1.requireIdentityBound(bundle)
        return bundle
    }

    // MARK: - Private

    private static func peerCertDTO(forIdentityPub identityPub: Data) throws -> LabCertJSON {
        let key = peerCertAccountPrefix + identityPub.ravenHex
        guard let raw = try readKeychain(account: key),
              let dto = try? JSONDecoder().decode(LabCertJSON.self, from: raw) else {
            throw TrustError.peerCertMissing
        }
        return dto
    }

    private static func listPeerCertDTOs() throws -> [LabCertJSON] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]] else {
            throw TrustError.persistFailed
        }
        var out: [LabCertJSON] = []
        var seenDevice: Set<String> = []
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasPrefix(peerCertAccountPrefix + "dev."),
                  let raw = entry[kSecValueData as String] as? Data,
                  let dto = try? JSONDecoder().decode(LabCertJSON.self, from: raw) else { continue }
            guard seenDevice.insert(dto.device_ed_pub).inserted else { continue }
            out.append(dto)
        }
        return out
    }

    private static func deleteKeychain(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TrustError.persistFailed
        }
    }

    private static func cachedLocalCertMatchesIdentity(_ dto: LabCertJSON, identityPub: Data) -> Bool {
        let identityHex = identityPub.ravenHex
        guard dto.user_ed_pub == identityHex || dto.device_ed_pub == identityHex else {
            return false
        }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        return dto.not_before_ms <= now && now < dto.not_after_ms
    }

    private static func discardLocalCertIfPresent() throws {
        try deleteKeychain(account: certAccount)
    }

    private static func discardLocalPrekeyIfPresent() throws {
        try deleteKeychain(account: prekeyPrivAccount)
        try deleteKeychain(account: prekeyPubAccount)
    }

    #if DEBUG
    /// Drop cached lab cert/prekey so the next `ensureLocalMaterial()` re-issues for the current identity.
    static func resetLocalMaterialForLabIntegration() throws {
        guard ATSAMEndpointDurableAdapters.labTestAEnabled else { return }
        try discardLocalCertIfPresent()
        try discardLocalPrekeyIfPresent()
    }
    #endif

    private static func loadOrIssueLocalCert(identityPub: Data) throws
        -> ATSAMPairInitV1.SignedDeviceCertificate {
        if let raw = try readKeychain(account: certAccount),
           let dto = try? JSONDecoder().decode(LabCertJSON.self, from: raw),
           cachedLocalCertMatchesIdentity(dto, identityPub: identityPub) {
            return try certFromDTO(dto)
        }
        try discardLocalCertIfPresent()
        let agreementPub = DeviceIdentityService.shared.agreementPublicKeyData
            ?? Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let notBefore = now.saturatingSubtraction(60_000)
        let notAfter = now &+ 365 * 24 * 3600 * 1_000
        var signing = Data("rvn1/devcert".utf8)
        signing.appendUInt16BE(32)
        signing.append(identityPub)
        signing.appendUInt16BE(32)
        signing.append(agreementPub)
        let idBytes = Data(deviceID.utf8)
        signing.appendUInt16BE(UInt16(idBytes.count))
        signing.append(idBytes)
        signing.appendUInt64BE(notBefore)
        signing.appendUInt64BE(notAfter)
        signing.appendUInt64BE(0)
        guard let sig = DeviceIdentityService.shared.sign(signing) else {
            throw TrustError.signFailed
        }
        let dto = LabCertJSON(
            device_ed_pub: identityPub.ravenHex,
            device_x_pub: agreementPub.ravenHex,
            device_id: deviceID,
            not_before_ms: notBefore,
            not_after_ms: notAfter,
            capabilities: 0,
            signature: sig.ravenHex,
            user_ed_pub: identityPub.ravenHex
        )
        try writeKeychain(account: certAccount, data: try JSONEncoder().encode(dto))
        return try certFromDTO(dto)
    }

    private static func loadOrPublishLocalPrekey(identityPub: Data) throws -> (
        ATSAMPairInitV1.SignedPrekeyBundle,
        Data,
        Data
    ) {
        if let priv = try readKeychain(account: prekeyPrivAccount),
           priv.count == 96,
           let pubRaw = try readKeychain(account: prekeyPubAccount),
           let dto = try? JSONDecoder().decode(LabPrekeyJSON.self, from: pubRaw),
           dto.identity_ed25519_pub_hex == identityPub.ravenHex {
            let now = UInt64(Date().timeIntervalSince1970 * 1_000)
            if dto.created_at_ms <= now && now < dto.expires_at_ms {
                let prekey = try prekeyFromDTO(dto)
                return (prekey, Data(priv.prefix(32)), Data(priv.suffix(64)))
            }
        }
        try discardLocalPrekeyIfPresent()
        let (ek, seed) = try ATSAMMLKem.keyGen()
        let xPriv = Curve25519.KeyAgreement.PrivateKey()
        let xPub = xPriv.publicKey.rawRepresentation
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let expires = now &+ 30 * 24 * 3600 * 1_000
        var signing = Data("rvn1/prekey".utf8)
        signing.append(UInt8(1))
        signing.append(identityPub)
        let idBytes = Data(deviceID.utf8)
        signing.appendUInt16BE(UInt16(idBytes.count))
        signing.append(idBytes)
        signing.append(xPub)
        signing.append(ek)
        signing.appendUInt32BE(1)
        signing.appendUInt32BE(0)
        signing.appendUInt64BE(now)
        signing.appendUInt64BE(expires)
        guard let sig = DeviceIdentityService.shared.sign(signing) else {
            throw TrustError.signFailed
        }
        let dto = LabPrekeyJSON(
            version: 1,
            identity_ed25519_pub_hex: identityPub.ravenHex,
            device_id: deviceID,
            x25519_pub_hex: xPub.ravenHex,
            mlkem768_ek_hex: ek.ravenHex,
            signed_prekey_id: 1,
            one_time_prekey_id: 0,
            one_time_x25519_pub_hex: nil,
            created_at_ms: now,
            expires_at_ms: expires,
            signature_hex: sig.ravenHex
        )
        var priv = Data()
        priv.append(xPriv.rawRepresentation)
        priv.append(seed)
        try writeKeychain(account: prekeyPrivAccount, data: priv)
        try writeKeychain(account: prekeyPubAccount, data: try JSONEncoder().encode(dto))
        return (try prekeyFromDTO(dto), xPriv.rawRepresentation, seed)
    }

    private static func certFromDTO(_ dto: LabCertJSON) throws
        -> ATSAMPairInitV1.SignedDeviceCertificate {
        let userEd = try LabHex.data(dto.user_ed_pub)
        let deviceEd = try LabHex.data(dto.device_ed_pub)
        let deviceX = try LabHex.data(dto.device_x_pub)
        let sig = try LabHex.data(dto.signature)
        var signing = Data("rvn1/devcert".utf8)
        signing.appendUInt16BE(UInt16(deviceEd.count))
        signing.append(deviceEd)
        signing.appendUInt16BE(UInt16(deviceX.count))
        signing.append(deviceX)
        let idBytes = Data(dto.device_id.utf8)
        signing.appendUInt16BE(UInt16(idBytes.count))
        signing.append(idBytes)
        signing.appendUInt64BE(dto.not_before_ms)
        signing.appendUInt64BE(dto.not_after_ms)
        signing.appendUInt64BE(dto.capabilities)
        return ATSAMPairInitV1.SignedDeviceCertificate(
            identityEd25519PublicKey: userEd,
            signingBytes: signing,
            signature: sig
        )
    }

    private static func prekeyFromDTO(_ dto: LabPrekeyJSON) throws
        -> ATSAMPairInitV1.SignedPrekeyBundle {
        let identity = try LabHex.data(dto.identity_ed25519_pub_hex)
        let xPub = try LabHex.data(dto.x25519_pub_hex)
        let ek = try LabHex.data(dto.mlkem768_ek_hex)
        let sig = try LabHex.data(dto.signature_hex)
        var signing = Data("rvn1/prekey".utf8)
        signing.append(dto.version)
        signing.append(identity)
        let idBytes = Data(dto.device_id.utf8)
        signing.appendUInt16BE(UInt16(idBytes.count))
        signing.append(idBytes)
        signing.append(xPub)
        signing.append(ek)
        signing.appendUInt32BE(dto.signed_prekey_id)
        signing.appendUInt32BE(dto.one_time_prekey_id)
        if dto.one_time_prekey_id != 0, let otp = dto.one_time_x25519_pub_hex {
            signing.append(try LabHex.data(otp))
        }
        signing.appendUInt64BE(dto.created_at_ms)
        signing.appendUInt64BE(dto.expires_at_ms)
        return ATSAMPairInitV1.SignedPrekeyBundle(signingBytes: signing, signature: sig)
    }

    private struct CertFields {
        var deviceEd: Data
        var deviceX: Data
        var deviceID: String
        var notBefore: UInt64
        var notAfter: UInt64
        var capabilities: UInt64
    }

    private static func parseCertFields(_ cert: ATSAMPairInitV1.SignedDeviceCertificate) throws
        -> CertFields {
        // Re-encode via DTO round-trip from keychain is easier — rebuild from signing bytes.
        var reader = cert.signingBytes
        guard reader.count > 12 else { throw TrustError.badJSON }
        // Skip domain
        let domain = Data("rvn1/devcert".utf8)
        guard reader.starts(with: domain) else { throw TrustError.badJSON }
        var offset = domain.count
        func takeU16() throws -> Int {
            guard offset + 2 <= reader.count else { throw TrustError.badJSON }
            let n = Int(reader[offset]) << 8 | Int(reader[offset + 1])
            offset += 2
            return n
        }
        func take(_ n: Int) throws -> Data {
            guard offset + n <= reader.count else { throw TrustError.badJSON }
            let d = reader.subdata(in: offset..<(offset + n))
            offset += n
            return d
        }
        func takeU64() throws -> UInt64 {
            let d = try take(8)
            return d.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        }
        let edLen = try takeU16()
        let deviceEd = try take(edLen)
        let xLen = try takeU16()
        let deviceX = try take(xLen)
        let idLen = try takeU16()
        let deviceID = String(data: try take(idLen), encoding: .utf8) ?? ""
        let notBefore = try takeU64()
        let notAfter = try takeU64()
        let capabilities = try takeU64()
        return CertFields(
            deviceEd: deviceEd,
            deviceX: deviceX,
            deviceID: deviceID,
            notBefore: notBefore,
            notAfter: notAfter,
            capabilities: capabilities
        )
    }

    private struct PrekeyFields {
        var identity: Data
        var deviceID: String
        var xPub: Data
        var mlkemEK: Data
        var signedPrekeyID: UInt32
        var oneTimePrekeyID: UInt32
        var oneTimeX: Data?
        var createdAt: UInt64
        var expiresAt: UInt64
    }

    private static func parsePrekeyFields(_ prekey: ATSAMPairInitV1.SignedPrekeyBundle) throws
        -> PrekeyFields {
        // Prefer stored JSON.
        if let pubRaw = try readKeychain(account: prekeyPubAccount),
           let dto = try? JSONDecoder().decode(LabPrekeyJSON.self, from: pubRaw) {
            return PrekeyFields(
                identity: try LabHex.data(dto.identity_ed25519_pub_hex),
                deviceID: dto.device_id,
                xPub: try LabHex.data(dto.x25519_pub_hex),
                mlkemEK: try LabHex.data(dto.mlkem768_ek_hex),
                signedPrekeyID: dto.signed_prekey_id,
                oneTimePrekeyID: dto.one_time_prekey_id,
                oneTimeX: try dto.one_time_x25519_pub_hex.map { try LabHex.data($0) },
                createdAt: dto.created_at_ms,
                expiresAt: dto.expires_at_ms
            )
        }
        throw TrustError.badJSON
    }

    #if DEBUG
    static func removeImportedPeerCertsForTesting() throws {
        try removeKeychainAccounts(withPrefix: peerCertAccountPrefix)
    }

    static func removeImportedPeerPrekeysForTesting() throws {
        try removeKeychainAccounts(withPrefix: peerPrekeyAccountPrefix)
    }

    private static func removeKeychainAccounts(withPrefix prefix: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]] else { return }
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }
    #endif

    private static func readKeychain(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw TrustError.persistFailed
        }
        return data
    }

    private static func writeKeychain(account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TrustError.persistFailed }
    }

    #if DEBUG
    /// Test-only: remove sticky revocation Keychain markers (production has no clear API).
    static func debugClearRevocationMarkers(deviceEd: Data, identityPub: Data) throws {
        try deleteKeychain(account: labRevokedDevicePrefix + deviceEd.ravenHex)
        try deleteKeychain(account: labRevokedIdentityPrefix + identityPub.ravenHex)
    }
    #endif
}

private extension UInt64 {
    func saturatingSubtraction(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}

private enum LabHex {
    static func data(_ hex: String) throws -> Data {
        guard let d = Data(ravenHex: hex) else { throw ATSAMLabTrustStore.TrustError.badHex }
        return d
    }
}

/// Nonisolated Keychain probes for dispatch contact book (§6.3.1).
private enum ATSAMLabTrustKeychain {
    static let service = "app.raven.ios.atsam.lab.trust"

    enum Probe: Equatable {
        case present
        case absent
        case error
    }

    #if DEBUG
    /// Test hook: force probe outcomes (nil restores SecItem).
    nonisolated(unsafe) static var debugForcedProbe: ((String) -> Probe)?
    #endif

    nonisolated static func probe(account: String) -> Probe {
        #if DEBUG
        if let forced = debugForcedProbe {
            return forced(account)
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .present
        case errSecItemNotFound:
            return .absent
        default:
            return .error
        }
    }
}

#if DEBUG
/// Test-visible Keychain probe control for admission fail-closed coverage.
enum ATSAMLabTrustStoreDebugKeychain {
    enum Probe: Equatable {
        case present
        case absent
        case error
    }

    static func reset() {
        ATSAMLabTrustKeychain.debugForcedProbe = nil
    }

    static func forceAll(_ probe: Probe) {
        let mapped: ATSAMLabTrustKeychain.Probe
        switch probe {
        case .present: mapped = .present
        case .absent: mapped = .absent
        case .error: mapped = .error
        }
        ATSAMLabTrustKeychain.debugForcedProbe = { _ in mapped }
    }

    /// Lab-test only: clears sticky revocation markers so negative apply paths can assert absence.
    @MainActor
    static func clearRevocationMarkers(deviceEd: Data, identityPub: Data) throws {
        try ATSAMLabTrustStore.debugClearRevocationMarkers(deviceEd: deviceEd, identityPub: identityPub)
    }
}
#endif

// MARK: - Secure LAN contact book (lab trust store → dispatch)

/// Durable lab contact book backed by imported device certs (§6.3.1 / §7).
final class RavenSecureLanLabTrustContactBook: RavenSecureLanContactBook {
    func isLocalContact(deviceEdPub: Data, userEdPub: Data) -> Bool {
        ATSAMLabTrustStore.peerIsTrusted(deviceEd: deviceEdPub)
            || ATSAMLabTrustStore.peerIsTrusted(identityPub: userEdPub)
    }

    func isBlocked(deviceEdPub: Data, userEdPub: Data, noiseEdPub: Data) -> Bool {
        ATSAMLabTrustStore.isAdmissionDenied(
            deviceEd: deviceEdPub,
            identityPub: userEdPub,
            noiseEd: noiseEdPub
        )
    }
}
