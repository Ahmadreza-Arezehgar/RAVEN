//
//  ContactRequestInboxViewModel.swift
//  RAVEN — Accept / Decline / Block for inbound RavenContactRequestV1.
//

import Foundation
import CryptoKit
import Observation
import Security

@MainActor
@Observable
final class ContactRequestInboxViewModel {
    var pending: [PendingContactRequest] = []
    var statusMessage: String?
    var petnameDraft: [String: String] = [:] // requestId hex → petname
    var isBusy: Bool = false

    var isEnabled: Bool { FeatureFlag.isRavenEnvelopeV1Enabled }

    func reload() {
        guard isEnabled else {
            pending = []
            statusMessage = "Enable RavenEnvelopeV1 for contact-request inbox"
            return
        }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            pending = []
            statusMessage = "Missing local identity"
            return
        }
        let addr = RavenAddressV1.encode(ed25519PublicKey: key.publicKey.rawRepresentation) ?? ""
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let inbox = ContactRequestInboxStore.buildInbox(
            recipientKey: key,
            recipientAddr: addr,
            nowMs: now
        )
        pending = inbox.pending
        statusMessage = pending.isEmpty
            ? "No pending contact requests"
            : "\(pending.count) pending — Accept binds raven_id + petname"
    }

    /// Ingest opaque wire body from LAN/BLE delivery (Bridge never decrypts).
    @discardableResult
    func ingestWire(_ wire: Data) -> Bool {
        guard isEnabled else { return false }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              let outer = try? RavenContactRequestV1.decodeWire(wire) else {
            return false
        }
        let addr = RavenAddressV1.encode(ed25519PublicKey: key.publicKey.rawRepresentation) ?? ""
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var inbox = ContactRequestInbox()
        do {
            _ = try inbox.ingest(
                outer: outer,
                recipientSigningKey: key,
                recipientAddr: addr,
                nowMs: now
            )
            ContactRequestInboxStore.upsertWire(wire)
            reload()
            return true
        } catch {
            return false
        }
    }

    func accept(requestId: Data) async throws {
        guard isEnabled else { throw RavenContactRequestError.missingKeys }
        let hex = requestId.ravenHex
        let pet = (petnameDraft[hex] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pet.isEmpty else { throw RavenContactRequestError.petnameRequired }
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            throw RavenContactRequestError.missingKeys
        }
        let addr = RavenAddressV1.encode(ed25519PublicKey: key.publicKey.rawRepresentation) ?? ""
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var inbox = ContactRequestInboxStore.buildInbox(
            recipientKey: key,
            recipientAddr: addr,
            nowMs: now
        )
        let outcome = try inbox.accept(
            requestId: requestId,
            accepterKey: key,
            petname: pet,
            nowMs: now
        )
        try outcome.accept.verify()

        // Bind local contact (raven_id + petname); verification = trusted contact.
        DiscoveryContactBindingStore.upsert(LocalDiscoveryContact(
            ravenId: outcome.binding.ravenId,
            pubHex: outcome.binding.pubHex,
            petname: outcome.binding.petname,
            publicTag: "",
            displayName: outcome.binding.petname,
            pinned: false,
            directlyVerified: false
        ))
        ContactRequestInboxStore.remove(requestId: requestId)

        await deliverAccept(outcome.accept, signingKey: key)
        petnameDraft.removeValue(forKey: hex)
        reload()
        statusMessage = "Accepted — bound \(pet)"
    }

    func decline(requestId: Data) throws {
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            throw RavenContactRequestError.missingKeys
        }
        let addr = RavenAddressV1.encode(ed25519PublicKey: key.publicKey.rawRepresentation) ?? ""
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var inbox = ContactRequestInboxStore.buildInbox(
            recipientKey: key,
            recipientAddr: addr,
            nowMs: now
        )
        try inbox.decline(requestId: requestId)
        ContactRequestInboxStore.remove(requestId: requestId)
        reload()
        statusMessage = "Declined"
    }

    func block(requestId: Data) throws {
        guard let seed = DeviceIdentityService.shared.deviceSigningSeed,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            throw RavenContactRequestError.missingKeys
        }
        let addr = RavenAddressV1.encode(ed25519PublicKey: key.publicKey.rawRepresentation) ?? ""
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var inbox = ContactRequestInboxStore.buildInbox(
            recipientKey: key,
            recipientAddr: addr,
            nowMs: now
        )
        let pubHex = try inbox.block(requestId: requestId)
        DiscoveryBlockStore.block(pubHex)
        ContactRequestInboxStore.remove(requestId: requestId)
        reload()
        statusMessage = "Blocked locally"
    }

    private func deliverAccept(
        _ accept: ContactAcceptV1,
        signingKey: Curve25519.Signing.PrivateKey
    ) async {
        let wire = accept.encodeWire()
        let messageId = accept.requestId
        let routingTag = Data(SHA256.hash(data: wire.prefix(64) + messageId)).prefix(16)
        let env = RavenServerlessLanPath.packSealedMessage(
            sealedBody: wire,
            messageId: messageId,
            routingTag: Data(routingTag),
            signingKey: signingKey
        )
        let packed = env.pack()
        if BLEMeshEngine.shared.hasActiveConnections {
            await BLEMeshEngine.shared.enqueueRawRavenEnvelopeV1(packed)
        }
        if let cfg = RavenServerlessLanConfig.stored {
            _ = try? await RavenServerlessLanPath.sendEnvelope(env, host: cfg.host, port: cfg.port)
        }
    }
}
