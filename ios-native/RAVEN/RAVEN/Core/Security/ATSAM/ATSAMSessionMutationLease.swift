//
//  ATSAMSessionMutationLease.swift
//  RAVEN
//
//  Exclusive per-session mutation lease (G1). Held from ratchet load through
//  protected/SQL commit and journal clear. Network I/O must stay outside.
//

import Foundation

final class ATSAMSessionMutationLease: @unchecked Sendable {

    static let shared = ATSAMSessionMutationLease()

    private let lock = NSLock()
    private var held = Set<Data>()

    func acquire(sessionID: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if held.contains(sessionID) {
            throw ATSAMEndpointTransactionV1.TransactionError.mutationInProgress
        }
        held.insert(sessionID)
    }

    func release(sessionID: Data) {
        lock.lock()
        defer { lock.unlock() }
        held.remove(sessionID)
    }

    func withLease<T>(sessionID: Data, _ body: () throws -> T) throws -> T {
        try acquire(sessionID: sessionID)
        defer { release(sessionID: sessionID) }
        return try body()
    }
}
