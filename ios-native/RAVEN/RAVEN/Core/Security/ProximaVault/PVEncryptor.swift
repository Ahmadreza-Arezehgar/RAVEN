//
//  PVEncryptor.swift
//  RAVEN — PROXIMA-VAULT
//
//  Encrypt entry point. Pure crypto — no I/O, no Keychain, no
//  feature flags. Caller is expected to:
//    1. Load + decrypt the pad from `PVPadStore`.
//    2. Load the matching cursor (per-direction state).
//    3. Call `encrypt(...)` to get back (envelope, updatedCursor).
//    4. Persist the updated cursor BEFORE handing the envelope to
//       the transport layer (mesh/bridge/online) — this is the
//       critical invariant for OTP correctness.
//    5. Hand the envelope bytes to whatever transport will carry it.
//       The transport sees the envelope as opaque payload; it does
//       not need to know PV exists.
//
//  This decoupling is what guarantees bridge/mesh-relay/online
//  message paths keep working after PV is added: those layers never
//  touch any code in this file.
//

import Foundation
// CryptoKit not imported in v1.0 — info-theoretic path uses pure
// XOR + GHASH, no AEAD primitives. Reintroduce when `.aesGcmSIV`
// mode lands.

enum PVEncryptor {

    /// Encrypt `plaintext` from the pad's owner toward the peer,
    /// using `direction` to select pad slices.
    ///
    /// On success returns the wire envelope AND an updated cursor
    /// that the caller MUST persist before transmitting. The
    /// envelope itself is fully self-describing — receiver can
    /// decrypt with nothing but its own copy of the pad + its
    /// cursor.
    ///
    /// Throws `PVError.padExhausted` if any required pad range is
    /// out of bytes for the new message. The cursor returned in that
    /// case has `exhausted = true` so subsequent encrypt attempts
    /// fail-fast.
    static func encrypt(plaintext: Data,
                        pad: PVPad,
                        cursor: PVPadCursor,
                        mode: PVConstants.Mode) throws -> (envelope: PVEnvelope,
                                                           updatedCursor: PVPadCursor) {

        // 1. Allocate this message's counter (advances the cursor).
        var workCursor = cursor
        let counter = try workCursor.allocateNextCounter()

        // 2. Fetch per-message key material from the pad.
        let kWc    = try PVKeyMaterial.universalHashKey(pad: pad,
                                                       direction: cursor.direction,
                                                       counter: counter)
        let mask   = try PVKeyMaterial.tagMask(pad: pad,
                                              direction: cursor.direction,
                                              counter: counter)

        // 3. Encrypt the body. v1.0 ships only `.infoTheoretic` —
        //    the `.aesGcmSIV` slot is reserved on the wire so future
        //    builds can enable it without a format break.
        let ciphertext: Data
        let cipherOffsetOnWire: UInt32
        let aeadNonceOnWire: Data

        switch mode {
        case .infoTheoretic:
            // Allocate fresh cipher-pad keystream of plaintext.count bytes.
            let allocation = try PVKeyMaterial.reserveCipherKeystream(
                pad: pad,
                cursor: workCursor,
                length: plaintext.count
            )
            workCursor = allocation.updatedCursor
            cipherOffsetOnWire = UInt32(workCursor.cipherBytesConsumed - UInt32(plaintext.count))
            // XOR plaintext with the keystream.
            ciphertext = PVWegmanCarter.xor(plaintext, allocation.keystream)
            // In info-theoretic mode the AEAD nonce slot is all-zero on wire.
            aeadNonceOnWire = Data(repeating: 0x00, count: PVConstants.aeadNonceBytes)

        case .aesGcmSIV:
            // v1.0 does NOT ship AES-GCM-SIV. CryptoKit exposes
            // `AES.GCM` only as an AEAD (ciphertext bundled with the
            // built-in 16-B AES tag), and our wire format
            // authenticates via Wegman-Carter — so we'd need raw
            // AES-CTR access to separate cipher from auth. That API
            // doesn't exist on iOS yet.
            //
            // Until it does, refuse the request loudly. The wire
            // format slot is reserved so a v2 build flipping this
            // mode on requires no format break.
            throw PVError.modeNotAvailable(mode: .aesGcmSIV)
        }

        // 4. Build a preliminary envelope with a zero tag, so we can
        //    compute the AAD bytes that the receiver will reconstruct.
        let preliminary = PVEnvelope(
            mode: mode,
            direction: cursor.direction,
            padId: pad.padId,
            senderPseudo: PVKeyMaterial.pseudonym(pad: pad, direction: cursor.direction),
            receiverPseudo: PVKeyMaterial.pseudonym(pad: pad, direction: cursor.direction.inverse),
            counter: counter,
            cipherOffset: cipherOffsetOnWire,
            aeadNonce: aeadNonceOnWire,
            ciphertext: ciphertext,
            tag: Data(repeating: 0x00, count: PVConstants.macTagBytes)
        )
        let aad = preliminary.aadBytes()

        // 5. Compute the Wegman-Carter tag over the AAD blob.
        let tag = PVWegmanCarter.tag(message: aad, key: kWc, mask: mask)

        // 6. Build the final envelope with the real tag.
        let envelope = PVEnvelope(
            mode: preliminary.mode,
            direction: preliminary.direction,
            padId: preliminary.padId,
            senderPseudo: preliminary.senderPseudo,
            receiverPseudo: preliminary.receiverPseudo,
            counter: preliminary.counter,
            cipherOffset: preliminary.cipherOffset,
            aeadNonce: preliminary.aeadNonce,
            ciphertext: preliminary.ciphertext,
            tag: tag
        )

        return (envelope, workCursor)
    }
}
