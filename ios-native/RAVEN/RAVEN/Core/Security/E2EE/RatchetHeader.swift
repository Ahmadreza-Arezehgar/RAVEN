//
//  RatchetHeader.swift
//  RAVEN
//
//  Per-message header that travels alongside every Double-Ratchet
//  ciphertext. Contains the data the receiver needs to advance their
//  ratchet state and locate the right message key.
//

import Foundation

/// Header sent in plaintext alongside every E2EE message.
///
/// • `dh`: sender's current DH ratchet public key (X25519, raw bytes).
///   When the receiver sees a *new* dh value they perform a DH ratchet
///   step and switch chains.
/// • `pn`: number of messages in the sender's *previous* sending chain.
///   Tells the receiver how many message keys may need to be cached
///   from the chain that's about to be retired.
/// • `n`:  message number in the current sending chain.
///
/// The header is bound to the ciphertext via AEAD associated data, so a
/// MITM rewriting any of these fields invalidates the GCM tag.
struct RatchetHeader: Codable, Equatable {
    /// Sender DH public key (X25519, 32 bytes raw).
    let dh: Data
    /// Previous sending chain length.
    let pn: UInt32
    /// Current message number.
    let n: UInt32

    // Compact JSON keys — keeps headers small on BLE.
    enum CodingKeys: String, CodingKey {
        case dh = "d"
        case pn = "p"
        case n  = "n"
    }
}

// MARK: - Wire format

extension RatchetHeader {
    /// Canonical bytes for use as AEAD Associated Data.
    /// Sorted-keys JSON is deterministic across encoder runs, which is
    /// required for AEAD-AD to round-trip.
    func canonicalAssociatedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

/// What actually goes over the wire — header + ciphertext, wrapped.
struct RatchetCiphertext: Codable, Equatable {
    let header: RatchetHeader
    /// AES-256-GCM combined ciphertext (nonce ‖ ciphertext ‖ tag).
    let body: Data

    enum CodingKeys: String, CodingKey {
        case header = "h"
        case body   = "b"
    }
}

// MARK: - Skipped-key cache identifier

/// Composite key for the skipped-message-keys cache. The (DH pubkey,
/// message number) tuple uniquely identifies a message that arrived out
/// of order so we can release its message key on demand without
/// breaking the linear chain.
struct SkippedKeyID: Hashable {
    let dh: Data
    let n: UInt32
}
