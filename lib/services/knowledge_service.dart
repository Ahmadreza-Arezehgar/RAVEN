import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:hybrid_messenger/models/fact_model.dart';
import 'package:hybrid_messenger/services/database_helper.dart';

/// Service for managing Knowledge Facts - CRUD + Search + Mesh Sync
class KnowledgeService {
  static final KnowledgeService _instance = KnowledgeService._internal();
  factory KnowledgeService() => _instance;
  KnowledgeService._internal();

  Database? _db;

  /// Initialize the knowledge database tables
  Future<void> init() async {
    _db = await DatabaseHelper.instance.database;
    await _createTables();
    print('📚 [Knowledge] Service initialized');
  }

  /// Create facts table and FTS index
  Future<void> _createTables() async {
    if (_db == null) return;

    // Main facts table
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS facts (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        claim TEXT NOT NULL,
        tags TEXT,
        lang TEXT DEFAULT 'en',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        author_id TEXT,
        author_display_name TEXT,
        privacy_mode TEXT DEFAULT 'showName',
        sources TEXT,
        verify_status TEXT DEFAULT 'unverified',
        verify_score INTEGER DEFAULT 0,
        verify_reason TEXT,
        hash TEXT NOT NULL,
        ttl INTEGER,
        sync_count INTEGER DEFAULT 0,
        last_sync_at TEXT
      )
    ''');

    // FTS5 virtual table for full-text search
    await _db!.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
        title,
        claim,
        tags,
        content='facts',
        content_rowid='rowid'
      )
    ''');

    // Triggers to keep FTS in sync
    await _db!.execute('''
      CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
        INSERT INTO facts_fts(rowid, title, claim, tags)
        VALUES (NEW.rowid, NEW.title, NEW.claim, NEW.tags);
      END
    ''');

    await _db!.execute('''
      CREATE TRIGGER IF NOT EXISTS facts_ad AFTER DELETE ON facts BEGIN
        INSERT INTO facts_fts(facts_fts, rowid, title, claim, tags)
        VALUES ('delete', OLD.rowid, OLD.title, OLD.claim, OLD.tags);
      END
    ''');

    await _db!.execute('''
      CREATE TRIGGER IF NOT EXISTS facts_au AFTER UPDATE ON facts BEGIN
        INSERT INTO facts_fts(facts_fts, rowid, title, claim, tags)
        VALUES ('delete', OLD.rowid, OLD.title, OLD.claim, OLD.tags);
        INSERT INTO facts_fts(rowid, title, claim, tags)
        VALUES (NEW.rowid, NEW.title, NEW.claim, NEW.tags);
      END
    ''');

