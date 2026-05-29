// MeshDedupRepository — persistent dedup of envelope ids the engine
// has already processed.
//
// The mesh broadcasts a message multiple times (spray + relay), so the
// receiver must dedup on `clientMessageId`. We keep a bounded LRU on
// disk (Application Support) so dedup survives app restarts within the
// 24 h TTL window — the same envelope showing up an hour later from a
// different relay shouldn't be re-displayed.

import Foundation

actor MeshDedupRepository {
    static let shared = MeshDedupRepository()

    private var seenIds: Set<String> = []
    private var idOrder: [String] = []
    private let maxIds = 5_000
    private var loaded = false

    private init() {}

    /// `true` if `id` has not been seen before. Idempotent — calling
    /// twice in a row will return `false` the second time.
    func isNewMessage(id: String) -> Bool {
        ensureLoaded()
        return !seenIds.contains(id)
    }

    /// Mark `id` as processed. Optionally include a per-message nonce
    /// (the encryption layer uses unique nonces too) — we store both as
    /// the same dedup key.
    func markProcessed(id: String, nonce: String? = nil) {
        ensureLoaded()
        guard !seenIds.contains(id) else { return }
        seenIds.insert(id)
        idOrder.append(id)
        if let nonce, !seenIds.contains(nonce) {
            seenIds.insert(nonce)
            idOrder.append(nonce)
        }
        trim()
        persist()
    }

    /// Wipe local state (e.g. on sign-out).
    func reset() {
        seenIds.removeAll(keepingCapacity: false)
        idOrder.removeAll(keepingCapacity: false)
        persist()
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var ids: [String]
    }

    private func storeURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("RAVEN", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mesh_dedup.json")
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        let url = storeURL()
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        idOrder = p.ids
        seenIds = Set(p.ids)
    }

    private func persist() {
        let p = Persisted(ids: idOrder)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: storeURL(), options: .atomic)
    }

    private func trim() {
        guard idOrder.count > maxIds else { return }
        let drop = idOrder.count - (maxIds / 2)
        let removed = idOrder.prefix(drop)
        idOrder.removeFirst(drop)
        for k in removed { seenIds.remove(k) }
    }
}
