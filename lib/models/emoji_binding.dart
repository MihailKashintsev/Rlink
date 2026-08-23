import 'dart:convert';

/// A single emoji's bindings: stickers to send right after a message
/// containing this emoji, and/or a custom emoji that replaces it in the
/// text. Either list may be empty (e.g. a sticker-only binding).
class EmojiBinding {
  final String emoji;
  final List<String> stickerRefs;
  final List<String> customEmojiShortcodes;

  const EmojiBinding({
    required this.emoji,
    this.stickerRefs = const [],
    this.customEmojiShortcodes = const [],
  });

  bool get isEmpty => stickerRefs.isEmpty && customEmojiShortcodes.isEmpty;

  EmojiBinding copyWith({
    List<String>? stickerRefs,
    List<String>? customEmojiShortcodes,
  }) =>
      EmojiBinding(
        emoji: emoji,
        stickerRefs: stickerRefs ?? this.stickerRefs,
        customEmojiShortcodes: customEmojiShortcodes ?? this.customEmojiShortcodes,
      );

  Map<String, dynamic> toJson() => {
        'e': emoji,
        'st': stickerRefs,
        'ce': customEmojiShortcodes,
      };

  factory EmojiBinding.fromJson(Map<String, dynamic> m) => EmojiBinding(
        emoji: (m['e'] as String? ?? '').trim(),
        stickerRefs: ((m['st'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(),
        customEmojiShortcodes: ((m['ce'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(),
      );

  static String encodeList(List<EmojiBinding> list) =>
      jsonEncode(list.map((b) => b.toJson()).toList());

  static List<EmojiBinding> decodeList(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => EmojiBinding.fromJson(Map<String, dynamic>.from(m)))
          .where((b) => b.emoji.isNotEmpty && !b.isEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
