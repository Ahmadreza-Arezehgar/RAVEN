//
//  PVStealthEnvelope.swift
//  RAVEN — PROXIMA-VAULT Stealth
//
//  Wire format for one PV-Stealth envelope. Body crypto is
//  unchanged from PV v3.1.2 — only the header layout differs.
//
//  Byte layout (all integers big-endian):
//
//    Offset Size  Field
//    ─────────────────────────────────────────────────────────────
//      0     4    magic           = "PVST"
//      4     1    version         = 0x12
//      5     1    mode            = 0x00 (info-theoretic) | 0x01 (AES-GCM-SIV)
//      6     1    direction       = 0x01 (forward) | 0x02 (reverse)
//      7     1    reserved        = 0x00 (must be zero)
//      8    16    lookup_nonce    fresh per envelope
//     24    16    lookup_tag      Trunc_128(HMAC(K_lookup^dir, ...))
//     40     4    counter         UInt32, sender's per-direction counter
//     44     4    cipherOffset    UInt32, byte offset into the cipher pad
//                                 (0xFFFFFFFF in AES-GCM-SIV mode)
//     48    12    aeadNonce       12 B; all-zero in info-theoretic mode
//     60     4    ciphertextLen   UInt32
//     64     N    ciphertext      length = ciphertextLen
//   64+N    16    tag             Wegman-Carter MAC
//
//  Header = 64 bytes. Minimum envelope = 64 + 0 + 16 = 80 bytes.
//

import Foundation

struct PVStealthEnvelope: Equatable, Hashable, Sendable {
    let mode: PVConstants.Mode
    let direction: PVDirection
    let lookupNonce: Data       // 16 B
    let lookupTag: Data         // 16 B
    let counter: UInt32
    let cipherOffset: UInt32
    let aeadNonce: Data         // 12 B
    let ciphertext: Data
    let tag: Data               // 16 B Wegman-Carter

    // MARK: - Encode

    func encode() -> Data {
        var out = Data()
        out.reserveCapacity(PVStealthConstants.headerSize + ciphertext.count + 16)

        out.append(contentsOf: PVStealthConstants.envelopeMagic)
        out.append(PVStealthConstants.formatVersion)
        out.append(mode.rawValue)
        out.append(direction.rawValue)
        out.append(0x00)  // reserved

        precondition(lookupNonce.count == PVStealthConstants.lookupNonceBytes)
        out.append(lookupNonce)
        precondition(lookupTag.count == PVStealthConstants.lookupTagBytes)
        out.append(lookupTag)

        out.append(contentsOf: Self.uint32BE(counter))
        out.append(contentsOf: Self.uint32BE(cipherOffset))

        precondition(aeadNonce.count == PVConstants.aeadNonceBytes)
        out.append(aeadNonce)

        out.append(contentsOf: Self.uint32BE(UInt32(ciphertext.count)))
        out.append(ciphertext)

        precondition(tag.count == PVConstants.macTagBytes)
        out.append(tag)

        return out
    }

    /// AAD blob (everything except the trailing 16-byte WC tag) —
    /// the exact bytes that feed the Wegman-Carter MAC.
    func aadBytes() -> Data {
        let full = encode()
        return full.prefix(full.count - 16)
    }

    // MARK: - Parse

    static func hasStealthMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return Array(data.prefix(4)) == PVStealthConstants.envelopeMagic
    }

    static func parse(_ data: Data) throws -> PVStealthEnvelope {
        guard data.count >= PVStealthConstants.minimumSize else {
            if data.count >= 4,
               Array(data.prefix(4)) == PVStealthConstants.envelopeMagic {
                throw PVStealthError.sizeMismatch(
                    expected: PVStealthConstants.minimumSize,
                    got: data.count
                )
            }
            throw PVStealthError.notAStealthEnvelope
        }

        let magic = Array(data.prefix(4))
        guard magic == PVStealthConstants.envelopeMagic else {
            throw PVStealthError.notAStealthEnvelope
        }
        let version = data[data.startIndex + 4]
        guard version == PVStealthConstants.formatVersion else {
            throw PVStealthError.unsupportedVersion(found: version)
        }
        guard let mode = PVConstants.Mode(rawValue: data[data.startIndex + 5]) else {
            throw PVStealthError.malformedHeader
        }
        guard let direction = PVDirection(rawValue: data[data.startIndex + 6]) else {
            throw PVStealthError.malformedHeader
        }
        guard data[data.startIndex + 7] == 0x00 else {
            throw PVStealthError.malformedHeader
        }

        func slice(_ start: Int, _ length: Int) -> Data {
            let s = data.startIndex + start
            return Data(data[s ..< (s + length)])
        }

        let lookupNonce  = slice(8, PVStealthConstants.lookupNonceBytes)
        let lookupTag    = slice(24, PVStealthConstants.lookupTagBytes)
        let counter      = Self.uint32BEFrom(slice(40, 4))
        let cipherOffset = Self.uint32BEFrom(slice(44, 4))
        let aeadNonce    = slice(48, PVConstants.aeadNonceBytes)
        let ciphertextLen = Self.uint32BEFrom(slice(60, 4))

        let bodyEnd = PVStealthConstants.headerSize + Int(ciphertextLen)
        guard bodyEnd + 16 <= data.count else {
            throw PVStealthError.sizeMismatch(
                expected: bodyEnd + 16,
                got: data.count
            )
        }
        let ciphertext = slice(PVStealthConstants.headerSize, Int(ciphertextLen))
        let macTag     = slice(bodyEnd, 16)

        return PVStealthEnvelope(
            mode: mode,
            direction: direction,
            lookupNonce: lookupNonce,
            lookupTag: lookupTag,
            counter: counter,
            cipherOffset: cipherOffset,
            aeadNonce: aeadNonce,
            ciphertext: ciphertext,
            tag: macTag
        )
    }

    // MARK: - Big-endian helpers

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8)  & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static func uint32BEFrom(_ data: Data) -> UInt32 {
        precondition(data.count == 4)
        let bytes = Array(data)
        return (UInt32(bytes[0]) << 24)
             | (UInt32(bytes[1]) << 16)
             | (UInt32(bytes[2]) << 8)
             |  UInt32(bytes[3])
    }
}
