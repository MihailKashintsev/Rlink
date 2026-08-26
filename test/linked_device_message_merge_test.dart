import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Exercises the exact query shape `ChatStorageService.getMessages` uses
/// when a contact has a known linked device (`peer_id = ? OR peer_id = ?`,
/// see LinkedDeviceFanout) — the real risk here isn't "does SQL work", it's
/// "does merging two keys into one conversation ever accidentally pull in
/// messages that belong to a THIRD, unrelated contact." Standalone
/// sqflite_common_ffi DB rather than the full ChatStorageService singleton,
/// same reasoning as message_search_fts_test.dart: that singleton's
/// `init()` needs a path_provider platform-channel mock this codebase
/// doesn't set up anywhere yet.
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
        timestamp INTEGER NOT NULL
      )
    ''');
  });

  tearDown(() => db.close());

  Future<void> insert(String id, String peerId, String text, int ts) =>
      db.insert('messages', {'id': id, 'peer_id': peerId, 'text': text, 'timestamp': ts});

  Future<List<Map<String, Object?>>> getMessagesMerged(String peerId, String? linkedKey) {
    if (linkedKey != null && linkedKey.isNotEmpty) {
      return db.query('messages',
          where: 'peer_id = ? OR peer_id = ?',
          whereArgs: [peerId, linkedKey],
          orderBy: 'timestamp ASC');
    }
    return db.query('messages', where: 'peer_id = ?', whereArgs: [peerId], orderBy: 'timestamp ASC');
  }

  test('with no linked device, only the exact peer_id is returned', () async {
    await insert('m1', 'bob-primary', 'hi', 1);
    await insert('m2', 'bob-child', 'from the other device', 2);
    final results = await getMessagesMerged('bob-primary', null);
    expect(results.map((r) => r['id']), ['m1']);
  });

  test('with a linked device, both keys merge into one timeline in order', () async {
    await insert('m1', 'bob-primary', 'first', 1);
    await insert('m2', 'bob-child', 'second, from the other device', 2);
    await insert('m3', 'bob-primary', 'third', 3);
    final results = await getMessagesMerged('bob-primary', 'bob-child');
    expect(results.map((r) => r['id']), ['m1', 'm2', 'm3']);
  });

  test('merging never pulls in a third, unrelated contact\'s messages', () async {
    await insert('m1', 'bob-primary', 'hi', 1);
    await insert('m2', 'bob-child', 'reply', 2);
    await insert('m3', 'carol', 'unrelated conversation', 3);
    final results = await getMessagesMerged('bob-primary', 'bob-child');
    expect(results.map((r) => r['id']), isNot(contains('m3')));
    expect(results.length, 2);
  });
}
