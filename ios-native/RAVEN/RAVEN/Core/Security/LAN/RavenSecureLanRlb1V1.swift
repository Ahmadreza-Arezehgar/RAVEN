//
//  RavenSecureLanRlb1V1.swift
//  RAVEN
//
//  RLB1 LAN bundle offer (device cert + signed prekey). Wire + canonical JSON
//  parity with node/crates/raven-core/src/lan_rlb1.rs and shared vectors.
//

import Foundation

// MARK: - Errors

enum RavenSecureLanRlb1Error: Error, Equatable, LocalizedError {
    case magic
    case version
    case kind
    case offerExceedsTransport
    case certOverflow
    case certTruncated
    case prekeyOverflow
    case trailingBytes
    case offerTooLarge
    case certJSON(String)
    case prekeyJSON(String)
    case prekeyVersion
    case mlkemLength
    case identityMismatch
    case deviceIDMismatch

    var errorDescription: String? {
        switch self {
        case .magic: return "rlb1 magic"
        case .version: return "rlb1 version"
        case .kind: return "rlb1 kind"
        case .offerExceedsTransport: return "rlb1 offer exceeds transport plaintext"
        case .certOverflow: return "rlb1 cert overflow"
        case .certTruncated: return "rlb1 cert truncated"
        case .prekeyOverflow: return "rlb1 prekey overflow"
        case .trailingBytes: return "rlb1 trailing bytes"
        case .offerTooLarge: return "rlb1 offer too large"
        case .certJSON(let detail): return "rlb1 cert json: \(detail)"
        case .prekeyJSON(let detail): return "rlb1 prekey json: \(detail)"
        case .prekeyVersion: return "PREKEY_VERSION"
        case .mlkemLength: return "mlkem ek length"
        case .identityMismatch: return "lan bundle prekey/cert identity mismatch"
        case .deviceIDMismatch: return "lan bundle prekey/cert device_id mismatch"
        }
    }
}

// MARK: - Types

enum RavenSecureLanRlb1V1 {
    static let rlb1Magic = Data("RLB1".utf8)
    static let rlb1Version: UInt8 = 1
    static let rlb1KindOffer: UInt8 = 2
    static let rlb1HeaderLen = 14
    static let maxOfferWire = 65_519
    static let mlkem768EKLen = 1184
    private static let maxJSONLen = 64 * 1024

    /// serde_json field order for DeviceCertificate.
    struct LanDeviceCertificate: Equatable {
        var deviceEdPub: Data
        var deviceXPub: Data
        var deviceID: String
        var notBeforeMs: UInt64
        var notAfterMs: UInt64
        var capabilities: UInt64
        var signature: Data
        var userEdPub: Data
    }

    /// PrekeyBundleJson field order (omit null otp on wire).
    struct LanPrekeyBundle: Equatable {
        var version: UInt8
        var identityEd25519Pub: Data
        var deviceID: String
        var x25519Pub: Data
        var mlkem768EK: Data
        var signedPrekeyID: UInt32
        var oneTimePrekeyID: UInt32
        var oneTimeX25519Pub: Data?
        var createdAtMs: UInt64
        var expiresAtMs: UInt64
        var signature: Data
    }

    struct LanBundle: Equatable {
        var cert: LanDeviceCertificate
        var prekey: LanPrekeyBundle
    }

    // MARK: - Public API

    static func encodeOffer(_ bundle: LanBundle) throws -> Data {
        let certJSON = try encodeCertJSON(bundle.cert)
        let prekeyJSON = try encodePrekeyJSON(bundle.prekey)
        if certJSON.count > maxJSONLen || prekeyJSON.count > maxJSONLen {
            throw RavenSecureLanRlb1Error.offerTooLarge
        }
        if rlb1HeaderLen + certJSON.count + prekeyJSON.count > maxOfferWire {
            throw RavenSecureLanRlb1Error.offerExceedsTransport
        }
        var out = Data(capacity: rlb1HeaderLen + certJSON.count + prekeyJSON.count)
        out.append(rlb1Magic)
        out.append(rlb1Version)
        out.append(rlb1KindOffer)
        out.appendUInt32BE(UInt32(certJSON.count))
        out.append(certJSON)
        out.appendUInt32BE(UInt32(prekeyJSON.count))
        out.append(prekeyJSON)
        return out
    }

