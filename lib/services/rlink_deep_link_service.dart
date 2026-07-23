import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/contact.dart';
import '../models/user_profile.dart';
import '../ui/rlink_nav_routes.dart';
import '../ui/screens/chat_screen.dart';
import '../ui/screens/channels_screen.dart';
import 'ai_bot_constants.dart';
import '../utils/rlink_deep_link.dart';
import 'ble_service.dart';
import 'channel_service.dart';
import 'app_settings.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'profile_service.dart';

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
    final user = RlinkDeepLink.parseUser(uri);
    if (user != null) {
      unawaited(openUserLinkInApp(user));
      return;
    }
    final botId = RlinkDeepLink.parseBotId(uri);
    if (botId != null && botId.isNotEmpty) {
      unawaited(openBotInApp(botId));
    }
  }

  /// Save (or merge) a contact from a scanned/opened `rlink://user` link,
  /// register its E2E key, and send our profile back so the exchange is mutual.
  /// Returns the stored [Contact], or null when the link is our own identity.
  Future<Contact?> applyUserLink(RlinkUserLink u) async {
    final me = CryptoService.instance.publicKeyHex;
    if (u.publicKeyHex.isEmpty || u.publicKeyHex == me) return null;

    final existing =
        await ChatStorageService.instance.getContact(u.publicKeyHex);
    final idx = u.publicKeyHex.hashCode.abs();
    final color = u.avatarColor ??
        existing?.avatarColor ??
        UserProfile.avatarColors[idx % UserProfile.avatarColors.length];
    final emoji = u.avatarEmoji.isNotEmpty
        ? u.avatarEmoji
        : (existing?.avatarEmoji ??
            UserProfile.avatarEmojis[idx % UserProfile.avatarEmojis.length]);
    final nick = u.nickname.isNotEmpty
        ? u.nickname
        : (existing?.nickname ?? 'Пользователь');

    final contact = (existing ??
            Contact(
              publicKeyHex: u.publicKeyHex,
              nickname: nick,
              avatarColor: color,
              avatarEmoji: emoji,
              addedAt: DateTime.now(),
            ))
        .copyWith(
      nickname: nick,
      username: u.username.isNotEmpty ? u.username : null,
      avatarColor: color,
      avatarEmoji: emoji,
      x25519Key: u.x25519Key,
      statusEmoji: u.statusEmoji.isNotEmpty ? u.statusEmoji : null,
    );
    await ChatStorageService.instance.saveContact(contact);

    final x = u.x25519Key;
    if (x != null && x.isNotEmpty) {
      BleService.instance.registerPeerX25519Key(u.publicKeyHex, x);
      await ChatStorageService.instance
          .updateContactX25519Key(u.publicKeyHex, x);
    }

    // Send our profile back so the other side can add us too.
    final myProfile = ProfileService.instance.profile;
    if (myProfile != null) {
      unawaited(GossipRouter.instance.sendPairRequest(
        publicKey: myProfile.publicKeyHex,
        nick: myProfile.nickname,
        username: myProfile.username,
        color: myProfile.avatarColor,
        emoji: myProfile.avatarEmoji,
        recipientId: u.publicKeyHex,
        x25519Key: CryptoService.instance.x25519PublicKeyBase64,
        tags: myProfile.tags,
        statusEmoji: myProfile.statusEmoji,
      ));
    }
    return contact;
  }

  /// Deep-link entry: add the contact, then open the chat with a snackbar.
  Future<void> openUserLinkInApp(RlinkUserLink u) async {
    final contact = await applyUserLink(u);
    final nav = _navigatorKey?.currentState;
    final ctx = _navigatorKey?.currentContext;
    if (nav == null || ctx == null) return;
    if (contact == null) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Это ваш собственный QR-код.')),
        );
      }
      return;
    }
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text('${contact.nickname} добавлен(а) в контакты')),
    );
    await nav.push(rlinkChatRoute(ChatScreen(
      peerId: contact.publicKeyHex,
      peerNickname: contact.nickname,
      peerAvatarColor: contact.avatarColor,
      peerAvatarEmoji: contact.avatarEmoji,
    )));
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
