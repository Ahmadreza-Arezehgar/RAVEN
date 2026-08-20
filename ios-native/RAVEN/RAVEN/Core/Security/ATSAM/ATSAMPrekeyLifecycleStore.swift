//
//  ATSAMPrekeyLifecycleStore.swift
//  RAVEN — lab PairInit claim journal + initiator packed-init persistence (§4.9).
//
//  Protected state namespace: app.raven.ios.atsam.prekey.v1
//  ClaimJournal always roll-forwards when the journal entry was durable; drop only
//  if the journal never reached protected storage.
//

import CryptoKit
import Foundation
import Security

@MainActor
final class ATSAMPrekeyLifecycleStore {

    static let shared = ATSAMPrekeyLifecycleStore()

    static let service = "app.raven.ios.atsam.prekey.v1"
    private static let stateAccount = "protected|prekey_lifecycle|v1"
    private static let stateMagic = "RVNPKL01"
    private static let claimIDDomain = Data("rvn1/prekey-lifecycle/claim/v1".utf8)
    private static let handoffTimeoutMs: UInt64 = 24 * 60 * 60 * 1_000
    private static let maxAcceptedClaims = 256

    enum StoreError: Error, Equatable {
        case gateClosed
        case initIdConflict
        case claimNotFound
        case claimBindingMismatch
        case claimHandoffExpired
        case resourceLimit
        case corruptProtectedState
        case protectedStore
        case injectedCrash(String)
    }

    enum ClaimState: String, Codable, Equatable {
        case pendingHandoff
        case completed
        case abandoned
    }

    enum CompleteClaimOutcome: Equatable {
        case completed
        case alreadyCompleted
    }

    enum PrekeyClaimOutcome: Equatable {
        case accepted(PrekeyClaim)
        case duplicatePending(PrekeyClaim)
        case duplicateCompleted(claimID: Data, sessionID: Data)
        case duplicateAbandoned(claimID: Data, sessionID: Data)
    }

    struct PrekeyClaim: Equatable {
        let claimID: Data
        let sessionID: Data
        private(set) var provisionalRoot: Data?

        mutating func takeProvisionalRoot() -> Data? {
            defer { provisionalRoot = nil }
            return provisionalRoot
        }
    }

    struct InitiatorOutboundRecord: Equatable, Codable {
        var packedWire: Data
        var initWire: Data
        var sessionID: Data
        var provisionalRoot: Data
        var createdAtMs: UInt64
    }

    enum FaultPoint: Equatable {
        case beforeClaimJournal
        case claimJournal
        case claimCommit
    }

    #if DEBUG
    private var injectedFault: FaultPoint?
    #endif

    private let lock = NSLock()
    private var memoryState: ProtectedState?
    private var memoryInitiator: [String: InitiatorOutboundRecord] = [:]
    private var useMemoryOnly = false

    private struct PendingClaimJournal: Codable, Equatable {
        var pairInitWire: Data
        var acceptedAtMs: UInt64
        /// Durable roll-forward aid: same root as the in-flight claim attempt.
        var provisionalRoot: Data
        var responderIdentity: Data
    }

    private struct AcceptedClaimRecord: Codable, Equatable {
        var claimID: Data
        var responderIdentity: Data
        var responderDevice: Data
        var signedPrekeyID: UInt32
        var oneTimePrekeyID: UInt32
        var initID: Data
        var initHash: Data
        var sessionID: Data
        var acceptedAtMs: UInt64
        var handoffDeadlineMs: UInt64
        var retainUntilMs: UInt64
        var state: ClaimState
    }

    private struct ProtectedState: Codable, Equatable {
        var magic: String
        var version: UInt8
        var claims: [AcceptedClaimRecord]
        var pending: PendingClaimJournal?
    }

    // MARK: - Test hooks

    #if DEBUG
    func clearInjectedFault() {
        lock.lock()
        defer { lock.unlock() }
        injectedFault = nil
    }

