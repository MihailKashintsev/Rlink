import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Ссылки вида [rlink://channel/<id>] — открытие канала в приложении.
///
/// Публичные приглашения: [channelInviteWebUri] — страница Tilda с `?channel=<id>` (см. [channelWebInvitePage]).
class RlinkDeepLink {
  RlinkDeepLink._();

  /// База веб-страницы Rlink (установка, лендинг, APK).
  static const String installWebBase = 'https://rendergames.ru/rlink';

  /// Лендинг «открыть канал» (Tilda). ID передаётся в query: `?channel=` — так проще одна страница без вложенных URL.
  static const String channelWebInvitePage =
      'https://rendergames.ru/rlinkchanales';

  static Uri channelUri(String channelId) =>
      Uri(scheme: 'rlink', host: 'channel', pathSegments: [channelId]);

  static Uri botUri(String botId) =>
      Uri(scheme: 'rlink', host: 'bot', pathSegments: [botId]);

  /// Contact-exchange link encoded in a QR: `rlink://user/<publicKeyHex>` with
  /// the profile carried in short query params (n=nick, u=username, c=color,
  /// e=avatar emoji, s=status emoji, x=X25519 key for E2E).
  static Uri userUri({
    required String publicKeyHex,
    String? x25519Key,
    String nickname = '',
    String username = '',
    int? avatarColor,
    String avatarEmoji = '',
    String statusEmoji = '',
  }) =>
      Uri(
        scheme: 'rlink',
        host: 'user',
        pathSegments: [publicKeyHex],
        queryParameters: {
          if (x25519Key != null && x25519Key.isNotEmpty) 'x': x25519Key,
          if (nickname.isNotEmpty) 'n': nickname,
          if (username.isNotEmpty) 'u': username,
          if (avatarColor != null) 'c': '$avatarColor',
          if (avatarEmoji.isNotEmpty) 'e': avatarEmoji,
          if (statusEmoji.isNotEmpty) 's': statusEmoji,
        },
      );

  /// Ссылка для шаринга и браузера: откроется сайт; при настроенных App Links — приложение.
  static Uri channelInviteWebUri(String channelId) => Uri.parse(
        '$channelWebInvitePage?channel=${Uri.encodeQueryComponent(channelId)}',
      );

  static String channelInviteShareText({
    required String channelTitle,
    required String channelId,
  }) {
    final url = channelInviteWebUri(channelId).toString();
    return 'Канал «$channelTitle» в Rlink\n$url';
  }

  /// [context] — виджет, от которого якорится системный лист (обязательно для iPad / macOS).
  static Rect sharePositionOriginFromContext(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.sizeOf(context);
    final center = Offset(size.width / 2, size.height / 2);
    return Rect.fromCenter(center: center, width: 48, height: 48);
  }

  static Future<void> shareChannelInvite({
    required BuildContext context,
    required String channelTitle,
    required String channelId,
  }) async {
    final text = channelInviteShareText(
      channelTitle: channelTitle,
      channelId: channelId,
    );
    try {
      await Share.share(
        text,
        subject: 'Rlink: $channelTitle',
        sharePositionOrigin: sharePositionOriginFromContext(context),
      );
    } catch (e, st) {
      debugPrint('[RlinkDeepLink] Share failed: $e\n$st');
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось открыть «Поделиться». '
              'Нажмите «Копировать ссылку» и вставьте в нужное приложение.',
            ),
          ),
        );
      }
    }
  }

  /// Разбор `rlink://channel/<id>`, `https://…/channel/<id>`,
  /// `https://…/rlink/channel/<id>`, `https://…/rlinkchanales?channel=<id>` и `?c=`.
  static String? parseChannelId(Uri uri) {
    if (uri.scheme == 'rlink' && uri.host == 'channel') {
      if (uri.pathSegments.isNotEmpty) return uri.pathSegments.first;
      final p = uri.path;
      if (p.length > 1 && p.startsWith('/')) {
        final seg = p
            .substring(1)
            .split('/')
            .firstWhere((s) => s.isNotEmpty, orElse: () => '');
        if (seg.isNotEmpty) return seg;
      }
    }
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      final q = uri.queryParameters;
      final fromQuery = q['channel'] ?? q['c'];
      if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;

      final segs = uri.pathSegments;
      final i = segs.indexOf('channel');
      if (i >= 0 && i + 1 < segs.length) return segs[i + 1];
    }
    return null;
  }

  static String? parseBotId(Uri uri) {
    if (uri.scheme == 'rlink' && uri.host == 'bot') {
      if (uri.pathSegments.isNotEmpty) return uri.pathSegments.first;
      final p = uri.path;
      if (p.length > 1 && p.startsWith('/')) {
        final seg = p
            .substring(1)
            .split('/')
            .firstWhere((s) => s.isNotEmpty, orElse: () => '');
        if (seg.isNotEmpty) return seg;
      }
    }
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      final q = uri.queryParameters;
      final fromQuery = q['bot'] ?? q['b'];
      if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;

      final segs = uri.pathSegments;
      final i = segs.indexOf('bot');
      if (i >= 0 && i + 1 < segs.length) return segs[i + 1];
    }
    return null;
  }

  static final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  /// Parse a contact-exchange link (`rlink://user/<hex>?…` or an `https` variant
  /// with `?user=<hex>`). Returns null if it isn't a valid identity link.
  static RlinkUserLink? parseUser(Uri uri) {
    String? hex;
    if (uri.scheme == 'rlink' && uri.host == 'user') {
      if (uri.pathSegments.isNotEmpty) {
        hex = uri.pathSegments.first;
      } else if (uri.path.length > 1 && uri.path.startsWith('/')) {
        hex = uri.path
            .substring(1)
            .split('/')
            .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      }
    } else if (uri.scheme == 'https' || uri.scheme == 'http') {
      hex = uri.queryParameters['user'];
      if (hex == null || hex.isEmpty) {
        final segs = uri.pathSegments;
        final i = segs.indexOf('user');
        if (i >= 0 && i + 1 < segs.length) hex = segs[i + 1];
      }
    }
    if (hex == null || !_hex64.hasMatch(hex)) return null;
    final q = uri.queryParameters;
    final colorStr = q['c'];
    final x = q['x'];
    return RlinkUserLink(
      publicKeyHex: hex.toLowerCase(),
      x25519Key: (x == null || x.isEmpty) ? null : x,
      nickname: q['n'] ?? '',
      username: q['u'] ?? '',
      avatarColor: colorStr != null ? int.tryParse(colorStr) : null,
      avatarEmoji: q['e'] ?? '',
      statusEmoji: q['s'] ?? '',
    );
  }
}

/// Identity parsed from an `rlink://user/…` contact-exchange link or QR code.
class RlinkUserLink {
  final String publicKeyHex;
  final String? x25519Key;
  final String nickname;
  final String username;
  final int? avatarColor;
  final String avatarEmoji;
  final String statusEmoji;

  const RlinkUserLink({
    required this.publicKeyHex,
    this.x25519Key,
    this.nickname = '',
    this.username = '',
    this.avatarColor,
    this.avatarEmoji = '',
    this.statusEmoji = '',
  });
}