    static func decodeOffer(_ bytes: Data) throws -> LanBundle {
        guard bytes.count >= 10, bytes.prefix(4) == rlb1Magic else {
            throw RavenSecureLanRlb1Error.magic
        }
        guard bytes[bytes.startIndex + 4] == rlb1Version else {
            throw RavenSecureLanRlb1Error.version
        }
        guard bytes[bytes.startIndex + 5] == rlb1KindOffer else {
            throw RavenSecureLanRlb1Error.kind
        }
        guard bytes.count <= maxOfferWire else {
            throw RavenSecureLanRlb1Error.offerExceedsTransport
        }

        let certLen = Int(bytes.u32BE(at: 6))
        let certStart = 10
        guard certLen >= 0 else { throw RavenSecureLanRlb1Error.certOverflow }
        let certEnd = certStart &+ certLen
        guard certEnd <= bytes.count else { throw RavenSecureLanRlb1Error.certTruncated }
        guard certEnd + 4 <= bytes.count else { throw RavenSecureLanRlb1Error.certTruncated }

        let prekeyLen = Int(bytes.u32BE(at: certEnd))
        let prekeyStart = certEnd &+ 4
        let prekeyEnd = prekeyStart &+ prekeyLen
        guard prekeyEnd >= prekeyStart else { throw RavenSecureLanRlb1Error.prekeyOverflow }
        guard prekeyEnd == bytes.count else { throw RavenSecureLanRlb1Error.trailingBytes }

        let certSlice = bytes.subdata(in: certStart..<certEnd)
        let prekeySlice = bytes.subdata(in: prekeyStart..<prekeyEnd)
        let cert = try decodeCertJSON(certSlice)
        let prekey = try decodePrekeyJSON(prekeySlice)
        let bundle = LanBundle(cert: cert, prekey: prekey)
        try requireIdentityBound(bundle)
        return bundle
    }

    static func requireIdentityBound(_ bundle: LanBundle) throws {
        if bundle.prekey.identityEd25519Pub != bundle.cert.userEdPub {
            throw RavenSecureLanRlb1Error.identityMismatch
        }
        if bundle.prekey.deviceID != bundle.cert.deviceID {
            throw RavenSecureLanRlb1Error.deviceIDMismatch
        }
    }

    static func isRlb1(_ bytes: Data) -> Bool {
        bytes.count >= 4 && bytes.prefix(4) == rlb1Magic
    }

    // MARK: - Vector fixture (matches lan_vectors::fixture_offer_bundle)

    static func fixtureOfferBundle(
        deviceSeed: Data,
        deviceID: String = "alice-lan-device-1",
        epochMs: UInt64 = 1_700_000_000_000
    ) throws -> LanBundle {
        precondition(deviceSeed.count == 32)
        let userPub = LanDeterministicEd25519.publicKey(seed: deviceSeed)
        let deviceX = Data(repeating: 0x71, count: 32)
        let cert = try issueDeviceCertificate(
            deviceSeed: deviceSeed,
            userEdPub: userPub,
            deviceEdPub: userPub,
            deviceXPub: deviceX,
            deviceID: deviceID,
            notBeforeMs: epochMs - 60_000,
            notAfterMs: epochMs + 86_400_000,
            capabilities: 7
        )
        let prekey = try signPrekeyBundle(
            deviceSeed: deviceSeed,
            bundle: LanPrekeyBundle(
                version: 1,
                identityEd25519Pub: Data(repeating: 0, count: 32),
                deviceID: deviceID,
                x25519Pub: deviceX,
                mlkem768EK: Data(repeating: 0x02, count: mlkem768EKLen),
                signedPrekeyID: 1,
                oneTimePrekeyID: 0,
                oneTimeX25519Pub: nil,
                createdAtMs: epochMs,
                expiresAtMs: epochMs + 86_400_000,
                signature: Data(repeating: 0, count: 64)
            )
        )
        return LanBundle(cert: cert, prekey: prekey)
    }

