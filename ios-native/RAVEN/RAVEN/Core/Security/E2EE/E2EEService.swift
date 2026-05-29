//
//  E2EEService.swift
//  RAVEN
//
//  Public façade over the Double-Ratchet + X3DH internals. Other parts
//  of the app (MessageStore, MeshTransport, etc.) talk to *this* class
//  and never see ratchet state directly.
//
//  Threading: serialised per-peer via the actor. Multiple peers can
//  encrypt/decrypt concurrently; messages for the same peer queue.
//
//  Integration points (Phase 2 wiring — not yet enabled in production):
//   • Outgoing text/media body → encrypt(toPeer:plaintext:) → wire blob
//   • Incoming wire blob → decrypt(fromPeer:wireBlob:) → text/media body
//   • Same path works for server-routed AND mesh-routed messages — the
//     ratchet doesn't know about transport.
//
//  Hard rule: this service NEVER reads or writes plaintext over the
//  network. It only ever produces or consumes opaque blobs.
//

import Foundation
import CryptoKit

/// Identifies a specific device of a specific user.
struct PeerAddress: Hashable, Codable {
    let userId: String
    let deviceId: String
}

/// Outbound wire format. One of:
///   • `.x3dh` — first message to a brand-new peer; carries enough
///     parameters for the recipient to derive SK and bootstrap their
///     ratchet state.
///   • `.message` — every subsequent message in an established session.
enum E2EEWirePacket: Codable, Equatable {
    case x3dh(X3DHInitialMessage)
    case message(RatchetCiphertext)

    enum Kind: String, Codable { case x3dh, message }
    enum CodingKeys: String, CodingKey { case kind, payload }

