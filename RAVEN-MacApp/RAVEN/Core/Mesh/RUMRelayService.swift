// RUMRelayService.swift
//
// Multi-hop forwarder for RUM v2 envelopes.
//
// Without this, BLE mesh delivery is degree-1 only: A → B works just
// when they're in direct radio range. With this, A → C → B succeeds
// even when A and B never see each other directly. The relay is
// transport-agnostic — it just re-broadcasts the same opaque v2 frame
// (the inner AES-GCM ciphertext stays encrypted to the original
// recipient, so a relay device can't read what it forwards).
//
// Routing strategy is a binary Spray-and-Wait variant of DTN epidemic
// flooding (see docs/RUM_V2_ROADMAP.md §C.2):
//
//   • Each fresh envelope ships with `spray_remaining = L` (L=4 free,
//     L=8 RAVEN+ tier).
//   • On forward, we keep half of the remaining budget and hand the
//     other half to the next hop. So a budget of 4 spreads as
//     4 → 2/2 → 1/1/1/1, fanning out at most 5 devices total before
//     the wait phase kicks in (`spray_remaining == 1` = direct only).
//   • A 24-hour Bloom filter dedups by msg_id so loops are bounded.
//
// Module-byte-identical sibling lives at
// `ios-native/RAVEN/RAVEN/Core/Mesh/RUMRelayService.swift`.

import Foundation

@MainActor
final class RUMRelayService {
    static let shared = RUMRelayService()

    // MARK: - Dedup state

    /// Items inserted in the last `dedupWindow`. Reset when full.
    private var seen = BloomFilter(expectedItems: 2_000, falsePositiveRate: 0.005)

    /// Sliding-window record of inserted msg_ids so we can re-seed the
    /// Bloom filter on overflow. We don't try to delete from the filter
    /// itself — Bloom filters are insert-only — we just rebuild it.
    private var seenWindow: [(hex: String, at: Date)] = []

    private static let dedupWindow: TimeInterval = 24 * 60 * 60 // 24 h

    /// msg_ids whose recipient has confirmed delivery (via STOP gossip).
    /// Carriers MUST NOT keep relaying these — the recipient already
    /// has the message, and additional copies just burn BLE bandwidth.
    /// Capped at `maxStoppedSize`; trimmed arbitrarily when over.
    private var stoppedMessages: Set<String> = []
    private static let maxStoppedSize = 5_000

    // MARK: - Lifecycle

    private var observer: NSObjectProtocol?

    private init() {}

