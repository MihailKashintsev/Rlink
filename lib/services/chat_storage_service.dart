import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/chat_message.dart';
import '../utils/reaction_emoji_key.dart';
import '../utils/reaction_limit.dart';
import '../utils/message_preview_formatter.dart';
import '../models/contact.dart';
import 'contact_trust_service.dart';
import 'image_service.dart';

Future<void> _backfillDmReadCursors(Database db) async {
  final peers = await db.rawQuery(
    'SELECT peer_id, MAX(timestamp) AS mt FROM messages GROUP BY peer_id',
  );
  for (final r in peers) {
    final pid = r['peer_id'] as String;
    final mt = r['mt'] as int;
    final idRows = await db.rawQuery(
      'SELECT id FROM messages WHERE peer_id = ? AND timestamp = ? '
      'ORDER BY id DESC LIMIT 1',
      [pid, mt],
    );
    final mid = idRows.isNotEmpty ? (idRows.first['id'] as String?) ?? '' : '';
    await db.insert(
      'conversation_read_cursor',
      {
        'conv_key': 'dm:$pid',
        'last_read_ts': mt,
        'last_read_id': mid,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

Future<void> _tryDeleteLocalMediaFile(String? path) async {
  if (kIsWeb) return;
  if (path == null || path.isEmpty) return;
  final resolved = ImageService.instance.resolveStoredPath(path) ?? path;
  try {
    final f = File(resolved);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

class ChatStorageService {
  ChatStorageService._();
  static final ChatStorageService instance = ChatStorageService._();

  Future<String> _dbPath(String fileName) async {
    if (kIsWeb) return fileName;
    final dir = await getApplicationDocumentsDirectory();
    return join(dir.path, fileName);
  }

  /// Один поток ЛС на Ed25519 ключ: в БД и нотификаторах всегда lowercase hex.
  static String normalizeDmPeerId(String peerId) {
    final t = peerId.trim();
    if (t.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t)) {
      return t.toLowerCase();
    }
    return t;
  }

  Database? _db;
  final _messageSavedController = StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get messageSavedStream => _messageSavedController.stream;

  Future<void> _ensureDbReady() async {
    if (_db != null) return;
    await init();
  }

  Future<void>? _webDbRecovery;

  bool _isSqliteCorruption(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('database disk image is malformed') ||
        text.contains('sqlite_error: 11') ||
        text.contains('sqliteexception(11') ||
        text.contains('sqlite_corrupt') ||
        text.contains('database_corrupt') ||
        text.contains('sqlite quick_check failed');
  }

  Future<T> _withWebDbRecovery<T>(
    String context,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } catch (e) {
      if (!kIsWeb || !_isSqliteCorruption(e)) rethrow;
      await _recoverWebDatabaseAfterCorruption(e, context);
      return action();
    }
  }

  Future<void> _recoverWebDatabaseAfterCorruption(
    Object error,
    String context,
  ) {
    if (!kIsWeb) return Future.value();
    final existing = _webDbRecovery;
    if (existing != null) return existing;

    final recovery = _recreateWebDatabaseAfterCorruption(error, context);
    _webDbRecovery = recovery.whenComplete(() {
      _webDbRecovery = null;
    });
    return _webDbRecovery!;
  }

  Future<void> _recreateWebDatabaseAfterCorruption(
    Object error,
    String context,
  ) async {
    final path = await _dbPath('rlink.db');
    debugPrint(
      '[RLINK][DB] Web database is corrupt during $context; '
      'recreating $path: $error',
    );
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    _contactsNotifier.value = [];
    _messagesNotifiers.clear();
    await deleteDatabase(path);
    _db = await _openMainDatabase(path);
  }

  /// Bumps when DM read cursors change — chat list refreshes unread badges.
  final readStateVersion = ValueNotifier<int>(0);

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _contactsNotifier.value = [];
  }

  Future<void> resetAll() async {
    await close();
    // Очищаем кэш нотификаторов сообщений
    _messagesNotifiers.clear();
    final path = await _dbPath('rlink.db');
    await deleteDatabase(path);
  }

  Future<Map<String, dynamic>> exportBackupSnapshot() async {
    await _ensureDbReady();
    if (_db == null) return const {'v': 1};
    final contacts = await _db!.query('contacts');
    final messages = await _db!.query('messages');
    final pins = await _db!.query('dm_chat_pins');
    final scheduled = await _db!.query('scheduled_dm');
    final cursors = await _db!.query('conversation_read_cursor');
    final localProfile = await _db!.query('local_profile_cache');
    return {
      'v': 1,
      'contacts': contacts.map((r) => Map<String, dynamic>.from(r)).toList(),
      'messages': messages.map((r) => Map<String, dynamic>.from(r)).toList(),
      'pins': pins.map((r) => Map<String, dynamic>.from(r)).toList(),
      'scheduled': scheduled.map((r) => Map<String, dynamic>.from(r)).toList(),
      'cursors': cursors.map((r) => Map<String, dynamic>.from(r)).toList(),
      'localProfile':
          localProfile.map((r) => Map<String, dynamic>.from(r)).toList(),
    };
  }

  Future<void> importBackupSnapshot(Map<String, dynamic> snapshot) async {
    await _ensureDbReady();
    if (_db == null) return;
    final contacts = (snapshot['contacts'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final messages = (snapshot['messages'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final pins = (snapshot['pins'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final scheduled = (snapshot['scheduled'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final cursors = (snapshot['cursors'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final localProfile =
        (snapshot['localProfile'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
    await _db!.transaction((txn) async {
      for (final row in contacts) {
        await txn.insert(
          'contacts',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in messages) {
        await txn.insert(
          'messages',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in pins) {
        await txn.insert(
          'dm_chat_pins',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in scheduled) {
        await txn.insert(
          'scheduled_dm',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in cursors) {
        await txn.insert(
          'conversation_read_cursor',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final row in localProfile) {
        await txn.insert(
          'local_profile_cache',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    _contactsNotifier.value = await getContacts();
    _messagesNotifiers.clear();
  }

  Future<void> init() async {
    // Windows/Linux: использует FFI-реализацию SQLite вместо нативной
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final path = await _dbPath('rlink.db');
    _db = await _openMainDatabase(path);
    debugPrint('[RLINK][DB] Initialized');
  }

  /// Full-text search index over `messages.text`, kept in sync by triggers
  /// rather than at each call site that writes a message — robust to any
  /// insert/update path, present or future. Best-effort: FTS5 ships in every
  /// sqlite3 build this project bundles (mobile system SQLite, the
  /// sqlite3_flutter_libs desktop binary, and the WASM build web uses all
  /// compile it in), but [searchMessages] still falls back to a plain LIKE
  /// scan if this table is somehow missing, so a platform without FTS5
  /// degrades instead of losing search entirely.
  Future<void> _createMessagesFts(Database db, {required bool backfill}) async {
    try {
      await db.execute(
          'CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(id UNINDEXED, text)');
      if (backfill) {
        await db.execute(
            'INSERT INTO messages_fts(id, text) SELECT id, text FROM messages');
      }
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
          INSERT INTO messages_fts(id, text) VALUES (new.id, new.text);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
          DELETE FROM messages_fts WHERE id = old.id;
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE ON messages BEGIN
          DELETE FROM messages_fts WHERE id = old.id;
          INSERT INTO messages_fts(id, text) VALUES (new.id, new.text);
        END
      ''');
    } catch (e) {
      debugPrint('[RLINK][DB] FTS5 setup failed, search will fall back to LIKE: $e');
    }
  }

  /// Splits [query] into words and quotes each as an FTS5 string literal
  /// (doubling embedded quotes), joined with the implicit AND — turns
  /// arbitrary user input into a safe MATCH argument instead of raw FTS5
  /// query syntax, which would throw on bare `-`/`*`/`:`/unbalanced quotes.
  static String _ftsMatchQuery(String query) {
    return query
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => '"${w.replaceAll('"', '""')}"')
        .join(' ');
  }

  Future<Database> _openMainDatabase(String path) async {
    Future<Database> open() async {
      final db = await openDatabase(
        path,
        version: 26,
        onCreate: (db, v) async {
          try {
            await db.rawQuery('PRAGMA journal_mode = WAL');
          } catch (_) {}
          await db.execute('''
          CREATE TABLE contacts (
            id                TEXT PRIMARY KEY,
            nick              TEXT NOT NULL,
            username          TEXT,
            color             INTEGER NOT NULL,
            emoji             TEXT NOT NULL,
            avatar_img_path   TEXT,
            x25519_key        TEXT,
            added_at          INTEGER NOT NULL,
            last_seen         INTEGER,
            tags              TEXT,
            banner_img_path   TEXT,
            profile_music_path TEXT,
            status_emoji       TEXT,
            nick_color         INTEGER,
            birthday           TEXT,
            linked_device_key  TEXT
          )
        ''');
          await db.execute('''
          CREATE TABLE messages (
            id                   TEXT PRIMARY KEY,
            peer_id              TEXT NOT NULL,
            text                 TEXT NOT NULL,
            reply_to_message_id  TEXT,
            image_path           TEXT,
            video_path           TEXT,
            voice_path           TEXT,
            latitude             REAL,
            longitude            REAL,
            file_path            TEXT,
            file_name            TEXT,
            file_size            INTEGER,
            is_outgoing          INTEGER NOT NULL,
            timestamp            INTEGER NOT NULL,
            status               INTEGER NOT NULL DEFAULT 1,
            reactions            TEXT,
            view_once            INTEGER NOT NULL DEFAULT 0,
            view_once_opened     INTEGER NOT NULL DEFAULT 0,
            is_sticker           INTEGER NOT NULL DEFAULT 0,
            forward_from_id      TEXT,
            forward_from_nick    TEXT,
            forward_from_channel_id TEXT,
            invite_payload       TEXT,
            gigachat_attachment_ids TEXT
          )
        ''');
          await db.execute(
              'CREATE INDEX idx_messages_peer ON messages(peer_id, timestamp)');
          await _createMessagesFts(db, backfill: false);
          await db.execute('''
          CREATE TABLE dm_chat_pins (
            peer_id    TEXT NOT NULL,
            message_id TEXT NOT NULL,
            pinned_at  INTEGER NOT NULL,
            PRIMARY KEY (peer_id, message_id)
          )
        ''');
          await db.execute(
              'CREATE INDEX idx_dm_pins_peer ON dm_chat_pins(peer_id, pinned_at)');
          await db.execute('''
          CREATE TABLE scheduled_dm (
            id                   TEXT PRIMARY KEY,
            peer_id              TEXT NOT NULL,
            text                 TEXT NOT NULL,
            reply_to_message_id  TEXT,
            send_at_ms           INTEGER NOT NULL,
            created_at           INTEGER NOT NULL
          )
        ''');
          await db.execute(
              'CREATE INDEX idx_sched_dm_at ON scheduled_dm(send_at_ms)');
          await db.execute('''
          CREATE TABLE conversation_read_cursor (
            conv_key      TEXT PRIMARY KEY,
            last_read_ts  INTEGER NOT NULL,
            last_read_id  TEXT NOT NULL DEFAULT ''
          )
        ''');
          await db.execute('''
          CREATE TABLE local_profile_cache (
            singleton       INTEGER PRIMARY KEY CHECK (singleton = 1),
            public_key_hex  TEXT NOT NULL,
            username        TEXT NOT NULL,
            nickname        TEXT NOT NULL,
            updated_at      INTEGER NOT NULL
          )
        ''');
        },
        onOpen: (db) async {
          try {
            await db.rawQuery('PRAGMA journal_mode = WAL');
          } catch (_) {}
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            try {
              await db.execute(
                'ALTER TABLE messages ADD COLUMN reply_to_message_id TEXT',
              );
            } catch (_) {}
          }
          if (oldVersion < 3) {
            try {
              await db.execute(
                'ALTER TABLE contacts ADD COLUMN avatar_img_path TEXT',
              );
            } catch (_) {}
            try {
              await db.execute(
                'ALTER TABLE messages ADD COLUMN image_path TEXT',
              );
            } catch (_) {}
          }
          if (oldVersion < 4) {
            try {
              await db.execute(
                'ALTER TABLE messages ADD COLUMN reactions TEXT',
              );
            } catch (_) {}
          }
          if (oldVersion < 5) {
            try {
              await db.execute(
                'ALTER TABLE messages ADD COLUMN voice_path TEXT',
              );
            } catch (_) {}
          }
          if (oldVersion < 6) {
            try {
              await db.execute(
                'ALTER TABLE messages ADD COLUMN video_path TEXT',
              );
            } catch (_) {}
          }
          if (oldVersion < 7) {
            try {
              await db.execute('ALTER TABLE messages ADD COLUMN latitude REAL');
            } catch (_) {}
            try {
              await db
                  .execute('ALTER TABLE messages ADD COLUMN longitude REAL');
            } catch (_) {}
          }
          if (oldVersion < 8) {
            try {
              await db
                  .execute('ALTER TABLE messages ADD COLUMN file_path TEXT');
            } catch (_) {}
            try {
              await db
                  .execute('ALTER TABLE messages ADD COLUMN file_name TEXT');
            } catch (_) {}
            try {
              await db
                  .execute('ALTER TABLE messages ADD COLUMN file_size INTEGER');
            } catch (_) {}
          }
          if (oldVersion < 9) {
            try {
              await db
                  .execute('ALTER TABLE contacts ADD COLUMN x25519_key TEXT');
            } catch (_) {}
          }
          if (oldVersion < 10) {
            try {
              await db.execute('ALTER TABLE contacts ADD COLUMN tags TEXT');
            } catch (_) {}
            try {
              await db.execute(
                  'ALTER TABLE contacts ADD COLUMN banner_img_path TEXT');
            } catch (_) {}
          }
          if (oldVersion < 11) {
            try {
              await db.execute('ALTER TABLE contacts ADD COLUMN username TEXT');
            } catch (_) {}
          }
          if (oldVersion < 12) {
            try {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN view_once INTEGER NOT NULL DEFAULT 0');
            } catch (_) {}
            try {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN view_once_opened INTEGER NOT NULL DEFAULT 0');
            } catch (_) {}
          }
          if (oldVersion < 13) {
            await db.execute('''
            CREATE TABLE scheduled_dm (
              id                   TEXT PRIMARY KEY,
              peer_id              TEXT NOT NULL,
              text                 TEXT NOT NULL,
              reply_to_message_id  TEXT,
              send_at_ms           INTEGER NOT NULL,
              created_at           INTEGER NOT NULL
            )
          ''');
            await db.execute(
                'CREATE INDEX idx_sched_dm_at ON scheduled_dm(send_at_ms)');
          }
          if (oldVersion < 14) {
            try {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN forward_from_id TEXT');
            } catch (_) {}
            try {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN forward_from_nick TEXT');
            } catch (_) {}
            await db.execute('''
            CREATE TABLE dm_chat_pins (
              peer_id    TEXT NOT NULL,
              message_id TEXT NOT NULL,
              pinned_at  INTEGER NOT NULL,
              PRIMARY KEY (peer_id, message_id)
            )
          ''');
            await db.execute(
                'CREATE INDEX idx_dm_pins_peer ON dm_chat_pins(peer_id, pinned_at)');
          }
          if (oldVersion < 15) {
            try {
              await db.execute(
                'ALTER TABLE contacts ADD COLUMN profile_music_path TEXT',
              );
            } catch (_) {}
          }
          if (oldVersion < 16) {
            await db.execute('''
            CREATE TABLE IF NOT EXISTS conversation_read_cursor (
              conv_key      TEXT PRIMARY KEY,
              last_read_ts  INTEGER NOT NULL,
              last_read_id  TEXT NOT NULL DEFAULT ''
            )
          ''');
            await _backfillDmReadCursors(db);
          }
          if (oldVersion < 17) {
            try {
              await db
                  .execute('ALTER TABLE contacts ADD COLUMN status_emoji TEXT');
            } catch (_) {}
          }
          if (oldVersion < 18) {
            try {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN forward_from_channel_id TEXT');
            } catch (_) {}
          }
          if (oldVersion < 19) {
            try {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN invite_payload TEXT');
            } catch (_) {}
          }
          if (oldVersion < 20) {
            try {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN gigachat_attachment_ids TEXT');
            } catch (_) {}
          }
          if (oldVersion < 22) {
            try {
              await db.execute(
                  'ALTER TABLE messages ADD COLUMN is_sticker INTEGER NOT NULL DEFAULT 0');
            } catch (_) {}
          }
          if (oldVersion < 23) {
            try {
              await db
                  .execute('ALTER TABLE contacts ADD COLUMN nick_color INTEGER');
            } catch (_) {}
          }
          if (oldVersion < 24) {
            try {
              await db
                  .execute('ALTER TABLE contacts ADD COLUMN birthday TEXT');
            } catch (_) {}
          }
          if (oldVersion < 21) {
            await db.execute('''
            CREATE TABLE IF NOT EXISTS local_profile_cache (
              singleton       INTEGER PRIMARY KEY CHECK (singleton = 1),
              public_key_hex  TEXT NOT NULL,
              username        TEXT NOT NULL,
              nickname        TEXT NOT NULL,
              updated_at      INTEGER NOT NULL
            )
          ''');
          }
          if (oldVersion < 25) {
            await _createMessagesFts(db, backfill: true);
          }
          if (oldVersion < 26) {
            try {
              await db.execute(
                  'ALTER TABLE contacts ADD COLUMN linked_device_key TEXT');
            } catch (_) {}
          }
        },
      );
      if (kIsWeb) {
        try {
          await _assertWebDatabaseHealthy(db);
        } catch (_) {
          try {
            await db.close();
          } catch (_) {}
          rethrow;
        }
      }
      return db;
    }

    try {
      return await open();
    } catch (e) {
      if (!kIsWeb || !_isSqliteCorruption(e)) rethrow;
      debugPrint(
        '[RLINK][DB] Web database is corrupt while opening $path; '
        'recreating it: $e',
      );
      await deleteDatabase(path);
      return open();
    }
  }

  Future<void> _assertWebDatabaseHealthy(Database db) async {
    final rows = await db.rawQuery('PRAGMA quick_check');
    final ok = rows.length == 1 &&
        rows.first.values.length == 1 &&
        rows.first.values.first?.toString().toLowerCase() == 'ok';
    if (!ok) {
      throw StateError('SQLite quick_check failed: $rows');
    }
  }

  // ── Контакты ─────────────────────────────────────────────────

  Future<void> saveContact(Contact contact) async {
    await _ensureDbReady();
    final map = contact.toMap();
    map['id'] = normalizeDmPeerId(contact.publicKeyHex);
    await _withWebDbRecovery('saveContact', () async {
      await _db?.insert(
        'contacts',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    _contactsNotifier.value = await getContacts();
    unawaited(_writeContactsCache());
  }

  Future<void> deleteContact(String id) async {
    await _db?.delete('contacts',
        where: 'id = ?', whereArgs: [normalizeDmPeerId(id)]);
    _contactsNotifier.value = await getContacts();
  }

  Future<List<Contact>> getContacts() async {
    await _ensureDbReady();
    return _withWebDbRecovery('getContacts', () async {
      final rows = await _db?.query('contacts', orderBy: 'nick ASC') ?? [];
      return rows.map(Contact.fromMap).toList();
    });
  }

  Future<Contact?> getContact(String id) async {
    await _ensureDbReady();
    final key = normalizeDmPeerId(id);
    return _withWebDbRecovery('getContact', () async {
      final rows =
          await _db?.query('contacts', where: 'id = ?', whereArgs: [key]);
      if (rows == null || rows.isEmpty) return null;
      return Contact.fromMap(rows.first);
    });
  }

  Future<void> updateContactLastSeen(String id) async {
    final key = normalizeDmPeerId(id);
    await _db?.update(
      'contacts',
      {'last_seen': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [key],
    );
  }

  Future<void> updateContact(Contact contact) async {
    await _db?.update(
      'contacts',
      {
        'nick': contact.nickname,
        'username': contact.username.isEmpty ? null : contact.username,
        'color': contact.avatarColor,
        'emoji': contact.avatarEmoji,
        'avatar_img_path': contact.avatarImagePath,
        'x25519_key': contact.x25519Key,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
        'tags': contact.tags.isEmpty ? null : contact.tags.join(','),
        'banner_img_path': contact.bannerImagePath,
        'profile_music_path': contact.profileMusicPath,
        'status_emoji':
            contact.statusEmoji.isEmpty ? null : contact.statusEmoji,
        'nick_color': contact.nickColor,
        'linked_device_key': contact.linkedDeviceKey,
      },
      where: 'id = ?',
      whereArgs: [normalizeDmPeerId(contact.publicKeyHex)],
    );
    _contactsNotifier.value = await getContacts();
    unawaited(_writeContactsCache());
  }

  /// Persist X25519 key for a contact (for E2E encryption across restarts)
  Future<void> updateContactX25519Key(String id, String x25519Key) async {
    final key = normalizeDmPeerId(id);
    // Flag a changed encryption key on an already-verified contact (possible
    // MITM) — onKeyObserved compares against the user-verified key.
    if (x25519Key.isNotEmpty) {
      unawaited(ContactTrustService.instance.onKeyObserved(key, x25519Key));
    }
    await _db?.update(
      'contacts',
      {'x25519_key': x25519Key},
      where: 'id = ?',
      whereArgs: [key],
    );
  }

  /// Записывает кэш имён контактов в файл для iOS-уведомлений.
  Future<void> _writeContactsCache() async {
    try {
      if (kIsWeb) return;
      final dir = await getApplicationDocumentsDirectory();
      final file = File(join(dir.path, 'contacts_cache.json'));
      final contacts = _contactsNotifier.value;
      final map = {for (final c in contacts) c.publicKeyHex: c.nickname};
      await file.writeAsString(jsonEncode(map));
    } catch (e) {
      debugPrint('[RLINK][DB] contacts cache write failed: $e');
    }
  }

  Future<void> updateContactAvatarImage(String id, String imagePath) async {
    final key = normalizeDmPeerId(id);
    await _db?.update(
      'contacts',
      {'avatar_img_path': imagePath},
      where: 'id = ?',
      whereArgs: [key],
    );
    _contactsNotifier.value = await getContacts();
  }

  Future<void> updateContactProfileMusic(String id, String musicPath) async {
    final key = normalizeDmPeerId(id);
    await _db?.update(
      'contacts',
      {'profile_music_path': musicPath},
      where: 'id = ?',
      whereArgs: [key],
    );
    _contactsNotifier.value = await getContacts();
  }

  final _contactsNotifier = ValueNotifier<List<Contact>>([]);
  ValueNotifier<List<Contact>> get contactsNotifier => _contactsNotifier;

  /// Увеличивается при изменении закреплений в личных чатах (UI плашки).
  final pinsVersion = ValueNotifier<int>(0);

  Future<void> loadContacts() async {
    _contactsNotifier.value = await getContacts();
  }

  // ── Сообщения ────────────────────────────────────────────────

  Future<void> saveMessage(ChatMessage message) async {
    await _ensureDbReady();
    final peerKey = normalizeDmPeerId(message.peerId);
    final stored =
        peerKey == message.peerId ? message : message.copyWith(peerId: peerKey);
    await _withWebDbRecovery('saveMessage', () async {
      await _db?.insert(
        'messages',
        stored.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    _notifyMessages(peerKey);
    _messageSavedController.add(stored);
  }

  Future<void> editMessage(String messageId, String newText) async {
    final peerId = await _getPeerIdForMessage(messageId);
    if (peerId == null) return;
    await _db?.update(
      'messages',
      {'text': newText},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notifyMessages(peerId);
  }

  Future<ChatMessage?> getMessageById(String messageId) async {
    await _ensureDbReady();
    return _withWebDbRecovery('getMessageById', () async {
      final rows = await _db?.query(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      if (rows == null || rows.isEmpty) return null;
      return ChatMessage.fromMap(rows.first);
    });
  }

  /// Сообщения со стикером (картинка `stk_*`) в чате с контактом, новые первыми.
  Future<List<ChatMessage>> getStickerMessagesForPeer(
    String peerId, {
    int limit = 500,
  }) async {
    final rows = await _db?.query(
      'messages',
      where: 'peer_id = ? AND image_path IS NOT NULL',
      whereArgs: [peerId],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    if (rows == null || rows.isEmpty) return const [];
    final out = <ChatMessage>[];
    for (final r in rows) {
      final m = ChatMessage.fromMap(r);
      final ip = m.imagePath;
      if (ip != null && basename(ip).startsWith('stk_')) {
        out.add(m);
      }
    }
    return out;
  }

  // ── Отложенная отправка (личный чат) ───────────────────────────

  Future<void> insertScheduledDm({
    required String id,
    required String peerId,
    required String text,
    String? replyToMessageId,
    required int sendAtMs,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db?.insert('scheduled_dm', {
      'id': id,
      'peer_id': peerId,
      'text': text,
      'reply_to_message_id': replyToMessageId,
      'send_at_ms': sendAtMs,
      'created_at': now,
    });
  }

  Future<List<ScheduledDmRow>> getDueScheduledMessages(int nowMs) async {
    final rows = await _db?.query(
      'scheduled_dm',
      where: 'send_at_ms <= ?',
      whereArgs: [nowMs],
      orderBy: 'send_at_ms ASC',
    );
    if (rows == null) return const [];
    return rows.map(ScheduledDmRow.fromMap).toList();
  }

  Future<void> deleteScheduledDm(String id) async {
    await _db?.delete('scheduled_dm', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteMessage(String messageId) async {
    final peerId = await _getPeerIdForMessage(messageId);
    if (peerId == null) return;
    await _db?.delete(
      'dm_chat_pins',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    await _db?.delete(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );
    pinsVersion.value++;
    _notifyMessages(peerId);
  }

  Future<String?> _getPeerIdForMessage(String messageId) async {
    final rows = await _db?.query(
      'messages',
      columns: const ['peer_id'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows == null || rows.isEmpty) return null;
    return rows.first['peer_id'] as String;
  }

  Future<void> markViewOnceOpened(String messageId) async {
    final peerId = await _getPeerIdForMessage(messageId);
    if (peerId == null) return;
    await _db?.update(
      'messages',
      {'view_once_opened': 1},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notifyMessages(peerId);
  }

  Future<void> updateMessageStatus(
    String messageId,
    MessageStatus status,
  ) async {
    final rows = await _db?.query(
      'messages',
      columns: ['peer_id'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows == null || rows.isEmpty) return;
    final peerId = rows.first['peer_id'] as String;

    await _db?.update(
      'messages',
      {'status': status.index},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notifyMessages(peerId);
  }

  Future<void> updateMessageStatusPreserveDelivered(
    String messageId,
    MessageStatus status,
  ) async {
    final deliveredIndex = MessageStatus.delivered.index;

    final updated = await _db?.update(
      'messages',
      {'status': status.index},
      where: 'id = ? AND status != ?',
      whereArgs: [messageId, deliveredIndex],
    );
    if (updated == null || updated == 0) return;

    final rows = await _db?.query(
      'messages',
      columns: ['peer_id'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows == null || rows.isEmpty) return;
    _notifyMessages(rows.first['peer_id'] as String);
  }

  /// History for one conversation. When [peerId]'s contact has a known
  /// linked device (see `Contact.linkedDeviceKey`/`LinkedDeviceFanout`),
  /// also pulls in messages filed under that key and merges them in —
  /// otherwise a reply sent from the contact's OTHER device, or a message
  /// this device fanned out there, would silently split into a second,
  /// invisible conversation instead of showing up in this one.
  Future<List<ChatMessage>> getMessages(String peerId,
      {int limit = 100}) async {
    await _ensureDbReady();
    final pid = normalizeDmPeerId(peerId);
    final linkedKey = (await getContact(pid))?.linkedDeviceKey;
    return _withWebDbRecovery('getMessages', () async {
      final rows = (linkedKey != null && linkedKey.isNotEmpty)
          ? await _db?.query(
                'messages',
                where: 'peer_id = ? OR peer_id = ?',
                whereArgs: [pid, normalizeDmPeerId(linkedKey)],
                orderBy: 'timestamp ASC',
                limit: limit,
              ) ??
              []
          : await _db?.query(
                'messages',
                where: 'peer_id = ?',
                whereArgs: [pid],
                orderBy: 'timestamp ASC',
                limit: limit,
              ) ??
              [];
      return rows.map(ChatMessage.fromMap).toList();
    });
  }

  /// Полнотекстовый поиск по всем перепискам (для глобального поиска).
  /// Возвращает совпадения от новых к старым.
  /// Searches message text, newest first. [peerId] narrows to one
  /// conversation; omit it to search every chat (used by the unified search
  /// in `chat_list_screen.dart`). Tries the FTS5 index first — much faster
  /// than a LIKE scan once history grows into the thousands, and matches
  /// whole words rather than raw substrings — falling back to the original
  /// LIKE scan if the index is missing or the query fails for any reason.
  Future<List<ChatMessage>> searchMessages(
    String query, {
    String? peerId,
    int limit = 40,
  }) async {
    final q = query.trim();
    if (q.length < 2) return [];
    await _ensureDbReady();
    return _withWebDbRecovery('searchMessages', () async {
      final db = _db;
      if (db == null) return const [];
      try {
        final rows = await db.rawQuery(
          '''
          SELECT messages.* FROM messages
          JOIN messages_fts ON messages.id = messages_fts.id
          WHERE messages_fts MATCH ?
          ${peerId != null ? 'AND messages.peer_id = ?' : ''}
          ORDER BY messages.timestamp DESC
          LIMIT ?
          ''',
          [_ftsMatchQuery(q), if (peerId != null) peerId, limit],
        );
        return rows.map(ChatMessage.fromMap).toList();
      } catch (e) {
        debugPrint('[RLINK][DB] FTS5 search failed, falling back to LIKE: $e');
        final rows = await db.query(
          'messages',
          where: peerId != null ? 'text LIKE ? AND peer_id = ?' : 'text LIKE ?',
          whereArgs: peerId != null ? ['%$q%', peerId] : ['%$q%'],
          orderBy: 'timestamp DESC',
          limit: limit,
        );
        return rows.map(ChatMessage.fromMap).toList();
      }
    });
  }

  /// Последние [limit] сообщений в хронологическом порядке (для ИИ / контекста API).
  Future<List<ChatMessage>> getRecentMessagesAscending(String peerId,
      {int limit = 24}) async {
    await _ensureDbReady();
    final pid = normalizeDmPeerId(peerId);
    return _withWebDbRecovery('getRecentMessagesAscending', () async {
      final rows = await _db?.rawQuery(
            '''
          SELECT * FROM messages
          WHERE peer_id = ?
          ORDER BY timestamp DESC, rowid DESC
          LIMIT ?
          ''',
            [pid, limit],
          ) ??
          [];
      final list = rows.map(ChatMessage.fromMap).toList();
      return list.reversed.toList();
    });
  }

  /// Вся история диалога (для экспорта в файл).
  Future<List<ChatMessage>> getAllMessages(String peerId) async {
    await _ensureDbReady();
    final pid = normalizeDmPeerId(peerId);
    return _withWebDbRecovery('getAllMessages', () async {
      final rows = await _db?.query(
            'messages',
            where: 'peer_id = ?',
            whereArgs: [pid],
            orderBy: 'timestamp ASC',
          ) ??
          [];
      return rows.map(ChatMessage.fromMap).toList();
    });
  }

  /// JSON-файл во временной директории (пути к медиа — как в локальной БД).
  /// Web-safe export of a DM conversation as a JSON string (no dart:io File) —
  /// used to upload the history straight to Google Drive.
  Future<String> exportDirectChatToJsonString(String peerId) async {
    final msgs = await getAllMessages(peerId);
    final contact = await getContact(peerId);
    final export = <String, dynamic>{
      'v': 1,
      'type': 'rlink_dm_export',
      'peerId': peerId,
      if (contact != null) 'peerNick': contact.nickname,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'messages': msgs.map((m) => m.toMap()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(export);
  }

  Future<File> exportDirectChatToJsonFile(String peerId) async {
    final msgs = await getAllMessages(peerId);
    final contact = await getContact(peerId);
    final export = <String, dynamic>{
      'v': 1,
      'type': 'rlink_dm_export',
      'peerId': peerId,
      if (contact != null) 'peerNick': contact.nickname,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'messages': msgs.map((m) => m.toMap()).toList(),
    };
    final dir = await getTemporaryDirectory();
    final name =
        'rlink_dm_${peerId.length >= 8 ? peerId.substring(0, 8) : peerId}_${DateTime.now().millisecondsSinceEpoch}.json';
    final f = File(join(dir.path, name));
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(export));
    return f;
  }

  /// Все исходящие сообщения со статусом sending/failed — для очереди повторной отправки.
  /// Отсортированы по возрастанию времени, чтобы порядок доставки не ломался.
  Future<List<ChatMessage>> getPendingOutgoingMessages() async {
    await _ensureDbReady();
    return _withWebDbRecovery('getPendingOutgoingMessages', () async {
      final rows = await _db?.query(
            'messages',
            where: 'is_outgoing = 1 AND (status = ? OR status = ?)',
            whereArgs: [
              MessageStatus.sending.index,
              MessageStatus.failed.index,
            ],
            orderBy: 'timestamp ASC',
          ) ??
          [];
      return rows.map(ChatMessage.fromMap).toList();
    });
  }

  /// Все исходящие сообщения, которые ещё не подтверждены ACK'ом (не delivered).
  /// Используется для гарантированной доставки: сообщения могут быть отправлены,
  /// но ACK мог не дойти, поэтому статус остаётся sent/sending/failed.
  Future<List<ChatMessage>> getUndeliveredOutgoingMessages() async {
    await _ensureDbReady();
    final deliveredIndex = MessageStatus.delivered.index;
    return _withWebDbRecovery('getUndeliveredOutgoingMessages', () async {
      final rows = await _db?.query(
            'messages',
            where: 'is_outgoing = 1 AND status != ?',
            whereArgs: [deliveredIndex],
            orderBy: 'timestamp ASC',
          ) ??
          [];
      return rows.map(ChatMessage.fromMap).toList();
    });
  }

  /// Исчезающие сообщения: удаляет сообщения чата старше [cutoffMs].
  /// Возвращает число удалённых.
  Future<int> deleteMessagesOlderThan(String peerId, int cutoffMs) async {
    final pid = normalizeDmPeerId(peerId);
    final n = await _db?.delete('messages',
            where: 'peer_id = ? AND timestamp < ?',
            whereArgs: [pid, cutoffMs]) ??
        0;
    if (n > 0) _messagesNotifiers.remove(pid);
    return n;
  }

  Future<void> deleteChat(String peerId) async {
    final pid = normalizeDmPeerId(peerId);
    await _db?.delete('dm_chat_pins', where: 'peer_id = ?', whereArgs: [pid]);
    await _db?.delete('messages', where: 'peer_id = ?', whereArgs: [pid]);
    await _db?.delete('conversation_read_cursor',
        where: 'conv_key = ?', whereArgs: ['dm:$pid']);
    pinsVersion.value++;
    readStateVersion.value++;
    _messagesNotifiers.remove(pid);
  }

  /// Все личные диалоги (контакты и профиль не затрагиваются).
  Future<void> deleteAllDirectMessages() async {
    await _db?.delete('dm_chat_pins');
    await _db?.delete('messages');
    await _db?.delete('conversation_read_cursor',
        where: "conv_key LIKE 'dm:%'");
    pinsVersion.value++;
    readStateVersion.value++;
    for (final n in _messagesNotifiers.values) {
      n.value = [];
    }
    _messagesNotifiers.clear();
  }

  /// Очистка личных чатов: либо полностью, либо только медиа у выбранных peer_id.
  Future<void> clearDirectMessages({
    required Set<String> peerIds,
    required bool mediaOnly,
  }) async {
    if (_db == null || peerIds.isEmpty) return;
    for (final raw in peerIds) {
      final pid = normalizeDmPeerId(raw);
      if (mediaOnly) {
        final rows = await _db!.query(
          'messages',
          columns: [
            'image_path',
            'video_path',
            'voice_path',
            'file_path',
          ],
          where: 'peer_id = ?',
          whereArgs: [pid],
        );
        for (final r in rows) {
          await _tryDeleteLocalMediaFile(r['image_path'] as String?);
          await _tryDeleteLocalMediaFile(r['video_path'] as String?);
          await _tryDeleteLocalMediaFile(r['voice_path'] as String?);
          await _tryDeleteLocalMediaFile(r['file_path'] as String?);
        }
        await _db!.rawUpdate(
          'UPDATE messages SET image_path=NULL, video_path=NULL, '
          'voice_path=NULL, file_path=NULL, file_name=NULL, file_size=NULL '
          'WHERE peer_id=?',
          [pid],
        );
      } else {
        await _db!
            .delete('dm_chat_pins', where: 'peer_id = ?', whereArgs: [pid]);
        await _db!.delete('messages', where: 'peer_id = ?', whereArgs: [pid]);
        await _db!.delete('conversation_read_cursor',
            where: 'conv_key = ?', whereArgs: ['dm:$pid']);
        _messagesNotifiers.remove(pid);
      }
      _notifyMessages(pid);
    }
    pinsVersion.value++;
    readStateVersion.value++;
  }

  /// Переносит все сообщения с [oldPeerId] на [newPeerId].
  /// Используется при смене ключа контакта (переустановка приложения).
  Future<void> migrateMessages(String oldPeerId, String newPeerId) async {
    final oldP = normalizeDmPeerId(oldPeerId);
    final newP = normalizeDmPeerId(newPeerId);
    if (oldP == newP) return;
    await _db?.update(
      'messages',
      {'peer_id': newP},
      where: 'peer_id = ?',
      whereArgs: [oldP],
    );
    await _db?.update(
      'conversation_read_cursor',
      {'conv_key': 'dm:$newP'},
      where: 'conv_key = ?',
      whereArgs: ['dm:$oldP'],
    );
    _messagesNotifiers.remove(oldP);
    _notifyMessages(newP);
  }

  Future<ChatMessage?> getLastMessage(String peerId) async {
    await _ensureDbReady();
    final pid = normalizeDmPeerId(peerId);
    return _withWebDbRecovery('getLastMessage', () async {
      final rows = await _db?.query(
        'messages',
        where: 'peer_id = ?',
        whereArgs: [pid],
        orderBy: 'timestamp DESC',
        limit: 1,
      );
      if (rows == null || rows.isEmpty) return null;
      return ChatMessage.fromMap(rows.first);
    });
  }

  // ИСПРАВЛЕННЫЙ SQL — GROUP BY вместо DISTINCT с агрегатом
  Future<List<String>> getChatPeerIds() async {
    await _ensureDbReady();
    return _withWebDbRecovery('getChatPeerIds', () async {
      final rows = await _db?.rawQuery('''
      SELECT peer_id
      FROM messages
      GROUP BY peer_id
      ORDER BY MAX(timestamp) DESC
    ''') ?? [];
      return rows.map((r) => r['peer_id'] as String).toList();
    });
  }

  /// Возвращает сводку всех чатов одним SQL JOIN запросом.
  /// Избегает N+1 паттерна при загрузке списка чатов.
  Future<List<ChatSummary>> getChatSummaries() async {
    await _ensureDbReady();
    return _withWebDbRecovery('getChatSummaries', () async {
      final rows = await _db?.rawQuery('''
      SELECT
        m.peer_id,
        m.text,
        m.image_path,
        m.voice_path,
        m.video_path,
        m.timestamp,
        c.nick,
        c.color,
        c.emoji,
        c.avatar_img_path
      FROM messages m
      INNER JOIN (
        SELECT peer_id, MAX(timestamp) AS max_ts
        FROM messages
        GROUP BY peer_id
      ) latest ON m.peer_id = latest.peer_id AND m.timestamp = latest.max_ts
      LEFT JOIN contacts c ON m.peer_id = c.id
      GROUP BY m.peer_id
      ORDER BY m.timestamp DESC
    ''') ?? [];
      final resolve = ImageService.instance.resolveStoredPath;
      return rows
          .map((r) => ChatSummary(
                peerId: r['peer_id'] as String,
                lastText: (r['text'] as String?) ?? '',
                lastImagePath: resolve(r['image_path'] as String?),
                lastVoicePath: resolve(r['voice_path'] as String?),
                lastVideoPath: resolve(r['video_path'] as String?),
                timestamp:
                    DateTime.fromMillisecondsSinceEpoch(r['timestamp'] as int),
                nickname: r['nick'] as String?,
                avatarColor: r['color'] as int?,
                avatarEmoji: r['emoji'] as String?,
                avatarImagePath: resolve(r['avatar_img_path'] as String?),
              ))
          .toList();
    });
  }

  /// Per-peer count of incoming DM messages after the read cursor.
  Future<Map<String, int>> getDmUnreadCounts() async {
    await _ensureDbReady();
    if (_db == null) return const {};
    return _withWebDbRecovery('getDmUnreadCounts', () async {
      final rows = await _db!.rawQuery('''
      SELECT m.peer_id AS pid, COUNT(*) AS c
      FROM messages m
      LEFT JOIN conversation_read_cursor cr ON cr.conv_key = ('dm:' || m.peer_id)
      WHERE m.is_outgoing = 0
      AND (
        cr.conv_key IS NULL
        OR m.timestamp > cr.last_read_ts
        OR (m.timestamp = cr.last_read_ts AND m.id > cr.last_read_id)
      )
      GROUP BY m.peer_id
    ''');
      return {for (final r in rows) r['pid'] as String: (r['c'] as int?) ?? 0};
    });
  }

  /// Marks the whole thread as read up to the latest stored message.
  Future<void> markDmRead(String peerId) async {
    if (_db == null) return;
    final pid = normalizeDmPeerId(peerId);
    final key = 'dm:$pid';
    final rows = await _db!.query(
      'messages',
      where: 'peer_id = ?',
      whereArgs: [pid],
      orderBy: 'timestamp DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      await _db!.delete(
        'conversation_read_cursor',
        where: 'conv_key = ?',
        whereArgs: [key],
      );
    } else {
      final m = ChatMessage.fromMap(rows.first);
      await _db!.insert(
        'conversation_read_cursor',
        {
          'conv_key': key,
          'last_read_ts': m.timestamp.millisecondsSinceEpoch,
          'last_read_id': m.id,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    readStateVersion.value++;
  }

  final Map<String, ValueNotifier<List<ChatMessage>>> _messagesNotifiers = {};

  ValueNotifier<List<ChatMessage>> messagesNotifier(String peerId) {
    final pid = normalizeDmPeerId(peerId);
    return _messagesNotifiers.putIfAbsent(pid, () => ValueNotifier([]));
  }

  Future<void> loadMessages(String peerId) async {
    await _ensureDbReady();
    final pid = normalizeDmPeerId(peerId);
    final msgs = await getMessages(pid);
    messagesNotifier(pid).value = msgs;
  }

  void _notifyMessages(String peerId) async {
    final pid = normalizeDmPeerId(peerId);
    // Всегда get-or-create: иначе при гонке saveMessage до loadMessages UI не обновлялся.
    final notifier = messagesNotifier(pid);
    final msgs = await getMessages(pid);
    if (_messagesNotifiers.containsKey(pid)) {
      notifier.value = msgs;
    }
  }

  static const _kMaxPinsPerChat = 20;

  /// Id закреплённых сообщений в порядке времени сообщения (старые первые).
  Future<List<String>> getPinnedMessageIdsChrono(String peerId) async {
    if (_db == null) return const [];
    final rows = await _db!.rawQuery(
      '''
      SELECT p.message_id AS mid FROM dm_chat_pins p
      INNER JOIN messages m ON m.id = p.message_id AND m.peer_id = p.peer_id
      WHERE p.peer_id = ?
      ORDER BY m.timestamp ASC, m.id ASC
      ''',
      [peerId],
    );
    return rows.map((r) => r['mid'] as String).toList();
  }

  Future<bool> isPinned(String peerId, String messageId) async {
    if (_db == null) return false;
    final rows = await _db!.rawQuery(
      'SELECT COUNT(*) AS c FROM dm_chat_pins WHERE peer_id = ? AND message_id = ?',
      [peerId, messageId],
    );
    final n = (rows.isNotEmpty ? rows.first['c'] as int? : null) ?? 0;
    return n > 0;
  }

  /// Закрепить сообщение в личном чате с [peerId]. Возвращает false если лимит.
  Future<bool> pinDmMessage(String peerId, String messageId) async {
    if (_db == null) return false;
    final exists = await _db!.query(
      'messages',
      columns: const ['id'],
      where: 'id = ? AND peer_id = ?',
      whereArgs: [messageId, peerId],
      limit: 1,
    );
    if (exists.isEmpty) return false;
    final cntRows = await _db!.rawQuery(
      'SELECT COUNT(*) AS c FROM dm_chat_pins WHERE peer_id = ?',
      [peerId],
    );
    final cnt = (cntRows.isNotEmpty ? cntRows.first['c'] as int? : null) ?? 0;
    if (cnt >= _kMaxPinsPerChat) return false;
    await _db!.insert(
      'dm_chat_pins',
      {
        'peer_id': peerId,
        'message_id': messageId,
        'pinned_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    pinsVersion.value++;
    return true;
  }

  Future<void> unpinDmMessage(String peerId, String messageId) async {
    if (_db == null) return;
    await _db!.delete(
      'dm_chat_pins',
      where: 'peer_id = ? AND message_id = ?',
      whereArgs: [peerId, messageId],
    );
    pinsVersion.value++;
  }

  Future<void> toggleReaction(
      String messageId, String emoji, String fromId) async {
    final em = canonicalReactionEmojiKey(emoji);
    final rows = await _db?.query(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows == null || rows.isEmpty) return;
    final msg = ChatMessage.fromMap(rows.first);

    final reactions =
        msg.reactions.map((k, v) => MapEntry(k, List<String>.from(v)));
    final senders = reactions[em];
    if (senders != null && senders.contains(fromId)) {
      senders.remove(fromId);
      if (senders.isEmpty) reactions.remove(em);
    } else {
      if (!reactionAddAllowed(reactions, em, fromId)) return;
      reactions.putIfAbsent(em, () => []).add(fromId);
    }

    await _db?.update(
      'messages',
      {'reactions': jsonEncode(reactions)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notifyMessages(msg.peerId);
  }

  /// Web cache mirror for own identity fields shown in registration/profile.
  Future<void> upsertLocalProfileCache({
    required String publicKeyHex,
    required String username,
    required String nickname,
  }) async {
    await _ensureDbReady();
    await _db?.insert(
      'local_profile_cache',
      {
        'singleton': 1,
        'public_key_hex': publicKeyHex.trim(),
        'username': username.trim(),
        'nickname': nickname.trim(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static const _messageMediaColumns = {
    'image_path',
    'video_path',
    'voice_path',
    'file_path',
  };

  /// Сумма размеров уникальных локальных файлов в колонке медиа (личные чаты).
  Future<int> sumDistinctMessageMediaBytes(String column) async {
    await _ensureDbReady();
    if (_db == null || !_messageMediaColumns.contains(column)) return 0;
    final rows = await _db!.rawQuery(
      'SELECT DISTINCT $column AS p FROM messages '
      'WHERE $column IS NOT NULL AND TRIM($column) != ""',
    );
    final seen = <String>{};
    var sum = 0;
    for (final r in rows) {
      final raw = r['p'] as String?;
      if (raw == null || raw.isEmpty) continue;
      if (raw.startsWith('data:')) continue;
      final resolved = ImageService.instance.resolveStoredPath(raw) ?? raw;
      if (seen.contains(resolved)) continue;
      seen.add(resolved);
      sum += await _lengthIfFile(resolved);
    }
    return sum;
  }

  /// Удаляет файлы и обнуляет колонку медиа во всех личных сообщениях.
  Future<void> clearAllMessageMediaColumn(String column) async {
    await _ensureDbReady();
    if (_db == null || !_messageMediaColumns.contains(column)) return;
    final rows = await _db!.query('messages', columns: [column, 'peer_id']);
    for (final r in rows) {
      await _tryDeleteLocalMediaFile(r[column] as String?);
    }
    if (column == 'file_path') {
      await _db!.execute(
        'UPDATE messages SET file_path=NULL, file_name=NULL, file_size=NULL '
        'WHERE file_path IS NOT NULL',
      );
    } else {
      await _db!.rawUpdate(
        'UPDATE messages SET $column=NULL WHERE $column IS NOT NULL '
        'AND TRIM($column) != ""',
      );
    }
    final peers = await getChatPeerIds();
    for (final pid in peers) {
      _notifyMessages(pid);
    }
  }
}

Future<int> _lengthIfFile(String path) async {
  if (kIsWeb) return 0;
  try {
    final f = File(path);
    if (await f.exists()) return await f.length();
  } catch (_) {}
  return 0;
}

/// Строка из `scheduled_dm` для отложенной отправки в личный чат.
class ScheduledDmRow {
  final String id;
  final String peerId;
  final String text;
  final String? replyToMessageId;
  final int sendAtMs;

  const ScheduledDmRow({
    required this.id,
    required this.peerId,
    required this.text,
    this.replyToMessageId,
    required this.sendAtMs,
  });

  factory ScheduledDmRow.fromMap(Map<String, dynamic> m) => ScheduledDmRow(
        id: m['id'] as String,
        peerId: m['peer_id'] as String,
        text: m['text'] as String,
        replyToMessageId: m['reply_to_message_id'] as String?,
        sendAtMs: m['send_at_ms'] as int,
      );
}

/// Сводка чата — возвращается из getChatSummaries() единым SQL запросом.
class ChatSummary {
  final String peerId;
  final String lastText;
  final String? lastImagePath;
  final String? lastVoicePath;
  final String? lastVideoPath;
  final DateTime timestamp;
  final String? nickname;
  final int? avatarColor;
  final String? avatarEmoji;
  final String? avatarImagePath;

  const ChatSummary({
    required this.peerId,
    required this.lastText,
    required this.timestamp,
    this.lastImagePath,
    this.lastVoicePath,
    this.lastVideoPath,
    this.nickname,
    this.avatarColor,
    this.avatarEmoji,
    this.avatarImagePath,
  });

  /// Текст для отображения в превью последнего сообщения.
  String get displayText {
    final fromText = formatMessagePreview(lastText.isEmpty ? null : lastText);
    if (fromText.isNotEmpty) return fromText;
    if (lastImagePath != null) {
      if (lastImagePath!.toLowerCase().endsWith('.gif')) return '🎞 GIF';
      return '📷 Фото';
    }
    if (lastVoicePath != null) return '🎤 Голосовое';
    if (lastVideoPath != null) return '📹 Видео';
    return '';
  }
}
