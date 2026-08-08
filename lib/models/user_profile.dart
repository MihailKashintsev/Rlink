import 'dart:convert';

import 'package:characters/characters.dart';

import '../services/image_service.dart';

class UserProfile {
  final String publicKeyHex;
  final String nickname;
  final String username;         // уникальный юзернейм (как в Telegram)
  final int avatarColor;
  final String avatarEmoji;
  final String? avatarImagePath; // локальный путь к фото аватара
  final List<String> tags;       // теги профиля (интересы)
  final String? bannerImagePath; // баннер профиля
  /// Локальный путь к аудио «музыка в профиле».
  final String? profileMusicPath;
  /// Эмодзи-статус (до нескольких эмодзи), показывается рядом с именем.
  final String statusEmoji;

  /// Premium: цвет отображаемого имени. null — обычный цвет темы.
  /// Едет вместе с профилем, поэтому виден всем собеседникам.
  final int? nickColor;

  /// День рождения в формате "MM-DD" (год необязателен — "YYYY-MM-DD").
  /// Едет вместе с профилем; контакты видят плашку в этот день.
  final String? birthday;

  const UserProfile({
    required this.publicKeyHex,
    required this.nickname,
    this.username = '',
    required this.avatarColor,
    required this.avatarEmoji,
    this.avatarImagePath,
    this.tags = const [],
    this.bannerImagePath,
    this.profileMusicPath,
    this.statusEmoji = '',
    this.nickColor,
    this.birthday,
  });

  /// month-day ("MM-DD") extracted from [birthday], or null.
  static String? monthDay(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final m = RegExp(r'(\d{2})-(\d{2})$').firstMatch(raw.trim());
    return m == null ? null : '${m.group(1)}-${m.group(2)}';
  }

  static const _ruMonthsGen = [
    'января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля',
    'августа', 'сентября', 'октября', 'ноября', 'декабря'
  ];

  /// Human "D месяца" label for a stored birthday, or the raw string on parse
  /// failure.
  static String birthdayLabel(String? raw) {
    final md = monthDay(raw);
    if (md == null) return raw ?? '';
    final p = md.split('-');
    final mo = int.tryParse(p[0]) ?? 1;
    final day = int.tryParse(p[1]) ?? 1;
    return '$day ${_ruMonthsGen[(mo - 1).clamp(0, 11)]}';
  }

  /// Is [birthday] today (local time)? Compares month + day only.
  static bool isToday(String? raw) {
    final md = monthDay(raw);
    if (md == null) return false;
    final now = DateTime.now();
    final today =
        '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return md == today;
  }

  /// Обрезка и нормализация строки статуса (графемы, не сырые code units).
  static String normalizeStatusEmoji(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    if (RegExp(r'^:[a-zA-Z0-9_]{1,48}:$').hasMatch(t)) return t;
    final c = t.characters;
    if (c.length <= 4) return t;
    return c.take(4).toString();
  }

  String get initials {
    final parts = nickname.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return nickname.isNotEmpty ? nickname[0].toUpperCase() : '?';
  }

  String get shortId =>
      publicKeyHex.length > 8 ? publicKeyHex.substring(0, 8) : publicKeyHex;

  Map<String, dynamic> toJson() => {
        'id': publicKeyHex,
        'nick': nickname,
        if (username.isNotEmpty) 'u': username,
        'color': avatarColor,
        'emoji': avatarEmoji,
        if (avatarImagePath != null) 'imgPath': avatarImagePath,
        if (tags.isNotEmpty) 'tags': tags,
        if (bannerImagePath != null) 'bannerPath': bannerImagePath,
        if (profileMusicPath != null) 'musicPath': profileMusicPath,
        if (statusEmoji.isNotEmpty) 'st': statusEmoji,
        if (nickColor != null) 'nc': nickColor,
        if (birthday != null && birthday!.isNotEmpty) 'bd': birthday,
      };

  static String _jsonString(Object? v) {
    if (v == null) return '';
    if (v is String) return v;
    return v.toString();
  }

  static List<String> _jsonStringList(Object? v) {
    if (v is! List) return const [];
    return v
        .map((e) => e == null ? '' : e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  factory UserProfile.fromJson(Map<String, dynamic> j) {
    final colorRaw = j['color'];
    final color = colorRaw is num
        ? colorRaw.toInt()
        : int.tryParse(_jsonString(colorRaw), radix: 10) ??
            UserProfile.avatarColors[0];
    return UserProfile(
      publicKeyHex: _jsonString(j['id']),
      nickname: _jsonString(j['nick']).isEmpty ? 'User' : _jsonString(j['nick']),
      username: _jsonString(j['u']),
      avatarColor: color,
      avatarEmoji: _jsonString(j['emoji']).isEmpty ? '😎' : _jsonString(j['emoji']),
      avatarImagePath: ImageService.instance.resolveStoredPath(
          j['imgPath'] == null ? null : _jsonString(j['imgPath'])),
      tags: _jsonStringList(j['tags']),
      bannerImagePath: ImageService.instance.resolveStoredPath(
          j['bannerPath'] == null ? null : _jsonString(j['bannerPath'])),
      profileMusicPath: ImageService.instance.resolveStoredPath(
          j['musicPath'] == null ? null : _jsonString(j['musicPath'])),
      statusEmoji: normalizeStatusEmoji(_jsonString(j['st'])),
      nickColor: j['nc'] is num
          ? (j['nc'] as num).toInt()
          : int.tryParse(_jsonString(j['nc'])),
      birthday: _jsonString(j['bd']).isEmpty ? null : _jsonString(j['bd']),
    );
  }

  String encode() => jsonEncode(toJson());

  static UserProfile? tryDecode(String s) {
    try {
      return UserProfile.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static const avatarColors = [
    0xFF5C6BC0,
    0xFF26A69A,
    0xFFEF5350,
    0xFFAB47BC,
    0xFF42A5F5,
    0xFF66BB6A,
    0xFFFF7043,
    0xFFEC407A,
  ];

  static const avatarEmojis = [
    '😎',
    '🥷',
    '🧙',
    '🧛',
    '🦊',
    '🐺',
    '🦁',
    '🐯',
    '🐻',
    '🐼',
    '🦄',
    '🐲',
    '👾',
    '🤖',
    '👻',
    '💀',
    '🔥',
    '⚡',
    '🌊',
    '💎',
    '🚀',
    '🎮',
    '🎸',
    '🏆',
    '🌙',
    '⭐',
    '🌈',
    '✨',
    '🔮',
    '🎯',
    '💥',
    '🌟',
  ];
}
