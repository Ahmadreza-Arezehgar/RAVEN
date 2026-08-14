//
//  RemoteInviteService.swift
//  RAVEN
//
//  Remote contact add over the serverless libp2p rendezvous.
//
//  Every other way to add a contact needs the two people to be physically
//  together (QR scan, BLE pairing, mesh broadcast) or to already know each
//  other's userId (ATSAM online pair). The workaround people actually use —
//  sending a QR screenshot over WhatsApp — hands the contact relationship to a
//  third party, which is the exact thing RAVEN claims not to do.
//
//  This carries a short-lived random token instead. The token holds no identity
//  and no keys; it only addresses a DHT rendezvous and derives the AEAD key that
//  seals the cards in transit. WhatsApp sees an opaque string with a ten-minute
//  life, not a userId and two public keys valid for 24 hours.
//
//  DESIGN NOTE — the card on the wire is the SAME signed payload the QR encodes
//  (`raven://friend?v=2&d=…`). That is deliberate: `FriendQRPayload.parseAndVerify`
//  already enforces the Ed25519 signature, the freshness window, AND the
//  serverless identity binding (userId == fingerprint(identityKey)) that stops
//  an attacker self-signing a card carrying a victim's userId. Inventing a
//  second card format would mean a second, less-reviewed trust path. This adds a
//  transport, not a trust model.
//

import Foundation
import SwiftUI
import CryptoKit

@MainActor
@Observable
final class RemoteInviteService {

    static let shared = RemoteInviteService()

    /// Default invite lifetime. Long enough to read a link to someone on a call,
    /// short enough that a captured token is dead before it is useful. The Go
    /// side clamps to [60, 3600] regardless.
    static let defaultTTLSeconds: Int = 10 * 60

    enum InviteError: LocalizedError {
        case noLocalIdentity
        case bridgeUnavailable
        case malformedToken
        case peerCardRejected
        case selfInvite

        var errorDescription: String? {
            switch self {
            case .noLocalIdentity:
                return "No local identity yet — finish sign-in first."
            case .bridgeUnavailable:
                return "The serverless bridge isn't connected. Check your internet connection."
            case .malformedToken:
                return "That invite code isn't valid."
            case .peerCardRejected:
                // Deliberately blunt: this is the anti-impersonation path.
                return "The other device's identity could not be verified. The invite was NOT accepted."
            case .selfInvite:
                return "That's your own invite code."
            }
        }
    }

    /// The token currently being advertised, if any.
    private(set) var activeToken: String?
    /// Set when a peer completes the exchange against our invite.
    private(set) var lastAcceptedPeer: FriendQRPayload?

    /// A verified card awaiting the inviter's explicit approval.
    ///
    /// 🔴 The inviter used to be trusted automatically: whoever redeemed the
    /// token was pinned `.trusted` before any UI appeared. Since the token
    /// travels through a third-party channel — which is the whole point — that
    /// meant anyone who saw it in transit could win the race and become a
    /// trusted contact silently. The QR path has always required an explicit
    /// confirmation step; this brings the remote path to parity.
    private(set) var pendingApproval: FriendQRPayload?

    private init() {
        LibP2PBridgeTransport.shared.onInviteRedeemedHandler = { [weak self] token, cardJSON in
            Task { @MainActor in
                await self?.handleRedeemedByPeer(token: token, cardJSON: cardJSON)
            }
        }
    }

    // MARK: - Card

    /// Build our signed contact card — byte-identical to what `MyQRCodeView`
    /// puts in the QR, including `issuedAt` and the Ed25519 signature over the
    /// canonical transcript, so the receiver's `parseAndVerify` applies unchanged.
    func buildMyCard() async -> String? {
        guard let userId = await KeychainService.shared.getUserId(), !userId.isEmpty else {
            return nil
        }
        let agreementB64 = DeviceIdentityService.shared.agreementPublicKeyData?.base64EncodedString()
        let identityB64 = DeviceIdentityService.shared.publicKeyBase64
        let fingerprint = DeviceIdentityService.shared.fingerprint
        let now = Date().timeIntervalSince1970

        let transcript = FriendQRPayload.canonicalTranscript(
            userId: userId,
            agreementPubBase64: agreementB64,
            identityPubBase64: identityB64,
            issuedAt: now
        )
        guard let signatureB64 = DeviceIdentityService.shared.sign(transcript)?.base64EncodedString() else {
            return nil
        }
        let payload = FriendQRPayload(
            userId: userId,
            displayName: AuthService.shared.currentUser?.displayName,
            username: AuthService.shared.currentUser?.username,
            agreementPubBase64: agreementB64,
            identityPubBase64: identityB64,
            fingerprint: fingerprint,
            issuedAt: now,
            signatureB64: signatureB64
        )
        return payload.toQRString()
    }

    // MARK: - Create (inviter)

    /// Publish a rendezvous and return the link to hand to the other person.
    func createInvite(ttlSeconds: Int = defaultTTLSeconds) async throws -> String {
        guard let card = await buildMyCard() else { throw InviteError.noLocalIdentity }
        do {
            let token = try LibP2PBridgeTransport.shared.createInvite(
                cardJSON: card,
                ttlSeconds: ttlSeconds
            )
            activeToken = token
            lastAcceptedPeer = nil
            return token
        } catch {
            throw InviteError.bridgeUnavailable
        }
    }

