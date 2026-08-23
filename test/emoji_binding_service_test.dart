import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:rlink/models/emoji_binding.dart';
import 'package:rlink/services/emoji_binding_service.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String path;
  _FakePathProvider(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EmojiBindingService svc;

  setUp(() async {
    final tmp = Directory.systemTemp.createTempSync('emoji_binding_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    // Fresh instance per test — the real class is a singleton, but its state
    // is just a private field we can reset by re-running init() against a
    // brand-new empty temp dir each time.
    svc = EmojiBindingService.instance;
    await svc.init();
  });

  test('isKnownEmoji recognizes a real emoji and rejects plain text', () {
    expect(svc.isKnownEmoji('😀'), isTrue);
    expect(svc.isKnownEmoji('a'), isFalse);
    expect(svc.isKnownEmoji(''), isFalse);
  });

  test('a fresh emoji has no binding', () {
    expect(svc.hasBinding('😀'), isFalse);
    expect(svc.stickerRefsFor('😀'), isEmpty);
    expect(svc.customEmojiShortcodesFor('😀'), isEmpty);
  });

  test('addStickerBinding creates a binding and is idempotent for duplicates', () async {
    await svc.addStickerBinding('😀', 'assets/foo.rls');
    expect(svc.hasBinding('😀'), isTrue);
    expect(svc.stickerRefsFor('😀'), ['assets/foo.rls']);

    await svc.addStickerBinding('😀', 'assets/foo.rls');
    expect(svc.stickerRefsFor('😀'), ['assets/foo.rls'],
        reason: 'adding the same ref twice must not duplicate it');
  });

  test('a single emoji can carry both sticker and custom-emoji bindings', () async {
    await svc.addStickerBinding('🎉', 'assets/party.rls');
    await svc.addCustomEmojiBinding('🎉', 'party_face');
    expect(svc.stickerRefsFor('🎉'), ['assets/party.rls']);
    expect(svc.customEmojiShortcodesFor('🎉'), ['party_face']);
  });

  test('removing the last ref/shortcode drops the binding entirely', () async {
    await svc.addStickerBinding('🔥', 'assets/fire.rls');
    await svc.removeStickerRef('🔥', 'assets/fire.rls');
    expect(svc.hasBinding('🔥'), isFalse);
  });

  test('removing one of several refs keeps the binding with the rest', () async {
    await svc.addStickerBinding('👍', 'assets/a.rls');
    await svc.addStickerBinding('👍', 'assets/b.rls');
    await svc.removeStickerRef('👍', 'assets/a.rls');
    expect(svc.stickerRefsFor('👍'), ['assets/b.rls']);
  });

  test('removeEmoji drops every ref/shortcode for that emoji at once', () async {
    await svc.addStickerBinding('❤️', 'assets/heart.rls');
    await svc.addCustomEmojiBinding('❤️', 'big_heart');
    await svc.removeEmoji('❤️');
    expect(svc.hasBinding('❤️'), isFalse);
  });

  test('a binding is actually written to disk, not just kept in memory', () async {
    final tmp = Directory.systemTemp.createTempSync('emoji_binding_test_disk_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    final fresh = EmojiBindingService.instance;
    await fresh.addStickerBinding('😎', 'assets/cool.rls');

    final file = File('${tmp.path}/emoji_bindings.json');
    expect(file.existsSync(), isTrue);
    final onDisk = EmojiBinding.decodeList(file.readAsStringSync());
    // The singleton accumulates bindings from earlier tests in this file, so
    // check the new entry landed rather than asserting the whole file's size.
    final mine = onDisk.where((b) => b.emoji == '😎').single;
    expect(mine.stickerRefs, ['assets/cool.rls']);
  });
}
