import 'dart:convert';
import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart' show defaultEmojiSet;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/emoji_binding.dart';
import '../utils/web_file_store.dart';

/// Persists emoji→sticker (send-after) and emoji→custom-emoji
/// (replace-in-text) bindings, and knows which glyphs are real emoji at all
/// (reusing the same dataset the emoji picker itself renders — see
/// unified_emoji_picker.dart's `epf` import — instead of a hand-rolled
/// Unicode-range regex, which would both over- and under-match).
class EmojiBindingService with ChangeNotifier {
  EmojiBindingService._();
  static final EmojiBindingService instance = EmojiBindingService._();

  static const _fileName = 'emoji_bindings.json';
  static const _webPath = 'opfs://rlink/$_fileName';

  Map<String, EmojiBinding> _byEmoji = {};
  bool _loaded = false;

  late final Set<String> _knownEmoji = {
    for (final cat in defaultEmojiSet)
      for (final e in cat.emoji) e.emoji,
  };

  bool isKnownEmoji(String glyph) => _knownEmoji.contains(glyph);

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _read();
    _byEmoji = {for (final b in raw) b.emoji: b};
  }

  EmojiBinding? bindingFor(String emoji) => _byEmoji[emoji];

  List<String> stickerRefsFor(String emoji) => _byEmoji[emoji]?.stickerRefs ?? const [];

  List<String> customEmojiShortcodesFor(String emoji) =>
      _byEmoji[emoji]?.customEmojiShortcodes ?? const [];

  bool hasBinding(String emoji) => _byEmoji.containsKey(emoji);

  List<EmojiBinding> get allBindings => _byEmoji.values.toList();

  Future<void> addStickerBinding(String emoji, String stickerRef) async {
    final cur = _byEmoji[emoji];
    final refs = <String>{...?cur?.stickerRefs, stickerRef}.toList();
    _byEmoji[emoji] = EmojiBinding(
      emoji: emoji,
      stickerRefs: refs,
      customEmojiShortcodes: cur?.customEmojiShortcodes ?? const [],
    );
    await _persist();
  }

  Future<void> addCustomEmojiBinding(String emoji, String shortcode) async {
    final cur = _byEmoji[emoji];
    final codes = <String>{...?cur?.customEmojiShortcodes, shortcode}.toList();
    _byEmoji[emoji] = EmojiBinding(
      emoji: emoji,
      stickerRefs: cur?.stickerRefs ?? const [],
      customEmojiShortcodes: codes,
    );
    await _persist();
  }

  Future<void> removeStickerRef(String emoji, String stickerRef) async {
    final cur = _byEmoji[emoji];
    if (cur == null) return;
    _setOrRemove(emoji, cur.stickerRefs.where((r) => r != stickerRef).toList(), cur.customEmojiShortcodes);
    await _persist();
  }

  Future<void> removeCustomEmojiShortcode(String emoji, String shortcode) async {
    final cur = _byEmoji[emoji];
    if (cur == null) return;
    _setOrRemove(emoji, cur.stickerRefs, cur.customEmojiShortcodes.where((c) => c != shortcode).toList());
    await _persist();
  }

  Future<void> removeEmoji(String emoji) async {
    if (_byEmoji.remove(emoji) != null) await _persist();
  }

  void _setOrRemove(String emoji, List<String> refs, List<String> codes) {
    if (refs.isEmpty && codes.isEmpty) {
      _byEmoji.remove(emoji);
    } else {
      _byEmoji[emoji] = EmojiBinding(emoji: emoji, stickerRefs: refs, customEmojiShortcodes: codes);
    }
  }

  Future<void> _persist() async {
    notifyListeners();
    final bytes = Uint8List.fromList(utf8.encode(EmojiBinding.encodeList(_byEmoji.values.toList())));
    if (kIsWeb) {
      await writeWebStoredFile(fileName: _fileName, bytes: bytes, mimeType: 'application/json');
      return;
    }
    final docs = await getApplicationDocumentsDirectory();
    await File(p.join(docs.path, _fileName)).writeAsBytes(bytes);
  }

  Future<List<EmojiBinding>> _read() async {
    try {
      Uint8List? bytes;
      if (kIsWeb) {
        bytes = await readWebStoredFile(_webPath);
      } else {
        final docs = await getApplicationDocumentsDirectory();
        final f = File(p.join(docs.path, _fileName));
        if (await f.exists()) bytes = await f.readAsBytes();
      }
      if (bytes == null || bytes.isEmpty) return const [];
      return EmojiBinding.decodeList(utf8.decode(bytes));
    } catch (_) {
      return const [];
    }
  }
}