    /// Stop advertising. Called on cancel, on accept, and when the sheet closes —
    /// an invite that outlives its UI is a rendezvous nobody is watching.
    func cancelActiveInvite() {
        guard let token = activeToken else { return }
        try? LibP2PBridgeTransport.shared.cancelInvite(token)
        activeToken = nil
    }

    /// A peer completed the exchange against our invite. Their card arrives
    /// UNVERIFIED — verify before trusting a single field of it.
    private func handleRedeemedByPeer(token: String, cardJSON: String) async {
        guard token == activeToken else { return }
        guard let verified = FriendQRPayload.parseAndVerify(cardJSON) else {
            // Signature, freshness, or identity-binding failed. Leave the invite
            // live: the legitimate peer may still be on their way.
            #if DEBUG
            print("🟡 [RemoteInvite] redeemer card REJECTED by parseAndVerify")
            #endif
            return
        }
        guard let myId = await KeychainService.shared.getUserId(),
              verified.userId != myId else { return }

        // Stop advertising the moment a valid card arrives — the token is
        // single-use. Otherwise a second party who also saw the token could
        // redeem it afterwards, and the inviter would be approving one contact
        // while another quietly completed the same exchange.
        cancelActiveInvite()

        // Do NOT trust yet. Surface for approval; `approvePending()` commits.
        pendingApproval = verified
    }

    /// Commit a pending redeemer after the user has approved them.
    func approvePending() async {
        guard let card = pendingApproval else { return }
        pendingApproval = nil
        await applyVerifiedCard(card)
        lastAcceptedPeer = card
    }

    /// Discard a pending redeemer. Nothing was trusted, so there is nothing to
    /// undo — the invite is already cancelled.
    func rejectPending() {
        pendingApproval = nil
    }

    // MARK: - Redeem (invitee)

    /// Redeem an invite token or `raven://i/<token>` link. Returns the peer's
    /// verified card; throws if it cannot be verified.
    @discardableResult
    func redeem(_ tokenOrLink: String) async throws -> FriendQRPayload {
        let token = Self.normalizeToken(tokenOrLink)
        guard !token.isEmpty else { throw InviteError.malformedToken }
        if token == activeToken { throw InviteError.selfInvite }

        guard let myCard = await buildMyCard() else { throw InviteError.noLocalIdentity }

        let peerCardJSON: String
        do {
            peerCardJSON = try LibP2PBridgeTransport.shared.redeemInvite(
                token: token,
                myCardJSON: myCard
            )
        } catch {
            throw InviteError.bridgeUnavailable
        }

        // The rendezvous proves possession of the token — nothing more. Identity
        // rests entirely on this check.
        guard let verified = FriendQRPayload.parseAndVerify(peerCardJSON) else {
            throw InviteError.peerCardRejected
        }
        if let myId = await KeychainService.shared.getUserId(), verified.userId == myId {
            throw InviteError.selfInvite
        }

        await applyVerifiedCard(verified)
        return verified
    }

    /// Accept `raven://i/<token>`, a bare token, or either with stray whitespace.
    static func normalizeToken(_ input: String) -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "raven://i/") {
            s = String(s[r.upperBound...])
        }
        // Tolerate a trailing query/fragment if the link was pasted from a
        // messenger that decorated it.
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            s = String(s[..<cut])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shareable form of the active token.
    static func link(for token: String) -> String { "raven://i/\(token)" }

    // MARK: - Apply

    /// Pin the verified peer exactly the way a QR scan does — same repositories,
    /// same trust state. `parseAndVerify` has already bound userId to the
    /// identity-key fingerprint, which is what makes pinning safe here.
    private func applyVerifiedCard(_ payload: FriendQRPayload) async {
        guard let identityB64 = payload.identityPubBase64,
              let identityKey = Data(base64Encoded: identityB64) else { return }
        let agreementKey = payload.agreementPubBase64
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { $0.count == 32 ? $0 : nil }

        let device = FriendDevice(
            friendUserId: payload.userId,
            // 🔴 ALWAYS derive; never trust `payload.fingerprint`.
            //
            // That field is NOT covered by the card's signature —
            // `FriendQRPayload.canonicalTranscript` signs only userId,
            // agreementPub, identityPub and issuedAt — yet
            // `friend_devices.fingerprint` is `TEXT NOT NULL UNIQUE` under an
            // INSERT OR REPLACE. So a card that is otherwise perfectly valid
            // could name an EXISTING contact's fingerprint and delete that
            // contact's trust row, silently erasing an established
            // relationship (and turning that friend back into a first-contact
            // TOFU target). Deriving from the signed identity key removes the
            // attacker's influence entirely.
            fingerprint: DeviceIdentityService.deriveFingerprint(from: identityKey),
            publicKey: identityKey,
            agreementPublicKey: agreementKey,
            // Same justification as a QR scan: the token travelled out-of-band
            // and `parseAndVerify` bound userId to the identity-key fingerprint.
            trustState: .trusted,
            verifiedAt: Date(),
            deviceName: payload.displayName ?? payload.username
        )
        try? await FriendDeviceRepository.shared.upsert(device)

        // Seed the serverless readers: the mesh sealer (ensureAgreementKey) and
        // the libp2p PeerID resolver (identityKey).
        await PeerKeyDirectory.shared.setVerifiedIdentity(
            identityKey: identityKey,
            agreementKey: agreementKey,
            for: payload.userId
        )

        // Resolve this peer's sealed-sender hash on inbound mesh frames — the
        // same gap the ATSAM pair path had.
        await MeshIdentityResolver.shared.register(userId: payload.userId)
    }
}
