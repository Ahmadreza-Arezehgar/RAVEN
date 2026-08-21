//
//  ATSAMHybridRatchetV2.swift
//  RAVEN
//
//  Vector-freeze KATs for ATSAM/hybrid-ratchet/v2 (production disabled).
//  No live callsites.
//

import CryptoKit
import Foundation

enum ATSAMHybridRatchetV2 {
    static let productionEnabled = false
    static let profile = Data("ATSAM/hybrid-ratchet/v2".utf8)
    static let trProtocolInfo = Data("ATSAM/hybrid-ratchet/v2\u{00}TR".utf8)
    static let spqrProtocolInfo = Data("ATSAM/hybrid-ratchet/v2\u{00}SPQR".utf8)
    static let ecRkInfo = Data("ATSAM/hybrid-ratchet/v2\u{00}EC-KDF-RK".utf8)
    static let sckaInitInfo = Data("ATSAM/hybrid-ratchet/v2\u{00}SPQR\u{00}SCKA-INIT".utf8)
    static let ackDomain = Data("ATSAM/v2/ack".utf8)
    static let aadDomain = Data("ATSAM/v2/aad".utf8)
    static let headerDomain = Data("ATSAM/v2/tr-header".utf8)
    static let sealedProto: UInt8 = 0x04
    static let maxSkip = 1000
    static let routeLookahead = 32
    static let mailboxLateArrivalDays = 7
    static let ackPlaintextLen = 197

    enum Error: Swift.Error {
        case badLength, nonContributoryDH, aeadFailed, verifyFailed, badStatus
        case pendingRequired, rebuildForbidden, ackOfAck
    }

    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let saltData = salt.isEmpty ? Data(count: 32) : salt
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: saltData,
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func kdfRK(rk: Data, dhOut: Data) throws -> (rkNext: Data, ck: Data) {
        guard rk.count == 32, dhOut.count == 32 else { throw Error.badLength }
        guard dhOut != Data(count: 32) else { throw Error.nonContributoryDH }
        let okm = hkdf(ikm: dhOut, salt: rk, info: ecRkInfo, length: 64)
        return (okm.prefix(32), okm.suffix(32))
    }

