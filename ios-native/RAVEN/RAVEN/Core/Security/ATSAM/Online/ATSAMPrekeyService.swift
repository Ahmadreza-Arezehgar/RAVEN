//
//  ATSAMPrekeyService.swift
//  RAVEN — ATSAM Phase B: online pair-init
//
//  Thin REST client around the server's `/api/atsam` endpoints.
//  Handles publish + fetch of ATSAM hybrid pre-key bundles plus
//  pair-init queue I/O.
//
//  All key material on the wire is BASE64-encoded — matches the
//  shape the server stores. Decoding to raw bytes happens here so
//  the higher-level pair coordinator (`ATSAMOnlinePairView`)
//  works in `Data` and never touches base64 plumbing.
//
//  Server-side spec lives in `server/routers/atsam_prekey.py`.
//

import Foundation

/// Top-level facade. Internally uses the existing `NetworkService`
/// actor for actual HTTP, so it picks up the same auth token +
/// retry behaviour as every other REST call in the app.
enum ATSAMPrekeyService {

    // MARK: - Wire DTOs (mirror server schema 1:1)

    // 🟥 ROUND 33 follow-up (2026-05-17) — DTO key style.
    //
    // NetworkService's shared JSONDecoder is configured with
    // `.convertFromSnakeCase` (NetworkService.swift line 371) and
    // the encoder with `.convertToSnakeCase` (line 375).  Until
    // this round the DTOs below used snake_case Swift property
    // names directly — which got DOUBLE-translated and broke the
    // round-trip:
    //   • Decode: server JSON "user_id" → decoder treats it as
    //     wire-snake → maps to Swift "userId" → no such property
    //     "userId" in BundleDTO (which has "user_id") → throws
    //     "Key not found: user_id".  This was the user's smoking
    //     gun: `❌ DECODE ERROR for BundleDTO`.
    //   • Encode: less visible because convertToSnakeCase is a
    //     no-op on already-snake_case names, but conceptually
    //     wrong.
    //
    // Fix: rename to camelCase so the JSON/Swift mapping is
    // symmetric with every other DTO in the codebase.

    struct PublishRequest: Encodable, Sendable {
        let deviceId: String
        let x25519Pub: String        // base64
        let mlKemPub: String         // base64
        let signedBy: String         // base64 Ed25519 pub
        let signature: String        // base64 signature
        let atsamVersion: Int
    }

    struct PublishResponse: Decodable, Sendable {
        let ok: Bool
    }

    struct BundleDTO: Decodable, Sendable {
        let userId: String
        let deviceId: String
        let x25519Pub: String
        let mlKemPub: String
        let signedBy: String
        let signature: String
        let atsamVersion: Int
    }

    struct PairInitDTO: Decodable, Sendable, Identifiable {
        let id: Int
        let fromUser: String
        let toUser: String
        let x25519Pub: String
        let mlKemPub: String
        let mlKemCt: String
        let pairingNonce: String
        let context: String
        let createdAt: Double
    }

    struct SubmitPairInitRequest: Encodable, Sendable {
        let toUser: String
        let x25519Pub: String
        let mlKemPub: String
        let mlKemCt: String
        let pairingNonce: String
        let context: String
    }

    struct SubmitPairInitResponse: Decodable, Sendable {
        let id: Int
    }

    struct AckResponse: Decodable, Sendable {
        let ok: Bool
    }

    // MARK: - Errors

    enum PrekeyError: Error {
        case missingMLKem
        case missingDeviceID
        case base64DecodeFailed(field: String)
    }

    // MARK: - Decoded form (caller-friendly)

    /// Bundle with key bytes already base64-decoded, ready to pass
    /// into `ATSAMHybridPairing.pairAsInitiator(...)`.
    struct DecodedBundle: Sendable {
        let userId: String
        let deviceId: String
        let xPub: Data
        let pqPub: Data
        let signedBy: Data
        let signature: Data
        let atsamVersion: Int
    }