    static func issueDeviceCertificate(
        deviceSeed: Data,
        userEdPub: Data,
        deviceEdPub: Data,
        deviceXPub: Data,
        deviceID: String,
        notBeforeMs: UInt64,
        notAfterMs: UInt64,
        capabilities: UInt64
    ) throws -> LanDeviceCertificate {
        let signing = try deviceCertSigningBytes(
            deviceEdPub: deviceEdPub,
            deviceXPub: deviceXPub,
            deviceID: deviceID,
            notBeforeMs: notBeforeMs,
            notAfterMs: notAfterMs,
            capabilities: capabilities
        )
        let signature = LanDeterministicEd25519.sign(seed: deviceSeed, message: signing)
        return LanDeviceCertificate(
            deviceEdPub: deviceEdPub,
            deviceXPub: deviceXPub,
            deviceID: deviceID,
            notBeforeMs: notBeforeMs,
            notAfterMs: notAfterMs,
            capabilities: capabilities,
            signature: signature,
            userEdPub: userEdPub
        )
    }

    static func signPrekeyBundle(deviceSeed: Data, bundle: LanPrekeyBundle) throws -> LanPrekeyBundle {
        var signed = bundle
        signed.identityEd25519Pub = LanDeterministicEd25519.publicKey(seed: deviceSeed)
        let signing = try prekeySigningBytes(signed)
        signed.signature = LanDeterministicEd25519.sign(seed: deviceSeed, message: signing)
        return signed
    }

    // MARK: - Signing bytes (records.rs / prekey_bundle.rs)

    static func deviceCertSigningBytes(
        deviceEdPub: Data,
        deviceXPub: Data,
        deviceID: String,
        notBeforeMs: UInt64,
        notAfterMs: UInt64,
        capabilities: UInt64
    ) throws -> Data {
        guard deviceEdPub.count == 32, deviceXPub.count == 32 else {
            throw RavenSecureLanRlb1Error.certJSON("bad key length")
        }
        let idBytes = Data(deviceID.utf8)
        guard idBytes.count <= UInt16.max else {
            throw RavenSecureLanRlb1Error.certJSON("device_id too long")
        }
        var out = Data("rvn1/devcert".utf8)
        out.appendUInt16BE(UInt16(deviceEdPub.count))
        out.append(deviceEdPub)
        out.appendUInt16BE(UInt16(deviceXPub.count))
        out.append(deviceXPub)
        out.appendUInt16BE(UInt16(idBytes.count))
        out.append(idBytes)
        out.appendUInt64BE(notBeforeMs)
        out.appendUInt64BE(notAfterMs)
        out.appendUInt64BE(capabilities)
        return out
    }

    static func prekeySigningBytes(_ bundle: LanPrekeyBundle) throws -> Data {
        guard bundle.mlkem768EK.count == mlkem768EKLen else {
            throw RavenSecureLanRlb1Error.mlkemLength
        }
        if bundle.oneTimePrekeyID == 0, bundle.oneTimeX25519Pub != nil {
            throw RavenSecureLanRlb1Error.prekeyJSON("otp inconsistency")
        }
        if bundle.oneTimePrekeyID != 0, bundle.oneTimeX25519Pub == nil {
            throw RavenSecureLanRlb1Error.prekeyJSON("otp missing key")
        }
        let idBytes = Data(bundle.deviceID.utf8)
        guard idBytes.count <= UInt16.max else {
            throw RavenSecureLanRlb1Error.prekeyJSON("device_id too long")
        }
        var out = Data("rvn1/prekey".utf8)
        out.append(bundle.version)
        out.append(bundle.identityEd25519Pub)
        out.appendUInt16BE(UInt16(idBytes.count))
        out.append(idBytes)
        out.append(bundle.x25519Pub)
        out.append(bundle.mlkem768EK)
        out.appendUInt32BE(bundle.signedPrekeyID)
        out.appendUInt32BE(bundle.oneTimePrekeyID)
        if let otp = bundle.oneTimeX25519Pub {
            out.append(otp)
        }
        out.appendUInt64BE(bundle.createdAtMs)
        out.appendUInt64BE(bundle.expiresAtMs)
        return out
    }