    func dropMemoryCacheForRelaunchSimulation() {
        lock.lock()
        defer { lock.unlock() }
        memoryState = nil
    }
    #endif

    func resetForTesting(memoryOnly: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        useMemoryOnly = memoryOnly
        memoryState = nil
        memoryInitiator = [:]
        #if DEBUG
        injectedFault = nil
        #endif
        if !memoryOnly {
            try? deleteKeychain(account: Self.stateAccount)
        }
    }

    #if DEBUG
    func injectFault(_ point: FaultPoint) {
        lock.lock()
        defer { lock.unlock() }
        injectedFault = point
    }
    #endif

    // MARK: - Responder claim journal

    func claimPairInit(
        pairInitWire: Data,
        initValue: ATSAMPairInitV1.PairInit,
        trust: ATSAMPairInitV1.TrustContext,
        root: Data,
        nowMs: UInt64
    ) throws -> PrekeyClaimOutcome {
        try lock.withLock {
            guard ATSAMEndpointDurableAdapters.labTestAEnabled else {
                throw StoreError.gateClosed
            }
            var state = try loadAndRecover()
            let digest = try ATSAMPairInitV1.initHash(initValue)
            let expectedSessionID = ATSAMPairInitV1.sessionID(initHash: digest)
            let responderIdentity = trust.responderCertificate.identityEd25519PublicKey

            if let existing = state.claims.first(where: {
                $0.responderIdentity == responderIdentity
                    && $0.responderDevice == initValue.responderDeviceEd25519PublicKey
                    && $0.signedPrekeyID == initValue.signedPrekeyID
                    && $0.oneTimePrekeyID == initValue.oneTimePrekeyID
                    && $0.initID == initValue.initID
                    && $0.initHash == digest
            }) {
                return claimOutcome(existing, duplicate: true, root: root)
            }

            if state.claims.contains(where: {
                $0.responderIdentity == responderIdentity
                    && $0.responderDevice == initValue.responderDeviceEd25519PublicKey
                    && $0.initID == initValue.initID
                    && $0.initHash != digest
            }) {
                throw StoreError.initIdConflict
            }

            guard state.claims.count < Self.maxAcceptedClaims else {
                throw StoreError.resourceLimit
            }

            try maybeFault(.beforeClaimJournal)
            state.pending = PendingClaimJournal(
                pairInitWire: pairInitWire,
                acceptedAtMs: nowMs,
                provisionalRoot: root,
                responderIdentity: responderIdentity
            )
            try storeState(&state)
            try maybeFault(.claimJournal)

            try recoverPendingClaim(&state, root: root, nowMs: nowMs, trust: trust)
            try storeState(&state)
            try maybeFault(.claimCommit)

            guard let accepted = state.claims.first(where: {
                $0.initHash == digest && $0.sessionID == expectedSessionID
            }) else {
                throw StoreError.corruptProtectedState
            }
            return claimOutcome(accepted, duplicate: false, root: root)
        }
    }

    func completeClaim(claimID: Data, sessionID: Data) throws -> CompleteClaimOutcome {
        try lock.withLock {
            var state = try loadAndRecover()
            guard let index = state.claims.firstIndex(where: { $0.claimID == claimID }) else {
                throw StoreError.claimNotFound
            }
            guard state.claims[index].sessionID == sessionID else {
                throw StoreError.claimBindingMismatch
            }
            switch state.claims[index].state {
            case .completed:
                return .alreadyCompleted
            case .abandoned:
                throw StoreError.claimHandoffExpired
            case .pendingHandoff:
                try deleteProvisionalRoot(claimID: claimID)
                state.claims[index].state = .completed
                try storeState(&state)
                return .completed
            }
        }
    }

    func acceptedClaimCount() throws -> Int {
        try lock.withLock {
            try loadAndRecover().claims.count
        }
    }

    #if DEBUG
    func claimState(initHash: Data) throws -> ClaimState? {
        try lock.withLock {
            try loadAndRecover().claims.first(where: { $0.initHash == initHash })?.state
        }
    }
    #endif