    var kind: Kind {
        switch self {
        case .x3dh:    return .x3dh
        case .message: return .message
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .x3dh:
            self = .x3dh(try c.decode(X3DHInitialMessage.self, forKey: .payload))
        case .message:
            self = .message(try c.decode(RatchetCiphertext.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .x3dh(let m):    try c.encode(m, forKey: .payload)
        case .message(let m): try c.encode(m, forKey: .payload)
        }
    }
}

// MARK: - Service

actor E2EEService {
    static let shared = E2EEService()

    private let store = RatchetSessionStore.shared
    private var bundleProvider: PreKeyBundleProvider?

    /// Per-peer task chains. The Double-Ratchet state is *mutable*
    /// per-message, so two concurrent encrypts for the same peer
    /// would otherwise race at the `await store.loadSession` /
    /// `await store.saveSession` suspension points: both could load
    /// the same starting state, both encrypt with header.n=N, then
    /// the receiver only manages to decrypt one (the other's key
    /// has already been consumed). We avoid that by chaining each
    /// peer's encrypts through a single `Task` so they execute
    /// strictly in order.
    ///
    /// The chain is per-peer to keep cross-peer throughput
    /// unaffected — encryption for Bob never blocks encryption for
    /// Alice.
    private var encryptChain: [PeerAddress: Task<Void, Never>] = [:]
    private var decryptChain: [PeerAddress: Task<Void, Never>] = [:]

    /// Plug in the bundle source (server REST + mesh advertisement) at
    /// app boot. The provider is deliberately injected so the same
    /// service works in tests with a stubbed bundle source.
    func configure(bundleProvider: PreKeyBundleProvider) {
        self.bundleProvider = bundleProvider
    }

    /// Wait for the prior in-flight encrypt for this peer (if any)
    /// to drain. Returns immediately if no task is queued.
    private func awaitPriorEncrypt(for peer: PeerAddress) async {
        if let prior = encryptChain[peer] {
            await prior.value
        }
    }
    private func awaitPriorDecrypt(for peer: PeerAddress) async {
        if let prior = decryptChain[peer] {
            await prior.value
        }
    }
    private func recordEncrypt(for peer: PeerAddress, task: Task<Void, Never>) {
        encryptChain[peer] = task
    }
    private func recordDecrypt(for peer: PeerAddress, task: Task<Void, Never>) {
        decryptChain[peer] = task
    }

    // MARK: - Public API: encrypt

    /// Encrypt a plaintext payload for a specific peer device. If we
    /// have no session yet, automatically performs X3DH using a
    /// freshly-fetched bundle and returns the X3DH-flavoured packet
    /// (which the receiver auto-detects).
    ///
    /// `associatedData` lets the caller bind extra context (room id,
    /// timestamp, etc.) to the AEAD tag — opportunistic protection
    /// against header substitution beyond what the ratchet itself
    /// already provides.
    func encrypt(
        toPeer peer: PeerAddress,
        plaintext: Data,
        associatedData: Data = Data()
    ) async throws -> E2EEWirePacket {
        // Wait for any prior encrypt for this peer to finish before
        // we touch the session state. See `encryptChain` doc above
        // for why this is necessary.
        await awaitPriorEncrypt(for: peer)

        // Wrap the actual work in a Task so we can install the
        // continuation pointer synchronously (within actor
        // isolation) before any awaits happen inside.
        let work: Task<E2EEWirePacket, Error> = Task { [self] in
            try await self.encryptInternal(
                toPeer: peer,
                plaintext: plaintext,
                associatedData: associatedData
            )
        }
        // Bookkeeping task for the chain — we don't care about its
        // value, only that it completes after `work` does so the
        // next encrypt knows we're done.
        let bookkeeper = Task<Void, Never> {
            _ = try? await work.value
        }
        recordEncrypt(for: peer, task: bookkeeper)

        defer {
            // Once we're past, clear the chain pointer if it's still
            // ours so the dictionary doesn't grow unbounded. `Task`
            // is Hashable so we can compare via `==`.
            if encryptChain[peer] == bookkeeper {
                encryptChain.removeValue(forKey: peer)
            }
        }
        return try await work.value
    }

    /// The actual encrypt body. Called inside a per-peer chain so
    /// concurrent calls for the same peer never interleave.
    private func encryptInternal(
        toPeer peer: PeerAddress,
        plaintext: Data,
        associatedData: Data
    ) async throws -> E2EEWirePacket {

        // 1. Existing session?
        if var state = try await store.loadSession(
            peerUserId: peer.userId,
            peerDeviceId: peer.deviceId
        ) {
            let ct = try DoubleRatchet.encrypt(
                state: &state,
                plaintext: plaintext,
                associatedData: associatedData
            )
            try await store.saveSession(
                peerUserId: peer.userId,
                peerDeviceId: peer.deviceId,
                state: state
            )
            return .message(ct)
        }

        // 2. No session — bootstrap via X3DH.
        guard let bundleProvider = bundleProvider else {
            throw RatchetError.sessionNotInitialised
        }
        let bundle = try await bundleProvider.fetchBundle(for: peer)
        guard bundle.verifySignature() else {
            throw RatchetError.bundleVerificationFailed
        }

        guard let identityAgreementKeyData = try await loadIdentityAgreementPrivate() else {
            throw RatchetError.sessionNotInitialised
        }
        let identityPriv = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: identityAgreementKeyData
        )

        let x3dh = try X3DH.initiate(
            ourIdentityAgreementPrivateKey: identityPriv,
            peerBundle: bundle
        )

        var state = try RatchetState.initialiseAsInitiator(
            sharedSecret: x3dh.sharedSecret,
            peerSignedPreKey: bundle.signedPreKey.publicKey
        )
        let ct = try DoubleRatchet.encrypt(
            state: &state,
            plaintext: plaintext,
            associatedData: associatedData
        )
        try await store.saveSession(
            peerUserId: peer.userId,
            peerDeviceId: peer.deviceId,
            state: state
        )

        guard let ourIdentityKey = DeviceIdentityService.shared.publicKeyData,
              let ourIdentityAgreementKey = DeviceIdentityService.shared.agreementPublicKeyData else {
            throw RatchetError.sessionNotInitialised
        }
        return .x3dh(X3DHInitialMessage(
            identityKey: ourIdentityKey,
            identityAgreementKey: ourIdentityAgreementKey,
            ephemeralKey: x3dh.ephemeralPublicKey,
            signedPreKeyId: x3dh.usedSignedPreKeyId,
            oneTimePreKeyId: x3dh.usedOneTimePreKeyId,
            firstCiphertext: ct
        ))
    }

    // MARK: - Public API: decrypt

    /// Decrypt a wire packet from a peer. Auto-handles the X3DH
    /// bootstrap on first contact.
    func decrypt(
        fromPeer peer: PeerAddress,
        wirePacket: E2EEWirePacket,
        associatedData: Data = Data()
    ) async throws -> Data {
        // Mirror of `encrypt`: serialise per-peer decrypts so that
        // out-of-order delivery is handled by the Double Ratchet's
        // own skipped-keys cache (a single source of truth) instead
        // of by interleaved actor calls fighting over the same
        // session state.
        await awaitPriorDecrypt(for: peer)

        let work: Task<Data, Error> = Task { [self] in
            try await self.decryptInternal(
                fromPeer: peer,
                wirePacket: wirePacket,
                associatedData: associatedData
            )
        }
        let bookkeeper = Task<Void, Never> {
            _ = try? await work.value
        }
        recordDecrypt(for: peer, task: bookkeeper)

        defer {
            if decryptChain[peer] == bookkeeper {
                decryptChain.removeValue(forKey: peer)
            }
        }
        return try await work.value
    }

    /// The actual decrypt body. Always invoked through the per-peer
    /// chain in `decrypt`.
    private func decryptInternal(
        fromPeer peer: PeerAddress,
        wirePacket: E2EEWirePacket,
        associatedData: Data
    ) async throws -> Data {

        switch wirePacket {

        case .message(let ct):
            guard var state = try await store.loadSession(
                peerUserId: peer.userId,
                peerDeviceId: peer.deviceId
            ) else {
                throw RatchetError.sessionNotInitialised
            }
            let plaintext = try DoubleRatchet.decrypt(
                state: &state,
                ciphertext: ct,
                associatedData: associatedData
            )
            try await store.saveSession(
                peerUserId: peer.userId,
                peerDeviceId: peer.deviceId,
                state: state
            )
            return plaintext

        case .x3dh(let initMsg):
            // Find the matching SPK and OPK.
            guard let spk = try await store.signedPreKey(id: initMsg.signedPreKeyId) else {
                throw RatchetError.bundleVerificationFailed
            }
            let opk: OneTimePreKeyPrivate?
            if let opkId = initMsg.oneTimePreKeyId {
                opk = try await store.consumeOneTimePreKey(id: opkId)
            } else {
                opk = nil
            }

            guard let identityAgreementKeyData = try await loadIdentityAgreementPrivate() else {
                throw RatchetError.sessionNotInitialised
            }
            let identityPriv = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: identityAgreementKeyData
            )
            let spkPriv = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: spk.privateKey
            )
            let opkPriv = try opk.map {
                try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0.privateKey)
            }