    /// Start listening for incoming v2 envelopes and forward them when
    /// appropriate. Idempotent — calling twice is a no-op.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .ravenMeshV2EnvelopeReceived,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let envelope = note.userInfo?["envelope"] as? RUMProtocolV2.Envelope,
                  let from = note.userInfo?["peerDeviceId"] as? String
            else { return }
            Task { await self.relayIfNeeded(envelope, from: from) }
        }
    }

    /// Stop listening. Called on sign-out via `AuthService.signOut`.
    func stop() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
    }

    // MARK: - STOP gossip

    /// Mark an `original_msg_id` as delivered. Called when:
    ///   • We are the recipient and just ingested the envelope, before
    ///     emitting our own STOP broadcast.
    ///   • A STOP envelope from another peer arrived and pointed at
    ///     this `original_msg_id` (its first 16 bytes of payload).
    ///
    /// After marking, `relayIfNeeded` will refuse to forward any future
    /// copy of `originalMsgID`, which is what stops the spray.
    func markStopped(msgID originalMsgID: Data) {
        let hex = originalMsgID.map { String(format: "%02x", $0) }.joined()
        stoppedMessages.insert(hex)
        if stoppedMessages.count > Self.maxStoppedSize {
            // Soft trim — drop ~25% of entries arbitrarily so we don't
            // grow unbounded across a long session. Bloom-filter dedup
            // covers correctness; the stopped set is just an
            // optimization to short-circuit early in `relayIfNeeded`.
            let trimmed = stoppedMessages.shuffled().prefix(Self.maxStoppedSize * 3 / 4)
            stoppedMessages = Set(trimmed)
        }
    }

    // MARK: - Forwarding

    private func relayIfNeeded(_ env: RUMProtocolV2.Envelope, from sourcePeer: String) async {
        // Don't relay envelopes addressed to me — `BLEMeshEngine` already
        // handed the inner ciphertext off to the chat ingest path AND
        // emitted a STOP gossip on our behalf.
        guard let myAgreement = DeviceIdentityService.shared.agreementPublicKeyData else { return }
        let myPID = RUMProtocolV2.peerID(fromPublicKey: myAgreement)
        if env.destPID == myPID { return }

        // Hard limits on how far a frame may propagate.
        guard env.ttl > 0 else { return }
        // `spray_remaining == 0` would mean "nobody should keep relaying".
        // `spray_remaining == 1` is the wait phase — only direct delivery
        // by whoever currently holds the lone copy. We only spray when 2+.
        guard env.sprayRemaining >= 2 else { return }

        // ── STOP gossip ────────────────────────────────────────────
        // STOP envelopes carry the original `msg_id` we want to halt as
        // their first 16 payload bytes. STOP itself uses a fresh
        // `msg_id` (so its own bloom-dedup is independent), and the
        // payload is what we look up to drop future copies of the
        // already-delivered message.
        if env.type == .stop {
            guard env.payload.count >= 16 else { return }
            let originalID = env.payload.prefix(16)
            let originalHex = originalID.map { String(format: "%02x", $0) }.joined()
            // First time we see this STOP target → mark + propagate.
            // Subsequent copies dropped to prevent flooding loops.
            if stoppedMessages.contains(originalHex) { return }
            markStopped(msgID: Data(originalID))
            // Fall through to the normal forward block so other relays
            // also learn about the stop.
        }

        // Dedup: have we already forwarded this msg_id? (Bloom filter is
        // probabilistic — a false positive means we drop a legitimate
        // forward, which is acceptable. False negatives are not — they
        // would loop forever.)
        let hex = env.msgID.map { String(format: "%02x", $0) }.joined()
        pruneDedupWindow()
        if seen.mightContain(hex) { return }

        // Regular envelope: skip if the recipient has already confirmed
        // delivery via a STOP we processed earlier.
        if env.type != .stop && stoppedMessages.contains(hex) {
            #if DEBUG
            print("[mesh-v2-relay] suppressed \(hex.prefix(8)) — already STOPped")
            #endif
            return
        }

        seen.insert(hex)
        seenWindow.append((hex: hex, at: Date()))

        // Build the forwarded envelope. Binary spray: half stays here,
        // half goes to the next hop. (Our half stays in the Bloom filter
        // so we don't double-forward when the same envelope arrives via
        // a different path.)
        let give = env.sprayRemaining / 2
        var forwarded = env
        forwarded.ttl = env.ttl - 1
        forwarded.hopCount = env.hopCount &+ 1   // saturating-add via overflow wrap is fine; TTL is the real limit
        forwarded.sprayRemaining = give

        guard let encoded = try? RUMProtocolV2.encode(forwarded) else {
            #if DEBUG
            print("[mesh-v2-relay] encode failed for \(hex.prefix(8))")
            #endif
            return
        }
        let padded = RUMProtocolV2.pad(encoded)

        #if DEBUG
        let kind = env.type == .stop ? "STOP" : "\(env.type)"
        print("[mesh-v2-relay] forwarding \(kind) \(hex.prefix(8)) ttl=\(forwarded.ttl) spray=\(forwarded.sprayRemaining) (skip=\(sourcePeer.prefix(8)))")
        #endif

        await BLEMeshEngine.shared.relayV2EnvelopeBytesToAllPeers(
            padded,
            except: sourcePeer
        )
    }

    private func pruneDedupWindow() {
        let cutoff = Date().addingTimeInterval(-Self.dedupWindow)
        seenWindow.removeAll { $0.at < cutoff }

        // Bloom filters are insert-only — rebuild when we overflow.
        if seen.itemCount > 2_000 {
            var fresh = BloomFilter(expectedItems: 2_000, falsePositiveRate: 0.005)
            for entry in seenWindow {
                fresh.insert(entry.hex)
            }
            seen = fresh
        }
    }
}