    // MARK: - Canonical JSON encode (serde field order; lowercase hex; omit null otp)

    static func encodeCertJSON(_ cert: LanDeviceCertificate) throws -> Data {
        guard cert.deviceEdPub.count == 32,
              cert.deviceXPub.count == 32,
              cert.signature.count == 64,
              cert.userEdPub.count == 32 else {
            throw RavenSecureLanRlb1Error.certJSON("bad field length")
        }
        var json = "{"
        json += "\"device_ed_pub\":\"" + cert.deviceEdPub.ravenHex + "\","
        json += "\"device_x_pub\":\"" + cert.deviceXPub.ravenHex + "\","
        json += "\"device_id\":" + jsonString(cert.deviceID) + ","
        json += "\"not_before_ms\":" + String(cert.notBeforeMs) + ","
        json += "\"not_after_ms\":" + String(cert.notAfterMs) + ","
        json += "\"capabilities\":" + String(cert.capabilities) + ","
        json += "\"signature\":\"" + cert.signature.ravenHex + "\","
        json += "\"user_ed_pub\":\"" + cert.userEdPub.ravenHex + "\""
        json += "}"
        guard let data = json.data(using: .utf8) else {
            throw RavenSecureLanRlb1Error.certJSON("utf8")
        }
        return data
    }

    static func encodePrekeyJSON(_ prekey: LanPrekeyBundle) throws -> Data {
        guard prekey.identityEd25519Pub.count == 32,
              prekey.x25519Pub.count == 32,
              prekey.mlkem768EK.count == mlkem768EKLen,
              prekey.signature.count == 64 else {
            throw RavenSecureLanRlb1Error.prekeyJSON("bad field length")
        }
        var json = "{"
        json += "\"version\":" + String(prekey.version) + ","
        json += "\"identity_ed25519_pub_hex\":\"" + prekey.identityEd25519Pub.ravenHex + "\","
        json += "\"device_id\":" + jsonString(prekey.deviceID) + ","
        json += "\"x25519_pub_hex\":\"" + prekey.x25519Pub.ravenHex + "\","
        json += "\"mlkem768_ek_hex\":\"" + prekey.mlkem768EK.ravenHex + "\","
        json += "\"signed_prekey_id\":" + String(prekey.signedPrekeyID) + ","
        json += "\"one_time_prekey_id\":" + String(prekey.oneTimePrekeyID) + ","
        if let otp = prekey.oneTimeX25519Pub {
            guard otp.count == 32 else { throw RavenSecureLanRlb1Error.prekeyJSON("bad otp length") }
            json += "\"one_time_x25519_pub_hex\":\"" + otp.ravenHex + "\","
        }
        json += "\"created_at_ms\":" + String(prekey.createdAtMs) + ","
        json += "\"expires_at_ms\":" + String(prekey.expiresAtMs) + ","
        json += "\"signature_hex\":\"" + prekey.signature.ravenHex + "\""
        json += "}"
        guard let data = json.data(using: .utf8) else {
            throw RavenSecureLanRlb1Error.prekeyJSON("utf8")
        }
        return data
    }

    // MARK: - JSON decode

    static func decodeCertJSON(_ data: Data) throws -> LanDeviceCertificate {
        let object = try jsonObject(data, label: "cert")
        return LanDeviceCertificate(
            deviceEdPub: try hexField(object, key: "device_ed_pub", bytes: 32),
            deviceXPub: try hexField(object, key: "device_x_pub", bytes: 32),
            deviceID: try stringField(object, key: "device_id"),
            notBeforeMs: try u64Field(object, key: "not_before_ms"),
            notAfterMs: try u64Field(object, key: "not_after_ms"),
            capabilities: try u64Field(object, key: "capabilities"),
            signature: try hexField(object, key: "signature", bytes: 64),
            userEdPub: try hexField(object, key: "user_ed_pub", bytes: 32)
        )
    }

