//
//  GREnvelope.swift
//  RAVEN — Ghost Route
//
//  Wire format + parse/build helpers. Pure-data only: no transport
//  I/O lives here (BLEMeshEngine / MeshGatewayService consume the
//  encoded bytes via existing transport code paths).
//
//  Layout (all integers big-endian):
//
//      Offset Size  Field
//      ────────────────────────────────────────────────────────
//        0     4    magic           "GR1!"
//        4     1    version         0x01
//        5     1    reserved        0x00 (rejected otherwise)
//        6    16    recipient_tag   Trunc_128(HMAC(K_route, ...))
//       22    16    nonce           fresh per envelope
//       38     4    payload_len     UInt32, length of opaque payload
//       42     N    payload         opaque ciphertext bytes
//
//  Minimum envelope size = 42 + 0 = 42 bytes (zero-length payload
//  legal but unusual).
//

import Foundation

/// One Ghost Route envelope in memory.
struct GREnvelope: Sendable, Equatable, Hashable {
    let recipientTag: Data    // 16 B
    let nonce: Data           // 16 B
    let payload: Data         // arbitrary length

    // MARK: - Build

    /// Build an envelope addressed to the pair owning `kRoute`.
    /// Generates a fresh nonce via CSPRNG and derives the
    /// recipient_tag from it.
    ///
    /// `payload` is opaque to Ghost Route — caller is responsible
    /// for any content encryption above this layer (Noise IK
    /// transport-mode, PV-RAW, etc.).
    static func build(kRoute: Data, payload: Data) throws -> GREnvelope {
        guard kRoute.count == 32 else {
            throw GRError.internalInputError(reason: "kRoute must be 32 B")
        }

        // Fresh per-message nonce.
        var nonce = Data(count: GRConstants.nonceBytes)
        let status = nonce.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, GRConstants.nonceBytes, base)
        }
        guard status == errSecSuccess else {
            throw GRError.internalInputError(reason: "SecRandomCopyBytes failed")
        }

        let tag = try GRRecipientTag.compute(kRoute: kRoute, nonce: nonce)
        return GREnvelope(recipientTag: tag, nonce: nonce, payload: payload)
    }

    // MARK: - Encode

    /// Canonical wire bytes.
    func encode() -> Data {
        precondition(recipientTag.count == GRConstants.recipientTagBytes)
        precondition(nonce.count == GRConstants.nonceBytes)

        var out = Data()
        out.reserveCapacity(GRConstants.headerSize + payload.count)

        out.append(contentsOf: GRConstants.envelopeMagic)
        out.append(GRConstants.version)
        out.append(0x00)  // reserved
        out.append(recipientTag)
        out.append(nonce)
        out.append(contentsOf: Self.uint32BE(UInt32(payload.count)))
        out.append(payload)
        return out
    }

    // MARK: - Cheap pre-check

    /// O(4) magic check. Use before allocating a parser.
    static func looksLikeEnvelope(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return Array(data.prefix(4)) == GRConstants.envelopeMagic
    }

    // MARK: - Parse

    /// Parse the canonical bytes. Throws `notAGREnvelope` on
    /// magic mismatch so callers can fall through to non-GR
    /// processing without surfacing an alarm.
    static func parse(_ data: Data) throws -> GREnvelope {
        guard data.count >= GRConstants.headerSize else {
            if data.count >= 4,
               Array(data.prefix(4)) == GRConstants.envelopeMagic {
                throw GRError.sizeMismatch(expected: GRConstants.headerSize, got: data.count)
            }
            throw GRError.notAGREnvelope
        }
        let magic = Array(data.prefix(4))
        guard magic == GRConstants.envelopeMagic else {
            throw GRError.notAGREnvelope
        }
        let version = data[data.startIndex + 4]
        guard version == GRConstants.version else {
            throw GRError.unsupportedVersion(found: version)
        }
        let reserved = data[data.startIndex + 5]
        guard reserved == 0x00 else {
            throw GRError.malformedHeader
        }

        func slice(_ start: Int, _ length: Int) -> Data {
            let s = data.startIndex + start
            return Data(data[s ..< (s + length)])
        }

        let tag        = slice(6, GRConstants.recipientTagBytes)
        let nonce      = slice(22, GRConstants.nonceBytes)
        let lenBytes   = slice(38, 4)
        let payloadLen = (UInt32(lenBytes[0]) << 24)
                       | (UInt32(lenBytes[1]) << 16)
                       | (UInt32(lenBytes[2]) << 8)
                       |  UInt32(lenBytes[3])
        let payloadEnd = GRConstants.headerSize + Int(payloadLen)
        guard payloadEnd <= data.count else {
            throw GRError.malformedHeader
        }
        let payload = slice(GRConstants.headerSize, Int(payloadLen))

        return GREnvelope(recipientTag: tag, nonce: nonce, payload: payload)
    }

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8)  & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
}

// MARK: - Receiver-side matcher

/// Decide which (if any) local pairing the envelope was addressed
/// to. Receiver-side O(M) work: for each active pairing, compute
/// the expected recipient_tag from K_route + envelope.nonce, then
/// constant-time-compare against `envelope.recipientTag`.
enum GRMatcher {

    /// One inbound match: which pairing answered for the envelope.
    struct Match: Sendable, Equatable {
        /// Stable identifier for the local pairing that matched.
        let pairingId: Data
        /// The envelope itself (parsed). Caller passes the payload
        /// to the next layer for decrypt.
        let envelope: GREnvelope
    }

    /// A keyed pairing entry. Caller is expected to load these
    /// from `ATSAMKeyTree.ghostRouteKey` for each active pair.
    struct ActivePair: Sendable, Equatable, Hashable {
        let pairingId: Data
        let kRoute: Data
    }

    /// Find the matching pairing for `envelope`, if any.
    /// Returns `nil` when the envelope is addressed elsewhere
    /// (the common case: most envelopes a relay observes are
    /// for other recipients).
    static func match(envelope: GREnvelope,
                      activePairs: [ActivePair]) throws -> Match? {
        for pair in activePairs {
            let expected = try GRRecipientTag.compute(
                kRoute: pair.kRoute,
                nonce: envelope.nonce
            )
            if GRRecipientTag.tagsEqual(expected, envelope.recipientTag) {
                return Match(pairingId: pair.pairingId, envelope: envelope)
            }
        }
        return nil
    }
}
