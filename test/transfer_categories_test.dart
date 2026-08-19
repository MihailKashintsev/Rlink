import 'package:flutter_test/flutter_test.dart';
import 'package:rlink/services/account_transfer_service.dart';

void main() {
  test('all categories selected by default', () {
    const c = TransferCategories();
    expect(c.selectedKinds, [
      'contact',
      'channel',
      'group',
      'emoji_pack',
      'dm',
      'settings',
      'sticker_pack',
    ]);
    for (final k in c.selectedKinds) {
      expect(c.isSelected(k), isTrue);
    }
  });

  test('deselecting a category removes exactly that kind', () {
    const c = TransferCategories(stickers: false, dmHistory: false);
    expect(c.selectedKinds, ['contact', 'channel', 'group', 'emoji_pack', 'settings']);
    expect(c.isSelected('sticker_pack'), isFalse);
    expect(c.isSelected('dm'), isFalse);
    expect(c.isSelected('contact'), isTrue);
  });

  test('isSelected is false for an unknown kind string', () {
    const c = TransferCategories();
    expect(c.isSelected('not_a_real_kind'), isFalse);
  });

  test('everything off yields an empty kind list', () {
    const c = TransferCategories(
      contacts: false,
      channels: false,
      groups: false,
      emojiPacks: false,
      dmHistory: false,
      settings: false,
      stickers: false,
    );
    expect(c.selectedKinds, isEmpty);
  });
}