    print('📚 [Knowledge] Tables created with FTS5 search');
  }

  // ═══════════════════════════════════════════════════════════════════
  // CRUD OPERATIONS
  // ═══════════════════════════════════════════════════════════════════

  /// Create a new fact
  Future<Fact> createFact(Fact fact) async {
    if (_db == null) await init();

    await _db!.insert(
      'facts',
      _factToRow(fact),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    print('📚 [Knowledge] Created fact: ${fact.title}');
    return fact;
  }

  /// Get a fact by ID
  Future<Fact?> getFact(String id) async {
    if (_db == null) await init();

    final rows = await _db!.query(
      'facts',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (rows.isEmpty) return null;
    return _rowToFact(rows.first);
  }

  /// Get all facts with optional filters
  Future<List<Fact>> getFacts({
    VerifyStatus? status,
    String? lang,
    String? authorId,
    int limit = 100,
    int offset = 0,
  }) async {
    if (_db == null) await init();

    String where = '1=1';
    List<dynamic> whereArgs = [];

    if (status != null) {
      where += ' AND verify_status = ?';
      whereArgs.add(status.name);
    }
    if (lang != null) {
      where += ' AND lang = ?';
      whereArgs.add(lang);
    }
    if (authorId != null) {
      where += ' AND author_id = ?';
      whereArgs.add(authorId);
    }

    final rows = await _db!.query(
      'facts',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    return rows.map(_rowToFact).toList();
  }

  /// Get verified facts only
  Future<List<Fact>> getVerifiedFacts({int limit = 50}) async {
    return getFacts(status: VerifyStatus.verified, limit: limit);
  }

  /// Update a fact
  Future<Fact> updateFact(Fact fact) async {
    if (_db == null) await init();

    final updated = fact.copyWith(updatedAt: DateTime.now());

    await _db!.update(
      'facts',
      _factToRow(updated),
      where: 'id = ?',
      whereArgs: [fact.id],
    );

    print('📚 [Knowledge] Updated fact: ${fact.id}');
    return updated;
  }

  /// Update verification status
  Future<void> updateVerifyStatus(
    String factId, {
    required VerifyStatus status,
    int? score,
    String? reason,
  }) async {
    if (_db == null) await init();

    await _db!.update(
      'facts',
      {
        'verify_status': status.name,
        if (score != null) 'verify_score': score,
        if (reason != null) 'verify_reason': reason,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [factId],
    );

    print('📚 [Knowledge] Updated verify status: $factId -> ${status.name}');
  }

  /// Delete a fact
  Future<void> deleteFact(String id) async {
    if (_db == null) await init();

    await _db!.delete('facts', where: 'id = ?', whereArgs: [id]);
    print('📚 [Knowledge] Deleted fact: $id');
  }

  // ═══════════════════════════════════════════════════════════════════
  // SEARCH (FTS5)
  // ═══════════════════════════════════════════════════════════════════

  /// Full-text search for facts
  Future<List<Fact>> searchFacts(String query, {int limit = 50}) async {
    if (_db == null) await init();
    if (query.trim().isEmpty) return [];

    // Escape special FTS characters
    final escaped = query.replaceAll('"', '""');

    final rows = await _db!.rawQuery('''
      SELECT facts.* FROM facts
      INNER JOIN facts_fts ON facts.rowid = facts_fts.rowid
      WHERE facts_fts MATCH '"$escaped"*'
      ORDER BY rank
      LIMIT ?
    ''', [limit]);

    print('📚 [Knowledge] Search "$query" found ${rows.length} results');
    return rows.map(_rowToFact).toList();
  }

  /// Get facts by tag
  Future<List<Fact>> getFactsByTag(String tag, {int limit = 50}) async {
    if (_db == null) await init();

    final rows = await _db!.query(
      'facts',
      where: 'tags LIKE ?',
      whereArgs: ['%$tag%'],
      orderBy: 'created_at DESC',
      limit: limit,
    );

    return rows.map(_rowToFact).toList();
  }

  // ═══════════════════════════════════════════════════════════════════
  // MESH SYNC
  // ═══════════════════════════════════════════════════════════════════

  /// Save or update a fact received from mesh
  Future<bool> syncFromMesh(Fact incoming) async {
    if (_db == null) await init();

    final existing = await getFact(incoming.id);

    if (existing == null) {
      // New fact - save it
      await createFact(incoming.copyWith(syncCount: 1, lastSyncAt: DateTime.now()));
      print('📚 [Mesh] Received new fact: ${incoming.title}');
      return true;
    }

    // Check if incoming is newer
    if (incoming.updatedAt.isAfter(existing.updatedAt)) {
      await updateFact(incoming.copyWith(
        syncCount: existing.syncCount + 1,
        lastSyncAt: DateTime.now(),
      ));
      print('📚 [Mesh] Updated fact from mesh: ${incoming.title}');
      return true;
    }

    // Same or older - ignore
    print('📚 [Mesh] Ignored older version: ${incoming.id}');
    return false;
  }

  /// Get facts that need to be synced (recently created/updated)
  Future<List<Fact>> getFactsForSync({int limit = 100}) async {
    if (_db == null) await init();

    final rows = await _db!.query(
      'facts',
      orderBy: 'updated_at DESC',
      limit: limit,
    );

    return rows.map(_rowToFact).toList();
  }

  // ═══════════════════════════════════════════════════════════════════
  // STATISTICS
  // ═══════════════════════════════════════════════════════════════════

  /// Get count of facts by status
  Future<Map<VerifyStatus, int>> getFactCounts() async {
    if (_db == null) await init();

    final result = <VerifyStatus, int>{};

    for (final status in VerifyStatus.values) {
      final count = Sqflite.firstIntValue(await _db!.rawQuery(
        'SELECT COUNT(*) FROM facts WHERE verify_status = ?',
        [status.name],
      )) ?? 0;
      result[status] = count;
    }

    return result;
  }

  /// Get total facts count
  Future<int> getTotalCount() async {
    if (_db == null) await init();
    return Sqflite.firstIntValue(
      await _db!.rawQuery('SELECT COUNT(*) FROM facts'),
    ) ?? 0;
  }

  /// Get user's verified fact count (for badges)
  Future<int> getUserVerifiedCount(String userId) async {
    if (_db == null) await init();
    return Sqflite.firstIntValue(await _db!.rawQuery(
      'SELECT COUNT(*) FROM facts WHERE author_id = ? AND verify_status = ?',
      [userId, VerifyStatus.verified.name],
    )) ?? 0;
  }

  // ═══════════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════════

  Map<String, dynamic> _factToRow(Fact fact) {
    return {
      'id': fact.id,
      'title': fact.title,
      'claim': fact.claim,
      'tags': jsonEncode(fact.tags),
      'lang': fact.lang,
      'created_at': fact.createdAt.toIso8601String(),
      'updated_at': fact.updatedAt.toIso8601String(),
      'author_id': fact.authorId,
      'author_display_name': fact.authorDisplayName,
      'privacy_mode': fact.privacyMode.name,
      'sources': jsonEncode(fact.sources),
      'verify_status': fact.verifyStatus.name,
      'verify_score': fact.verifyScore,
      'verify_reason': fact.verifyReason,
      'hash': fact.hash,
      'ttl': fact.ttl,
      'sync_count': fact.syncCount,
      'last_sync_at': fact.lastSyncAt?.toIso8601String(),
    };
  }

  Fact _rowToFact(Map<String, dynamic> row) {
    return Fact(
      id: row['id'] as String,
      title: row['title'] as String,
      claim: row['claim'] as String,
      tags: _parseJsonList(row['tags']),
      lang: row['lang'] as String? ?? 'en',
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      authorId: row['author_id'] as String?,
      authorDisplayName: row['author_display_name'] as String?,
      privacyMode: PrivacyMode.values.firstWhere(
        (e) => e.name == row['privacy_mode'],
        orElse: () => PrivacyMode.showName,
      ),
      sources: _parseJsonList(row['sources']),
      verifyStatus: VerifyStatus.values.firstWhere(
        (e) => e.name == row['verify_status'],
        orElse: () => VerifyStatus.unverified,
      ),
      verifyScore: row['verify_score'] as int? ?? 0,
      verifyReason: row['verify_reason'] as String?,
      hash: row['hash'] as String,
      ttl: row['ttl'] as int?,
      syncCount: row['sync_count'] as int? ?? 0,
      lastSyncAt: row['last_sync_at'] != null
          ? DateTime.parse(row['last_sync_at'] as String)
          : null,
    );
  }

  List<String> _parseJsonList(dynamic value) {
    if (value == null) return [];
    if (value is List) return value.cast<String>();
    if (value is String) {
      try {
        return (jsonDecode(value) as List).cast<String>();
      } catch (_) {
        return [];
      }
    }
    return [];
  }
}
