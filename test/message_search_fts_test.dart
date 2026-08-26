import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Exercises the exact FTS5 schema/trigger SQL from
/// `ChatStorageService._createMessagesFts` against a real sqflite_common_ffi
/// database — not a mock. Kept as a standalone in-memory DB rather than
/// going through `ChatStorageService.instance` because that singleton's
/// `init()` calls `path_provider`, which needs its own platform-channel
/// mock this codebase doesn't set up anywhere yet; that's a real gap but a
/// separate one from "is this FTS5 SQL actually correct," which is the risk
/// this test is targeting (virtual table + trigger syntax is exactly the
/// kind of thing that's easy to get subtly wrong and not notice locally).
///
/// The schema/SQL here must be kept in sync with
/// `lib/services/chat_storage_service.dart`'s `_createMessagesFts` — it's
/// duplicated because Dart's privacy is per-file and there's no way to
/// import a `_`-prefixed method from a test file.
void main() {
  late Database db;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        peer_id TEXT NOT NULL,
        text TEXT NOT NULL,
        is_outgoing INTEGER NOT NULL,
        timestamp INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE VIRTUAL TABLE messages_fts USING fts5(id UNINDEXED, text)');
    await db.execute('''
      CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(id, text) VALUES (new.id, new.text);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages BEGIN
        DELETE FROM messages_fts WHERE id = old.id;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER messages_fts_au AFTER UPDATE ON messages BEGIN
        DELETE FROM messages_fts WHERE id = old.id;
        INSERT INTO messages_fts(id, text) VALUES (new.id, new.text);
      END
    ''');
  });

  tearDown(() => db.close());

  Future<void> insert(String id, String peerId, String text, {int ts = 1000}) =>
      db.insert('messages',
          {'id': id, 'peer_id': peerId, 'text': text, 'is_outgoing': 0, 'timestamp': ts});

  /// Mirrors `ChatStorageService._ftsMatchQuery`: quote each word as an FTS5
  /// string literal (doubling embedded quotes) so raw user input — which
  /// may contain bare `-`/`*`/`:`/unbalanced quotes, all meaningful to FTS5
  /// query syntax — can never throw a MATCH syntax error.
  String ftsMatchQuery(String query) => query
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => '"${w.replaceAll('"', '""')}"')
      .join(' ');

  Future<List<Map<String, Object?>>> search(String query, {String? peerId}) {
    return db.rawQuery(
      '''
      SELECT messages.* FROM messages
      JOIN messages_fts ON messages.id = messages_fts.id
      WHERE messages_fts MATCH ?
      ${peerId != null ? 'AND messages.peer_id = ?' : ''}
      ORDER BY messages.timestamp DESC
      ''',
      [ftsMatchQuery(query), if (peerId != null) peerId],
    );
  }

  test('a newly inserted message is findable by a word in its text', () async {
    await insert('m1', 'alice', 'let\'s meet at the coffee shop tomorrow');
    final results = await search('coffee');
    expect(results.map((r) => r['id']), ['m1']);
  });

  test('peerId narrows results to one conversation', () async {
    await insert('m1', 'alice', 'the meeting is at noon');
    await insert('m2', 'bob', 'the meeting is at noon too');
    final results = await search('meeting', peerId: 'alice');
    expect(results.map((r) => r['id']), ['m1']);
  });

  test('editing a message updates what search finds', () async {
    await insert('m1', 'alice', 'original text');
    await db.update('messages', {'text': 'edited text'}, where: 'id = ?', whereArgs: ['m1']);
    expect(await search('original'), isEmpty);
    expect((await search('edited')).map((r) => r['id']), ['m1']);
  });

  test('deleting a message removes it from search results', () async {
    await insert('m1', 'alice', 'searchable content');
    await db.delete('messages', where: 'id = ?', whereArgs: ['m1']);
    expect(await search('searchable'), isEmpty);
  });

  test('FTS5-special characters in the query do not throw', () async {
    await insert('m1', 'alice', 'check the pull-request: item*3');
    // A bare -, *, or : is meaningful FTS5 query syntax and throws if not
    // quoted — this must not crash regardless of what the user typed.
    for (final q in ['pull-request', 'item*3', 'weird:query', '"unbalanced', "'quote"]) {
      await expectLater(search(q), completes);
    }
  });

  test('multi-word queries require all words present (implicit AND)', () async {
    await insert('m1', 'alice', 'the quick brown fox');
    await insert('m2', 'alice', 'the quick red fox');
    final results = await search('quick brown');
    expect(results.map((r) => r['id']), ['m1']);
  });
}