    static func kdfCK(ck: Data) throws -> (ckNext: Data, mk: Data) {
        guard ck.count == 32 else { throw Error.badLength }
        let key = SymmetricKey(data: ck)
        let mk = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: key))
        let ckNext = Data(HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: key))
        return (ckNext, mk)
    }

    static func kdfHybrid(ecMk: Data, sckaMk: Data) throws -> (key: Data, nonce: Data) {
        guard ecMk.count == 32, sckaMk.count == 32 else { throw Error.badLength }
        let okm = hkdf(ikm: ecMk, salt: sckaMk, info: trProtocolInfo, length: 44)
        return (Data(okm.prefix(32)), Data(okm.suffix(12)))
    }

    struct SckaInit: Equatable {
        var rk: Data
        var ckSend: Data
        var ckRecv: Data
    }

    static func ratchetInitAliceSCKA(skScka: Data) throws -> SckaInit {
        guard skScka.count == 32 else { throw Error.badLength }
        let okm = hkdf(ikm: skScka, salt: Data(count: 32), info: sckaInitInfo, length: 96)
        return SckaInit(
            rk: Data(okm[0..<32]),
            ckSend: Data(okm[32..<64]),
            ckRecv: Data(okm[64..<96])
        )
    }

    static func ratchetInitBobSCKA(skScka: Data) throws -> SckaInit {
        guard skScka.count == 32 else { throw Error.badLength }
        let okm = hkdf(ikm: skScka, salt: Data(count: 32), info: sckaInitInfo, length: 96)
        return SckaInit(
            rk: Data(okm[0..<32]),
            ckSend: Data(okm[64..<96]),
            ckRecv: Data(okm[32..<64])
        )
    }

    static func aeadSeal(key: Data, nonce: Data, plaintext: Data, aad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try ChaChaPoly.Nonce(data: nonce),
            authenticating: aad
        )
        return box.ciphertext + box.tag
    }

    static func aeadOpen(key: Data, nonce: Data, ciphertextAndTag: Data, aad: Data) throws -> Data {
        guard ciphertextAndTag.count >= 16 else { throw Error.aeadFailed }
        let ct = ciphertextAndTag.dropLast(16)
        let tag = ciphertextAndTag.suffix(16)
        let boxed = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: nonce),
            ciphertext: ct,
            tag: tag
        )
        do {
            return try ChaChaPoly.open(boxed, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw Error.aeadFailed
        }
    }

    struct AckV2: Equatable {
        var ackedMessageId: Data
        var ackedObjectDigest: Data
        var status: UInt8
        var ackNonce: Data
        var createdAtMs: UInt64
        var recipientDeviceCertHash: Data
        var sessionId: Data
        var signature: Data
    }

    static func ackSigningBytes(_ ack: AckV2) throws -> Data {
        guard ack.ackedMessageId.count == 16,
              ack.ackedObjectDigest.count == 32,
              ack.ackNonce.count == 12,
              ack.recipientDeviceCertHash.count == 32,
              ack.sessionId.count == 32 else { throw Error.badLength }
        guard ack.status == 1 || ack.status == 2 else { throw Error.badStatus }
        var out = ackDomain
        out.append(ack.ackedMessageId)
        out.append(ack.ackedObjectDigest)
        out.append(ack.status)
        out.append(ack.ackNonce)
        var be = ack.createdAtMs.bigEndian
        out.append(Data(bytes: &be, count: 8))
        out.append(ack.recipientDeviceCertHash)
        out.append(ack.sessionId)
        return out
    }

    static func encodeAckPlaintext(_ ack: AckV2) throws -> Data {
        guard ack.signature.count == 64 else { throw Error.badLength }
        return try ackSigningBytes(ack).dropFirst(ackDomain.count) + ack.signature
    }

    static func decodeAckPlaintext(_ buf: Data) throws -> AckV2 {
        guard buf.count == ackPlaintextLen else { throw Error.badLength }
        var off = 0
        func take(_ n: Int) -> Data {
            let d = buf.subdata(in: off..<(off + n))
            off += n
            return d
        }
        return AckV2(
            ackedMessageId: take(16),
            ackedObjectDigest: take(32),
            status: take(1)[0],
            ackNonce: take(12),
            createdAtMs: take(8).reduce(0) { ($0 << 8) | UInt64($1) },
            recipientDeviceCertHash: take(32),
            sessionId: take(32),
            signature: take(64)
        )
    }

    static func verifyAck(_ ack: AckV2, deviceEdPub: Data) throws {
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: deviceEdPub)
        let sb = try ackSigningBytes(ack)
        guard pub.isValidSignature(ack.signature, for: sb) else { throw Error.verifyFailed }
    }

    static func domainCatalog() -> [String: String] {
        [
            "PROFILE": profile.hexString,
            "TR_PROTOCOL_INFO": trProtocolInfo.hexString,
            "SPQR_PROTOCOL_INFO": spqrProtocolInfo.hexString,
            "EC_RK_INFO": ecRkInfo.hexString,
            "AEAD_NONCE_INFO": Data("ATSAM/hybrid-ratchet/v2\u{00}AEAD-nonce".utf8).hexString,
            "SCKA_INIT_INFO": sckaInitInfo.hexString,
            "SCKA_INIT_ALICE_INFO": sckaInitInfo.hexString,
            "SCKA_INIT_BOB_INFO": sckaInitInfo.hexString,
            "ACK_DOMAIN": ackDomain.hexString,
            "AAD_DOMAIN": aadDomain.hexString,
            "HEADER_DOMAIN": headerDomain.hexString,
            "SEALED_PROTO": String(format: "%02x", sealedProto),
            "MAX_SKIP": "\(maxSkip)",
            "ROUTE_LOOKAHEAD": "\(routeLookahead)",
            "MAILBOX_LATE_ARRIVAL_DAYS": "\(mailboxLateArrivalDays)",
            "COMPOSITE_HEADER_LEN": "\(headerDomain.count + 1 + 32 + 4 + 4 + 4 + 4 + 4 + 1 + 32)",
            "ACK_PLAINTEXT_LEN": "\(ackPlaintextLen)",
            "KDF_HYBRID_L": "44",
            "AEAD": "ChaCha20-Poly1305",
        ]
    }

    // MARK: - ACK-CAS transition model (KAT only)

    enum AckCasState: Equatable {
        case idle
        case candidateCloned
        case sealed(retained: Data)
        case pendingAckSend(retained: Data, digest: Data)
        case materialized(retained: Data)
        case sent(retained: Data)
        case cleared
    }

    struct AckCasMachine {
        private(set) var state: AckCasState = .idle
        private(set) var durableMutation = false

        mutating func apply(action: String, retained: Data? = nil, digest: Data? = nil) throws {
            switch action {
            case "clone_candidate_send_state":
                guard state == .idle else { throw Error.badStatus }
                state = .candidateCloned
            case "seal_AckV2":
                guard case .candidateCloned = state, let retained else { throw Error.badStatus }
                state = .sealed(retained: retained)
            case "write_PENDING_ACK_SEND":
                guard case .sealed(let r) = state, let digest else { throw Error.badStatus }
                state = .pendingAckSend(retained: r, digest: digest)
            case "CAS_Materialized":
                guard case .pendingAckSend(let r, _) = state else {
                    throw Error.pendingRequired
                }
                durableMutation = true
                state = .materialized(retained: r)
            case "network_send_OUTSIDE_lease":
                guard case .materialized(let r) = state else { throw Error.badStatus }
                state = .sent(retained: r)
            case "clear_PENDING_ACK_SEND_on_success":
                guard case .sent = state else { throw Error.badStatus }
                state = .cleared
            case "ack_of_ack":
                throw Error.ackOfAck
            case "rebuild_ack_bytes_on_retry":
                throw Error.rebuildForbidden
            default:
                throw Error.badStatus
            }
        }

        mutating func casWithoutPending() throws {
            throw Error.pendingRequired
        }
    }
}

