import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/contact.dart';
import '../ui/rlink_nav_routes.dart';
import '../ui/screens/chat_screen.dart';
import '../ui/screens/channels_screen.dart';
import 'ai_bot_constants.dart';
import '../utils/rlink_deep_link.dart';
import 'channel_service.dart';
import 'app_settings.dart';
import 'chat_storage_service.dart';

/// Вход по ссылке `rlink://channel/...` (macOS / iOS / Android).
class RlinkDeepLinkService {
  RlinkDeepLinkService._();
  static final instance = RlinkDeepLinkService._();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  GlobalKey<NavigatorState>? _navigatorKey;
  bool _initialLinkConsumed = false;

  /// Вызывать после инициализации сервисов; [key] — [MaterialApp.navigatorKey].
  Future<void> start(GlobalKey<NavigatorState> key) async {
    _navigatorKey = key;
    if (kIsWeb) {
      // Web entry links come as query params in the current page URL.
      _handle(Uri.base);
      return;
    }
    _sub ??= _appLinks.uriLinkStream.listen(_handle, onError: (e) {
      debugPrint('[DeepLink] stream: $e');
    });
    if (!_initialLinkConsumed) {
      _initialLinkConsumed = true;
      try {
        final initial = await _appLinks.getInitialLink();
        if (initial != null) {
          _handle(initial);
        }
      } catch (e) {
        debugPrint('[DeepLink] getInitialLink: $e');
      }
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _initialLinkConsumed = false;
  }

  void _handle(Uri uri) {
    final channelId = RlinkDeepLink.parseChannelId(uri);
    if (channelId != null && channelId.isNotEmpty) {
      unawaited(openChannelInApp(channelId));
      return;
    }
    final botId = RlinkDeepLink.parseBotId(uri);
    if (botId != null && botId.isNotEmpty) {
      unawaited(openBotInApp(botId));
    }
  }

  /// Открыть ленту канала, если он уже есть в локальной базе.
  Future<void> openChannelInApp(String channelId) async {
    final nav = _navigatorKey?.currentState;
    final ctx = _navigatorKey?.currentContext;
    if (nav == null || ctx == null) return;

    final row = await ChannelService.instance.getChannel(channelId);
    if (row == null) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text(
              'Канал не найден на устройстве. Нужно приглашение или синхронизация с подписчиками.',
            ),
          ),
        );
      }
      return;
    }

    if (!ctx.mounted) return;
    await nav.push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelViewScreen(channel: row),
      ),
    );
  }

  Future<void> openBotInApp(String botId) async {
    final nav = _navigatorKey?.currentState;
    final ctx = _navigatorKey?.currentContext;
    if (nav == null || ctx == null) return;

    final bot = findAiBotById(botId);
    if (bot == null) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Бот не найден в этой версии Rlink.')),
        );
      }
      return;
    }

    final enabled = AppSettings.instance.enabledBotIds.toSet()..add(bot.id);
    await AppSettings.instance.setEnabledBotIds(enabled.toList());
    final existing = await ChatStorageService.instance.getContact(bot.id);
    if (existing == null) {
      await ChatStorageService.instance.saveContact(Contact(
        publicKeyHex: bot.id,
        nickname: bot.name,
        avatarColor: bot.avatarColor,
        avatarEmoji: bot.avatarEmoji,
        addedAt: DateTime.now(),
      ));
    }

    if (!ctx.mounted) return;
    await nav.push(
      rlinkChatRoute(ChatScreen(
        peerId: bot.id,
        peerNickname: bot.name,
        peerAvatarColor: bot.avatarColor,
        peerAvatarEmoji: bot.avatarEmoji,
      )),
    );
  }
}
