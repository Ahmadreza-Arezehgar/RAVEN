import 'dart:convert';  // ✅ For jsonEncode
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';
import '../models/user_model.dart';
import '../models/contact_model.dart';
import '../models/message_model.dart';
import '../models/post_model.dart';
import '../models/security_settings_model.dart';

// ═══════════════════════════════════════════════════════════════════════════
// HASHTAG EXTRACTION UTILITY
// ═══════════════════════════════════════════════════════════════════════════
List<String> extractHashtags(String text) {
  final re = RegExp(r'(?:^|\s)#([A-Za-z0-9_]+)');
  final tags = <String>{};
  for (final m in re.allMatches(text)) {
    tags.add(m.group(1)!.toLowerCase());
  }
  return tags.toList();
}

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('hybrid_messenger.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    final db = await openDatabase(
      path,
      version: 17, // v17: Added group chat columns to contacts
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
    
    // ✅ Self-healing: Ensure all required columns exist
    await _ensureMessagesColumns(db);
    
    return db;
  }
  
  /// Self-healing schema: ensures all required columns exist in users table
  /// This fixes cases where migration didn't run or DB was corrupted
  Future<void> _ensureUsersColumns(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(users)');
    final existingCols = cols.map((e) => e['name'] as String).toSet();
    
    Future<void> addColIfMissing(String name, String typeSql) async {
      if (!existingCols.contains(name)) {
        try {
          await db.execute('ALTER TABLE users ADD COLUMN $name $typeSql');
          print('✅ [Schema] Added missing column: users.$name');
        } catch (e) {
          print('⚠️ [Schema] Could not add users.$name: $e');
        }
      }
    }
    
    // Core user columns
    await addColIfMissing('firstName', 'TEXT');
    await addColIfMissing('lastName', 'TEXT');
    await addColIfMissing('email', 'TEXT');
    await addColIfMissing('phone', 'TEXT');
    await addColIfMissing('birthYear', 'INTEGER');
    await addColIfMissing('passwordHash', 'TEXT');
    await addColIfMissing('language', "TEXT DEFAULT 'en'");
    await addColIfMissing('publicKey', 'TEXT');
    await addColIfMissing('showUsername', 'INTEGER DEFAULT 1');
    await addColIfMissing('avatarPath', 'TEXT');
    await addColIfMissing('bio', 'TEXT');
  }
  
  /// Self-healing schema: ensures all required columns exist in messages table
  /// This fixes cases where migration didn't run or DB was corrupted
  Future<void> _ensureMessagesColumns(Database db) async {
    // First ensure users table is complete
    await _ensureUsersColumns(db);
    
    final cols = await db.rawQuery('PRAGMA table_info(messages)');
    final existingCols = cols.map((e) => e['name'] as String).toSet();
    
    Future<void> addColIfMissing(String name, String typeSql) async {
      if (!existingCols.contains(name)) {
        try {
          await db.execute('ALTER TABLE messages ADD COLUMN $name $typeSql');
          print('✅ [Schema] Added missing column: messages.$name');
        } catch (e) {
          print('⚠️ [Schema] Could not add $name: $e');
        }
      }
    }
    
    // DTN columns
    await addColIfMissing('messageSignature', 'TEXT');
    await addColIfMissing('sprayCounter', 'INTEGER DEFAULT 5');
    await addColIfMissing('originDeviceId', 'TEXT');
    await addColIfMissing('hopCount', 'INTEGER DEFAULT 0');
    await addColIfMissing('hopLimit', 'INTEGER DEFAULT 10');  // ✅ Added for DTN routing
    await addColIfMissing('deliveryAuthority', 'TEXT');       // ✅ Added for DTN routing
    
    // Security columns
    await addColIfMissing('expiresAt', 'TEXT');
    await addColIfMissing('deliveredAt', 'TEXT');
    await addColIfMissing('readAt', 'TEXT');
    
    // ✅ Voice transcript columns (v14)
    await addColIfMissing('audioUrl', 'TEXT');
    await addColIfMissing('transcriptText', 'TEXT');
    await addColIfMissing('transcriptLang', 'TEXT');
    await addColIfMissing('transcriptStatus', 'INTEGER DEFAULT 0');
    await addColIfMissing('audioDurationSeconds', 'REAL');  // ✅ Voice message duration
    
    // ✅ Media metadata columns (for image/file display on receiver)
    await addColIfMissing('fileName', 'TEXT');
    await addColIfMissing('mimeType', 'TEXT');
    await addColIfMissing('fileSize', 'INTEGER');
    await addColIfMissing('thumbnailUrl', 'TEXT');
    
    // ✅ Offline-first sync columns
    await addColIfMissing('serverId', 'TEXT');
    await addColIfMissing('syncState', 'INTEGER DEFAULT 0');  // 0=localOnly
    await addColIfMissing('localPath', 'TEXT');
    await addColIfMissing('retryCount', 'INTEGER DEFAULT 0');
    await addColIfMissing('lastError', 'TEXT');
    
    // ✅ Reply columns (v15)
    await addColIfMissing('replyToMessageId', 'TEXT');
    await addColIfMissing('replyToTextPreview', 'TEXT');
    await addColIfMissing('replyToSenderName', 'TEXT');
    await addColIfMissing('replyToType', 'INTEGER');
    
    // ✅ Like column (v15)
    await addColIfMissing('isLiked', 'INTEGER DEFAULT 0');
    
    // ✅ Group/Individual chat support for contacts table
    Future<void> addContactsColIfMissing(String name, String typeSql) async {
      try {
        await db.execute('ALTER TABLE contacts ADD COLUMN $name $typeSql');
        print('✅ Added contacts column: $name');
      } catch (e) {
        // Column already exists
      }
    }
    await addContactsColIfMissing('isGroup', 'INTEGER DEFAULT 0');  // 0=individual, 1=group
    await addContactsColIfMissing('roomId', 'TEXT');  // For groups: group_<uuid>
    await addContactsColIfMissing('groupTitle', 'TEXT');  // Group display name
    await addContactsColIfMissing('membersJson', 'TEXT');  // JSON array of member IDs
    
    // Ensure indexes
    await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_expiresAt ON messages(expiresAt)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_contacts_isGroup ON contacts(isGroup)');
  }
  
  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    print('🔄 Upgrading database from version $oldVersion to $newVersion');
    
    // Migration from version 1 to 2: Add pairId column to contacts
    if (oldVersion < 2) {
      print('📦 Migration 1→2: Adding message_counts and pairId');
      
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS message_counts (
            pairId TEXT PRIMARY KEY,
            count INTEGER NOT NULL DEFAULT 0,
            lastMessageAt TEXT NOT NULL
          )
        ''');
        print('✅ Created message_counts table');
      } catch (e) {
        print('⚠️ message_counts table might exist: $e');
      }
      
      // Add pairId column to contacts
      try {
        await db.execute('ALTER TABLE contacts ADD COLUMN pairId TEXT');
        print('✅ Added pairId column to contacts table');
      } catch (e) {
        print('⚠️ pairId column might already exist: $e');
      }
      
      // Add nickname column to contacts
      try {
        await db.execute('ALTER TABLE contacts ADD COLUMN nickname TEXT');
        print('✅ Added nickname column to contacts table');
      } catch (e) {
        print('⚠️ nickname column might already exist: $e');
      }
      
      // Add status column if not exists
      try {
        await db.execute('ALTER TABLE contacts ADD COLUMN status INTEGER DEFAULT 0');
        print('✅ Added status column to contacts table');
      } catch (e) {
        // Ignore if column exists
      }
    }
    
    // Migration from version 2 to 3 (or 1 to 3): Add posts table
    if (oldVersion < 3) {
      print('📦 Migration →3: Adding posts table');
      
      try {
        await db.execute(
          'CREATE TABLE IF NOT EXISTS posts('
            'id TEXT PRIMARY KEY, '
            'authorId TEXT, '
            'authorName TEXT, '
            'authorAvatar TEXT, '
            'content TEXT NOT NULL, '
            'imageUrl TEXT, '
            'timestamp TEXT NOT NULL, '
            'likes INTEGER DEFAULT 0, '
            'comments INTEGER DEFAULT 0, '
            'isLocal INTEGER DEFAULT 1'
          ')'
        );
        print('✅ Created posts table');
      } catch (e) {
        print('⚠️ Error creating posts table: $e');
      }
    }
    
    // Migration from version 3 to 4: Add showUsername column
    if (oldVersion < 4) {
      print('📦 Migration →4: Adding showUsername column');
      
      try {
        await db.execute('ALTER TABLE users ADD COLUMN showUsername INTEGER DEFAULT 1');
        print('✅ Added showUsername column to users table');
      } catch (e) {
        print('⚠️ showUsername column might exist: $e');
      }
    }
    
    // Migration from version 4 to 5: Add publicKey column for E2EE
    if (oldVersion < 5) {
      print('📦 Migration →5: Adding publicKey column');
      try {
        await db.execute('ALTER TABLE users ADD COLUMN publicKey TEXT');
        print('✅ Added publicKey column to users table');
      } catch (e) {
        print('⚠️ publicKey column might exist: $e');
      }
    }
    
    // Migration from version 5 to 6: Add sendMethod to posts
    if (oldVersion < 6) {
      print('📦 Migration →6: Adding sendMethod column to posts');
      try {
        await db.execute('ALTER TABLE posts ADD COLUMN sendMethod TEXT DEFAULT "unknown"');
        print('✅ Added sendMethod column to posts table');
      } catch (e) {
        print('⚠️ sendMethod column might exist: $e');
      }
    }
    
    // Migration from version 6 to 7: Add reports table (App Store requirement)
    if (oldVersion < 7) {
      print('📦 Migration →7: Adding reports table');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS reports (
            id TEXT PRIMARY KEY,
            reporterId TEXT NOT NULL,
            reportedUserId TEXT,
            reportedContentId TEXT,
            reportedContentType TEXT,
            reason TEXT NOT NULL,
            description TEXT,
            timestamp TEXT NOT NULL,
            status TEXT DEFAULT 'pending'
          )
        ''');
        print('✅ Created reports table');
      } catch (e) {
        print('⚠️ reports table might exist: $e');
      }
    }
    
    // Migration from version 7 to 8: Add social features
    if (oldVersion < 8) {
      print('📦 Migration →8: Adding social features');
      try {
        // Rename imagePath to imageUrl for consistency
        await db.execute('ALTER TABLE posts RENAME COLUMN imagePath TO imageUrl');
        print('✅ Renamed imagePath → imageUrl');
        
        // Add columns to posts table
        await db.execute('ALTER TABLE posts ADD COLUMN actualSendMethod TEXT');
        await db.execute('ALTER TABLE posts ADD COLUMN reposts INTEGER DEFAULT 0');
        await db.execute('ALTER TABLE posts ADD COLUMN likedBy TEXT DEFAULT "[]"');
        print('✅ Added social columns to posts table');
        
        // Create comments table
        await db.execute('''
          CREATE TABLE IF NOT EXISTS comments (
            id TEXT PRIMARY KEY,
            postId TEXT NOT NULL,
            userId TEXT NOT NULL,
            userName TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            FOREIGN KEY (postId) REFERENCES posts(id) ON DELETE CASCADE
          )
        ''');
        print('✅ Created comments table');
      } catch (e) {
        print('⚠️ Social features migration error: $e');
      }
    }
    
    // Migration from version 8 to 9: Add authentication fields
    if (oldVersion < 9) {
      print('📦 Migration →9: Adding authentication fields');
      try {
        await db.execute('ALTER TABLE users ADD COLUMN firstName TEXT');
        await db.execute('ALTER TABLE users ADD COLUMN lastName TEXT');
        await db.execute('ALTER TABLE users ADD COLUMN birthYear INTEGER');
        await db.execute('ALTER TABLE users ADD COLUMN passwordHash TEXT');
        await db.execute('ALTER TABLE users ADD COLUMN language TEXT DEFAULT "en"');
        print('✅ Added auth fields to users table');
      } catch (e) {
        print('⚠️ Auth fields migration error: $e');
      }
    }
    
    // Migration from version 9 to 10: Add email/phone to users, imageUrl/sendMethod to posts
    if (oldVersion < 10) {
      print('📦 Migration →10: Adding email/phone and post columns');
      try {
        // Add email and phone to users table
        await db.execute('ALTER TABLE users ADD COLUMN email TEXT');
        await db.execute('ALTER TABLE users ADD COLUMN phone TEXT');
        print('✅ Added email/phone columns to users table');
        
        // Add imageUrl and sendMethod to posts table if missing
        try {
          await db.execute('ALTER TABLE posts ADD COLUMN imageUrl TEXT');
          print('✅ Added imageUrl column to posts table');
        } catch (e) {
          print('⚠️ imageUrl column might exist: $e');
        }
        
        try {
          await db.execute('ALTER TABLE posts ADD COLUMN sendMethod TEXT DEFAULT "local"');
          print('✅ Added sendMethod column to posts table');
        } catch (e) {
          print('⚠️ sendMethod column might exist: $e');
        }
      } catch (e) {
        print('⚠️ Migration v10 error: $e');
      }
    }
    
    // Migration from version 10 to 11: Add security_settings table and message expiration
    if (oldVersion < 11) {
      print('📦 Migration →11: Adding security_settings table');
      try {
        // Create security_settings table
        await db.execute('''
          CREATE TABLE IF NOT EXISTS security_settings (
            id TEXT PRIMARY KEY,
            userId TEXT NOT NULL UNIQUE,
            passcodeEnabled INTEGER DEFAULT 0,
            biometricEnabled INTEGER DEFAULT 0,
            twoFactorEnabled INTEGER DEFAULT 0,
            twoFactorMethod TEXT,
            autoDeleteEnabled INTEGER DEFAULT 0,
            autoDeletePeriodHours INTEGER DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
          )
        ''');
        print('✅ Created security_settings table');
        
        // Add expiresAt column to messages for auto-delete
        try {
          await db.execute('ALTER TABLE messages ADD COLUMN expiresAt TEXT');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_expiresAt ON messages(expiresAt)');
          print('✅ Added expiresAt column to messages table');
        } catch (e) {
          print('⚠️ expiresAt column might exist: $e');
        }
      } catch (e) {
        print('⚠️ Migration v11 error: $e');
      }
    }
    
    // Migration from version 11 to 12: Add DTN mesh networking columns
    if (oldVersion < 12) {
      print('📦 Migration →12: Adding DTN mesh networking columns');
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN messageSignature TEXT');
        print('✅ Added messageSignature column');
      } catch (e) {
        print('⚠️ messageSignature column might exist: $e');
      }
      
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN sprayCounter INTEGER DEFAULT 5');
        print('✅ Added sprayCounter column');
      } catch (e) {
        print('⚠️ sprayCounter column might exist: $e');
      }
      
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN originDeviceId TEXT');
        print('✅ Added originDeviceId column');
      } catch (e) {
        print('⚠️ originDeviceId column might exist: $e');
      }
      
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN hopCount INTEGER DEFAULT 0');
        print('✅ Added hopCount column');
      } catch (e) {
        print('⚠️ hopCount column might exist: $e');
      }
    }
    
    // Migration from version 12 to 13: Add hashtags table for post search
    if (oldVersion < 13) {
      print('📦 Migration →13: Adding hashtags table for post search');
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS hashtags (
            tag TEXT NOT NULL,
            postId TEXT NOT NULL,
            PRIMARY KEY(tag, postId)
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_hashtags_tag ON hashtags(tag)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_hashtags_postId ON hashtags(postId)');
        print('✅ Created hashtags table with indexes');
        
        // Index for text search on posts
        await db.execute('CREATE INDEX IF NOT EXISTS idx_posts_content ON posts(content)');
        print('✅ Created content index on posts');
      } catch (e) {
        print('⚠️ Migration v13 error: $e');
      }
    }
    
    // Migration from version 13 to 14: Add voice transcript columns
    if (oldVersion < 14) {
      print('📦 Migration →14: Adding voice transcript columns to messages');
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN audioUrl TEXT');
        print('✅ Added audioUrl column');
      } catch (e) {
        print('⚠️ audioUrl column might exist: $e');
      }
      
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN transcriptText TEXT');
        print('✅ Added transcriptText column');
      } catch (e) {
        print('⚠️ transcriptText column might exist: $e');
      }
      
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN transcriptLang TEXT');
        print('✅ Added transcriptLang column');
      } catch (e) {
        print('⚠️ transcriptLang column might exist: $e');
      }
      
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN transcriptStatus INTEGER DEFAULT 0');
        print('✅ Added transcriptStatus column');
      } catch (e) {
        print('⚠️ transcriptStatus column might exist: $e');
      }
    }
    
    // Migration from version 14 to 15: Add reply and like columns
    if (oldVersion < 15) {
      print('📦 Migration →15: Adding reply and like columns to messages');
      
      // Reply columns
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN replyToMessageId TEXT');
        print('✅ Added replyToMessageId column');
      } catch (e) {
        print('⚠️ replyToMessageId column might exist: $e');
      }
      
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN replyToTextPreview TEXT');
        print('✅ Added replyToTextPreview column');
      } catch (e) {
        print('⚠️ replyToTextPreview column might exist: $e');
      }
      
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN replyToSenderName TEXT');
        print('✅ Added replyToSenderName column');
      } catch (e) {
        print('⚠️ replyToSenderName column might exist: $e');
      }
      
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN replyToType INTEGER');
        print('✅ Added replyToType column');
      } catch (e) {
        print('⚠️ replyToType column might exist: $e');
      }
      
      // Like column
      try {
        await db.execute('ALTER TABLE messages ADD COLUMN isLiked INTEGER DEFAULT 0');
        print('✅ Added isLiked column');
      } catch (e) {
        print('⚠️ isLiked column might exist: $e');
      }
    }
    
    // Migration from version 15 to 16: Add Mesh networking tables
    if (oldVersion < 16) {
      print('📦 Migration →16: Adding Mesh networking tables');
      
      // Presence check-ins table
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS presence_events (
            fingerprint TEXT PRIMARY KEY,
            nickname TEXT,
            lastSeenAt INTEGER,
            expiresAt INTEGER
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_presence_expires ON presence_events(expiresAt)');
        print('✅ Created presence_events table');
      } catch (e) {
        print('⚠️ presence_events table might exist: $e');
      }
      
      // Dead-drop messages table
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS dead_drops (
            id TEXT PRIMARY KEY,
            cell TEXT,
            title TEXT,
            text TEXT,
            expiresAt INTEGER,
            storedAt INTEGER,
            seen INTEGER DEFAULT 0,
            fromNickname TEXT,
            fromFingerprint TEXT
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_deaddrop_cell ON dead_drops(cell)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_deaddrop_expires ON dead_drops(expiresAt)');
        print('✅ Created dead_drops table');
      } catch (e) {
        print('⚠️ dead_drops table might exist: $e');
      }
      
      // Knowledge items table
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS knowledge_items (
            hash TEXT PRIMARY KEY,
            title TEXT,
            kind TEXT,
            mime TEXT,
            size INTEGER,
            expiresAt INTEGER,
            payloadText TEXT,
            localPath TEXT,
            score INTEGER DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_knowledge_score ON knowledge_items(score)');
        print('✅ Created knowledge_items table');
      } catch (e) {
        print('⚠️ knowledge_items table might exist: $e');
      }
      
      // Knowledge peers table (tracks who has what)
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS knowledge_peers (
            hash TEXT,
            fingerprint TEXT,
            lastSeenAt INTEGER,
            PRIMARY KEY (hash, fingerprint)
          )
        ''');
        print('✅ Created knowledge_peers table');
      } catch (e) {
        print('⚠️ knowledge_peers table might exist: $e');
      }
    }
    
    // Migration from version 16 to 17: Add group chat columns to contacts
    if (oldVersion < 17) {
      print('📦 Migration →17: Adding group chat columns to contacts');
      
      // roomId column for group chats
      try {
        await db.execute('ALTER TABLE contacts ADD COLUMN roomId TEXT');
        print('✅ Added roomId column');
      } catch (e) {
        print('⚠️ roomId column might exist: $e');
      }
      
      // isGroup column to distinguish groups from direct chats
      try {
        await db.execute('ALTER TABLE contacts ADD COLUMN isGroup INTEGER DEFAULT 0');
        print('✅ Added isGroup column');
      } catch (e) {
        print('⚠️ isGroup column might exist: $e');
      }
      
      // groupTitle column for group display name
      try {
        await db.execute('ALTER TABLE contacts ADD COLUMN groupTitle TEXT');
        print('✅ Added groupTitle column');
      } catch (e) {
        print('⚠️ groupTitle column might exist: $e');
      }
      
      // membersJson column to store group member IDs
      try {
        await db.execute('ALTER TABLE contacts ADD COLUMN membersJson TEXT');
        print('✅ Added membersJson column');
      } catch (e) {
        print('⚠️ membersJson column might exist: $e');
      }
      
      // Index for roomId lookups
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_contacts_roomId ON contacts(roomId)');
        print('✅ Created roomId index');
      } catch (e) {
        print('⚠️ roomId index might exist: $e');
      }
    }
    
    print('✅ Database migration complete!');
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL,
        email TEXT,
        phone TEXT,
        avatarPath TEXT,
        bio TEXT,
        showUsername INTEGER DEFAULT 1,
        publicKey TEXT,
        createdAt TEXT NOT NULL,
        firstName TEXT,
        lastName TEXT,
        birthYear INTEGER,
        passwordHash TEXT,
        language TEXT DEFAULT 'en'
      )
    ''');

    await db.execute(
      'CREATE TABLE posts('
        'id TEXT PRIMARY KEY, '
        'authorId TEXT, '
        'authorName TEXT, '
        'authorAvatar TEXT, '
        'content TEXT, '
        'imageUrl TEXT, '
        'timestamp TEXT, '
        'likes INTEGER DEFAULT 0, '
        'comments INTEGER DEFAULT 0, '
        'isLocal INTEGER DEFAULT 0, '
        'sendMethod TEXT DEFAULT "wifi"'
      ')',
    );
    
    await db.execute(
      'CREATE TABLE contacts('
        'id TEXT PRIMARY KEY, '
        'pairId TEXT, '
        'userId TEXT UNIQUE, '
        'username TEXT, '
        'avatarUrl TEXT, '
        'status INTEGER DEFAULT 0, '
        'pinned INTEGER DEFAULT 0, '
        'blocked INTEGER DEFAULT 0, '
        'unreadCount INTEGER DEFAULT 0, '
        'lastMessageTime TEXT, '
        'lastMessagePreview TEXT, '
        'addedAt TEXT'
      ')',
    );

    await db.execute('''
      CREATE TABLE message_counts (
        pairId TEXT PRIMARY KEY,
        count INTEGER NOT NULL DEFAULT 0,
        lastMessageAt TEXT NOT NULL
      )
    ''');


    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        roomId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        senderName TEXT NOT NULL,
        recipientId TEXT NOT NULL,
        text TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        via TEXT,
        status INTEGER NOT NULL,
        type INTEGER NOT NULL,
        ttl INTEGER NOT NULL DEFAULT 10,
        routePath TEXT,
        needsForwarding INTEGER NOT NULL DEFAULT 1,
        deliveredAt TEXT,
        readAt TEXT,
        expiresAt TEXT,
        messageSignature TEXT,
        sprayCounter INTEGER DEFAULT 5,
        originDeviceId TEXT,
        hopCount INTEGER DEFAULT 0,
        hopLimit INTEGER DEFAULT 10,
        deliveryAuthority TEXT,
        audioUrl TEXT,
        transcriptText TEXT,
        transcriptLang TEXT,
        transcriptStatus INTEGER DEFAULT 0,
        audioDurationSeconds REAL,
        fileName TEXT,
        mimeType TEXT,
        fileSize INTEGER,
        thumbnailUrl TEXT,
        serverId TEXT,
        syncState INTEGER DEFAULT 0,
        localPath TEXT,
        retryCount INTEGER DEFAULT 0,
        lastError TEXT,
        replyToMessageId TEXT,
        replyToTextPreview TEXT,
        replyToSenderName TEXT,
        replyToType INTEGER,
        isLiked INTEGER DEFAULT 0
      )
    ''');

    await db.execute('CREATE INDEX idx_messages_roomId ON messages(roomId)');
    await db.execute('CREATE INDEX idx_messages_timestamp ON messages(timestamp)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_expiresAt ON messages(expiresAt)');

    // Reports table for UGC moderation (App Store requirement)
    await db.execute('''
      CREATE TABLE reports (
        id TEXT PRIMARY KEY,
        reporterId TEXT NOT NULL,
        reportedUserId TEXT,
        reportedContentId TEXT,
        reportedContentType TEXT,
        reason TEXT NOT NULL,
        description TEXT,
        timestamp TEXT NOT NULL,
        status TEXT DEFAULT 'pending'
      )
    ''');
    
    // Security settings table
    await db.execute('''
      CREATE TABLE security_settings (
        id TEXT PRIMARY KEY,
        userId TEXT NOT NULL UNIQUE,
        passcodeEnabled INTEGER DEFAULT 0,
        biometricEnabled INTEGER DEFAULT 0,
        twoFactorEnabled INTEGER DEFAULT 0,
        twoFactorMethod TEXT,
        autoDeleteEnabled INTEGER DEFAULT 0,
        autoDeletePeriodHours INTEGER DEFAULT 0,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )
    ''');
    
    // ✅ Hashtags table for post search
    await db.execute('''
      CREATE TABLE IF NOT EXISTS hashtags (
        tag TEXT NOT NULL,
        postId TEXT NOT NULL,
        PRIMARY KEY(tag, postId)
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_hashtags_tag ON hashtags(tag)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_hashtags_postId ON hashtags(postId)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_posts_content ON posts(content)');
    
    // ✅ Mesh networking tables
    // Presence check-ins
    await db.execute('''
      CREATE TABLE IF NOT EXISTS presence_events (
        fingerprint TEXT PRIMARY KEY,
        nickname TEXT,
        lastSeenAt INTEGER,
        expiresAt INTEGER
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_presence_expires ON presence_events(expiresAt)');
    
    // Dead-drop messages
    await db.execute('''
      CREATE TABLE IF NOT EXISTS dead_drops (
        id TEXT PRIMARY KEY,
        cell TEXT,
        title TEXT,
        text TEXT,
        expiresAt INTEGER,
        storedAt INTEGER,
        seen INTEGER DEFAULT 0,
        fromNickname TEXT,
        fromFingerprint TEXT
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_deaddrop_cell ON dead_drops(cell)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_deaddrop_expires ON dead_drops(expiresAt)');
    
    // Knowledge items
    await db.execute('''
      CREATE TABLE IF NOT EXISTS knowledge_items (
        hash TEXT PRIMARY KEY,
        title TEXT,
        kind TEXT,
        mime TEXT,
        size INTEGER,
        expiresAt INTEGER,
        payloadText TEXT,
        localPath TEXT,
        score INTEGER DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_knowledge_score ON knowledge_items(score)');
    
    // Knowledge peers
    await db.execute('''
      CREATE TABLE IF NOT EXISTS knowledge_peers (
        hash TEXT,
        fingerprint TEXT,
        lastSeenAt INTEGER,
        PRIMARY KEY (hash, fingerprint)
      )
    ''');
  }

  Future<User> insertUser(User user) async {
    final db = await database;
    await db.insert('users', user.toJson());
    return user;
  }

  Future<User?> getUser(String id) async {
    final db = await database;
    final maps = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return User.fromJson(maps.first);
  }

  Future<User?> getCurrentUser() async {
    final db = await database;
    final maps = await db.query('users', limit: 1);
    if (maps.isEmpty) return null;
    return User.fromJson(maps.first);
  }

  /// Get user by ID for contact verification
  Future<User?> getUserById(String userId) async {
    final db = await database;
    final maps = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return User.fromJson(maps.first);
  }

  Future<int> updateUser(User user) async {
    final db = await database;
    return db.update(
      'users',
      user.toJson(),
      where: 'id = ?',
      whereArgs: [user.id],
    );
  }

  Future<int> saveUser(User user) async {
    return updateUser(user);
  }

  Future<Contact> insertContact(Contact contact) async {
    final db = await database;
    await db.insert('contacts', contact.toJson());
    return contact;
  }

  Future<void> updateContactStatus(String userId, int status) async {
    final db = await database;
    await db.update('contacts', {'status': status}, where: 'userId = ?', whereArgs: [userId]);
  }
  
  // Also handles inserting if new
  Future<void> upsertContact(Contact contact, int status) async {
    final db = await database;
    final exists = await db.query('contacts', where: 'userId = ?', whereArgs: [contact.userId]);
    if (exists.isNotEmpty) {
      await db.update('contacts', {'status': status}, where: 'userId = ?', whereArgs: [contact.userId]);
    } else {
      final map = contact.toJson(); // Use toJson for consistency with insertContact
      map['status'] = status;
      await db.insert('contacts', map);
    }
  }

  Future<List<Contact>> getAllContacts() async {
    final db = await database;
    final maps = await db.query('contacts', orderBy: 'username ASC');
    print('📇 [getAllContacts] Found ${maps.length} total contacts');
    return maps.map((m) => Contact.fromJson(m)).toList();
  }
  
  /// Get only contacts that are friends (status=1)
  Future<List<Contact>> getFriendsContacts() async {
    final db = await database;
    final maps = await db.query(
      'contacts',
      where: 'status = 1',
      orderBy: 'username ASC',
    );
    print('👥 [getFriendsContacts] Found ${maps.length} rows with status=1');
    
    final contacts = <Contact>[];
    for (final m in maps) {
      print('   ├── userId=${m['userId']}, username=${m['username']}, status=${m['status']}');
      try {
        final contact = Contact.fromJson(m);
        contacts.add(contact);
        print('   │   ✅ Parsed successfully');
      } catch (e) {
        print('   │   ❌ PARSING ERROR: $e');
        print('   │   Raw data: $m');
      }
    }
    
    print('👥 [getFriendsContacts] Returning ${contacts.length} contacts');
    return contacts;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // GROUP / INDIVIDUAL CHAT QUERIES
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Get group chats (isGroup=1)
  Future<List<Contact>> getGroupChats() async {
    final db = await database;
    final maps = await db.query(
      'contacts',
      where: 'blocked = 0 AND isGroup = 1',
      orderBy: 'pinned DESC, lastMessageTime DESC',
    );
    print('👥 [getGroupChats] Found ${maps.length} group chats');
    return maps.map((m) => Contact.fromJson(m)).toList();
  }
  
  /// Get individual chats (isGroup=0 or NULL)
  Future<List<Contact>> getIndividualChats() async {
    final db = await database;
    final maps = await db.query(
      'contacts',
      where: 'blocked = 0 AND (isGroup = 0 OR isGroup IS NULL)',
      orderBy: 'pinned DESC, lastMessageTime DESC',
    );
    print('👥 [getIndividualChats] Found ${maps.length} individual chats');
    return maps.map((m) => Contact.fromJson(m)).toList();
  }
  
  /// Get all conversations (both group and individual)
  Future<List<Contact>> getAllConversations() async {
    final db = await database;
    final maps = await db.query(
      'contacts',
      where: 'blocked = 0 AND lastMessageTime IS NOT NULL',
      orderBy: 'pinned DESC, lastMessageTime DESC',
    );
    print('👥 [getAllConversations] Found ${maps.length} conversations');
    return maps.map((m) => Contact.fromJson(m)).toList();
  }
  
  /// Create or update a group conversation
  Future<void> createGroupConversation({
    required String roomId,          // group_xxx
    required String title,
    required List<String> memberIds,
    String? avatarUrl,
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    
    // Check if already exists
    final existing = await db.query(
      'contacts',
      where: 'roomId = ?',
      whereArgs: [roomId],
      limit: 1,
    );
    
    if (existing.isNotEmpty) {
      // Update existing
      await db.update(
        'contacts',
        {
          'username': title,
          'groupTitle': title,
          'membersJson': jsonEncode(memberIds),
          if (avatarUrl != null) 'avatarUrl': avatarUrl,
        },
        where: 'roomId = ?',
        whereArgs: [roomId],
      );
      print('✅ [createGroupConversation] Updated group: $title');
    } else {
      // Create new
      await db.insert(
        'contacts',
        {
          'id': const Uuid().v4(),
          'userId': roomId,  // For groups, userId = roomId
          'username': title,
          'avatarUrl': avatarUrl,
          'isGroup': 1,
          'roomId': roomId,
          'groupTitle': title,
          'membersJson': jsonEncode(memberIds),
          'status': 1,  // Active
          'pinned': 0,
          'blocked': 0,
          'unreadCount': 0,
          'lastMessageTime': now,
          'lastMessagePreview': 'Group created',
          'addedAt': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      print('✅ [createGroupConversation] Created group: $title with ${memberIds.length} members');
    }
  }
  
  /// 🔍 DEBUG: Dump all contacts table
  Future<void> debugDumpContacts() async {
    final db = await database;
    final maps = await db.query('contacts');
    print('═══════════════════════════════════════════════════════════');
    print('🔍 [DEBUG] CONTACTS TABLE DUMP (${maps.length} rows)');
    print('═══════════════════════════════════════════════════════════');
    for (final m in maps) {
      print('   id: ${m['id']}');
      print('   userId: ${m['userId']}');
      print('   username: ${m['username']}');
      print('   status: ${m['status']}');
      print('   addedAt: ${m['addedAt']}');
      print('   ─────────────────────────────────────');
    }
    print('═══════════════════════════════════════════════════════════');
  }

  Future<Contact?> getContact(String userId) async {
    final db = await database;
    final maps = await db.query(
      'contacts',
      where: 'userId = ?',
      whereArgs: [userId],
    );

    if (maps.isEmpty) return null;
    return Contact.fromJson(maps.first);
  }

  Future<int> updateContact(Contact contact) async {
    final db = await database;
    return db.update(
      'contacts',
      contact.toJson(),
      where: 'id = ?',
      whereArgs: [contact.id],
    );
  }

  Future<int> deleteContact(String id) async {
    final db = await database;
    return db.delete(
      'contacts',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Delete contact by userId (used for swipe-to-delete in messages list)
  Future<int> deleteContactByUserId(String userId) async {
    final db = await database;
    return db.delete(
      'contacts',
      where: 'userId = ?',
      whereArgs: [userId],
    );
  }

  /// Insert message with duplicate protection
  /// If a message with the same id already exists, it will be ignored
  Future<ChatMessage> insertMessage(ChatMessage message) async {
    final db = await database;
    await db.insert(
      'messages', 
      message.toJson(),
      conflictAlgorithm: ConflictAlgorithm.ignore, // Prevent duplicate inserts
    );
    return message;
  }
  
  /// Check if a message with given ID already exists
  Future<bool> messageExists(String messageId) async {
    final db = await database;
    final result = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  Future<List<ChatMessage>> getMessagesForRoom(String roomId) async {
    final db = await database;
    final maps = await db.query(
      'messages',
      where: 'roomId = ?',
      whereArgs: [roomId],
      orderBy: 'timestamp ASC',
    );
    return maps.map((m) => ChatMessage.fromJson(m)).toList();
  }

  Future<int> updateMessage(ChatMessage message) async {
    final db = await database;
    return db.update(
      'messages',
      message.toJson(),
      where: 'id = ?',
      whereArgs: [message.id],
    );
  }
  
  /// Update only the status of a message by ID
  Future<int> updateMessageStatus(String messageId, MessageStatus status) async {
    final db = await database;
    return db.update(
      'messages',
      {'status': status.index},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }
  
  /// Update voice message transcript
  /// transcriptStatus: 0=none, 1=generating, 2=ready, 3=failed
  Future<int> updateMessageTranscript({
    required String messageId,
    String? transcriptText,
    String? transcriptLang,
    required int transcriptStatus,
  }) async {
    final db = await database;
    final updateData = <String, dynamic>{
      'transcriptStatus': transcriptStatus,
    };
    if (transcriptText != null) updateData['transcriptText'] = transcriptText;
    if (transcriptLang != null) updateData['transcriptLang'] = transcriptLang;
    
    print('📝 Updating transcript for message $messageId: status=$transcriptStatus');
    return db.update(
      'messages',
      updateData,
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Update message like status
  Future<int> updateMessageLike(String messageId, bool isLiked) async {
    final db = await database;
    print('❤️ Updating like for message $messageId: isLiked=$isLiked');
    return db.update(
      'messages',
      {'isLiked': isLiked ? 1 : 0},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }


  Future<List<ChatMessage>> getPendingMessages() async {
    final db = await database;
    final maps = await db.query(
      'messages',
      where: 'status = ?',
      whereArgs: [MessageStatus.pending.index],
      orderBy: 'timestamp ASC',
    );
    return maps.map((m) => ChatMessage.fromJson(m)).toList();
  }

  Future<void> close() async {
    final db = await database;
    db.close();
  }
  
  // MARK: - Cloud Sync Methods
  
  /// Get messages that haven't been synced to server
  Future<List<ChatMessage>> getUnsyncedMessages() async {
    final db = await database;
    final maps = await db.query(
      'messages',
      where: 'syncState != ? OR syncState IS NULL',
      whereArgs: [4], // 4 = SyncState.synced.index
      orderBy: 'timestamp ASC',
      limit: 50, // Batch limit
    );
    print('📤 [DB] Found ${maps.length} unsynced messages');
    return maps.map((m) => ChatMessage.fromJson(m)).toList();
  }
  
  /// Mark a message as synced to server
  Future<void> markMessageSynced(String messageId) async {
    final db = await database;
    await db.update(
      'messages',
      {'syncState': 4}, // 4 = SyncState.synced.index
      where: 'id = ?',
      whereArgs: [messageId],
    );
    print('✅ [DB] Marked message $messageId as synced');
  }

  // MARK: - Backup & Restore Methods

  /// Export all messages as JSON for backup
  Future<List<Map<String, dynamic>>> exportAllMessages() async {
    final db = await database;
    final maps = await db.query('messages', orderBy: 'timestamp ASC');
    return maps;
  }

  /// Import messages from backup with duplicate detection
  /// Returns the number of messages imported
  Future<int> importMessages(List<Map<String, dynamic>> messages) async {
    final db = await database;
    int importedCount = 0;

    await db.transaction((txn) async {
      for (var messageData in messages) {
        try {
          // Check if message already exists by ID
          final existing = await txn.query(
            'messages',
            where: 'id = ?',
            whereArgs: [messageData['id']],
            limit: 1,
          );

          if (existing.isEmpty) {
            // Insert new message
            await txn.insert('messages', messageData);
            importedCount++;
          }
        } catch (e) {
          print('Error importing message ${messageData['id']}: $e');
          // Continue with next message
        }
      }
    });

    return importedCount;
  }


  // --- Friend & Message Count Logic ---

  Future<bool> areFriends(String userId) async {
    final db = await database;
    final maps = await db.query(
      'contacts',
      where: 'userId = ? AND status = 1', // 1 = accepted
      whereArgs: [userId],
    );
    final result = maps.isNotEmpty;
    print('🔍 [areFriends] userId=$userId result=$result (found ${maps.length} records)');
    return result;
  }

  Future<int> getMessageCount(String myId, String otherId) async {
    final db = await database;
    final pairId = _getPairId(myId, otherId);
    final maps = await db.query(
      'message_counts',
      columns: ['count'],
      where: 'pairId = ?',
      whereArgs: [pairId],
    );
    if (maps.isEmpty) return 0;
    return maps.first['count'] as int;
  }

  Future<void> incrementMessageCount(String myId, String otherId) async {
    final db = await database;
    final pairId = _getPairId(myId, otherId);
    
    // Check if exists
    final current = await getMessageCount(myId, otherId);
    final count = current + 1;
    
    await db.insert(
      'message_counts',
      {
        'pairId': pairId,
        'count': count,
        'lastMessageAt': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  
  String _getPairId(String a, String b) {
    return (a.compareTo(b) < 0) ? '${a}_$b' : '${b}_$a';
  }
  
  // === FRIEND SYSTEM ===
  
  Future<int> getFriendStatus(String userId1, String userId2) async {
    final db = await database;
    final pairId = _getPairId(userId1, userId2);
    
    print('🔍 [getFriendStatus] userId1=$userId1 userId2=$userId2 pairId=$pairId');
    
    // Try by pairId first
    var result = await db.query(
      'contacts',
      where: 'pairId = ?',
      whereArgs: [pairId],
    );
    
    if (result.isEmpty) {
      // Fallback: try by userId (in case pairId wasn't set)
      result = await db.query(
        'contacts',
        where: 'userId = ?',
        whereArgs: [userId2],
      );
      print('🔍 [getFriendStatus] pairId query empty, userId query returned ${result.length} results');
    }
    
    if (result.isEmpty) {
      print('❌ [getFriendStatus] No contact found → returning 0 (Stranger)');
      return 0; // Stranger
    }
    
    final status = result.first['status'] as int;
    print('✅ [getFriendStatus] Found contact with status=$status');
    return status;
  }
  
  /// Update friend status and create/update contact
  /// status: 0=stranger, 1=friend, 2=pending, 3=request_sent
  Future<void> updateFriendStatus(
    String userId1, 
    String userId2, 
    int status, {
    String? username,
    String? avatarPath,
  }) async {
    final db = await database;
    final pairId = _getPairId(userId1, userId2);
    
    print('📝 [updateFriendStatus] userId1=$userId1 userId2=$userId2 status=$status pairId=$pairId');
    
    // First, check if contact exists
    final existing = await db.query(
      'contacts',
      where: 'userId = ?',
      whereArgs: [userId2],
      limit: 1,
    );
    
    final now = DateTime.now().toIso8601String();
    
    if (existing.isNotEmpty) {
      // Update existing contact
      final updateData = <String, dynamic>{
        'pairId': pairId,
        'status': status,
      };
      if (username != null) updateData['username'] = username;
      if (avatarPath != null) updateData['avatarUrl'] = avatarPath; // ✅ Fixed: avatarUrl not avatarPath
      
      await db.update(
        'contacts',
        updateData,
        where: 'userId = ?',
        whereArgs: [userId2],
      );
      print('✅ [updateFriendStatus] Updated contact $userId2 to status=$status');
    } else {
      // Insert new contact
      final contactId = const Uuid().v4();
      await db.insert(
        'contacts',
        {
          'id': contactId,
          'pairId': pairId,
          'userId': userId2,
          'username': username ?? 'User', 
          'avatarUrl': avatarPath, // ✅ Fixed: avatarUrl not avatarPath
          'status': status,
          'pinned': 0,
          'blocked': 0,
          'unreadCount': 0,
          'addedAt': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      print('✅ [updateFriendStatus] Created contact $userId2 with status=$status username=$username');
    }
  }
  
  Future<bool> canSendMessage(String myId, String otherId) async {
    final status = await getFriendStatus(myId, otherId);
    if (status == 1) return true; // Friends = unlimited
    
    // Strangers: check 3-message limit
    final count = await getMessageCount(myId, otherId);
    return count < 3;
  }
  
  Future<bool> needsFriendRequest(String myId, String otherId) async {
    final status = await getFriendStatus(myId, otherId);
    if (status != 0) return false; // Already has status
    
    final count = await getMessageCount(myId, otherId);
    return count >= 3;
  }
  
  // === UNREAD COUNT ===
  
  Future<void> incrementUnreadCount(String pairId) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE contacts SET unreadCount = unreadCount + 1 WHERE pairId = ?',
      [pairId],
    );
  }
  
  Future<void> clearUnreadCount(String pairId) async {
    final db = await database;
    await db.update(
      'contacts',
      {'unreadCount': 0},
      where: 'pairId = ?',
      whereArgs: [pairId],
    );
  }
  
  Future<int> getUnreadCount(String pairId) async {
    final db = await database;
    final result = await db.query(
      'contacts',
      columns: ['unreadCount'],
      where: 'pairId = ?',
      whereArgs: [pairId],
    );
    
    if (result.isEmpty) return 0;
    return result.first['unreadCount'] as int? ?? 0;
  }
  
  /// Clear unread count by userId (for when user opens chat)
  Future<void> clearUnreadCountByUserId(String otherUserId) async {
    final db = await database;
    await db.update(
      'contacts',
      {'unreadCount': 0},
      where: 'userId = ?',
      whereArgs: [otherUserId],
    );
  }
  
  // === CONVERSATION LIST ===
  
  /// Get list of conversations for Messages page
  /// Sorted by pinned first, then by lastMessageTime
  Future<List<Contact>> getConversationList() async {
    final db = await database;
    final maps = await db.query(
      'contacts',
      where: 'blocked = 0',
      orderBy: 'pinned DESC, lastMessageTime DESC',
    );
    return maps.map((m) => Contact.fromJson(m)).toList();
  }
  
  /// Update conversation after sending/receiving a message
  /// Call this after every insertMessage()
  Future<void> touchConversation({
    required String otherUserId,
    required String otherUsername,
    required String preview,
    required DateTime time,
    required bool incoming,
  }) async {
    final db = await database;
    
    // Check if contact exists
    final existing = await db.query(
      'contacts',
      where: 'userId = ?',
      whereArgs: [otherUserId],
      limit: 1,
    );
    
    final previewText = preview.length > 50 ? '${preview.substring(0, 50)}...' : preview;
    
    if (existing.isEmpty) {
      // Create new contact/conversation
      await db.insert('contacts', {
        'id': const Uuid().v4(),
        'userId': otherUserId,
        'username': otherUsername,
        'status': 0, // Stranger by default
        'pinned': 0,
        'blocked': 0,
        'unreadCount': incoming ? 1 : 0,
        'lastMessageTime': time.toIso8601String(),
        'lastMessagePreview': previewText,
        'addedAt': DateTime.now().toIso8601String(),
      });
      print('📝 Created conversation with $otherUsername');
    } else {
      // Update existing conversation
      final currentUnread = existing.first['unreadCount'] as int? ?? 0;
      await db.update(
        'contacts',
        {
          'lastMessageTime': time.toIso8601String(),
          'lastMessagePreview': previewText,
          if (incoming) 'unreadCount': currentUnread + 1,
        },
        where: 'userId = ?',
        whereArgs: [otherUserId],
      );
      print('📝 Updated conversation with $otherUsername');
    }
  }
  
  // === POSTS ===
  
  Future<void> insertPost(Post post) async {
    final db = await database;
    await db.insert(
      'posts',
      {
        'id': post.id,
        'authorId': post.authorId,
        'authorName': post.authorName,
        'authorAvatar': post.authorAvatar,
        'content': post.content,
        'imageUrl': post.imageUrl,
        'timestamp': post.timestamp.toIso8601String(),
        'likes': post.likes,
        'comments': post.comments,
        'isLocal': post.isLocal ? 1 : 0,
        'sendMethod': post.sendMethod.name,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    
    // ✅ Extract and save hashtags for search
    final tags = extractHashtags(post.content);
    for (final tag in tags) {
      await db.insert(
        'hashtags',
        {'tag': tag, 'postId': post.id},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    if (tags.isNotEmpty) {
      print('📌 Saved ${tags.length} hashtags for post ${post.id}: ${tags.join(", ")}');
    }
  }
  
  Future<List<Post>> getPosts({bool? isLocal, PostSendMethod? sendMethod}) async {
    final db = await database;
    
    String whereClause = '';
    List<dynamic> whereArgs = [];
    
    if (isLocal != null) {
      whereClause = 'isLocal = ?';
      whereArgs.add(isLocal ? 1 : 0);
    }
    
    if (sendMethod != null) {
      if (whereClause.isNotEmpty) whereClause += ' AND ';
      whereClause += 'sendMethod = ?';
      whereArgs.add(sendMethod.name);
    }
    
    final List<Map<String, dynamic>> maps = await db.query(
      'posts',
      where: whereClause.isEmpty ? null : whereClause,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'timestamp DESC',
    );
    
    final posts = maps.map((map) => Post.fromJson(map)).toList();
    
    // DEBUG: Log retrieved posts
    print('📥 Retrieved ${posts.length} posts from DB (isLocal: $isLocal, sendMethod: $sendMethod)');
    if (posts.isNotEmpty) {
      for (var post in posts.take(3)) {
        final preview = post.content.length > 30 
            ? '${post.content.substring(0, 30)}...' 
            : post.content;
        print('   - "$preview" by ${post.authorName}');
      }
    } else {
      print('   ⚠️ No posts found!');
    }
    
    return posts;
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // POST SEARCH METHODS
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Search posts by hashtag (e.g. #iran → all posts with #iran)
  Future<List<Post>> searchPostsByHashtag(String tag) async {
    final db = await database;
    final normalizedTag = tag.toLowerCase().replaceAll('#', '');
    
    final maps = await db.rawQuery('''
      SELECT p.* FROM posts p
      JOIN hashtags h ON h.postId = p.id
      WHERE h.tag = ?
      ORDER BY p.timestamp DESC
      LIMIT 50
    ''', [normalizedTag]);
    
    final posts = maps.map((m) => Post.fromJson(m)).toList();
    print('🔍 Found ${posts.length} posts with hashtag #$normalizedTag');
    return posts;
  }
  
  /// Search posts by text content (full-text search)
  Future<List<Post>> searchPostsByText(String query) async {
    final db = await database;
    
    final maps = await db.query(
      'posts',
      where: 'LOWER(content) LIKE LOWER(?)',
      whereArgs: ['%$query%'],
      orderBy: 'timestamp DESC',
      limit: 50,
    );
    
    final posts = maps.map((m) => Post.fromJson(m)).toList();
    print('🔍 Found ${posts.length} posts containing "$query"');
    return posts;
  }
  
  /// Get trending hashtags (most used in last 7 days)
  Future<List<Map<String, dynamic>>> getTrendingHashtags({int limit = 10}) async {
    final db = await database;
    final weekAgo = DateTime.now().subtract(const Duration(days: 7)).toIso8601String();
    
    final results = await db.rawQuery('''
      SELECT h.tag, COUNT(*) as count
      FROM hashtags h
      JOIN posts p ON h.postId = p.id
      WHERE p.timestamp > ?
      GROUP BY h.tag
      ORDER BY count DESC
      LIMIT ?
    ''', [weekAgo, limit]);
    
    print('🔥 Found ${results.length} trending hashtags');
    return results;
  }
  
  // === REPORTS (App Store Compliance) ===
  
  Future<void> insertReport({
    required String reporterId,
    String? reportedUserId,
    String? reportedContentId,
    String? reportedContentType,
    required String reason,
    String? description,
  }) async {
    final db = await database;
    await db.insert('reports', {
      'id': const Uuid().v4(),
      'reporterId': reporterId,
      'reportedUserId': reportedUserId,
      'reportedContentId': reportedContentId,
      'reportedContentType': reportedContentType,
      'reason': reason,
      'description': description,
      'timestamp': DateTime.now().toIso8601String(),
      'status': 'pending',
    });
    print('✅ Report submitted');
  }
  
  // === BLOCK USER ===
  
  Future<void> blockUser(String userId) async {
    final db = await database;
    await db.update(
      'contacts',
      {'blocked': 1},
      where: 'userId = ?',
      whereArgs: [userId],
    );
    print('✅ Blocked user $userId');
  }
  
  Future<void> unblockUser(String userId) async {
    final db = await database;
    await db.update(
      'contacts',
      {'blocked': 0},
      where: 'userId = ?',
      whereArgs: [userId],
    );
    print('✅ Unblocked user $userId');
  }
  
  Future<bool> isUserBlocked(String userId) async {
    final db = await database;
    final result = await db.query(
      'contacts',
      where: 'userId = ? AND blocked = 1',
      whereArgs: [userId],
    );
    return result.isNotEmpty;
  }
  
  // === NICKNAME ===
  
  Future<void> updateNickname(String contactId, String? nickname) async {
    final db = await database;
    await db.update(
      'contacts',
      {'nickname': nickname},
      where: 'id = ?',
      whereArgs: [contactId],
    );
    print('✅ Updated nickname for contact $contactId');
  }
  
  // === USERNAME SEARCH ===
  
  /// Search for users by username (case-insensitive, partial match)
  Future<List<User>> searchUsersByUsername(String username) async {
    final db = await database;
    
    // Search for users whose username contains the query (case-insensitive)
    final results = await db.query(
      'users',
      where: 'LOWER(username) LIKE LOWER(?)',
      whereArgs: ['%$username%'],
      limit: 10,
      orderBy: 'username ASC',
    );
    
    return results.map((map) => User.fromJson(map)).toList();
  }
  
  // === SECURITY SETTINGS ===
  
  /// Get security settings for a user
  Future<SecuritySettings?> getSecuritySettings(String userId) async {
    final db = await database;
    final result = await db.query(
      'security_settings',
      where: 'userId = ?',
      whereArgs: [userId],
      limit: 1,
    );
    
    if (result.isEmpty) {
      // Return default settings if none exist
      return SecuritySettings(
        id: const Uuid().v4(),
        userId: userId,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    }
    
    return SecuritySettings.fromJson(result.first);
  }
  
  /// Update or insert security set tings
  Future<void> updateSecuritySettings(SecuritySettings settings) async {
    final db = await database;
    final updated = settings.copyWith(updatedAt: DateTime.now());
    
    await db.insert(
      'security_settings',
      updated.toJson(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    print('✅ Security settings updated for user ${settings.userId}');
  }
  
  /// Get list of blocked users
  Future<List<Map<String, dynamic>>> getBlockedUsers() async {
    final db = await database;
    final result = await db.query(
      'contacts',
      where: 'blocked = 1',
      orderBy: 'username ASC',
    );
    return result;
  }
  
  /// Get messages that have expired based on expiresAt timestamp
  Future<List<ChatMessage>> getExpiredMessages() async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    
    final maps = await db.query(
      'messages',
      where: 'expiresAt IS NOT NULL AND expiresAt < ?',
      whereArgs: [now],
    );
    
    return maps.map((m) => ChatMessage.fromJson(m)).toList();
  }
  
  /// Delete expired messages
  Future<int> deleteExpiredMessages() async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    
    final count = await db.delete(
      'messages',
      where: 'expiresAt IS NOT NULL AND expiresAt < ?',
      whereArgs: [now],
    );
    
    if (count > 0) {
      print('✅ Deleted $count expired messages');
    }
    
    return count;
  }
  
  /// Set expiration time for a specific message
  Future<void> setMessageExpiration(String messageId, DateTime expiresAt) async {
    final db = await database;
    await db.update(
      'messages',
      {'expiresAt': expiresAt.toIso8601String()},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }
  
  /// Set expiration for all messages in a room based on auto-delete period
  Future<void> setRoomMessagesExpiration(String roomId, int hours) async {
    final db = await database;
    final expiresAt = DateTime.now().add(Duration(hours: hours));
    
    await db.update(
      'messages',
      {'expiresAt': expiresAt.toIso8601String()},
      where: 'roomId = ? AND expiresAt IS NULL',
      whereArgs: [roomId],
    );
  }
}

