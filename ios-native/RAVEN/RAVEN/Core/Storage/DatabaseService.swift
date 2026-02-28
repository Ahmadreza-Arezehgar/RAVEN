import Foundation
import SQLCipher

// MARK: - Database Service (SQLite with Encryption)
actor DatabaseService {
    static let shared = DatabaseService()
    
    private var db: OpaquePointer?
    private let dbPath: String
    private var isInitialized = false
    
    /// Lazy initialization: if the database hasn't been initialized yet, do it now.
    /// This prevents race conditions where the UI reads before the async init in AppDelegate completes.
    private func ensureInitialized() throws {
        if !isInitialized {
            try initialize()
        }
    }
    
    private init() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // Fallback to NSHomeDirectory — always available
            dbPath = NSHomeDirectory() + "/Documents/raven.sqlite"
            return
        }
        dbPath = documentsPath.appendingPathComponent("raven.sqlite").path
    }
    
    /// Execute raw DDL (CREATE TABLE / CREATE INDEX) safely within the actor.
    /// Use this instead of exposing the raw OpaquePointer to external callers.
    func executeDDL(_ statements: [String]) throws {
        try ensureInitialized()
        try _executeDDL(statements)
    }

    /// Internal DDL executor — skips ensureInitialized() so it can be called
    /// during runMigrations() without triggering an infinite recursion loop.
    private func _executeDDL(_ statements: [String]) throws {
        guard db != nil else { throw DatabaseError.failedToOpen } // 🔴 SAFEGUARD: prevent nil db crash
        for sql in statements {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                let error = String(cString: sqlite3_errmsg(db))
                #if DEBUG
                print("DDL Error: \(error)")
                #endif
                throw DatabaseError.failedToCreateTable
            }
        }
    }
    
    // MARK: - Setup
    
    func initialize() throws {
        if isInitialized { return }
        
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            throw DatabaseError.failedToOpen
        }
        
        // Apply database encryption using SQLCipher.
        // CRITICAL: PRAGMA key MUST be the first statement after sqlite3_open.
        // Any other PRAGMA before this breaks SQLCipher encryption entirely.
        try applyEncryption()
        
        // Enable WAL mode for concurrent read/write (prevents "Database is locked" errors)
        // NOTE: Must be AFTER applyEncryption() per SQLCipher documentation.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        
        try createTables()
        try runMigrations()
    }
    
    /// Apply encryption to the database using a key stored in Keychain
    /// Uses SQLCipher's PRAGMA key with hex format for secure key handling
    /// CRITICAL: In production, encryption failure is FATAL - never allow unencrypted DB
    private func applyEncryption() throws {
        guard let sqlCipherVersion = detectSQLCipherVersion() else {
            #if DEBUG
            print("⚠️ [Database] SQLCipher not linked - running UNENCRYPTED (DEBUG ONLY)")
            return
            #else
            // 🔴 CRITICAL FIX: Removed fatalError to prevent crash loops
            // (e.g. when Keychain is locked after a device reboot)
            throw DatabaseError.failedToApplyEncryptionKey
            #endif
        }
        #if DEBUG
        print("✅ [Database] SQLCipher detected (\(sqlCipherVersion))")
        #endif
        
        // Get or create encryption key from Keychain
        let encryptionKey = try getOrCreateDatabaseKey()
        
        // The key from Keychain is already a 64-char hex string (256-bit key).
        // Use PRAGMA key with hex format directly. Format: x'hexstring'
        // NOTE: Previously this was double-hex-encoded (UTF-8 bytes of hex string were re-hex-encoded),
        // producing a 128-char key. Migration below handles existing databases.
        let pragmaSQL = "PRAGMA key = \"x'\(encryptionKey)'\";"
        
        var errorMessage: UnsafeMutablePointer<CChar>?
        let keyResult = sqlite3_exec(db, pragmaSQL, nil, nil, &errorMessage)
        
        if keyResult != SQLITE_OK {
            if let errorMessage = errorMessage {
                sqlite3_free(errorMessage)
            }
            throw DatabaseError.failedToApplyEncryptionKey
        }
        
        // Validate that the DB can be queried with the configured key.
        // This prevents silently continuing with a bad/mismatched key.
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let testResult = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil)
        if testResult == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW {
            #if DEBUG
            print("✅ [Database] Encryption enabled")
            #endif
            return
        }
        
        // Migration: Try the old double-hex-encoded key for existing databases
        sqlite3_finalize(stmt)
        stmt = nil
        
        let legacyHexKey = encryptionKey.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? ""
        let legacyPragmaSQL = "PRAGMA key = \"x'\(legacyHexKey)'\";"
        sqlite3_exec(db, legacyPragmaSQL, nil, nil, nil)
        
        let legacyTestResult = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &stmt, nil)
        guard legacyTestResult == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            // ✅ Bug 2 fix: Database is unreadable (key lost after iCloud backup restore).
            // Delete the corrupt file so next initialize() creates a fresh database.
            // Without this, the app is permanently bricked in an error loop.
            sqlite3_finalize(stmt)
            stmt = nil
            sqlite3_close(db)
            db = nil
            try? FileManager.default.removeItem(atPath: dbPath)
            #if DEBUG
            print("🔴 [Database] Key validation failed — deleted unreadable DB for fresh start")
            #endif
            throw DatabaseError.failedToValidateEncryptionKey
        }
        
        // Legacy key works — re-key to the correct key
        #if DEBUG
        print("⚠️ [Database] Migrating from legacy double-encoded key to correct key")
        #endif
        let rekeySQL = "PRAGMA rekey = \"x'\(encryptionKey)'\";"
        sqlite3_exec(db, rekeySQL, nil, nil, nil)
        
        #if DEBUG
        print("✅ [Database] Encryption enabled (migrated)")
        #endif
    }
    
    /// SQLCipher exposes `PRAGMA cipher_version`.
    /// On plain SQLite this pragma usually returns no rows, which we treat as unavailable.
    private func detectSQLCipherVersion() -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        let prepareResult = sqlite3_prepare_v2(db, "PRAGMA cipher_version;", -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let valuePtr = sqlite3_column_text(stmt, 0) else { return nil }
        
        let version = String(cString: valuePtr).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
    
    /// Get or create a 256-bit encryption key stored securely in Keychain
    private func getOrCreateDatabaseKey() throws -> String {
        let keychainKey = "raven.database.encryption.key"
        let service = "app.raven.ios"
        
        // Try to retrieve existing key
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) {
            return key
        }
        
        // Post-reboot, pre-first-unlock: Keychain is unavailable.
        // BLE may wake the app before the user enters their passcode.
        if status == errSecInteractionNotAllowed {
            #if DEBUG
            print("⚠️ [Database] Keychain locked (device not yet unlocked after reboot). Deferring DB access.")
            #endif
            throw DatabaseError.keychainLocked
        }
        
        // Generate new 256-bit key (32 bytes = 64 hex chars)
        var keyData = Data(count: 32)
        let generateStatus = keyData.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        
        guard generateStatus == errSecSuccess else {
            throw DatabaseError.encryptionKeyGenerationFailed
        }
        
        let newKey = keyData.map { String(format: "%02x", $0) }.joined()
        
        // Store in Keychain with highest protection level
        let storeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: Data(newKey.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        let storeStatus = SecItemAdd(storeQuery as CFDictionary, nil)
        
        if storeStatus != errSecSuccess && storeStatus != errSecDuplicateItem {
            throw DatabaseError.failedToStoreEncryptionKey
        }
        
        #if DEBUG
        print("✅ [Database] Generated new encryption key")
        #endif
        return newKey
    }
    
    // MARK: - Migrations (for existing databases)
    
    private func runMigrations() throws {
        // Migration 1: Add group columns to conversations table (if missing)
        try addColumnIfMissing(table: "conversations", column: "is_group", definition: "INTEGER DEFAULT 0")
        try addColumnIfMissing(table: "conversations", column: "group_name", definition: "TEXT")
        try addColumnIfMissing(table: "conversations", column: "group_avatar_url", definition: "TEXT")
        
        // Migration 2: Add deletion tracking columns to messages table
        try addColumnIfMissing(table: "messages", column: "is_deleted_for_me", definition: "INTEGER DEFAULT 0")
        try addColumnIfMissing(table: "messages", column: "is_deleted_globally", definition: "INTEGER DEFAULT 0")
        
        // Migration 3: Add mesh columns to posts table
        try addColumnIfMissing(table: "posts", column: "mesh_status", definition: "TEXT DEFAULT NULL")
        try addColumnIfMissing(table: "posts", column: "mesh_broadcast_stopped", definition: "INTEGER DEFAULT 0")
        
        // Migration 4: Create mesh dedup cache for replay attack prevention (C4)
        try _executeDDL(MeshDedupRepository.tableCreationSQL())
        
        // Migration 5: Track dual-path race attempts per message
        try addColumnIfMissing(table: "messages", column: "sent_via_server", definition: "INTEGER DEFAULT 0")
        try addColumnIfMissing(table: "messages", column: "sent_via_mesh", definition: "INTEGER DEFAULT 0")
        
        // Migration 6: Harden pending ACK queue for offline retries/backoff.
        try addColumnIfMissing(table: "pending_acks", column: "delivered_via", definition: "TEXT NOT NULL DEFAULT 'mesh'")
        try addColumnIfMissing(table: "pending_acks", column: "path_used", definition: "TEXT")
        try addColumnIfMissing(table: "pending_acks", column: "idempotency_key", definition: "TEXT")
        try addColumnIfMissing(table: "pending_acks", column: "attempts", definition: "INTEGER DEFAULT 0")
        try addColumnIfMissing(table: "pending_acks", column: "last_attempt_at", definition: "REAL")
        try addColumnIfMissing(table: "pending_acks", column: "next_retry_at", definition: "REAL DEFAULT 0")
        try addColumnIfMissing(table: "pending_acks", column: "last_error", definition: "TEXT")
        
        if sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_pending_acks_retry ON pending_acks(next_retry_at)", nil, nil, nil) != SQLITE_OK {
            throw DatabaseError.failedToCreateTable
        }
        
        // Migration 7: Observability timeline columns on outbox
        try addColumnIfMissing(table: "outbox", column: "first_mesh_send_at", definition: "TEXT")
        try addColumnIfMissing(table: "outbox", column: "first_server_upload_at", definition: "TEXT")
        try addColumnIfMissing(table: "outbox", column: "server_ack_at", definition: "TEXT")
        try addColumnIfMissing(table: "outbox", column: "cancellation_propagated_at", definition: "TEXT")
        
        // Migration 8: Persistent relay queue for store-and-forward
        try _executeDDL(RelayQueueRepository.tableCreationSQL())
        
        // Migration 9: Persist verified badge status for conversation peers
        try addColumnIfMissing(table: "conversations", column: "is_verified", definition: "INTEGER DEFAULT 0")
        
        // Migration 10: Add premium and verified badges to posts
        try addColumnIfMissing(table: "posts", column: "is_verified", definition: "INTEGER DEFAULT 0")
        try addColumnIfMissing(table: "posts", column: "is_premium", definition: "INTEGER DEFAULT 0")
        
        // Migration 11: Add initial_send to posts for Mesh Tracking
        try addColumnIfMissing(table: "posts", column: "initial_send", definition: "TEXT")
        
        // Migration 12: Add pending_reads table for offline-first read sync
        try _executeDDL(PendingReadService.tableCreationSQL())
        
        // Migration 13: Add message_reads table for group read receipts
        try _executeDDL(ReadReceiptRepository.tableCreationSQL())
        
        // Migration 14: Add media_json for offline post media support
        try addColumnIfMissing(table: "posts", column: "media_json", definition: "TEXT")
        
        // Migration 15 (Bug 2 fix): Limbo table for group messages targeting unknown groups
        try _executeDDL(PendingGroupMessageRepository.tableCreationSQL())
        
        // Migration 16 (Bug 6 fix): X25519 agreement key for ECDH encryption
        try addColumnIfMissing(table: "friend_devices", column: "agreement_public_key", definition: "BLOB")
        
        // Migration 17: Add entities_json for @mention persistence
        try addColumnIfMissing(table: "messages", column: "entities_json", definition: "TEXT")
        
        // Migration 18: Message Requests fields
        try addColumnIfMissing(table: "conversations", column: "request_status", definition: "TEXT")
        try addColumnIfMissing(table: "conversations", column: "is_request_sender", definition: "INTEGER")
        try addColumnIfMissing(table: "conversations", column: "pending_sent_count", definition: "INTEGER")
        try addColumnIfMissing(table: "conversations", column: "request_id", definition: "TEXT")
        
        // Migration 19: Add channel support
        try addColumnIfMissing(table: "conversations", column: "is_channel", definition: "INTEGER DEFAULT 0")
        try addColumnIfMissing(table: "conversations", column: "channel_username", definition: "TEXT")
        try addColumnIfMissing(table: "conversations", column: "channel_type", definition: "TEXT")
        try addColumnIfMissing(table: "messages", column: "forwarded_from_channel", definition: "TEXT")
        try addColumnIfMissing(table: "messages", column: "forwarded_from_channel_name", definition: "TEXT")

        isInitialized = true
        #if DEBUG
        print("✅ [Database] Migrations complete")
        #endif
    }
    
    /// Allowed table names for SQL operations (prevents SQL injection)
    private static let allowedTables: Set<String> = [
        "messages", "conversations", "posts", "local_feed", 
        "pending_reads", "mesh_message_cache", "friend_devices", "pending_acks",
        "outbox", "message_reads"
    ]
    
    /// Validate table name against whitelist (SQL injection prevention)
    private func validateTableName(_ table: String) throws {
        guard Self.allowedTables.contains(table) else {
            throw DatabaseError.invalidTableName(table)
        }
    }
    
    /// Add a column to a table only if it doesn't already exist
    /// This prevents "duplicate column name" warnings
    /// SECURITY: Table and column names are validated against whitelist
    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        // 🔒 SQL Injection Prevention: Validate table name
        try validateTableName(table)
        
        // 🔒 Column name validation: alphanumeric + underscore only
        let columnPattern = /^[a-zA-Z_][a-zA-Z0-9_]*$/
        guard column.wholeMatch(of: columnPattern) != nil else {
            throw DatabaseError.invalidColumnName(column)
        }
        
        // Check if column exists using PRAGMA table_info
        // Table name is now validated, safe for interpolation
        let pragmaSQL = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        
        var columnExists = false
        if sqlite3_prepare_v2(db, pragmaSQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(stmt, 1) {
                    let name = String(cString: namePtr)
                    if name == column {
                        columnExists = true
                        break
                    }
                }
            }
        }
        sqlite3_finalize(stmt)
        
        // Only add if missing - table and column names are validated
        if !columnExists {
            let alterSQL = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)"
            if sqlite3_exec(db, alterSQL, nil, nil, nil) == SQLITE_OK {
                #if DEBUG
                print("📦 [Database] Added column \(table).\(column)")
                #endif
            }
        }
    }
    
    private func createTables() throws {
        let schemas = [
            // MESSAGES - with client_message_id for idempotency
            """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                client_message_id TEXT NOT NULL UNIQUE,
                server_id TEXT UNIQUE,
                room_id TEXT NOT NULL,
                sender_id TEXT NOT NULL,
                sender_name TEXT,
                recipient_id TEXT NOT NULL,
                text TEXT,
                timestamp TEXT NOT NULL,
                type TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                delivery_authority TEXT NOT NULL DEFAULT 'server',
                sent_via_server INTEGER NOT NULL DEFAULT 0,
                sent_via_mesh INTEGER NOT NULL DEFAULT 0,
                display_state TEXT NOT NULL DEFAULT 'ready',
                created_at TEXT,
                delivered_at TEXT,
                read_at TEXT,
                local_path TEXT,
                remote_url TEXT,
                thumbnail_url TEXT,
                file_name TEXT,
                mime_type TEXT,
                file_size INTEGER,
                audio_duration_seconds INTEGER,
                upload_progress REAL DEFAULT 0,
                last_error TEXT,
                reply_to_message_id TEXT,
                reply_to_text_preview TEXT,
                reply_to_sender_name TEXT,
                reply_to_type TEXT,
                forwarded_from_channel TEXT,
                forwarded_from_channel_name TEXT,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_messages_room ON messages(room_id)",
            "CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp DESC)",
            "CREATE INDEX IF NOT EXISTS idx_messages_client_id ON messages(client_message_id)",
            
            // CONVERSATIONS
            """
            CREATE TABLE IF NOT EXISTS conversations (
                room_id TEXT PRIMARY KEY,
                peer_id TEXT NOT NULL,
                peer_username TEXT,
                peer_first_name TEXT,
                peer_last_name TEXT,
                peer_avatar_path TEXT,
                last_message_id TEXT,
                last_message_content TEXT,
                last_message_type TEXT,
                last_message_timestamp TEXT,
                last_message_sender_id TEXT,
                last_message_delivery_authority TEXT,
                unread_count INTEGER DEFAULT 0,
                is_pinned INTEGER DEFAULT 0,
                is_muted INTEGER DEFAULT 0,
                is_group INTEGER DEFAULT 0,
                group_name TEXT,
                group_avatar_url TEXT,
                is_channel INTEGER DEFAULT 0,
                channel_username TEXT,
                channel_type TEXT,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_conversations_updated ON conversations(updated_at DESC)",
            
            // GROUPS - for group chat persistence
            """
            CREATE TABLE IF NOT EXISTS groups (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                avatar_url TEXT,
                description TEXT,
                created_by TEXT NOT NULL,
                creator_username TEXT,
                created_at TEXT NOT NULL,
                member_count INTEGER DEFAULT 0,
                members_json TEXT,
                sync_status TEXT DEFAULT 'synced',
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_groups_updated ON groups(updated_at DESC)",
            
            // GROUP NICKNAMES - personal nicknames for group members
            """
            CREATE TABLE IF NOT EXISTS group_nicknames (
                id TEXT PRIMARY KEY,
                group_id TEXT NOT NULL,
                member_id TEXT NOT NULL,
                nickname TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(group_id, member_id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_group_nicknames_group ON group_nicknames(group_id)",
            
            // GROUP WALLPAPERS - personal wallpaper preferences per group
            """
            CREATE TABLE IF NOT EXISTS group_wallpapers (
                group_id TEXT PRIMARY KEY,
                wallpaper_type TEXT NOT NULL,
                wallpaper_value TEXT,
                updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """,
            
            // NOTIFICATIONS
            """
            CREATE TABLE IF NOT EXISTS notifications (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                data TEXT,
                timestamp TEXT NOT NULL,
                is_read INTEGER DEFAULT 0
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_notifications_timestamp ON notifications(timestamp DESC)",
            
            // POSTS - for feed persistence
            """
            CREATE TABLE IF NOT EXISTS posts (
                id TEXT PRIMARY KEY,
                client_post_id TEXT UNIQUE,
                author_id TEXT NOT NULL,
                author_username TEXT NOT NULL,
                author_avatar TEXT,
                content TEXT NOT NULL DEFAULT '',
                image_url TEXT,
                visibility TEXT,
                latitude REAL,
                longitude REAL,
                distance_m INTEGER,
                likes INTEGER DEFAULT 0,
                comments INTEGER DEFAULT 0,
                reposts INTEGER DEFAULT 0,
                view_count INTEGER DEFAULT 0,
                is_local INTEGER DEFAULT 0,
                is_liked INTEGER DEFAULT 0,
                is_reposted INTEGER DEFAULT 0,
                source TEXT,
                status TEXT DEFAULT 'posted',
                feed_type TEXT,
                timestamp TEXT NOT NULL,
                edited_at TEXT,
                is_verified INTEGER DEFAULT 0,
                is_premium INTEGER DEFAULT 0,
                initial_send TEXT,
                media_json TEXT,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_posts_timestamp ON posts(timestamp DESC)",
            "CREATE INDEX IF NOT EXISTS idx_posts_feed ON posts(feed_type)",
            "CREATE INDEX IF NOT EXISTS idx_posts_status ON posts(status)",
            "CREATE INDEX IF NOT EXISTS idx_posts_client_id ON posts(client_post_id)",
            
            // DELIVERY_JOBS - Persistent job tracking for reliable message delivery
            // Separate from messages to handle retry logic independently
            """
            CREATE TABLE IF NOT EXISTS delivery_jobs (
                job_id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL,
                channel TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER DEFAULT 0,
                next_retry_at REAL,
                last_error TEXT,
                stopped INTEGER DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(message_id, channel)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_delivery_jobs_state ON delivery_jobs(state)",
            "CREATE INDEX IF NOT EXISTS idx_delivery_jobs_channel ON delivery_jobs(channel)",
            "CREATE INDEX IF NOT EXISTS idx_delivery_jobs_retry ON delivery_jobs(next_retry_at)",
            
            // STOP_CACHE - Persisted stop commands with TTL
            """
            CREATE TABLE IF NOT EXISTS stop_cache (
                message_id TEXT PRIMARY KEY,
                stopped_at REAL NOT NULL,
                expires_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_stop_cache_expires ON stop_cache(expires_at)",
            
            // OUTBOX - Unified message delivery tracking (one row per message)
            // Core of "never lose messages" + "don't duplicate" guarantee
            """
            CREATE TABLE IF NOT EXISTS outbox (
                client_message_id TEXT PRIMARY KEY,
                receiver_id TEXT NOT NULL,
                payload TEXT NOT NULL,
                created_at TEXT NOT NULL,
                server_state INTEGER NOT NULL DEFAULT 0,
                mesh_state INTEGER NOT NULL DEFAULT 0,
                delivered_via TEXT,
                delivered_at TEXT
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_outbox_server_state ON outbox(server_state)",
            "CREATE INDEX IF NOT EXISTS idx_outbox_mesh_state ON outbox(mesh_state)",
            
            // PENDING_ACKS - Mesh delivery ACKs to sync when internet returns
            // Part of "First Delivery Wins" pattern
            """
            CREATE TABLE IF NOT EXISTS pending_acks (
                client_message_id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_pending_acks_created_at ON pending_acks(created_at)",
            
            // PENDING_ACK_DEAD_LETTERS - Exhausted ACK retries for diagnostics/support
            """
            CREATE TABLE IF NOT EXISTS pending_ack_dead_letters (
                client_message_id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                delivered_via TEXT NOT NULL DEFAULT 'mesh',
                path_used TEXT,
                idempotency_key TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                failed_at REAL NOT NULL,
                last_error TEXT
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_pending_ack_dead_failed_at ON pending_ack_dead_letters(failed_at)",
            
            // MESH_SEEN_POSTS - Deduplication cache for mesh-received posts
            """
            CREATE TABLE IF NOT EXISTS mesh_seen_posts (
                post_id TEXT PRIMARY KEY,
                first_seen_at REAL NOT NULL,
                expires_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_mesh_seen_expires ON mesh_seen_posts(expires_at)"
        ]
        
        for sql in schemas {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                let error = String(cString: sqlite3_errmsg(db))
                #if DEBUG
                print("DB Error: \(error)")
                #endif
                throw DatabaseError.failedToCreateTable
            }
        }
    }
    
    // MARK: - Execute
    
    func execute(_ sql: String, params: [Any] = []) throws {
        try ensureInitialized()
        guard db != nil else { throw DatabaseError.failedToOpen } // 🔴 SAFEGUARD: prevent nil db crash
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw DatabaseError.failedToPrepare
        }
        
        try bindParams(statement: statement, params: params)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            let error = String(cString: sqlite3_errmsg(db))
            // Ignore UNIQUE constraint violations (idempotency)
            if error.contains("UNIQUE constraint") {
                return
            }
            throw DatabaseError.failedToExecute
        }
    }
    
    /// Execute multiple database operations within a single transaction.
    /// This is critical for bulk operations (e.g. upserting hundreds of posts)
    /// to avoid per-row disk writes which cause freezes and excessive I/O.
    /// The closure receives an isolated reference to `self` so callers can
    /// invoke `execute(_:params:)` without actor-isolation errors.
    func executeInTransaction(_ operations: (isolated DatabaseService) throws -> Void) throws {
        try ensureInitialized()
        try execute("BEGIN TRANSACTION")
        do {
            try operations(self)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    
    // MARK: - Query
    
    func query(_ sql: String, params: [Any] = []) throws -> [[String: Any]] {
        try ensureInitialized()
        guard db != nil else { throw DatabaseError.failedToOpen } // 🔴 SAFEGUARD: prevent nil db crash
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw DatabaseError.failedToPrepare
        }
        
        try bindParams(statement: statement, params: params)
        
        var results: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let columnCount = sqlite3_column_count(statement)
            
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(statement, i))
                case SQLITE_BLOB:
                    if let blob = sqlite3_column_blob(statement, i) {
                        let size = sqlite3_column_bytes(statement, i)
                        row[name] = Data(bytes: blob, count: Int(size))
                    } else {
                        row[name] = Data()
                    }
                case SQLITE_NULL:
                    row[name] = NSNull()
                default:
                    break
                }
            }
            results.append(row)
        }
        
        return results
    }
    
    // MARK: - Exists
    
    func exists(_ sql: String, params: [Any] = []) throws -> Bool {
        try ensureInitialized()
        let results = try query(sql, params: params)
        return !results.isEmpty
    }
    
    // MARK: - Helpers
    
    private func bindParams(statement: OpaquePointer?, params: [Any]) throws {
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, param) in params.enumerated() {
            let idx = Int32(index + 1)
            switch param {
            case let value as String:
                sqlite3_bind_text(statement, idx, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                sqlite3_bind_int64(statement, idx, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, idx, value)
            case let value as Double:
                sqlite3_bind_double(statement, idx, value)
            case let value as Data:
                value.withUnsafeBytes { bytes in
                    if let ptr = bytes.baseAddress {
                        sqlite3_bind_blob(statement, idx, ptr, Int32(value.count), SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(statement, idx)
                    }
                }
            case let value as Date:
                // Safety: convert Date to epoch Double (prevents NSTaggedDate crash)
                sqlite3_bind_double(statement, idx, value.timeIntervalSince1970)
            case let value as Bool:
                sqlite3_bind_int64(statement, idx, value ? 1 : 0)
            case is NSNull:
                sqlite3_bind_null(statement, idx)
            default:
                sqlite3_bind_text(statement, idx, "\(param)", -1, SQLITE_TRANSIENT)
            }
        }
    }
    
    // MARK: - Clear All Data (for logout)
    
    func clearAllData() throws {
        let tables = [
            "messages", "conversations", "notifications", "posts", "groups",
            "outbox", "pending_acks", "pending_ack_dead_letters",
            "delivery_jobs", "friend_devices", "stop_cache",
            "mesh_seen_posts", "group_nicknames", "group_wallpapers",
            "pending_reads", "message_reads"
        ]
        for table in tables {
            do {
                try execute("DELETE FROM \(table)")
            } catch {
                #if DEBUG
                print("[DatabaseService] Skipping \(table): \(error)")
                #endif
            }
        }
        #if DEBUG
        print("[DatabaseService] All data cleared")
        #endif
    }
    
    // MARK: - Close
    
    func close() {
        sqlite3_close(db)
        db = nil
        isInitialized = false
    }
}

// MARK: - Error
enum DatabaseError: Error {
    case failedToOpen
    case failedToCreateTable
    case failedToPrepare
    case failedToExecute
    case failedToApplyEncryptionKey
    case failedToValidateEncryptionKey
    case encryptionKeyGenerationFailed
    case failedToStoreEncryptionKey
    case invalidTableName(String)    // SQL injection prevention
    case invalidColumnName(String)   // SQL injection prevention
    case keychainLocked              // Device locked after reboot, Keychain inaccessible
}