    // MARK: - Initiator packed-init persistence

    /// Persist exact packed PairInit bytes + provisional session metadata before first send.
    func persistInitiatorOutbound(
        initID: Data,
        packedWire: Data,
        initWire: Data,
        sessionID: Data,
        provisionalRoot: Data,
        createdAtMs: UInt64
    ) throws {
        try lock.withLock {
            guard ATSAMEndpointDurableAdapters.labTestAEnabled else {
                throw StoreError.gateClosed
            }
            let record = InitiatorOutboundRecord(
                packedWire: packedWire,
                initWire: initWire,
                sessionID: sessionID,
                provisionalRoot: provisionalRoot,
                createdAtMs: createdAtMs
            )
            let account = initiatorAccount(initID: initID)
            if useMemoryOnly {
                memoryInitiator[account] = record
                return
            }
            let data = try JSONEncoder().encode(record)
            try writeKeychain(account: account, data: data)
        }
    }

    /// Loss/retry path: return the same packed bytes (no new init_id/root/OTP).
    func loadInitiatorOutbound(initID: Data) throws -> InitiatorOutboundRecord? {
        try lock.withLock {
            let account = initiatorAccount(initID: initID)
            if useMemoryOnly {
                return memoryInitiator[account]
            }
            guard let raw = try readKeychain(account: account) else { return nil }
            return try JSONDecoder().decode(InitiatorOutboundRecord.self, from: raw)
        }
    }

    /// Most recent pending initiator outbound (exact-retry path).
    func loadPendingInitiatorOutbound() throws -> (initID: Data, record: InitiatorOutboundRecord)? {
        try lock.withLock {
            guard ATSAMEndpointDurableAdapters.labTestAEnabled else {
                throw StoreError.gateClosed
            }
            if useMemoryOnly {
                guard !memoryInitiator.isEmpty else { return nil }
                let best = memoryInitiator.max { $0.value.createdAtMs < $1.value.createdAtMs }
                guard let entry = best else { return nil }
                let initID = initiatorInitID(fromAccount: entry.key)
                return (initID, entry.value)
            }
            var bestAccount: String?
            var bestRecord: InitiatorOutboundRecord?
            for account in try listKeychainAccounts(matchingPrefix: "pair|init|") {
                guard let raw = try readKeychain(account: account),
                      let record = try? JSONDecoder().decode(InitiatorOutboundRecord.self, from: raw) else {
                    continue
                }
                if bestRecord == nil || record.createdAtMs > bestRecord!.createdAtMs {
                    bestAccount = account
                    bestRecord = record
                }
            }
            guard let account = bestAccount, let record = bestRecord else { return nil }
            return (initiatorInitID(fromAccount: account), record)
        }
    }

    func clearInitiatorOutbound(initID: Data) throws {
        try lock.withLock {
            let account = initiatorAccount(initID: initID)
            if useMemoryOnly {
                memoryInitiator.removeValue(forKey: account)
                return
            }
            try deleteKeychain(account: account)
        }
    }

    // MARK: - Recovery

    private func loadAndRecover() throws -> ProtectedState {
        var state = try loadState()
        if state.pending != nil {
            try recoverPendingClaim(&state, root: nil, nowMs: nil, trust: nil)
            try storeState(&state)
        }
        return state
    }

