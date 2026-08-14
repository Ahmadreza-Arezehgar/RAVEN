//
//  ContactRequestInboxViewModel.swift
//  RAVEN — PairInit friend-request inbox (legacy contact-request path stay fail-closed).
//

import Foundation
import CryptoKit
import Observation

struct PendingPairInitRequest: Identifiable, Equatable {
    var id: String { initID.ravenHex }
    let initID: Data
    let wire: Data
    let initiatorAddress: String
    let createdAtMs: UInt64
}

@MainActor
@Observable
final class ContactRequestInboxViewModel {
    var pending: [PendingPairInitRequest] = []
    var statusMessage: String?
    var petnameDraft: [String: String] = [:]
    var isBusy: Bool = false

    /// Legacy RavenContactRequestV1 rows — intentionally unused for Test A.
    var legacyPending: [PendingContactRequest] = []

    var isEnabled: Bool { FeatureFlag.isRavenEnvelopeV1Enabled }

    private var stored: [Data: Data] = [:] // initID → wire

    func reload() {
        guard isEnabled else {
            pending = []
            statusMessage = "Enable RavenEnvelopeV1 for contact-request inbox"
            Self.traceFriendRequest(
                status: "WAITING_FOR_RAVEN_ENVELOPE_FLAG",
                detail: "flag_off"
            )
            return
        }
        if !ATSAMPairInitV1.productionEnabled {
            pending = []
            statusMessage = "Security hold: set RAVEN_LAB_TEST_A=1 (DEBUG) for PairInit friend requests"
            Self.traceFriendRequest(
                status: "PRODUCTION_GATE_DISABLED:WAITING_FOR_PAIR_INIT_SESSION",
                detail: "pair_init=\(ATSAMPairInitV1.productionEnabled) endpoint=\(ATSAMEndpointTransactionV1.productionEnabled)"
            )
            return
        }
        pending = stored.values.compactMap { wire in
            guard let decoded = try? ATSAMPairInitV1.decodeInit(wire) else { return nil }
            return PendingPairInitRequest(
                initID: decoded.initID,
                wire: wire,
                initiatorAddress: decoded.initiatorAddress,
                createdAtMs: decoded.createdAtMs
            )
        }
        .sorted { $0.createdAtMs > $1.createdAtMs }
        statusMessage = pending.isEmpty
            ? "No pending PairInit — pull from Mac while Raven is open"
            : "\(pending.count) PairInit waiting"
        Self.traceFriendRequest(
            status: "PAIR_INIT_INBOX_READY",
            detail: "count=\(pending.count)"
        )
    }

    private static func traceFriendRequest(status: String, detail: String) {
        #if DEBUG
        let payload: [String: Any] = [
            "sessionId": "532d3b",
            "runId": "test-a-recovery",
            "hypothesisId": "TRACE",
            "location": "ContactRequestInboxViewModel.reload",
            "message": "TRACE_FRIEND_REQUEST",
            "data": [
                "status": status,
                "detail": detail,
                "pair_init": ATSAMPairInitV1.productionEnabled,
                "endpoint": ATSAMEndpointTransactionV1.productionEnabled,
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
        #endif
    }

    /// Ingest PairInit wire (RVPI1) from LAN/BLE endpoint dispatch.
    @discardableResult
    func ingestPairInitWire(_ wire: Data) -> Bool {
        guard ATSAMPairInitV1.productionEnabled else { return false }
        guard let decoded = try? ATSAMPairInitV1.decodeInit(wire) else { return false }
        stored[decoded.initID] = wire
        reload()
        return true
    }

    /// Legacy path — always fail closed.
    @discardableResult
    func ingestWire(_ wire: Data) -> Bool {
        // Prefer PairInit magic if present.
        if case .pairInit(let initWire) = RavenPairInitLanOob.classifyMessageCiphertext(wire) {
            return ingestPairInitWire(initWire)
        }
        if wire.count == ATSAMPairInitV1.initWireLength {
            return ingestPairInitWire(wire)
        }
        return false
    }

    func accept(requestId: Data) async throws {
        guard isEnabled, ATSAMPairInitV1.productionEnabled else {
            throw RavenContactRequestError.sessionRequired
        }
        guard let wire = stored[requestId] else {
            throw RavenContactRequestError.sessionRequired
        }
        isBusy = true
        defer { isBusy = false }
        // Complete ML-KEM decap + PairResponse + LAN uplink (durable session first).
        try await ATSAMPairInitAcceptService.accept(pairInitWire: wire)
        NotificationCenter.default.post(
            name: .ravenPairInitAccepted,
            object: nil,
            userInfo: ["wire": wire, "initID": requestId]
        )
        stored.removeValue(forKey: requestId)
        reload()
        statusMessage = "Accepted — PairResponse uplinked"
        #if DEBUG
        print("TRACE_PAIR_INIT_ACCEPTED init=\(requestId.prefix(4).map { String(format: "%02x", $0) }.joined())…")
        #endif
    }

    func decline(requestId: Data) throws {
        stored.removeValue(forKey: requestId)
        reload()
        statusMessage = "Declined"
    }

    func block(requestId: Data) throws {
        stored.removeValue(forKey: requestId)
        reload()
        statusMessage = "Blocked locally"
    }
}

extension Notification.Name {
    static let ravenPairInitAccepted = Notification.Name("ravenPairInitAccepted")
}
