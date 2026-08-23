import 'dart:convert';

import '../models/channel.dart';
import '../models/chat_message.dart';
import '../models/group.dart';
import '../models/message_poll.dart';
import '../models/rls_sticker.dart';
import '../models/rlv_sticker.dart';
import '../models/shared_collab.dart';
import '../models/tgs_sticker.dart';
import 'custom_emoji_text.dart';

// `stk_*` (native filename prefix) only identifies a sticker on native
// platforms; web stores stickers as inline `data:` refs with no such
// filename, so that check silently fell through to "📷 Фото" for every
// sticker sent on web. The format predicates recognize a sticker ref in
// either shape (native path or web `data:` URL) — use those instead.
bool _isStickerImagePath(String path) =>
    looksLikeRlsRef(path) || looksLikeRlvRef(path) || looksLikeTgsRef(path) ||
    path.split('/').last.startsWith('stk_');

// Same marker set `RichMessageText` renders (see rich_message_text.dart's
// doc-comment) — previews are a plain subtitle string, not a rich widget, so
// "its own formatting" means stripped-to-readable-text rather than actual
// bold/italic glyphs, matching how every reference messenger renders a
// chat-list subtitle. Spoiler is handled separately, first, and never
// reveals its content — the whole point of the marker.
final _previewSpoilerRegex = RegExp(r'\|\|([\s\S]*?)\|\|');
final _previewMdLinkRegex = RegExp(r'\[([^\]]+)\]\((https?://[^\s)]+)\)');
final _previewBoldRegex = RegExp(r'\*\*([\s\S]*?)\*\*');
final _previewUnderlineRegex = RegExp(r'__([\s\S]*?)__');
final _previewStrikeRegex = RegExp(r'~~([\s\S]*?)~~');
final _previewMonoRegex = RegExp(r'`([\s\S]*?)`');
final _previewItalicRegex = RegExp(r'_([\s\S]*?)_');

/// Strips message-formatting markers for the plain-text preview line: bold
/// `**`/underline `__`/strike `~~`/mono `` ` ``/italic `_`/`[text](url)`
/// collapse to their readable inner text, and `||spoiler||` is masked to
/// "🙈" rather than shown in the clear — a spoiler hidden in the chat must
/// stay hidden on the chat-list screen too.
String stripPreviewFormatting(String text) {
  var t = text.replaceAll(_previewSpoilerRegex, '🙈');
  t = t.replaceAllMapped(_previewMdLinkRegex, (m) => m.group(1) ?? '');
  t = t.replaceAllMapped(_previewBoldRegex, (m) => m.group(1) ?? '');
  t = t.replaceAllMapped(_previewUnderlineRegex, (m) => m.group(1) ?? '');
  t = t.replaceAllMapped(_previewStrikeRegex, (m) => m.group(1) ?? '');
  t = t.replaceAllMapped(_previewMonoRegex, (m) => m.group(1) ?? '');
  t = t.replaceAllMapped(_previewItalicRegex, (m) => m.group(1) ?? '');
  return t;
}

/// Человекочитаемое превью последнего сообщения (список чатов и т.п.).
String formatMessagePreview(String? text, {String? pollJson}) {
  final p = MessagePoll.tryDecode(pollJson ?? '');
  if (p != null) {
    final q = p.question.trim();
    return q.isEmpty ? '📊 Опрос' : '📊 $q';
  }
  if (text == null || text.isEmpty) return '';

  final todo = SharedTodoPayload.tryDecode(text);
  if (todo != null) {
    final title = todo.title.trim();
    final head = title.isEmpty ? 'Список задач' : title;
    final n = todo.items.length;
    return '📋 $head${n > 0 ? ' · $n п.' : ''}';
  }

  final cal = SharedCalendarPayload.tryDecode(text);
  if (cal != null) {
    final title = cal.title.trim();
    return title.isEmpty ? '📅 Событие' : '📅 $title';
  }

  if (text == '📷' || text == '📷 Фото') return '📷 Фото';
  if (text == '🎤 Голосовое') return '🎤 Голосовое';
  if (text == '📹 Видео' || text == '⬛ Видео') return text;
  if (text.startsWith('📎 ')) return text;

  return humanizeCustomEmojiCodes(stripPreviewFormatting(text));
}

/// Превью для последнего сообщения личного чата (список диалогов).
String dmLastMessagePreview(ChatMessage m) {
  if (m.stickerPackPayload != null) {
    final title = (m.stickerPackPayload!['title'] as String?)?.trim();
    if (title != null && title.isNotEmpty) {
      return '🩵 Набор «$title»';
    }
    return '🩵 Набор стикеров';
  }
  final inv = m.invitePayloadJson;
  if (inv != null && inv.isNotEmpty) {
    try {
      final map = jsonDecode(inv) as Map<String, dynamic>;
      final ty = map['type'] as String? ?? map['kind'] as String?;
      if (ty == 'emoji_pack') {
        final name = (map['name'] as String?)?.trim();
        if (name != null && name.isNotEmpty) return '😀 Набор «$name»';
        return '😀 Набор эмодзи';
      }
    } catch (_) {}
  }
  var t = formatMessagePreview(m.text.isEmpty ? null : m.text);
  if (t.isNotEmpty) return t;
  if (m.imagePath != null) {
    if (_isStickerImagePath(m.imagePath!)) return '🩵 Стикер';
    if (m.imagePath!.toLowerCase().endsWith('.gif')) return '🎞 GIF';
    return '📷 Фото';
  }
  if (m.voicePath != null) return '🎤 Голосовое';
  if (m.videoPath != null) return '📹 Видео';
  if (m.filePath != null) {
    if (m.text.startsWith('📎 ')) return m.text;
    return '📎 Файл';
  }
  return '';
}

/// Превью последнего сообщения группы (учёт медиа без текста).
String formatGroupMessagePreview(GroupMessage m) {
  final t = formatMessagePreview(m.text, pollJson: m.pollJson);
  if (t.isNotEmpty) return t;
  final img = m.imagePath;
  if (img != null && img.isNotEmpty) {
    if (_isStickerImagePath(img)) return '🩵 Стикер';
    return img.toLowerCase().endsWith('.gif') ? '🎞 GIF' : '📷 Фото';
  }
  if (m.voicePath != null && m.voicePath!.isNotEmpty) return '🎤 Голосовое';
  if (m.videoPath != null && m.videoPath!.isNotEmpty) return '📹 Видео';
  return 'Сообщение';
}

/// Превью последнего поста канала.
String formatChannelPostPreview(ChannelPost p) {
  final t = formatMessagePreview(p.text, pollJson: p.pollJson);
  if (t.isNotEmpty) return t;
  final img = p.imagePath;
  if (img != null && img.isNotEmpty) {
    if (_isStickerImagePath(img)) return '🩵 Стикер';
    return img.toLowerCase().endsWith('.gif') ? '🎞 GIF' : '📷 Фото';
  }
  if (p.voicePath != null && p.voicePath!.isNotEmpty) return '🎤 Голосовое';
  if (p.videoPath != null && p.videoPath!.isNotEmpty) return '📹 Видео';
  if (p.filePath != null && p.filePath!.isNotEmpty) return '📎 Файл';
  return 'Пост';
}
