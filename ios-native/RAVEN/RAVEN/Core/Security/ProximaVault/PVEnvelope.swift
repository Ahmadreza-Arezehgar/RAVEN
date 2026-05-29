//
//  PVEnvelope.swift
//  RAVEN — PROXIMA-VAULT
//
//  Wire format for one PV ciphertext blob.
//
//  PV envelopes are CONTENT-LAYER: they sit inside whatever
//  transport carries them (Noise IK transport-mode payload, mesh
//  relay frame body, bridge tunnel payload). Transport never reads
//  past the magic bytes — it treats the envelope as opaque, which
//  is exactly what keeps bridge / mesh-relay / online paths
//  untouched by PV's addition.
//
//  Byte layout (all integers big-endian):
//
//    Offset Size  Field
//    ─────────────────────────────────────────────────────────────
//      0     4    magic           = "PV31" (0x50 0x56 0x33 0x31)
//      4     1    version         = 0x12
//      5     1    mode            = 0x00 (info-theoretic) | 0x01 (AES-GCM-SIV)
//      6     1    direction       = 0x01 (forward) | 0x02 (reverse)
//      7     1    reserved        = 0x00 (must be zero, reject otherwise)
//      8    16    padId           — public, NOT secret
//     24    16    senderPseudo    — pad-local sender pseudonym
//     40    16    receiverPseudo  — pad-local receiver pseudonym
//     56     4    counter         — UInt32, sender's per-direction counter
//     60     4    cipherOffset    — UInt32, byte offset into the cipher pad
//                                   (only meaningful in info-theoretic mode;
//                                   set to 0xFFFFFFFF in AES-GCM-SIV mode)
//     64    12    aeadNonce       — 12 B, only in AES-GCM-SIV mode
//                                   (in info-theoretic mode, set to all-zero
//                                   and ignored)
//     76     4    ciphertextLen   — UInt32, length of ciphertext body
//     80     N    ciphertext      — body, length = ciphertextLen
//   80+N    16    tag             — Wegman-Carter MAC
//
//  Header is always 80 bytes. Minimum envelope size = 80 + 0 + 16 = 96.
//
//  AAD (input to GHASH for tag, in this exact order):
//    magic || version || mode || direction || reserved ||
//    padId || senderPseudo || receiverPseudo ||
//    counter || cipherOffset || aeadNonce || ciphertextLen || ciphertext
//
//  = full envelope minus the last 16 bytes (the tag itself).
//
//  Mode-binding (Patch 1): because `mode` is part of the AAD that
//  feeds the GHASH, a man-in-the-middle who flips it to downgrade
//  AES-GCM-SIV → info-theoretic (or vice versa) breaks the tag and
//  the receiver drops the envelope. Same property defeats any
//  attempt to swap `direction`, `padId`, or `cipherOffset`.
//

import Foundation

/// One PV envelope, parsed from on-wire bytes or constructed
/// in-memory before being serialised.
struct PVEnvelope: Equatable, Hashable, Sendable {
    let mode: PVConstants.Mode
    let direction: PVDirection
    let padId: Data            // 16 B
    let senderPseudo: Data     // 16 B
    let receiverPseudo: Data   // 16 B
    let counter: UInt32
    let cipherOffset: UInt32   // 0xFFFFFFFF if `mode == .aesGcmSIV`
    let aeadNonce: Data        // 12 B; all-zero if info-theoretic
    let ciphertext: Data       // arbitrary length
    let tag: Data              // 16 B Wegman-Carter MAC

    // MARK: - Constants

    /// Total fixed header size in bytes (everything up to but not
    /// including the ciphertext body).
    static let headerSize: Int = 80

    /// Minimum legal envelope size (header + zero-length ciphertext + tag).
    static let minimumSize: Int = headerSize + 16

    // MARK: - Serialisation

    /// Encode the envelope to a single contiguous `Data` blob.
    /// Result is suitable for direct embedding inside any transport
    /// payload (Noise transport-mode message, mesh frame body,
    /// bridge tunnel chunk).
    func encode() -> Data {
        var out = Data()
        out.reserveCapacity(Self.headerSize + ciphertext.count + 16)

        // Bytes 0..3 — magic
        out.append(contentsOf: PVConstants.envelopeMagic)
        // Byte 4 — version
        out.append(PVConstants.formatVersion)
        // Byte 5 — mode
        out.append(mode.rawValue)
        // Byte 6 — direction
        out.append(direction.rawValue)
        // Byte 7 — reserved
        out.append(0x00)
        // Bytes 8..23 — padId (16 B)
        precondition(padId.count == PVConstants.padIdBytes)
        out.append(padId)
        // Bytes 24..39 — senderPseudo
        precondition(senderPseudo.count == PVConstants.pseudonymBytes)
        out.append(senderPseudo)
        // Bytes 40..55 — receiverPseudo
        precondition(receiverPseudo.count == PVConstants.pseudonymBytes)
        out.append(receiverPseudo)
        // Bytes 56..59 — counter (big-endian UInt32)
        out.append(contentsOf: PVEnvelope.uint32BE(counter))
        // Bytes 60..63 — cipherOffset (big-endian UInt32)
        out.append(contentsOf: PVEnvelope.uint32BE(cipherOffset))
        // Bytes 64..75 — aeadNonce (12 B)
        precondition(aeadNonce.count == PVConstants.aeadNonceBytes)
        out.append(aeadNonce)
        // Bytes 76..79 — ciphertextLen
        out.append(contentsOf: PVEnvelope.uint32BE(UInt32(ciphertext.count)))
        // Body
        out.append(ciphertext)
        // Tag (last 16 B)
        precondition(tag.count == PVConstants.macTagBytes)
        out.append(tag)

        return out
    }