    // MARK: - Auto-publish (silent, on every launch)
    //
    // 🟥 ROUND 33 (2026-05-17) — silent auto-publish at app launch.
    //
    // Until this round the publish path was buried behind a manual
    // "Publish My Bundle" button in `ATSAMOnlinePairView`.  Most
    // users never visited that screen.  Consequence:
    //   • Server returns 404 for `/api/atsam/prekey/{userId}`.
    //   • `PeerKeyDirectory.ensureAgreementKey` returns nil.
    //   • `MessageContentSealer.seal` silently falls back to RVNP1
    //     plaintext.  Text messages ship UNENCRYPTED on the wire.
    //   • Vault attachment encrypt explicitly REFUSES the fallback
    //     and the user sees "Vault couldn't get the recipient's
    //     encryption key" — exactly the screenshot the user
    //     reported with `fetchBundle(...) failed: Not found`.
    //
    // Fix: publish the device's STABLE X25519 + Ed25519 keys to
    // `/api/atsam/prekey/publish` on every launch (idempotent on
    // server side, so re-publishing is cheap).  Throttled to one
    // attempt per launch so a transient network blip doesn't spam.
    //
    // The previous scaffold used an EPHEMERAL Ed25519 key per
    // publish call (see `ATSAMOnlinePairView.publishLocalBundle`
    // line 254 — "For the scaffold we sign the bundle with an
    // ephemeral Ed25519 key derived from a fixed identifier.")
    // That meant signature verification ON THE READ PATH would
    // fail because each publish used a different signing key.
    // We sign with the device's STABLE identity key here so the
    // strong-format `userId || xPub || pqPub` verify in
    // PeerKeyDirectory.fetchAndVerifyFromServer succeeds.

    /// Set after the first successful auto-publish per launch so
    /// repeated app foreground events don't re-spam the server.
    /// `static` is fine here — `ATSAMPrekeyService` is an enum.
    private static var autoPublishSucceededThisLaunch = false

    /// Publish the device's stable bundle if we haven't already
    /// done so this session.  Safe to call from app launch + on
    /// every foreground transition — idempotent after first
    /// success, retries on previous-failure.  All errors are
    /// swallowed and logged; never throws to the caller so launch
    /// flow can't be blocked by a publish hiccup.
    @discardableResult
    static func autoPublishIfNeeded() async -> Bool {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return false }
        if autoPublishSucceededThisLaunch { return true }

        NSLog("🔑 [ATSAMAutoPublish] starting…")

        // 1. Resolve userId — without a logged-in user we have
        //    nothing to publish for.
        guard let userId = await KeychainService.shared.getUserId(),
              !userId.isEmpty else {
            NSLog("🔑 [ATSAMAutoPublish] skipped — no userId in keychain (not logged in yet).")
            return false
        }

        // 2. Resolve the stable X25519 agreement public key from
        //    DeviceIdentityService.  This is the SAME key the
        //    receiver-side decrypt path expects to find on the
        //    server bundle.
        guard let xPub = DeviceIdentityService.shared.agreementPublicKeyData,
              xPub.count == 32 else {
            NSLog("🔑 [ATSAMAutoPublish] skipped — DeviceIdentityService has no agreement public key yet.")
            return false
        }

        // 3. Resolve the stable Ed25519 signing key (the device's
        //    persistent identity).  Sign the strong-format payload
        //    `"raven-bundle-v2" || 0x00 || userId || 0x00 || xPub || pqPub`
        //    — must match `PeerKeyDirectory.strongSignedPayload`
        //    byte-for-byte or the receiver's verify fails.
        let pqPub = Data()  // X25519-only for now; matches what the v1.7 chat path requires
        let signingPayload = Self.strongSignedBundlePayload(
            userId: userId,
            xPub: xPub,
            pqPub: pqPub
        )
        guard let signature = DeviceIdentityService.shared.sign(signingPayload),
              let identityKey = DeviceIdentityService.shared.publicKeyData else {
            NSLog("🔑 [ATSAMAutoPublish] skipped — DeviceIdentityService.sign returned nil (private key not loaded).")
            return false
        }

        // 4. Device ID — stable per app install via
        //    DeviceIdentityService.fingerprint (16 hex chars).
        let deviceId = DeviceIdentityService.shared.fingerprint
            ?? UUID().uuidString  // last-resort if fingerprint isn't ready

        // 5. Build the request directly (skipping ATSAMPairingKeys
        //    because that struct insists on a PRIVATE half we don't
        //    use here — we only need the published public bundle).
        let req = PublishRequest(
            deviceId: deviceId,
            x25519Pub: xPub.base64EncodedString(),
            mlKemPub: pqPub.base64EncodedString(),  // empty string when no PQ
            signedBy: identityKey.base64EncodedString(),
            signature: signature.base64EncodedString(),
            atsamVersion: 1
        )

