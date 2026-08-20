//
//  RavenSecureLanEphemeralPeers.swift
//  RAVEN
//
//  Process-memory ephemeral LAN peer cache (RLB1 strangers).
//  Parity with node/crates/raven-core/src/lan_dispatch.rs remember_ephemeral_peer.
//

import Foundation

// MARK: - Durable side-effect boundary (tests spy this)

protocol RavenSecureLanTrustedPeerPersistence: AnyObject {
    func persistTrustedPeerBundle(_ bundle: RavenSecureLanRlb1V1.LanBundle) throws
}

final class RavenSecureLanNullTrustedPeerPersistence: RavenSecureLanTrustedPeerPersistence {
    func persistTrustedPeerBundle(_ bundle: RavenSecureLanRlb1V1.LanBundle) throws {
        _ = bundle
    }
}

// MARK: - Ephemeral cache

/// Process memory only — never writes durable stranger peer material.
final class RavenSecureLanEphemeralPeerCache {
    static let defaultMaxPeers = 16
    static let defaultTTLSeconds: TimeInterval = 15 * 60

    private struct Entry {
        var bundle: RavenSecureLanRlb1V1.LanBundle
        var expiresAt: Date
    }

    private var map: [Data: Entry] = [:]
    private let maxPeers: Int
    private let ttl: TimeInterval
    private var now: () -> Date

    init(
        maxPeers: Int = RavenSecureLanEphemeralPeerCache.defaultMaxPeers,
        ttl: TimeInterval = RavenSecureLanEphemeralPeerCache.defaultTTLSeconds,
        now: @escaping () -> Date = Date.init
    ) {
        self.maxPeers = maxPeers
        self.ttl = ttl
        self.now = now
    }

    var count: Int {
        purgeExpired(at: now())
        return map.count
    }

    /// Mirror Rust `remember_ephemeral_peer`.
    func remember(_ bundle: RavenSecureLanRlb1V1.LanBundle) {
        let key = bundle.cert.deviceEdPub
        guard key.count == 32 else { return }
        let current = now()
        purgeExpired(at: current)

        while map.count >= maxPeers {
            guard let victim = map.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key else {
                break
            }
            map.removeValue(forKey: victim)
        }

        map[key] = Entry(
            bundle: bundle,
            expiresAt: current.addingTimeInterval(ttl)
        )
    }

    func load(deviceEdPub: Data) -> RavenSecureLanRlb1V1.LanBundle? {
        guard deviceEdPub.count == 32 else { return nil }
        let current = now()
        purgeExpired(at: current)
        return map[deviceEdPub]?.bundle
    }

    func load(matchingAnyPub pub: Data) -> RavenSecureLanRlb1V1.LanBundle? {
        guard pub.count == 32 else { return nil }
        let current = now()
        purgeExpired(at: current)
        if let direct = map[pub]?.bundle { return direct }
        return map.values.first(where: {
            $0.bundle.cert.userEdPub == pub
        })?.bundle
    }

    /// Remember peer; durable write only when contact-trusted (Rust `cache_peer_bundle`).
    func cachePeerBundle(
        _ bundle: RavenSecureLanRlb1V1.LanBundle,
        contactBook: RavenSecureLanContactBook,
        durable: RavenSecureLanTrustedPeerPersistence?
    ) throws {
        try RavenSecureLanRlb1V1.requireIdentityBound(bundle)
        remember(bundle)
        if contactBook.isLocalContact(
            deviceEdPub: bundle.cert.deviceEdPub,
            userEdPub: bundle.cert.userEdPub
        ) {
            try durable?.persistTrustedPeerBundle(bundle)
        }
    }

    private func purgeExpired(at current: Date) {
        map = map.filter { $0.value.expiresAt > current }
    }
}