    /// Compute the AAD blob over which the Wegman-Carter MAC is
    /// taken. By definition this is the entire encoded envelope
    /// minus the final 16-byte tag — so encrypting and decrypting
    /// agree on a single byte-sequence with no parsing.
    func aadBytes() -> Data {
        let full = encode()
        return full.prefix(full.count - 16)
    }

    // MARK: - Parsing

    /// Try to parse an envelope from a byte blob. Returns
    /// `.notAPVEnvelope` if the magic doesn't match — this is the
    /// signal callers use to decide "fall through to non-PV
    /// processing". All other failures are real protocol errors.
    static func parse(_ data: Data) throws -> PVEnvelope {
        guard data.count >= minimumSize else {
            // Could be either truncation OR not-a-PV-envelope. We
            // distinguish by checking the prefix first.
            if data.count >= 4,
               Array(data.prefix(4)) == PVConstants.envelopeMagic {
                throw PVError.envelopeTruncated
            }
            throw PVError.notAPVEnvelope
        }

        // Magic
        let magicBytes = Array(data.prefix(4))
        guard magicBytes == PVConstants.envelopeMagic else {
            throw PVError.notAPVEnvelope
        }
        // Version
        let version = data[data.startIndex + 4]
        guard version == PVConstants.formatVersion else {
            throw PVError.unsupportedFormatVersion(found: version)
        }
        // Mode
        guard let mode = PVConstants.Mode(rawValue: data[data.startIndex + 5]) else {
            throw PVError.envelopeMalformed
        }
        // Direction
        guard let direction = PVDirection(rawValue: data[data.startIndex + 6]) else {
            throw PVError.envelopeMalformed
        }
        // Reserved must be zero
        guard data[data.startIndex + 7] == 0x00 else {
            throw PVError.envelopeMalformed
        }

        // Helper: slice bytes [start, end) from the data, normalised
        // to a fresh Data buffer to avoid base-offset confusion.
        func slice(_ start: Int, _ length: Int) -> Data {
            let s = data.startIndex + start
            return Data(data[s ..< (s + length)])
        }

        let padId          = slice(8, 16)
        let senderPseudo   = slice(24, 16)
        let receiverPseudo = slice(40, 16)
        let counter        = uint32BEFrom(slice(56, 4))
        let cipherOffset   = uint32BEFrom(slice(60, 4))
        let aeadNonce      = slice(64, 12)
        let ciphertextLen  = uint32BEFrom(slice(76, 4))

        // Sanity check: declared ciphertext length must fit.
        let bodyStart = headerSize
        let bodyEnd = bodyStart + Int(ciphertextLen)
        guard bodyEnd + 16 <= data.count else {
            throw PVError.envelopeTruncated
        }
        let ciphertext = slice(bodyStart, Int(ciphertextLen))
        let tag        = slice(bodyEnd, 16)

        return PVEnvelope(
            mode: mode,
            direction: direction,
            padId: padId,
            senderPseudo: senderPseudo,
            receiverPseudo: receiverPseudo,
            counter: counter,
            cipherOffset: cipherOffset,
            aeadNonce: aeadNonce,
            ciphertext: ciphertext,
            tag: tag
        )
    }

    // MARK: - Quick magic check (cheap pre-flight)

    /// Returns true if the byte prefix looks like a PV envelope.
    /// Cheap O(4) call; suitable for use in chat-receive paths
    /// before deciding to allocate a parser.
    static func hasPVMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return Array(data.prefix(4)) == PVConstants.envelopeMagic
    }

    // MARK: - Big-endian helpers (private)

    private static func uint32BE(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8)  & 0xFF),
            UInt8(value         & 0xFF),
        ]
    }

    private static func uint32BEFrom(_ data: Data) -> UInt32 {
        precondition(data.count == 4)
        let bytes = Array(data)
        return (UInt32(bytes[0]) << 24) |
               (UInt32(bytes[1]) << 16) |
               (UInt32(bytes[2]) << 8)  |
                UInt32(bytes[3])
    }
}
