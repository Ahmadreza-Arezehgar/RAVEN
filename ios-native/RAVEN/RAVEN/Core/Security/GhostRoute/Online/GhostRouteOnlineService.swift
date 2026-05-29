//
//  GhostRouteOnlineService.swift
//  RAVEN — Ghost Route online REST client
//
//  Thin wrapper around the existing `NetworkService` actor for
//  the three Ghost Route online endpoints:
//
//      POST /api/ghost-route/deposit  → deposit one envelope
//      POST /api/ghost-route/fetch    → fetch envelopes for a tag set
//      POST /api/ghost-route/ack      → mark envelopes delivered
//
//  Server-side spec lives in `server/routers/ghost_route.py`.
//

import Foundation

enum GhostRouteOnlineService {

    // MARK: - Wire DTOs (mirror server schema)

    struct DepositRequest: Encodable, Sendable {
        let recipient_tag: String  // base64 of 16-byte tag
        let envelope: String       // base64 of envelope bytes
    }

    struct DepositResponse: Decodable, Sendable {
        let id: Int
    }

    struct FetchRequest: Encodable, Sendable {
        let tags: [String]         // base64 of 16-byte tags
    }

    struct EnvelopeDTO: Decodable, Sendable, Identifiable {
        let id: Int
        let recipient_tag: String
        let envelope: String
        let deposited_at: Double
    }

    struct FetchResponse: Decodable, Sendable {
        let envelopes: [EnvelopeDTO]
    }

    struct AckRequest: Encodable, Sendable {
        let ids: [Int]
    }

    struct AckResponse: Decodable, Sendable {
        let acknowledged: Int
    }

    // MARK: - Errors

    enum ServiceError: Error {
        case base64DecodeFailed(field: String)
        case nothingToFetch
    }

    /// Convenience type returned by `fetch` after base64 decoding.
    struct DecodedEnvelope: Sendable, Equatable {
        let serverId: Int
        let recipientTag: Data    // 16 B raw
        let envelopeBytes: Data
        let depositedAt: Date
    }

    // MARK: - Deposit (send side)

    /// Deposit one Ghost Route envelope for a recipient. Returns
    /// the server-assigned id (useful for retries; not used for
    /// security).
    @discardableResult
    static func deposit(recipientTag: Data, envelopeBytes: Data) async throws -> Int {
        precondition(recipientTag.count == GRConstants.recipientTagBytes,
                     "recipientTag must be \(GRConstants.recipientTagBytes) B")
        let req = DepositRequest(
            recipient_tag: recipientTag.base64EncodedString(),
            envelope:      envelopeBytes.base64EncodedString()
        )
        let resp: DepositResponse = try await NetworkService.shared.post(
            path: "/api/ghost-route/deposit",
            body: req
        )
        return resp.id
    }

    // MARK: - Fetch (receive side)

    /// Fetch envelopes matching ANY of the given expected tags.
    /// Returns base64-decoded `DecodedEnvelope` values. The
    /// caller is responsible for matching server-ids back to
    /// the local cursor + acking them after successful decrypt.
    static func fetch(tags: [Data]) async throws -> [DecodedEnvelope] {
        if tags.isEmpty {
            throw ServiceError.nothingToFetch
        }
        let req = FetchRequest(tags: tags.map { $0.base64EncodedString() })
        let resp: FetchResponse = try await NetworkService.shared.post(
            path: "/api/ghost-route/fetch",
            body: req
        )
        return try resp.envelopes.map { dto in
            guard let tagBytes = Data(base64Encoded: dto.recipient_tag) else {
                throw ServiceError.base64DecodeFailed(field: "recipient_tag")
            }
            guard let envBytes = Data(base64Encoded: dto.envelope) else {
                throw ServiceError.base64DecodeFailed(field: "envelope")
            }
            return DecodedEnvelope(
                serverId: dto.id,
                recipientTag: tagBytes,
                envelopeBytes: envBytes,
                depositedAt: Date(timeIntervalSince1970: dto.deposited_at)
            )
        }
    }

    // MARK: - Ack

    /// Mark a set of envelope ids as delivered. MUST be called
    /// after a successful local decrypt of the matched envelope,
    /// or the server will re-serve the same envelopes on every
    /// poll.
    @discardableResult
    static func ack(ids: [Int]) async throws -> Int {
        if ids.isEmpty { return 0 }
        let req = AckRequest(ids: ids)
        let resp: AckResponse = try await NetworkService.shared.post(
            path: "/api/ghost-route/ack",
            body: req
        )
        return resp.acknowledged
    }
}