    private func recoverPendingClaim(
        _ state: inout ProtectedState,
        root: Data?,
        nowMs: UInt64?,
        trust: ATSAMPairInitV1.TrustContext?
    ) throws {
        guard let pending = state.pending else { return }
        defer { state.pending = nil }

        let initValue = try ATSAMPairInitV1.decodeInit(pending.pairInitWire)
        let digest = try ATSAMPairInitV1.initHash(initValue)

        if state.claims.contains(where: {
            $0.responderDevice == initValue.responderDeviceEd25519PublicKey
                && $0.initID == initValue.initID
                && $0.initHash != digest
        }) {
            throw StoreError.corruptProtectedState
        }

        if state.claims.contains(where: { $0.initHash == digest }) {
            return
        }

        let resolvedRoot: Data
        if let root {
            resolvedRoot = root
        } else if !pending.provisionalRoot.isEmpty {
            resolvedRoot = pending.provisionalRoot
        } else if let stored = try loadProvisionalRoot(
            initHash: digest,
            sessionID: ATSAMPairInitV1.sessionID(initHash: digest)
        ) {
            resolvedRoot = stored
        } else {
            resolvedRoot = try Self.deriveResponderRoot(initValue: initValue)
        }

        let responderIdentity: Data
        if let trust {
            responderIdentity = trust.responderCertificate.identityEd25519PublicKey
        } else {
            responderIdentity = pending.responderIdentity
        }

        let acceptedAt = pending.acceptedAtMs
        let handoffDeadline = acceptedAt &+ Self.handoffTimeoutMs
        let retainUntil = handoffDeadline
        let sessionID = ATSAMPairInitV1.sessionID(initHash: digest)
        let claimID = Self.claimID(
            responderIdentity: responderIdentity,
            responderDevice: initValue.responderDeviceEd25519PublicKey,
            signedPrekeyID: initValue.signedPrekeyID,
            oneTimePrekeyID: initValue.oneTimePrekeyID,
            initID: initValue.initID,
            initHash: digest
        )

        try storeProvisionalRoot(claimID: claimID, root: resolvedRoot)

        state.claims.append(
            AcceptedClaimRecord(
                claimID: claimID,
                responderIdentity: responderIdentity,
                responderDevice: initValue.responderDeviceEd25519PublicKey,
                signedPrekeyID: initValue.signedPrekeyID,
                oneTimePrekeyID: initValue.oneTimePrekeyID,
                initID: initValue.initID,
                initHash: digest,
                sessionID: sessionID,
                acceptedAtMs: acceptedAt,
                handoffDeadlineMs: handoffDeadline,
                retainUntilMs: retainUntil,
                state: .pendingHandoff
            )
        )
        _ = nowMs
    }

    private func claimOutcome(
        _ claim: AcceptedClaimRecord,
        duplicate: Bool,
        root: Data
    ) -> PrekeyClaimOutcome {
        switch claim.state {
        case .completed:
            return .duplicateCompleted(claimID: claim.claimID, sessionID: claim.sessionID)
        case .abandoned:
            return .duplicateAbandoned(claimID: claim.claimID, sessionID: claim.sessionID)
        case .pendingHandoff:
            let provisional = (try? loadProvisionalRoot(claimID: claim.claimID)) ?? root
            let value = PrekeyClaim(
                claimID: claim.claimID,
                sessionID: claim.sessionID,
                provisionalRoot: provisional
            )
            return duplicate ? .duplicatePending(value) : .accepted(value)
        }
    }

    // MARK: - Protected state I/O

    private func loadState() throws -> ProtectedState {
        if useMemoryOnly {
            return memoryState ?? ProtectedState(magic: Self.stateMagic, version: 1, claims: [], pending: nil)
        }
        guard let raw = try readKeychain(account: Self.stateAccount) else {
            return ProtectedState(magic: Self.stateMagic, version: 1, claims: [], pending: nil)
        }
        let decoded = try JSONDecoder().decode(ProtectedState.self, from: raw)
        guard decoded.magic == Self.stateMagic, decoded.version == 1 else {
            throw StoreError.corruptProtectedState
        }
        return decoded
    }

    private func storeState(_ state: inout ProtectedState) throws {
        if useMemoryOnly {
            memoryState = state
            return
        }
        let data = try JSONEncoder().encode(state)
        try writeKeychain(account: Self.stateAccount, data: data)
    }

    // MARK: - Provisional root (Keychain)

    private func provisionalRootAccount(claimID: Data) -> String {
        "claim|root|" + claimID.ravenHexLower
    }