    static func decodePrekeyJSON(_ data: Data) throws -> LanPrekeyBundle {
        let object = try jsonObject(data, label: "prekey")
        let version = try u64Field(object, key: "version")
        guard version <= UInt64(UInt8.max) else { throw RavenSecureLanRlb1Error.prekeyVersion }
        guard UInt8(version) == 1 else { throw RavenSecureLanRlb1Error.prekeyVersion }
        let oneTimeID = try u32Field(object, key: "one_time_prekey_id")
        var oneTimePub: Data?
        if oneTimeID != 0 {
            oneTimePub = try hexField(object, key: "one_time_x25519_pub_hex", bytes: 32)
        }
        let mlkem = try hexField(object, key: "mlkem768_ek_hex", exactLen: mlkem768EKLen)
        return LanPrekeyBundle(
            version: 1,
            identityEd25519Pub: try hexField(object, key: "identity_ed25519_pub_hex", bytes: 32),
            deviceID: try stringField(object, key: "device_id"),
            x25519Pub: try hexField(object, key: "x25519_pub_hex", bytes: 32),
            mlkem768EK: mlkem,
            signedPrekeyID: try u32Field(object, key: "signed_prekey_id"),
            oneTimePrekeyID: oneTimeID,
            oneTimeX25519Pub: oneTimePub,
            createdAtMs: try u64Field(object, key: "created_at_ms"),
            expiresAtMs: try u64Field(object, key: "expires_at_ms"),
            signature: try hexField(object, key: "signature_hex", bytes: 64)
        )
    }

    // MARK: - JSON helpers

    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for ch in value {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) {
                    out.append(ch)
                } else {
                    for scalar in ch.unicodeScalars {
                        out += String(format: "\\u%04x", scalar.value)
                    }
                }
            }
        }
        out += "\""
        return out
    }

    private static func jsonObject(_ data: Data, label: String) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RavenSecureLanRlb1Error.certJSON("not an object")
            }
            return object
        } catch {
            throw (label == "cert"
                ? RavenSecureLanRlb1Error.certJSON(error.localizedDescription)
                : RavenSecureLanRlb1Error.prekeyJSON(error.localizedDescription))
        }
    }

    private static func stringField(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw RavenSecureLanRlb1Error.certJSON("missing \(key)")
        }
        return value
    }

    private static func u64Field(_ object: [String: Any], key: String) throws -> UInt64 {
        if let value = object[key] as? UInt64 { return value }
        if let value = object[key] as? Int, value >= 0 { return UInt64(value) }
        if let value = object[key] as? NSNumber { return value.uint64Value }
        throw RavenSecureLanRlb1Error.certJSON("missing \(key)")
    }

    private static func u32Field(_ object: [String: Any], key: String) throws -> UInt32 {
        if let value = object[key] as? UInt32 { return value }
        if let value = object[key] as? Int, value >= 0 { return UInt32(value) }
        if let value = object[key] as? NSNumber { return value.uint32Value }
        throw RavenSecureLanRlb1Error.prekeyJSON("missing \(key)")
    }

    private static func hexField(
        _ object: [String: Any],
        key: String,
        bytes: Int? = nil,
        exactLen: Int? = nil
    ) throws -> Data {
        guard let hex = object[key] as? String else {
            throw RavenSecureLanRlb1Error.prekeyJSON("missing \(key)")
        }
        guard let data = Data(ravenHex: hex) else {
            throw RavenSecureLanRlb1Error.prekeyJSON("bad hex \(key)")
        }
        if let bytes, data.count != bytes {
            throw RavenSecureLanRlb1Error.prekeyJSON("expected \(bytes) bytes for \(key)")
        }
        if let exactLen, data.count != exactLen {
            throw RavenSecureLanRlb1Error.mlkemLength
        }
        return data
    }
}

// MARK: - Data helpers

private extension Data {
    func u32BE(at offset: Int) -> UInt32 {
        precondition(offset + 4 <= count)
        return UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }
}