// MARK: - PairInit / PairResponse V2

enum ATSAMPairInitV2 {
    static let productionEnabled = false
    static let version: UInt8 = 2
    static let suite: UInt8 = 1
    static let profile = Data("ATSAM/hybrid-ratchet/v2".utf8)
    static let initMagic = Data([0x52, 0x56, 0x50, 0x49, 0x32, 0, 0, 0]) // RVPI2
    static let responseMagic = Data([0x52, 0x56, 0x50, 0x52, 0x32, 0, 0, 0]) // RVPR2
    static let initMagicV1 = Data([0x52, 0x56, 0x50, 0x49, 0x31, 0, 0, 0]) // RVPI1
    static let transcriptDomain = Data("ATSAM/v2/transcript".utf8)
    static let pairInitLabel = Data("ATSAM/v2/pair-init".utf8)
    static let confirmLabel = Data("ATSAM/v2/pair-init/confirm".utf8)
    static let sessionIdDomain = Data("ATSAM/v2/pair-session".utf8)
    static let pairExpandInfoPrefix = Data("ATSAM/hybrid-ratchet/v2\u{00}pair-expand".utf8)
    static let initSigningDomain = Data("rvn1/pair-init-v2".utf8)
    static let responseSigningDomain = Data("rvn1/pair-response-v2".utf8)
    static let wireLen = 2787
    static let responseWireLen = 227

    enum Error: Swift.Error {
        case badLength, v1Reinterpret, badMagic, badVersion, verifyFailed
    }

    struct Expand: Equatable {
        var skEc: Data
        var skScka: Data
        var kRouteMaster: Data
        var kConfirm: Data
        var transcriptHash: Data
        var initHashV2: Data
        var sessionId: Data
    }

    static func rejectIfV1(_ wire: Data) throws {
        if wire.count >= 8, wire.prefix(8) == initMagicV1 {
            throw Error.v1Reinterpret
        }
    }

    static func decodeInitWire(_ wire: Data) throws {
        try rejectIfV1(wire)
        guard wire.count == wireLen else { throw Error.badLength }
        guard wire.prefix(8) == initMagic else { throw Error.badMagic }
        guard wire[8] == version, wire[9] == suite else { throw Error.badVersion }
        let plen = Int(wire[11])
        guard plen == profile.count, wire.subdata(in: 12..<(12 + plen)) == profile else {
            throw Error.badVersion
        }
    }

