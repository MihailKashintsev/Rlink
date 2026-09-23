import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/models/contact.dart';

/// Regression test for a critical bug (reported by the user, 2026-09-23):
/// main.dart's onProfile handler used to look for an "old contact to merge
/// history into" by comparing nicknames with `==` — a free-text field either
/// user can set to anything. Two unrelated people who happened to pick the
/// same display name ("Alex", "Аня", ...) would have their entire contact
/// record (and chat history) silently merged onto whichever public key's
/// profile arrived second, deleting the original. This mirrors the exact
/// predicate in main.dart's `oldContact` lookup after the fix — kept in sync
/// by hand since that logic lives inline in a giant setup closure that isn't
/// practically unit-testable directly (same trade-off as the FTS/linked-
/// device-merge tests elsewhere in this suite).
Contact? findOldContactForMerge(
    List<Contact> contacts, String incomingPublicKey) {
  final hexStubRe = RegExp(r'^[0-9a-fA-F]{6,}');
  for (final c in contacts) {
    if (c.publicKeyHex == incomingPublicKey) continue;
    final stripped = c.nickname.replaceAll('...', '');
    if (hexStubRe.hasMatch(stripped) &&
        incomingPublicKey.startsWith(stripped)) {
      return c;
    }
  }
  return null;
}

Contact _contact(String key, String nick) => Contact(
      publicKeyHex: key,
      nickname: nick,
      avatarColor: 0xFF000000,
      avatarEmoji: '🙂',
      addedAt: DateTime(2020),
    );

void main() {
  test(
      'two unrelated contacts sharing a common nickname are never merged',
      () {
    final existing = _contact('a' * 64, 'Alex');
    final incomingKey = 'b' * 64; // a totally unrelated stranger's real key
    final match = findOldContactForMerge([existing], incomingKey);
    expect(match, isNull,
        reason: 'a same-nickname stranger must not inherit an existing '
            "contact's history/identity");
  });

  test('a genuine stub contact (hex-prefix nickname) still matches for merge',
      () {
    final fullKey = 'a1b2c3d4e5f6${'0' * 52}';
    final stub = _contact(fullKey.substring(0, 8), 'a1b2c3d4...');
    final match = findOldContactForMerge([stub], fullKey);
    expect(match?.publicKeyHex, stub.publicKeyHex,
        reason: 'the legitimate stub-contact merge path must still work');
  });

  test('an ordinary short nickname that is not hex-like never matches', () {
    final existing = _contact('c' * 64, 'Bob');
    final incomingKey = 'd' * 64;
    final match = findOldContactForMerge([existing], incomingKey);
    expect(match, isNull);
  });
}
