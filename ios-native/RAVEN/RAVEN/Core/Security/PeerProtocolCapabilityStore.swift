//
//  PeerProtocolCapabilityStore.swift
//  RAVEN
//
//  2026-05-16 — round 12.
//
//  An in-memory cache tracking which peers we believe support
//  Raven's full ATSAM hybrid stack vs. a legacy / downlevel client.
//
//  The signal currently feeds one piece of UI: the dismissible
//  "Not end-to-end encrypted with full ATSAM" capsule banner that
//  the chat surface drops in at the top-right of the conversation.
//  When we receive a DM whose body is wrapped in the explicit
//  plaintext magic (RVNP1) or carries no magic at all (a pre-round-
//  10 sender), we know the peer doesn't have a live Noise / ATSAM
//  session with us and we flag them downlevel.
//
//  Capability state is intentionally *session-only* (no disk
//  persistence): if a peer upgrades their app between launches, the
//  next received Noise-sealed message clears the warning on its own.
//
//  Observability: the surface exposed to SwiftUI is an `@Observable`
//  view model — `PeerProtocolBannerState` — that vends a per-peer
//  computed flag the banner reads from. The underlying actor stays
//  off the main actor so background message decode paths can mark
//  peers without bouncing through the UI thread.

import Foundation
import SwiftUI

// MARK: - Per-peer protocol verdict

enum PeerProtocolLevel: Sendable, Equatable {
    /// We have not observed any protocol signal from the peer this
    /// session. Default state — UI shows nothing.
    case unknown

    /// The peer is up-to-date with the local app: we have either an
    /// active Noise transport session OR have decoded a RVNS1 sealed
    /// envelope from them this session.
    case modernATSAM

    /// 🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-CRIT-1.
    ///
    /// LOCAL signal only — our `MessageContentSealer.seal` fell back
    /// because we had no Noise session AND no recipient key. We don't
    /// know whether the peer is truly on v1.6 or whether an attacker
    /// just forced our session to evict. The banner fires so the user
    /// is informed, BUT this level NEVER authorises wire-level
    /// plaintext: send-side downgrade requires `.legacyClient` (a
    /// confirmed RECEIVED legacy frame from the peer).
    ///
    /// The previous "proactive" path collapsed this into
    /// `.legacyClient` and shipped plaintext on the next tap — that
    /// turned a session-eviction primitive into a confidentiality
    /// break. We keep the banner-only signal so users still get
    /// visibility, but require independent peer-side confirmation
    /// before the wire goes cleartext.
    case suspectedLegacy

    /// The peer's outbound message arrived as RVNP1 (admitted
    /// plaintext) or a legacy bare payload. They almost certainly do
    /// NOT have ATSAM enabled — surface the warning banner AND
    /// authorise the sender-side plaintext downgrade.
    case legacyClient
}

// MARK: - Store actor

actor PeerProtocolCapabilityStore {
    static let shared = PeerProtocolCapabilityStore()

    private var levels: [String: PeerProtocolLevel] = [:]
    /// Per-peer "user dismissed the banner this session" flag. Once a
    /// peer sets this, the banner stays hidden for them until the
    /// process restarts — we don't want a sticky banner that the user
    /// has already acknowledged.
    private var dismissed: Set<String> = []

    private init() {}

    func level(for peerUserId: String) -> PeerProtocolLevel {
        levels[peerUserId] ?? .unknown
    }

    /// Record an observation. The transition from `.modernATSAM` ←
    /// `.legacyClient` (i.e. recovery) clears any prior dismissal so
    /// the user can be re-notified if the peer somehow downgrades
    /// again later.
    func record(_ level: PeerProtocolLevel, for peerUserId: String) async {
        let prev = levels[peerUserId] ?? .unknown
        if prev == level { return }
        levels[peerUserId] = level
        if level == .modernATSAM {
            dismissed.remove(peerUserId)
        }
        await PeerProtocolBannerState.shared.bump(peerUserId: peerUserId)
    }

    /// User tapped the X. Suppress the banner for this peer until
    /// process restart OR until the peer downgrades again.
    func markDismissed(_ peerUserId: String) async {
        dismissed.insert(peerUserId)
        await PeerProtocolBannerState.shared.bump(peerUserId: peerUserId)
    }

    func isDismissed(_ peerUserId: String) -> Bool {
        dismissed.contains(peerUserId)
    }

    /// Combined check the banner consumer calls. The banner is
    /// visible iff the peer is downlevel AND the user hasn't already
    /// dismissed it this session.
    ///
    /// 🔴 ROUND 26 — both `.legacyClient` AND `.suspectedLegacy` fire
    /// the banner; only `.legacyClient` is allowed to trigger the
    /// send-path plaintext downgrade in `MessageRouter`.
    func shouldShowBanner(for peerUserId: String) -> Bool {
        guard !dismissed.contains(peerUserId) else { return false }
        let lvl = levels[peerUserId] ?? .unknown
        return lvl == .legacyClient || lvl == .suspectedLegacy
    }
}

// MARK: - Observable view-model bridge

/// SwiftUI doesn't observe an actor's state, so we mirror the store
/// to a tiny @Observable class that publishes a monotonic bump
/// counter. Views call `level(for:)` / `shouldShow(for:)` lazily and
/// re-render when the counter increments.
///
/// Keeping the counter per-peer (vs. one global counter) means a
/// chat with peer A doesn't re-render every time we mutate peer B.
@MainActor
@Observable
final class PeerProtocolBannerState {
    static let shared = PeerProtocolBannerState()

    /// Monotonic per-peer counter — read by ChatView to invalidate
    /// just its own subscription. Reading any key forces the view
    /// onto the dependency graph.
    private(set) var bumps: [String: Int] = [:]

    private init() {}

    /// Called by the actor whenever a peer's level or dismissal
    /// changes. Must be called on the main actor.
    func bump(peerUserId: String) {
        bumps[peerUserId, default: 0] &+= 1
    }
}