        do {
            let _: PublishResponse = try await NetworkService.shared.post(
                path: "/api/atsam/prekey/publish",
                body: req
            )
            autoPublishSucceededThisLaunch = true
            NSLog("✅ [ATSAMAutoPublish] published bundle for user=%@ device=%@", String(userId.prefix(8)), String(deviceId.prefix(8)))
            return true
        } catch {
            NSLog("⚠️ [ATSAMAutoPublish] publish failed (will retry next launch): %@", error.localizedDescription)
            return false
        }
    }

    /// Local mirror of `PeerKeyDirectory.strongSignedPayload`.  We
    /// don't import the helper directly because PKD is an actor and
    /// this is a free function on an enum — same wire shape:
    ///   "raven-bundle-v2" || 0x00 || userId || 0x00 || xPub || pqPub
    private static func strongSignedBundlePayload(
        userId: String,
        xPub: Data,
        pqPub: Data
    ) -> Data {
        var out = Data()
        out.append(Data("raven-bundle-v2".utf8))
        out.append(0x00)
        out.append(Data(userId.utf8))
        out.append(0x00)
        out.append(xPub)
        out.append(pqPub)
        return out
    }

    // MARK: - Publish (self)

    /// Publish THIS device's hybrid bundle so peers can fetch it
    /// and initiate a pair. Idempotent on (current user, device_id).
    static func publishMyBundle(local: ATSAMPairingKeys,
                                deviceId: String,
                                identityKey: Data,
                                signature: Data) async throws {
        guard !local.pqPub.isEmpty else { throw PrekeyError.missingMLKem }
        guard !deviceId.isEmpty else { throw PrekeyError.missingDeviceID }

        let req = PublishRequest(
            deviceId: deviceId,
            x25519Pub: local.xPub.base64EncodedString(),
            mlKemPub: local.pqPub.base64EncodedString(),
            signedBy: identityKey.base64EncodedString(),
            signature: signature.base64EncodedString(),
            atsamVersion: 1
        )
        let _: PublishResponse = try await NetworkService.shared.post(
            path: "/api/atsam/prekey/publish",
            body: req
        )
    }

    // MARK: - Fetch (peer)

    /// Fetch a peer's bundle. Returns decoded bytes ready for
    /// the pairing call.
    static func fetchBundle(userId: String,
                            deviceId: String? = nil) async throws -> DecodedBundle {
        var queryItems: [URLQueryItem]? = nil
        if let deviceId, !deviceId.isEmpty {
            queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
        }
        let dto: BundleDTO = try await NetworkService.shared.get(
            path: "/api/atsam/prekey/\(userId)",
            queryItems: queryItems
        )
        guard let xPub = Data(base64Encoded: dto.x25519Pub) else {
            throw PrekeyError.base64DecodeFailed(field: "x25519Pub")
        }
        // Empty ml_kem_pub is valid for X25519-only devices (current
        // chat-layer Noise IK only needs X25519); only reject when
        // the base64 itself is malformed (Data(base64Encoded:) on
        // an empty string returns `Data()`, which is fine here).
        let pqPub = Data(base64Encoded: dto.mlKemPub) ?? Data()
        guard let signedBy = Data(base64Encoded: dto.signedBy) else {
            throw PrekeyError.base64DecodeFailed(field: "signedBy")
        }
        guard let signature = Data(base64Encoded: dto.signature) else {
            throw PrekeyError.base64DecodeFailed(field: "signature")
        }
        return DecodedBundle(
            userId: dto.userId,
            deviceId: dto.deviceId,
            xPub: xPub,
            pqPub: pqPub,
            signedBy: signedBy,
            signature: signature,
            atsamVersion: dto.atsamVersion
        )
    }

    // MARK: - Pair-init submission

    /// Deposit Alice's pair-init for Bob into the server queue.
    /// Bob fetches it on his next online.
    @discardableResult
    static func submitPairInit(toUserId: String,
                               local: ATSAMPairingKeys,
                               outgoingCiphertext: Data,
                               pairingNonce: Data,
                               context: String) async throws -> Int {
        let req = SubmitPairInitRequest(
            toUser: toUserId,
            x25519Pub: local.xPub.base64EncodedString(),
            mlKemPub: local.pqPub.base64EncodedString(),
            mlKemCt: outgoingCiphertext.base64EncodedString(),
            pairingNonce: pairingNonce.base64EncodedString(),
            context: context
        )
        let resp: SubmitPairInitResponse = try await NetworkService.shared.post(
            path: "/api/atsam/pair-init",
            body: req
        )
        return resp.id
    }

    // MARK: - Pair-init pickup

    /// Fetch the queue of pair-inits addressed to the current user.
    static func fetchPendingPairInits() async throws -> [PairInitDTO] {
        try await NetworkService.shared.get(path: "/api/atsam/pair-init")
    }

    /// Mark a pair-init as delivered after a successful local
    /// `pairAsResponder`. MUST be called or the same packet will
    /// be returned again on next poll.
    @discardableResult
    static func ackPairInit(id: Int) async throws -> Bool {
        struct Empty: Encodable {}
        let resp: AckResponse = try await NetworkService.shared.post(
            path: "/api/atsam/pair-init/\(id)/ack",
            body: Empty()
        )
        return resp.ok
    }
}