    static func initHashV2(_ wire: Data) throws -> Data {
        try decodeInitWire(wire)
        return Data(SHA256.hash(data: pairInitLabel + wire))
    }

    static func transcriptHash(_ wire: Data) throws -> Data {
        try decodeInitWire(wire)
        return Data(SHA256.hash(data: transcriptDomain + pairInitLabel + wire))
    }

    static func pairExpand(zX: Data, zPQ: Data, wire: Data) throws -> Expand {
        guard zX.count == 32, zPQ.count == 32 else { throw Error.badLength }
        let th = try transcriptHash(wire)
        let ih = try initHashV2(wire)
        var info = pairExpandInfoPrefix
        info.append(th)
        let okm = ATSAMHybridRatchetV2.hkdf(ikm: zX + zPQ, salt: th, info: info, length: 128)
        return Expand(
            skEc: Data(okm[0..<32]),
            skScka: Data(okm[32..<64]),
            kRouteMaster: Data(okm[64..<96]),
            kConfirm: Data(okm[96..<128]),
            transcriptHash: th,
            initHashV2: ih,
            sessionId: Data(SHA256.hash(data: sessionIdDomain + ih))
        )
    }

    static func confirmationTag(kConfirm: Data, initHash: Data) throws -> Data {
        guard kConfirm.count == 32, initHash.count == 32 else { throw Error.badLength }
        let msg = confirmLabel + Data([0]) + initHash
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: kConfirm)))
    }

    static func decodeResponseWire(_ wire: Data) throws {
        guard wire.count == responseWireLen else { throw Error.badLength }
        guard wire.prefix(8) == responseMagic else { throw Error.badMagic }
        guard wire[8] == version, wire[9] == suite else { throw Error.badVersion }
    }

    static func initSigningBytes(wire: Data) throws -> Data {
        try decodeInitWire(wire)
        return initSigningDomain + wire.dropLast(64)
    }

    static func responseSigningBytes(wire: Data) throws -> Data {
        try decodeResponseWire(wire)
        return responseSigningDomain + wire.dropLast(64)
    }

    static func verifyInitSignature(wire: Data, pub: Data) throws {
        let signing = try initSigningBytes(wire: wire)
        let signature = wire.suffix(64)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: pub)
        guard key.isValidSignature(signature, for: signing) else { throw Error.verifyFailed }
    }

    static func verifyResponseSignature(wire: Data, pub: Data) throws {
        let signing = try responseSigningBytes(wire: wire)
        let signature = wire.suffix(64)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: pub)
        guard key.isValidSignature(signature, for: signing) else { throw Error.verifyFailed }
    }

    /// Frozen PairInit V2 field offsets (PROFILE_LEN=23).
    static func wireOffsets() -> [String: Int] {
        var o = 0
        var out: [String: Int] = [:]
        out["magic"] = o; o += 8
        out["version"] = o; o += 1
        out["suite"] = o; o += 1
        out["role"] = o; o += 1
        out["profile_len"] = o; o += 1
        out["profile"] = o; o += profile.count
        out["initiator_address"] = o; o += 44
        out["responder_address"] = o; o += 44
        out["init_id"] = o; o += 16
        out["pairing_nonce"] = o; o += 32
        out["initiator_device_ed_pub"] = o; o += 32
        out["responder_device_ed_pub"] = o; o += 32
        out["initiator_ephemeral_x25519_pub"] = o; o += 32
        out["responder_signed_x25519_pub"] = o; o += 32
        out["responder_one_time_x25519_pub"] = o; o += 32
        out["initiator_device_cert_hash"] = o; o += 32
        out["responder_device_cert_hash"] = o; o += 32
        out["responder_prekey_bundle_hash"] = o; o += 32
        out["signed_prekey_id"] = o; o += 4
        out["one_time_prekey_id"] = o; o += 4
        out["responder_mlkem768_ek"] = o; o += 1184
        out["mlkem768_ciphertext"] = o; o += 1088
        out["created_at_ms"] = o; o += 8
        out["expires_at_ms"] = o; o += 8
        out["signature"] = o; o += 64
        out["total_len"] = o
        return out
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
