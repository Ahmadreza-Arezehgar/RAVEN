//
//  ContactRequestInboxStore.swift
//  RAVEN — persist pending RavenContactRequestV1 + local bindings / blocks.
//
//  Ciphertext stays opaque to Bridge; open only with local identity.
//

import Foundation
import CryptoKit

/// Device-local bindings from Accept (raven_id + petname + verification).
enum DiscoveryContactBindingStore {
    private static let key = "raven.discovery.contact_bindings.v1"

    static func load() -> [LocalDiscoveryContact] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            return []
        }
        return rows.map {
            LocalDiscoveryContact(
                ravenId: $0.ravenId,
                pubHex: $0.pubHex,
                petname: $0.petname,
                publicTag: $0.publicTag,
                displayName: $0.displayName,
                pinned: $0.pinned,
                directlyVerified: $0.directlyVerified
            )
        }
    }

    static func upsert(_ contact: LocalDiscoveryContact) {
        var all = load()
        all.removeAll { $0.ravenId == contact.ravenId }
        all.append(contact)
        save(all)
    }

    static func save(_ contacts: [LocalDiscoveryContact]) {
        let rows = contacts.map {
            Row(
                ravenId: $0.ravenId,
                pubHex: $0.pubHex,
                petname: $0.petname,
                publicTag: $0.publicTag,
                displayName: $0.displayName,
                pinned: $0.pinned,
                directlyVerified: $0.directlyVerified
            )
        }
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private struct Row: Codable {
        var ravenId: String
        var pubHex: String
        var petname: String
        var publicTag: String
        var displayName: String
        var pinned: Bool
        var directlyVerified: Bool
    }
}

enum DiscoveryBlockStore {
    private static let key = "raven.discovery.blocked_pubhex.v1"

    static func load() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(arr.map { $0.lowercased() })
    }

    static func block(_ pubHex: String) {
        var s = load()
        s.insert(pubHex.lowercased())
        UserDefaults.standard.set(Array(s), forKey: key)
    }
}

/// Persist pending wire blobs; open on load with local signing key.
enum ContactRequestInboxStore {
    private static let key = "raven.discovery.contact_inbox.wires.v1"

    static func loadWires() -> [Data] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rows = try? JSONDecoder().decode([Data].self, from: data) else {
            return []
        }
        return rows
    }

    static func saveWires(_ wires: [Data]) {
        if let data = try? JSONEncoder().encode(wires) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func upsertWire(_ wire: Data) {
        var all = loadWires()
        // Dedup by request_id if decodeable
        if let outer = try? RavenContactRequestV1.decodeWire(wire) {
            all.removeAll {
                (try? RavenContactRequestV1.decodeWire($0))?.requestId == outer.requestId
            }
        }
        all.append(wire)
        saveWires(all)
    }

    static func remove(requestId: Data) {
        var all = loadWires()
        all.removeAll {
            (try? RavenContactRequestV1.decodeWire($0))?.requestId == requestId
        }
        saveWires(all)
    }

    static func buildInbox(
        recipientKey: Curve25519.Signing.PrivateKey,
        recipientAddr: String,
        nowMs: UInt64
    ) -> ContactRequestInbox {
        var inbox = ContactRequestInbox()
        for wire in loadWires() {
            guard let outer = try? RavenContactRequestV1.decodeWire(wire) else { continue }
            _ = try? inbox.ingest(
                outer: outer,
                recipientSigningKey: recipientKey,
                recipientAddr: recipientAddr,
                nowMs: nowMs
            )
        }
        return inbox
    }
}

/// Short safety phrase for nearby confirm-to-bind (mirrors raven_core::nearby_safety_phrase).
enum NearbySafetyPhrase {
    private static let words: [String] = [
        "amber", "birch", "cedar", "delta", "ember", "flint", "grove", "harbor",
        "iris", "jade", "kite", "lotus", "maple", "nova", "olive", "pine",
        "quartz", "river", "sage", "tide", "umbra", "vale", "willow", "xenon",
        "yarrow", "zephyr", "coral", "dusk", "echo", "fern", "glen", "haze",
    ]

    static func phrase(tokenHex: String, commitmentHex: String) -> String? {
        guard let token = Data(ravenHex: tokenHex), token.count == 16,
              let commitment = Data(ravenHex: commitmentHex), commitment.count == 32 else {
            return nil
        }
        return phrase(token: token, commitment: commitment)
    }

    static func phrase(token: Data, commitment: Data) -> String {
        var material = Data("raven/nearby/safety-phrase/v1".utf8)
        material.append(token)
        material.append(commitment)
        let dig = Data(SHA256.hash(data: material))
        let a = words[Int(dig[0]) % words.count]
        let b = words[Int(dig[1]) % words.count]
        let c = words[Int(dig[2]) % words.count]
        return "\(a)-\(b)-\(c)"
    }

    static func matches(expected: String, entered: String) -> Bool {
        expected.trimmingCharacters(in: .whitespacesAndNewlines)
            == entered.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
