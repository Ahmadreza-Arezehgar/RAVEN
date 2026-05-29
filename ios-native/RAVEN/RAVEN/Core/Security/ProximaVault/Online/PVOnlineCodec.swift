//
//  PVOnlineCodec.swift
//  RAVEN — PROXIMA-VAULT online codec
//
//  Phase A wiring: makes PV-RAW Vault Mode usable on the existing
//  online (websocket + bridge) text-message path. Server-side
//  changes are NOT required.
//
//  Strategy
//  ────────
//  PV-RAW is a content-layer primitive: the bytes it produces are
//  opaque to any transport that carries them. So the addition for
//  online traffic is just a CODEC that:
//
//    Sender:
//      plaintext_text  ─►  PVEnvelope.encode()  ─►  opaque bytes
//                                                    ─► websocket
//
//    Receiver:
//      websocket bytes ─►  PVEnvelope.parse()   ─►  plaintext_text
//
//  Existing transport-layer encryption (AES-GCM on `MeshEnvelope`,
//  Noise IK, TLS to the server, etc.) is unchanged. PV-RAW sits
//  INSIDE that — meaning the server sees an additional layer of
//  opaque ciphertext but otherwise routes the message as before.
//
//  This file is the only place where chat / transport call PV. It
//  exposes a narrow surface so future call sites cannot get the
//  pad cursor accounting wrong.
//

import Foundation

enum PVOnlineCodec {

    // MARK: - Marker bytes
    //
    // PV envelopes already start with `"PV31"` magic. Online
    // receivers detect "this is PV" by that magic, so non-PV
    // messages (the vast majority on the wire) flow through
    // unchanged.

    /// Returns true if `bytes` looks like a PV-RAW envelope.
    /// Cheap O(4) check; safe to call on every inbound message
    /// before allocating the parser.
    static func isPVPayload(_ bytes: Data) -> Bool {
        guard bytes.count >= 4 else { return false }
        return Array(bytes.prefix(4)) == PVConstants.envelopeMagic
    }

    // MARK: - Encode (send side)

    /// Wrap `plaintext` for the conversation identified by `pad`.
    /// Returns (1) the wire bytes to hand to the transport, and
    /// (2) the updated pad cursor that the caller MUST persist
    /// before transmission. This persist-before-emit ordering is
    /// the OTP correctness invariant — see PVEncryptor.encrypt for
    /// the reasoning.
    ///
    /// Throws PVError.padExhausted if the pad ran out of bytes
    /// for any required range. Caller should surface a UI
    /// "re-pair required" prompt and refuse the send.
    static func encode(plaintext: Data,
                       pad: PVPad,
                       cursor: PVPadCursor,
                       mode: PVConstants.Mode = .infoTheoretic) throws ->
        (wireBytes: Data, updatedCursor: PVPadCursor) {

        let result = try PVEncryptor.encrypt(
            plaintext: plaintext,
            pad: pad,
            cursor: cursor,
            mode: mode
        )
        let wireBytes = result.envelope.encode()
        return (wireBytes, result.updatedCursor)
    }

    // MARK: - Decode (receive side)

    /// Attempt to decode `bytes` as a PV envelope addressed to
    /// the conversation identified by `pad`. Returns:
    ///
    ///   .notPV               — bytes are not a PV envelope. The
    ///                          caller should fall through to the
    ///                          normal (non-PV) processing path.
    ///                          This is the COMMON case for any
    ///                          transport that carries mixed
    ///                          traffic.
    ///   .padMismatch         — looks like PV but the pad-id in
    ///                          the envelope does not match this
    ///                          conversation's pad. Likely
    ///                          addressed to a different pair.
    ///   .authFailed          — tag verification failed. Drop
    ///                          silently; do NOT advance the
    ///                          cursor.
    ///   .decoded(text, cur)  — success. Hand `text` to the chat
    ///                          UI. Caller MUST persist `cur`
    ///                          before acknowledging delivery.
    enum DecodeResult: Sendable {
        case notPV
        case padMismatch
        case authFailed
        case decoded(plaintext: Data, updatedCursor: PVPadCursor)
        case error(message: String)
    }

    static func decode(bytes: Data,
                       pad: PVPad,
                       cursor: PVPadCursor) -> DecodeResult {
        guard isPVPayload(bytes) else { return .notPV }

        let envelope: PVEnvelope
        do {
            envelope = try PVEnvelope.parse(bytes)
        } catch PVError.notAPVEnvelope {
            // Magic prefix matched but the rest didn't — call
            // through as "not PV" so the caller doesn't crash.
            return .notPV
        } catch {
            return .error(message: "PV parse failed: \(error)")
        }

        do {
            let r = try PVDecryptor.decrypt(envelope: envelope, pad: pad, cursor: cursor)
            return .decoded(plaintext: r.plaintext, updatedCursor: r.updatedCursor)
        } catch PVError.padNotFound {
            return .padMismatch
        } catch PVError.authFailed {
            return .authFailed
        } catch {
            return .error(message: "PV decrypt failed: \(error)")
        }
    }
}