            // Reproduce the X3DH shared secret using the peer's
            // *agreement* (X25519) identity key — the Ed25519 identity
            // key in the same message is reserved for trust binding
            // at higher layers (TOFU), not the DH math.
            let sk = try X3DH.respond(
                ourIdentityAgreementPrivateKey: identityPriv,
                ourSignedPreKeyPrivate: spkPriv,
                ourOneTimePreKeyPrivate: opkPriv,
                peerIdentityAgreementKey: initMsg.identityAgreementKey,
                peerEphemeralKey: initMsg.ephemeralKey
            )
            var state = RatchetState.initialiseAsResponder(
                sharedSecret: sk,
                ourSignedPreKeyPrivate: spkPriv
            )
            let plaintext = try DoubleRatchet.decrypt(
                state: &state,
                ciphertext: initMsg.firstCiphertext,
                associatedData: associatedData
            )
            try await store.saveSession(
                peerUserId: peer.userId,
                peerDeviceId: peer.deviceId,
                state: state
            )
            return plaintext
        }
    }

    // MARK: - Bundle generation (publish our keys)

    /// Build the public bundle to upload to the server (or advertise
    /// over mesh). Rotates the signed pre-key if there isn't one.
    func currentPublicBundle(
        userId: String,
        deviceId: String,
        ensureOneTimePool minimum: Int = 20
    ) async throws -> PreKeyBundle {

        // Make sure we have a signed pre-key.
        let spk: SignedPreKeyPrivate
        if let cur = try await store.currentSignedPreKey() {
            spk = cur
        } else {
            spk = try await store.rotateSignedPreKey()
        }

        // Top up one-time pool if needed.
        let unused = try await store.unusedOneTimePreKeyCount()
        if unused < minimum {
            _ = try await store.generateOneTimePreKeys(count: minimum - unused)
        }

        // Pop one OPK to bundle. (The server normally manages this
        // pop; for self-tests / mesh advertisement we attach one
        // ourselves.)
        let opkRow = try await store.unusedOneTimePreKeyCount() > 0
            ? try await firstAvailableOneTimePreKey()
            : nil

        guard let identityKey = DeviceIdentityService.shared.publicKeyData,
              let identityAgreementKey = DeviceIdentityService.shared.agreementPublicKeyData else {
            throw RatchetError.sessionNotInitialised
        }

        return PreKeyBundle(
            userId: userId,
            deviceId: deviceId,
            identityKey: identityKey,
            identityAgreementKey: identityAgreementKey,
            signedPreKey: SignedPreKeyPublic(
                id: spk.id,
                publicKey: spk.publicKey,
                signature: spk.signature,
                createdAt: spk.createdAt
            ),
            oneTimePreKey: opkRow.map {
                OneTimePreKeyPublic(id: $0.id, publicKey: $0.publicKey)
            },
            createdAt: Date().timeIntervalSince1970
        )
    }

    private func firstAvailableOneTimePreKey() async throws -> OneTimePreKeyPrivate? {
        // Light helper — the full pool query lives in the store; we
        // just grab one without consuming.
        // (Using the store's query path directly would expose more API
        // than necessary, so we just re-use the count + a fresh fetch.)
        let db = DatabaseService.shared
        let rows = try await db.query(
            "SELECT id, private_key, public_key FROM e2ee_onetime_prekeys WHERE consumed = 0 ORDER BY id ASC LIMIT 1",
            params: []
        )
        guard let row = rows.first,
              let id = row["id"] as? Int64,
              let priv = row["private_key"] as? Data,
              let pub  = row["public_key"]  as? Data else {
            return nil
        }
        return OneTimePreKeyPrivate(
            id: UInt32(truncatingIfNeeded: id),
            privateKey: priv,
            publicKey: pub
        )
    }

    // MARK: - Helpers

    /// Pull the X25519 identity agreement private key out of the
    /// Keychain. DeviceIdentityService manages it — we use a small
    /// extension on it (see bottom of file) to expose just the bytes.
    private func loadIdentityAgreementPrivate() async throws -> Data? {
        return DeviceIdentityService.shared.agreementPrivateKeyData
    }
}

// MARK: - Bundle Provider abstraction

/// Source of peer pre-key bundles. In production this is the network
/// layer; in tests it's a stub that returns a constant bundle.
///
/// We don't require `Sendable` here — calls happen inside the
/// E2EEService actor, so isolation is the actor's responsibility.
/// Implementers should still ensure thread safety internally.
protocol PreKeyBundleProvider: AnyObject {
    func fetchBundle(for peer: PeerAddress) async throws -> PreKeyBundle
}
