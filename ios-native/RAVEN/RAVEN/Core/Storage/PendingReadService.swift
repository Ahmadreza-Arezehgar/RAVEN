import Foundation

struct PendingReadRecord: Identifiable {
    let id: String
    let type: String       // "message" or "notification"
    let targetId: String?  // roomId or notificationId (nil for read-all)
    let lastItemId: String? // lastMessageId if available
    let isAll: Bool        // Is this a mark-all-as-read request?
    let createdAt: Date
}

actor PendingReadService {
    static let shared = PendingReadService()
    private let db = DatabaseService.shared
    private var isSyncing = false
    
    private init() {}
    
    static func tableCreationSQL() -> [String] {
        return [
            """
            CREATE TABLE IF NOT EXISTS pending_reads (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                target_id TEXT,
                last_item_id TEXT,
                is_all INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_pending_reads_created ON pending_reads(created_at)"
        ]
    }
    
    func enqueue(type: String, targetId: String?, lastItemId: String? = nil, isAll: Bool) async {
        let id = UUID().uuidString
        let createdAt = SharedDateFormatters.formatISO8601(Date())
        let sql = """
            INSERT INTO pending_reads (id, type, target_id, last_item_id, is_all, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        try? await db.execute(sql, params: [id, type, targetId ?? NSNull(), lastItemId ?? NSNull(), isAll ? 1 : 0, createdAt])
        #if DEBUG
        print("  [PendingRead] Queued \(type) read (isAll: \(isAll))")
        #endif
        
        // If online, attempt sync immediately
        Task { await sync() }
    }
    
    func sync() async {
        guard NetworkMonitor.shared.isOnline else { return }
        guard !isSyncing else { return }
        
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            let sql = "SELECT * FROM pending_reads ORDER BY created_at ASC LIMIT 100"
            let rows = try await db.query(sql)
            
            let records = rows.compactMap { row -> PendingReadRecord? in
                guard let id = row["id"] as? String,
                      let type = row["type"] as? String,
                      let createdAtStr = row["created_at"] as? String,
                      let createdAt = SharedDateFormatters.parseISO8601(createdAtStr) else {
                    return nil
                }
                let targetId = row["target_id"] as? String
                let lastItemId = row["last_item_id"] as? String
                let isAll = (row["is_all"] as? Int64) == 1
                return PendingReadRecord(id: id, type: type, targetId: targetId, lastItemId: lastItemId, isAll: isAll, createdAt: createdAt)
            }
            
            
            for record in records {
                var success = false
                do {
                    if record.type == "message" {
                        if record.isAll {
                            let _: Empty = try await NetworkService.shared.post(
                                path: "/api/messages/read-all",
                                body: [String: String]()
                            )
                            success = true
                        } else if let roomId = record.targetId {
                            let _: Empty = try await NetworkService.shared.post(
                                path: "/api/messages/read",
                                body: ["room_id": roomId]
                            )
                            success = true
                        }
                        
                        if success {
                            try? await db.execute("DELETE FROM pending_reads WHERE id = ?", params: [record.id])
                        }
                        
                    } else if record.type == "notification" {
                        struct NotifEmptyBody: Encodable {}
                        if record.isAll {
                            let _: Empty = try await NetworkService.shared.post(
                                path: "/api/notifications/read-all",
                                body: NotifEmptyBody()
                            )
                            try? await db.execute("DELETE FROM pending_reads WHERE id = ?", params: [record.id])
                        } else if let notifId = record.targetId {
                            let _: Empty = try await NetworkService.shared.post(
                                path: "/api/notifications/\(notifId)/read",
                                body: NotifEmptyBody()
                            )
                            try? await db.execute("DELETE FROM pending_reads WHERE id = ?", params: [record.id])
                        }
                    }
                } catch {
                    #if DEBUG
                    print("  [PendingReadSyncWorker] Failed to sync record \(record.id): \(error)")
                    #endif
                    // Drop invalid records to prevent queue from getting stuck
                    if let apiError = error as? APIError {
                        switch apiError {
                        case .notFound, .badRequest:
                            try? await db.execute("DELETE FROM pending_reads WHERE id = ?", params: [record.id])
                        default: break
                        }
                    }
                }
            }
        } catch {
            #if DEBUG
            print("  [PendingReadSyncWorker] Failed to get pending reads: \(error)")
            #endif
        }
    }
}