    private func initiatorAccount(initID: Data) -> String {
        "pair|init|" + initID.ravenHexLower
    }

    private func initiatorInitID(fromAccount account: String) -> Data {
        let hex = String(account.dropFirst("pair|init|".count))
        var bytes = Data()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            bytes.append(UInt8(hex[cursor..<next], radix: 16)!)
            cursor = next
        }
        return bytes
    }

    private func listKeychainAccounts(matchingPrefix prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]] else {
            throw StoreError.protectedStore
        }
        return entries.compactMap { entry in
            guard let account = entry[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { return nil }
            return account
        }
    }

    private func storeProvisionalRoot(claimID: Data, root: Data) throws {
        if useMemoryOnly { return }
        try writeKeychain(account: provisionalRootAccount(claimID: claimID), data: root)
    }

    private func loadProvisionalRoot(claimID: Data) throws -> Data? {
        if useMemoryOnly { return nil }
        return try readKeychain(account: provisionalRootAccount(claimID: claimID))
    }

    private func loadProvisionalRoot(initHash: Data, sessionID: Data) throws -> Data? {
        let state = try loadState()
        guard let claim = state.claims.first(where: { $0.initHash == initHash && $0.sessionID == sessionID }) else {
            return nil
        }
        return try loadProvisionalRoot(claimID: claim.claimID)
    }

    private func deleteProvisionalRoot(claimID: Data) throws {
        if useMemoryOnly { return }
        try deleteKeychain(account: provisionalRootAccount(claimID: claimID))
    }

    // MARK: - Keychain

    private func readKeychain(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw StoreError.protectedStore
        }
        return data
    }

    private func writeKeychain(account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.protectedStore }
    }

    private func deleteKeychain(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Fault injection

    private func maybeFault(_ point: FaultPoint) throws {
        #if DEBUG
        guard injectedFault == point else { return }
        injectedFault = nil
        let label: String
        switch point {
        case .beforeClaimJournal: label = "before claim journal"
        case .claimJournal: label = "claim journal"
        case .claimCommit: label = "claim commit"
        }
        throw StoreError.injectedCrash(label)
        #else
        _ = point
        #endif
    }

    // MARK: - Crypto helpers

    static func claimID(
        responderIdentity: Data,
        responderDevice: Data,
        signedPrekeyID: UInt32,
        oneTimePrekeyID: UInt32,
        initID: Data,
        initHash: Data
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: claimIDDomain)
        hasher.update(data: responderIdentity)
        hasher.update(data: responderDevice)
        var sp = signedPrekeyID.bigEndian
        withUnsafeBytes(of: &sp) { hasher.update(data: $0) }
        var otp = oneTimePrekeyID.bigEndian
        withUnsafeBytes(of: &otp) { hasher.update(data: $0) }
        hasher.update(data: initID)
        hasher.update(data: initHash)
        return Data(hasher.finalize())
    }

    static func deriveResponderRoot(initValue: ATSAMPairInitV1.PairInit) throws -> Data {
        let secrets = try ATSAMLabTrustStore.localHybridSecrets()
        let selectedXSecret: Data
        if initValue.oneTimePrekeyID != 0 {
            throw StoreError.corruptProtectedState
        } else {
            selectedXSecret = secrets.xSecret
        }
        let ourX = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: selectedXSecret)
        let peerX = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: initValue.initiatorEphemeralX25519PublicKey
        )
        let shared = try ourX.sharedSecretFromKeyAgreement(with: peerX)
        let zX = shared.withUnsafeBytes { Data($0) }
        let zPQ = try ATSAMMLKem.decapsulate(
            ciphertext: initValue.mlKem768Ciphertext,
            privateKey: secrets.mlkemSeed
        )
        return try ATSAMPairInitV1.deriveProvisionalRoot(
            zX: zX,
            zPQ: zPQ,
            pairInit: initValue
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Data {
    var ravenHexLower: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
