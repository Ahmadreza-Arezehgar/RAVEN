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
    ///
    /// Idempotency contract
    /// ────────────────────
    /// Migrations re-run on every launch (we don't carry a schema-version
    /// number forward). That means an `ALTER TABLE … ADD COLUMN` for a
    /// column that already exists, or a `CREATE TABLE` for an existing
    /// table, would normally throw and pollute the log with red `DDL
    /// Error:` lines on every cold start (the user-reported symptom).
    ///
    /// We classify these as **benign** — the desired post-condition is
    /// "the column / table exists" which is already true. The executor
    /// silently succeeds in that case so the call site doesn't have to
    /// guard with `_columnExists` for every single column. Other DDL
    /// failures (real schema bugs) still throw.
    ///
    /// FTS5 absence
    /// ────────────
    /// When SQLCipher is built without the FTS5 module, any `CREATE
    /// VIRTUAL TABLE … USING fts5(…)` statement fails with
    /// "no such module: fts5". We log that condition once at info level
    /// and swallow the error so the rest of the migration can proceed
    /// — search just falls back to the slower `LIKE` path documented
    /// in `ConversationSearchSheet.swift`.
    private func _executeDDL(_ statements: [String]) throws {
        guard db != nil else { throw DatabaseError.failedToOpen } // 🔴 SAFEGUARD: prevent nil db crash
        for sql in statements {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                let error = String(cString: sqlite3_errmsg(db)).lowercased()

                // Benign idempotency cases — the post-condition is
                // already satisfied. SQLite returns these verbatim
                // strings; matching by substring keeps us robust to
                // small wording differences across SQLite versions.
                let benign = error.contains("duplicate column name")
                          || error.contains("already exists")
                          || error.contains("no such column")  // RENAME of a column
                                                               // that's already been renamed
                if benign {
                    continue
                }

                // FTS5 module absent — flag once, then move on. The
                // app degrades gracefully to LIKE-based search.
                if error.contains("no such module: fts5") {
                    #if DEBUG
                    print("⚠️ [Database] FTS5 module unavailable in this SQLCipher build — skipping FTS5 migration. Search will use the LIKE fallback.")
                    #endif
                    continue
                }

                #if DEBUG
                print("DDL Error: \(error)")
                #endif
                throw DatabaseError.failedToCreateTable
            }
        }
    }
    
    /// Check if a table exists in the database (for idempotent migrations).
    private func _tableExists(_ name: String) -> Bool {
        guard db != nil else { return false }
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)' LIMIT 1"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Check if a column exists on a table (for idempotent migrations).
    /// Uses PRAGMA table_info which is safe against the same SQL injection
    /// surface as `_tableExists` (we control the table name in callers).
    private func _columnExists(table: String, column: String) -> Bool {
        guard db != nil else { return false }
        let sql = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1),
               String(cString: cName) == column {
                return true
            }
        }
        return false
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
    
    /// File-backed fallback for the SQLCipher encryption key when the
    /// system Keychain refuses us with errSecMissingEntitlement (Catalyst
    /// ad-hoc-signed binaries). Lives at
    ///   ~/Library/Application Support/RAVEN/db.key
    /// with mode 0600. Same threat model as the main Keychain on a
    /// non-sandboxed local DMG: protected by the user's macOS login.
    private static let fallbackKeyURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RAVEN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("db.key")
    }()

    private func loadFallbackKey() -> String? {
        guard let data = try? Data(contentsOf: Self.fallbackKeyURL),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    private func writeFallbackKey(_ key: String) throws {
        let data = Data(key.utf8)
        try data.write(to: Self.fallbackKeyURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                ofItemAtPath: Self.fallbackKeyURL.path)
    }

    /// Get or create a 256-bit encryption key stored securely in Keychain
    /// (with a file-backed fallback for ad-hoc Catalyst).
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

        // Catalyst ad-hoc fallback path — see comment on `fallbackKeyURL`.
        if status == errSecMissingEntitlement {
            #if DEBUG
            print("⚠️ [Database] errSecMissingEntitlement reading DB key — using file fallback")
            #endif
            if let existing = loadFallbackKey() {
                return existing
            }
            // Fall through to generation; we'll persist it via the fallback path below.
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

        if storeStatus == errSecMissingEntitlement {
            // Persist via the file-backed fallback so subsequent launches reuse this key.
            do {
                try writeFallbackKey(newKey)
                #if DEBUG
                print("✅ [Database] Generated new encryption key (file fallback)")
                #endif
                return newKey
            } catch {
                throw DatabaseError.failedToStoreEncryptionKey
            }
        }

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
        
        // Migration 20: Soft-delete tracking for conversations
        // When user swipes to delete a chat, we set deleted_at instead of hard-deleting.
        // This prevents ghost conversations from reappearing via background polling/UPSERT.
        try addColumnIfMissing(table: "conversations", column: "deleted_at", definition: "TEXT")
        
        // Migration 21: PRoPHET delivery predictability table for smart mesh routing
        try _executeDDL(DeliveryPredictabilityRepository.tableCreationSQL())
        
        // Migration 22: Add post_type column + repair existing video posts
        // BUG FIX: post_type was never persisted in upsert(), so all video posts
        // had NULL post_type in DB → defaulted to "text" on cold restart → broken video rendering.
        try addColumnIfMissing(table: "posts", column: "post_type", definition: "TEXT DEFAULT 'text'")
        
        // Data repair: Fix existing video posts that have media_json with "video" mediaType
        // but post_type is NULL or "text". This is a one-time retroactive fix.
        try _executeDDL([
            """
            UPDATE posts SET post_type = 'video'
            WHERE (post_type IS NULL OR post_type = 'text')
            AND media_json LIKE '%"mediaType":"video"%'
            """,
            """
            UPDATE posts SET post_type = 'video'
            WHERE (post_type IS NULL OR post_type = 'text')
            AND media_json LIKE '%"media_type":"video"%'
            """,
            """
            UPDATE posts SET post_type = 'video'
            WHERE (post_type IS NULL OR post_type = 'text')
            AND (image_url LIKE '%.mp4' OR image_url LIKE '%.mov' OR image_url LIKE '%.m4v')
            """
        ])

        // Migration 23: Echo tables — anonymous broadcast questions with emoji responses
        try _executeDDL([
            """
            CREATE TABLE IF NOT EXISTS echoes (
                echo_id TEXT PRIMARY KEY,
                author_pseudonym TEXT NOT NULL,
                content TEXT NOT NULL,
                h3_cell TEXT,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                is_mine INTEGER DEFAULT 0,
                received_at INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS echo_responses (
                echo_id TEXT NOT NULL,
                response_emoji TEXT NOT NULL,
                response_nonce TEXT NOT NULL,
                received_at INTEGER NOT NULL,
                PRIMARY KEY (echo_id, response_nonce)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_echoes_active ON echoes(expires_at)",
            "CREATE INDEX IF NOT EXISTS idx_echo_responses_echo ON echo_responses(echo_id)"
        ])

        // Migration 24: Flock Mode tables — group movement tracking via mesh
        // CRITICAL: Only create if NEITHER old nor new table exists.
        // If we always CREATE old-name tables, Migration 26 will fail trying to rename
        // when the new-name table already exists from a previous successful migration.
        if !_tableExists("clubs") && !_tableExists("flocks") {
            try _executeDDL([
                """
                CREATE TABLE IF NOT EXISTS clubs (
                    flock_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    invite_code TEXT NOT NULL,
                    creator_id TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    drop_threshold_meters INTEGER DEFAULT 200,
                    max_members INTEGER DEFAULT 20
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS club_members (
                    member_id TEXT PRIMARY KEY,
                    flock_id TEXT NOT NULL,
                    user_id TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    h3_cell INTEGER,
                    last_seen_at INTEGER NOT NULL,
                    is_me INTEGER DEFAULT 0
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_clubs_code ON clubs(invite_code)",
                "CREATE INDEX IF NOT EXISTS idx_clubs_expires ON clubs(expires_at)",
                "CREATE INDEX IF NOT EXISTS idx_club_members_club ON club_members(flock_id)"
            ])
        }

        // Migration 25: Proximity-Locked Content table
        // CRITICAL: Only create if NEITHER old nor new table exists (same pattern as Mig 24).
        if !_tableExists("vaulted_content") && !_tableExists("proximity_content") {
            try _executeDDL([
                """
                CREATE TABLE IF NOT EXISTS vaulted_content (
                    content_id TEXT PRIMARY KEY,
                    creator_id TEXT NOT NULL,
                    creator_pseudonym TEXT NOT NULL,
                    title TEXT NOT NULL,
                    encrypted_payload TEXT NOT NULL,
                    nonce TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    target_cells TEXT NOT NULL,
                    resolution INTEGER DEFAULT 7,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL,
                    is_unlocked INTEGER DEFAULT 0,
                    unlock_distance INTEGER DEFAULT 1200,
                    received_at INTEGER NOT NULL
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_vaulted_content_expires ON vaulted_content(expires_at)"
            ])
        }

        // Migration 26: Rename Flock → Club (idempotent)
        // Only rename if old table still exists — prevents crash on re-launch
        // CRITICAL: ALTER TABLE RENAME only changes the table name, NOT column names.
        // So club_members still has "flock_id" column, not "club_id".
        if _tableExists("flocks") {
            try? _executeDDL([
                "ALTER TABLE flocks RENAME TO clubs",
                "ALTER TABLE flock_members RENAME TO club_members"
            ])
            // Re-create indexes (old index names no longer valid)
            try? _executeDDL([
                "DROP INDEX IF EXISTS idx_flocks_code",
                "DROP INDEX IF EXISTS idx_flocks_expires",
                "DROP INDEX IF EXISTS idx_flock_members_flock",
                "CREATE INDEX IF NOT EXISTS idx_clubs_code ON clubs(invite_code)",
                "CREATE INDEX IF NOT EXISTS idx_clubs_expires ON clubs(expires_at)",
                "CREATE INDEX IF NOT EXISTS idx_club_members_club ON club_members(flock_id)"
            ])
        }

        // Migration 27: Rename proximity_content → vaulted_content (idempotent)
        if _tableExists("proximity_content") && !_tableExists("vaulted_content") {
            try? _executeDDL([
                "ALTER TABLE proximity_content RENAME TO vaulted_content",
                "DROP INDEX IF EXISTS idx_proximity_expires",
                "CREATE INDEX IF NOT EXISTS idx_vaulted_content_expires ON vaulted_content(expires_at)"
            ])
        } else if _tableExists("proximity_content") {
            // Old table exists alongside new — drop the duplicate old one
            try? _executeDDL(["DROP TABLE IF EXISTS proximity_content"])
        }

        // Migration 28: Add vault_lock column to posts (JSON-encoded VaultLock)
        try? _executeDDL([
            "ALTER TABLE posts ADD COLUMN vault_lock TEXT"
        ])

        // Migration 29: Add vault_lock column to messages (JSON-encoded VaultLock)
        try? _executeDDL([
            "ALTER TABLE messages ADD COLUMN vault_lock TEXT"
        ])

        // Migration 30: Finish the Flock → Club rename by renaming the
        // `flock_id` columns. Migration 26 only renamed the tables; the columns
        // were left as `flock_id` because ALTER TABLE RENAME doesn't touch
        // columns. SQLite supports RENAME COLUMN since 3.25 (iOS 14+).
        if _columnExists(table: "clubs", column: "flock_id") {
            try? _executeDDL([
                "ALTER TABLE clubs RENAME COLUMN flock_id TO club_id"
            ])
        }
        if _columnExists(table: "club_members", column: "flock_id") {
            try? _executeDDL([
                "ALTER TABLE club_members RENAME COLUMN flock_id TO club_id",
                "DROP INDEX IF EXISTS idx_club_members_club",
                "CREATE INDEX IF NOT EXISTS idx_club_members_club ON club_members(club_id)"
            ])
        }

        // Migration 31: Club Profile fields — description, contact info, GPS precision, location source
        // CRITICAL: Each ALTER runs independently — if a column already exists,
        // _executeDDL throws and would abort remaining columns in a batch.
        try? _executeDDL(["ALTER TABLE clubs ADD COLUMN description TEXT"])
        try? _executeDDL(["ALTER TABLE clubs ADD COLUMN contact_email TEXT"])
        try? _executeDDL(["ALTER TABLE clubs ADD COLUMN external_link TEXT"])
        try? _executeDDL(["ALTER TABLE clubs ADD COLUMN raven_group_id TEXT"])
        try? _executeDDL(["ALTER TABLE clubs ADD COLUMN location_precision TEXT DEFAULT 'exact'"])
        try? _executeDDL(["ALTER TABLE clubs ADD COLUMN location_source TEXT DEFAULT 'mesh'"])

        // Migration 32: Precise GPS coordinates for club members (exact mode)
        try? _executeDDL(["ALTER TABLE club_members ADD COLUMN precise_lat REAL"])
        try? _executeDDL(["ALTER TABLE club_members ADD COLUMN precise_lng REAL"])

        // Migration 33: Avatar URL for club members (map pin display)
        // ⚡ BUG FIX (Club avatar): column was missing, so avatarURL on the
        // ClubMember model was never persisted and pins always showed initials.
        try? _executeDDL(["ALTER TABLE club_members ADD COLUMN avatar_url TEXT"])

        // Migration 34a: Mesh-only RavenShot — coords + opt-in flag on posts
        // so mesh-broadcast posts can render as map pins even when offline.
        try? _executeDDL([
            "ALTER TABLE posts ADD COLUMN latitude REAL",
            "ALTER TABLE posts ADD COLUMN longitude REAL",
            "ALTER TABLE posts ADD COLUMN show_on_raven_shot INTEGER DEFAULT 0",
            "CREATE INDEX IF NOT EXISTS idx_posts_raven_shot ON posts(show_on_raven_shot) WHERE show_on_raven_shot = 1",
        ])

        // Migration 34: Full-text search index over messages (FTS5)
        // ⚡ Replaces O(N) `LIKE '%q%'` scan in ConversationSearchSheet with
        // an indexed FTS5 MATCH query — instant search even with 100k+ messages.
        // External-content table: indexes the existing `messages` rows without
        // duplicating their data; triggers keep it in sync on INSERT/UPDATE/DELETE.
        try? _executeDDL([
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                text,
                sender_name,
                file_name,
                content='messages',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            )
            """,
            // Backfill any existing rows that pre-date the FTS table.
            // Idempotent: rebuilding from `content='messages'` is the
            // documented FTS5 way to populate from external content.
            "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')",
            // Triggers — keep FTS in sync with `messages`.
            """
            CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, text, sender_name, file_name)
                VALUES (new.rowid, new.text, new.sender_name, new.file_name);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, text, sender_name, file_name)
                VALUES('delete', old.rowid, old.text, old.sender_name, old.file_name);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, text, sender_name, file_name)
                VALUES('delete', old.rowid, old.text, old.sender_name, old.file_name);
                INSERT INTO messages_fts(rowid, text, sender_name, file_name)
                VALUES (new.rowid, new.text, new.sender_name, new.file_name);
            END
            """,
        ])

        // Migration 35: Telegram-style archive — hide a chat from
        // the inbox without deleting it. The main list filters
        // `is_archived = 0`; the archived folder filters `= 1`.
        try addColumnIfMissing(table: "conversations", column: "is_archived", definition: "INTEGER DEFAULT 0")
        try addColumnIfMissing(table: "conversations", column: "archived_at", definition: "REAL")

        isInitialized = true
        #if DEBUG
        print("✅ [Database] Migrations complete")
        #endif
    }
    
    /// Allowed table names for SQL operations (prevents SQL injection)
    private static let allowedTables: Set<String> = [
        "messages", "conversations", "posts", "local_feed", 
        "pending_reads", "mesh_message_cache", "friend_devices", "pending_acks",
        "outbox", "message_reads", "echoes", "echo_responses",
        "clubs", "club_members", "vaulted_content"
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
        
        // BUG FIX (2026-05-10): the previous version silently swallowed
        // BOTH (a) "table doesn't exist yet" cases (PRAGMA returns no
        // rows → `columnExists = false` → ALTER fails → no log, no
        // throw) AND (b) any genuine ALTER failures. The chain bug
        // it hid: Migration 16 ran BEFORE FriendDeviceRepository
        // created its table on a fresh install, so
        // `agreement_public_key` was never persisted, so ECDH was
        // permanently broken — and nobody knew because the silent
        // catch buried the error.
        //
        // New behaviour: return early WITHOUT logging when the table
        // genuinely doesn't exist (caller's responsibility to create
        // it first); throw on any real ALTER failure so callers can
        // react instead of carrying on with a missing column.

        // Check if table exists at all
        let tableExistsSQL = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
        var tableExistsStmt: OpaquePointer?
        var tableExists = false
        if sqlite3_prepare_v2(db, tableExistsSQL, -1, &tableExistsStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(tableExistsStmt, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(tableExistsStmt) == SQLITE_ROW { tableExists = true }
        }
        sqlite3_finalize(tableExistsStmt)
        guard tableExists else {
            #if DEBUG
            print("⚠️ [Database] addColumnIfMissing skipped — table '\(table)' doesn't exist yet (caller must create it first)")
            #endif
            return
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
            let rc = sqlite3_exec(db, alterSQL, nil, nil, nil)
            if rc == SQLITE_OK {
                #if DEBUG
                print("📦 [Database] Added column \(table).\(column)")
                #endif
            } else {
                let err = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.failedToExecute
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
                post_type TEXT DEFAULT 'text',
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

            // 🐛 BUG FIX (2026-05-10): unwrap an `Optional` payload before
            // the type switch. The previous version handled `is NSNull`
            // but NOT `Optional<T>.none` — a caller writing
            // `someStringOpt as Any` produced an `Optional<String>.none`
            // box that matched NONE of the switch cases and fell through
            // to the `default`, binding the literal four-character
            // string `"nil"` via `"\(param)"`. Result: nullable columns
            // (h3_cell, avatar_url, contact_email, external_link, …)
            // ended up with `"nil"` in SQL, breaking every COALESCE,
            // `IS NULL`, and `String?` decoder downstream.
            //
            // Mirror.reflect makes the switch see the underlying value
            // (or NSNull when the optional is .none), so every existing
            // `optional as Any` call site at EchoRepository / ClubRepository /
            // PostRepository / etc. is now correct without per-site edits.
            let unwrapped: Any = {
                let mirror = Mirror(reflecting: param)
                if mirror.displayStyle == .optional {
                    if let child = mirror.children.first { return child.value }
                    return NSNull()
                }
                return param
            }()

            switch unwrapped {
            case let value as String:
                sqlite3_bind_text(statement, idx, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                sqlite3_bind_int64(statement, idx, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(statement, idx, value)
            case let value as Double:
                sqlite3_bind_double(statement, idx, value)
            case let value as Data:
                _ = value.withUnsafeBytes { bytes in
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
                sqlite3_bind_text(statement, idx, "\(unwrapped)", -1, SQLITE_TRANSIENT)
            }
        }
    }
    
    // MARK: - Clear All Data (for logout)
    
    func clearAllData() throws {
        // BUG FIX (2026-05-10): the previous list omitted relay_queue,
        // mesh_dedup_cache, vaulted_content, clubs, club_members,
        // echoes, echo_responses → next user on the same device
        // inherited the previous user's clubs, vaulted notes, echoes,
        // and mesh dedup state (privacy leak + incorrect dedup
        // decisions). Tables added below; `try` is wrapped per-table so
        // a missing table on an old DB schema doesn't abort the whole
        // wipe.
        let tables = [
            // Existing — chat / social core
            "messages", "conversations", "notifications", "posts", "groups",
            "outbox", "pending_acks", "pending_ack_dead_letters",
            "delivery_jobs", "friend_devices", "stop_cache",
            "mesh_seen_posts", "group_nicknames", "group_wallpapers",
            "pending_reads", "message_reads", "delivery_predictability",
            // Added 2026-05-10 — mesh + premium features that were leaking
            "relay_queue", "mesh_dedup_cache",
            "vaulted_content",
            "clubs", "club_members",
            "echoes", "echo_responses"
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
