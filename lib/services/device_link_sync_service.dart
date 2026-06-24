import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/contact.dart';
import 'dm_bot_flags.dart';
import 'app_settings.dart';
import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'gossip_router.dart';
import 'relay_service.dart';

/// Live progress of a linked-device snapshot transfer (drives the sync animation).
class LinkSyncProgress {
  final int done;
  final int total;
  final String phase;

  /// Recently received items (emoji + color) for the avatar carousel.
  final List<({String emoji, int color})> avatars;
  const LinkSyncProgress({
    required this.done,
    required this.total,
    required this.phase,
    this.avatars = const [],
  });

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

/// Syncs DM history between linked primary/child devices.
class DeviceLinkSyncService {
  DeviceLinkSyncService._();
  static final DeviceLinkSyncService instance = DeviceLinkSyncService._();

  /// Non-null while a child device is receiving a snapshot — the UI shows the
  /// sync animation overlay. Cleared when the transfer finishes.
  final ValueNotifier<LinkSyncProgress?> progress =
      ValueNotifier<LinkSyncProgress?>(null);
  int _progressTotal = 0;
  int _progressDone = 0;
  final List<({String emoji, int color})> _progressAvatars = [];

  StreamSubscription<ChatMessage>? _messageSub;
  VoidCallback? _relayListener;
  VoidCallback? _settingsListener;
  bool _initialized = false;
  bool _snapshotSending = false;
  bool _snapshotRequestedThisSession = false;
  final Set<String> _suppressLocalMirrorIds = <String>{};

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    GossipRouter.instance.onDeviceDmSyncRequest = (sourceId, publicKey) {
      unawaited(_handleSnapshotRequest(sourceId, publicKey));
    };
    GossipRouter.instance.onDeviceDmSyncPacket =
        (sourceId, publicKey, kind, data, snapshot) {
      return _handleSyncPacket(
        sourceId: sourceId,
        publicKey: publicKey,
        kind: kind,
        data: data,
        snapshot: snapshot,
      );
    };

    _messageSub = ChatStorageService.instance.messageSavedStream.listen((msg) {
      unawaited(_onLocalMessageSaved(msg));
    });

    _relayListener = () {
      if (RelayService.instance.isConnected) {
        unawaited(_requestSnapshotIfNeeded());
      }
    };
    RelayService.instance.state.addListener(_relayListener!);

    _settingsListener = () {
      if (!AppSettings.instance.isDeviceLinked) {
        onUnlinked();
      }
    };
    AppSettings.instance.addListener(_settingsListener!);

    unawaited(_requestSnapshotIfNeeded());
  }

  void dispose() {
    _initialized = false;
    unawaited(_messageSub?.cancel() ?? Future<void>.value());
    _messageSub = null;
    if (_relayListener != null) {
      RelayService.instance.state.removeListener(_relayListener!);
      _relayListener = null;
    }
    if (_settingsListener != null) {
      AppSettings.instance.removeListener(_settingsListener!);
      _settingsListener = null;
    }
  }

  Future<void> onLinkedAsChild() async {
    _snapshotRequestedThisSession = false;
    await _requestSnapshotIfNeeded(force: true);
  }

  void onUnlinked() {
    _snapshotRequestedThisSession = false;
    _suppressLocalMirrorIds.clear();
  }

  Future<void> mirrorAckDelivered(String messageId) async {
    final linkedPeer = _linkedPeerKey();
    final myKey = CryptoService.instance.publicKeyHex;
    if (linkedPeer == null || myKey.isEmpty || messageId.isEmpty) return;
    try {
      await GossipRouter.instance.sendDeviceDmSync(
        publicKey: myKey,
        recipientId: linkedPeer,
        kind: 'dm_status',
        data: <String, dynamic>{
          'id': messageId,
          'st': MessageStatus.delivered.index,
        },
      );
    } catch (e) {
      debugPrint('[RLINK][LinkSync] Failed to mirror ACK: $e');
    }
  }

  Future<void> _requestSnapshotIfNeeded({bool force = false}) async {
    final settings = AppSettings.instance;
    if (!settings.isLinkedChildDevice) return;
    if (!force && _snapshotRequestedThisSession) return;

    final linkedPeer = settings.linkedDevicePublicKey.trim();
    final myKey = CryptoService.instance.publicKeyHex;
    if (linkedPeer.isEmpty || myKey.isEmpty) return;

    if (!RelayService.instance.isConnected) {
      try {
        await RelayService.instance.connect();
      } catch (_) {}
    }
    if (!RelayService.instance.isConnected) return;

    try {
      await GossipRouter.instance.sendDeviceDmSyncRequest(
        publicKey: myKey,
        recipientId: linkedPeer,
      );
      _snapshotRequestedThisSession = true;
      debugPrint(
          '[RLINK][LinkSync] Snapshot request sent to ${linkedPeer.substring(0, 8)}');
    } catch (e) {
      debugPrint('[RLINK][LinkSync] Failed to request snapshot: $e');
    }
  }

  Future<void> _handleSnapshotRequest(String sourceId, String publicKey) async {
    final settings = AppSettings.instance;
    if (!settings.isPrimaryDevice) return;
    if (!_isLinkedPeer(publicKey)) return;
    if (_snapshotSending) return;
    await _sendSnapshotTo(publicKey);
  }

  Future<void> _sendSnapshotTo(String recipientId) async {
    final myKey = CryptoService.instance.publicKeyHex;
    if (myKey.isEmpty) return;

    _snapshotSending = true;
    try {
      Future<void> send(String kind, [Map<String, dynamic> data = const {}]) =>
          GossipRouter.instance.sendDeviceDmSync(
            publicKey: myKey,
            recipientId: recipientId,
            kind: kind,
            data: data,
            snapshot: true,
          );

      await send('dm_reset');

      // Gather everything up front so the child can show an accurate progress bar.
      final contacts = (await ChatStorageService.instance.getContacts())
          .where((c) =>
              !isDmBotPeerId(c.publicKeyHex) &&
              _normalizeKey(c.publicKeyHex) != _normalizeKey(recipientId))
          .toList();
      final channels = (await ChannelService.instance.getChannels())
          .where((c) => c.isPublic && !c.blocked)
          .toList();
      final peerIds = await ChatStorageService.instance.getChatPeerIds();
      final allMessages = <ChatMessage>[];
      for (final peerId in peerIds) {
        if (isDmBotPeerId(peerId)) continue;
        if (_normalizeKey(peerId) == _normalizeKey(recipientId)) continue;
        allMessages
            .addAll(await ChatStorageService.instance.getAllMessages(peerId));
      }

      final total = contacts.length + channels.length + allMessages.length;
      await send('link_begin', {'total': total});

      for (final c in contacts) {
        await send('ct', _encodeContact(c));
        await Future.delayed(const Duration(milliseconds: 8));
      }
      for (final ch in channels) {
        await send('chan', {
          'id': ch.id,
          'n': ch.name,
          'col': ch.avatarColor,
          'em': ch.avatarEmoji,
          'adm': ch.adminId,
        });
        await Future.delayed(const Duration(milliseconds: 8));
      }

      var sent = 0;
      for (final msg in allMessages) {
        await send('dm_msg', _encodeMessage(msg));
        sent++;
        if (sent % 30 == 0) {
          await Future.delayed(const Duration(milliseconds: 20));
        }
      }

      await send('dm_done', <String, dynamic>{'count': sent});
      debugPrint('[RLINK][LinkSync] Snapshot sent: contacts=${contacts.length} '
          'channels=${channels.length} messages=$sent');
    } catch (e) {
      debugPrint('[RLINK][LinkSync] Snapshot send failed: $e');
    } finally {
      _snapshotSending = false;
    }
  }

  Future<void> _onLocalMessageSaved(ChatMessage msg) async {
    if (_suppressLocalMirrorIds.remove(msg.id)) return;

    final linkedPeer = _linkedPeerKey();
    final myKey = CryptoService.instance.publicKeyHex;
    if (linkedPeer == null || myKey.isEmpty) return;

    if (isDmBotPeerId(msg.peerId)) return;
    if (_normalizeKey(msg.peerId) == _normalizeKey(linkedPeer)) return;

    try {
      await GossipRouter.instance.sendDeviceDmSync(
        publicKey: myKey,
        recipientId: linkedPeer,
        kind: 'dm_msg',
        data: _encodeMessage(msg),
      );
    } catch (e) {
      debugPrint('[RLINK][LinkSync] Live mirror failed: $e');
    }
  }

  Future<void> _handleSyncPacket({
    required String sourceId,
    required String publicKey,
    required String kind,
    required Map<String, dynamic> data,
    required bool snapshot,
  }) async {
    if (!_isLinkedPeer(publicKey)) return;

    switch (kind) {
      case 'dm_reset':
        // Child hides its own previous conversations before the parent's arrive.
        await ChatStorageService.instance.deleteAllDirectMessages();
        return;
      case 'link_begin':
        _progressTotal = (data['total'] as num?)?.toInt() ?? 0;
        _progressDone = 0;
        _progressAvatars.clear();
        _emitProgress('Перенос профиля…');
        return;
      case 'ct':
        final c = _decodeContact(data);
        if (c != null) {
          await ChatStorageService.instance.saveContact(c);
          _bumpProgress('Контакты', emoji: c.avatarEmoji, color: c.avatarColor);
        }
        return;
      case 'chan':
        await _applyChannel(data);
        _bumpProgress('Каналы',
            emoji: (data['em'] as String?) ?? '📢',
            color: (data['col'] as num?)?.toInt() ?? 0xFF42A5F5);
        return;
      case 'dm_msg':
        final msg = _decodeMessage(data);
        if (msg == null) return;
        _suppressLocalMirror(msg.id);
        await ChatStorageService.instance.saveMessage(msg);
        _bumpProgress('Сообщения');
        return;
      case 'dm_status':
        final msgId = data['id'] as String?;
        final statusRaw = (data['st'] as num?)?.toInt();
        if (msgId == null || statusRaw == null) return;
        await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msgId,
          _statusFromIndex(statusRaw),
        );
        return;
      case 'dm_done':
        if (snapshot && AppSettings.instance.isLinkedChildDevice) {
          debugPrint(
              '[RLINK][LinkSync] Snapshot applied from ${sourceId.substring(0, sourceId.length.clamp(0, 8))}');
        }
        // Finish the animation a beat later so it doesn't flash away.
        Future<void>.delayed(const Duration(milliseconds: 900), () {
          progress.value = null;
        });
        return;
      default:
        return;
    }
  }

  void _emitProgress(String phase) {
    progress.value = LinkSyncProgress(
      done: _progressDone,
      total: _progressTotal,
      phase: phase,
      avatars: List.unmodifiable(_progressAvatars),
    );
  }

  void _bumpProgress(String phase, {String? emoji, int? color}) {
    _progressDone++;
    if (emoji != null && color != null) {
      _progressAvatars.add((emoji: emoji, color: color));
      if (_progressAvatars.length > 24) _progressAvatars.removeAt(0);
    }
    _emitProgress(phase);
  }

  /// Child applies a channel the parent shared: ensure it exists locally and
  /// subscribe to it (best-effort; admin co-ownership is not transferred).
  Future<void> _applyChannel(Map<String, dynamic> data) async {
    final id = data['id'] as String?;
    if (id == null || id.isEmpty) return;
    try {
      final myId = CryptoService.instance.publicKeyHex;
      final existing = await ChannelService.instance.getChannel(id);
      if (existing != null) {
        if (!existing.subscriberIds.contains(myId)) {
          await ChannelService.instance.subscribe(id, myId);
          unawaited(GossipRouter.instance.broadcastChannelSubscribe(
            channelId: id,
            userId: myId,
            x25519: CryptoService.instance.x25519PublicKeyBase64,
          ));
        }
      }
      // If not present locally yet, the relay directory snapshot will add it;
      // the child can then join via the channel id.
    } catch (e) {
      debugPrint('[RLINK][LinkSync] applyChannel failed: $e');
    }
  }

  static Map<String, dynamic> _encodeContact(Contact c) => <String, dynamic>{
        'pk': c.publicKeyHex,
        'n': c.nickname,
        'u': c.username,
        'col': c.avatarColor,
        'em': c.avatarEmoji,
        if (c.x25519Key != null && c.x25519Key!.isNotEmpty) 'x': c.x25519Key,
        if (c.tags.isNotEmpty) 'tg': c.tags,
        'se': c.statusEmoji,
      };

  static Contact? _decodeContact(Map<String, dynamic> data) {
    final pk = data['pk'] as String?;
    if (pk == null || pk.isEmpty) return null;
    return Contact(
      publicKeyHex: pk,
      nickname: (data['n'] as String?) ?? '',
      username: (data['u'] as String?) ?? '',
      avatarColor: (data['col'] as num?)?.toInt() ?? 0xFF42A5F5,
      avatarEmoji: (data['em'] as String?) ?? '🙂',
      x25519Key: data['x'] as String?,
      addedAt: DateTime.now(),
      tags: (data['tg'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
      statusEmoji: (data['se'] as String?) ?? '',
    );
  }

  String? _linkedPeerKey() {
    final settings = AppSettings.instance;
    if (!settings.isDeviceLinked) return null;
    final key = settings.linkedDevicePublicKey.trim();
    if (key.isEmpty) return null;
    return key;
  }

  bool _isLinkedPeer(String publicKey) {
    final linked = _linkedPeerKey();
    if (linked == null) return false;
    return _normalizeKey(linked) == _normalizeKey(publicKey);
  }

  static String _normalizeKey(String key) => key.trim().toLowerCase();

  static MessageStatus _statusFromIndex(int index) {
    final safe = index.clamp(0, MessageStatus.values.length - 1);
    return MessageStatus.values[safe];
  }

  static String _normalizedTextForMirror(ChatMessage msg) {
    if (msg.text.trim().isNotEmpty) return msg.text;
    if (msg.voicePath != null) return '🎤 Голосовое';
    if (msg.videoPath != null) return '📹 Видео';
    if (msg.filePath != null || msg.fileName != null) {
      final name = (msg.fileName ?? '').trim();
      return name.isEmpty ? '📎 Файл' : '📎 $name';
    }
    if (msg.imagePath != null) return '📷 Фото';
    return ' ';
  }

  static Map<String, dynamic> _encodeMessage(ChatMessage msg) {
    return <String, dynamic>{
      'id': msg.id,
      'p': msg.peerId,
      't': _normalizedTextForMirror(msg),
      'o': msg.isOutgoing ? 1 : 0,
      'ts': msg.timestamp.millisecondsSinceEpoch,
      'st': msg.status.index,
      if (msg.replyToMessageId != null) 'rt': msg.replyToMessageId,
      if (msg.latitude != null) 'lat': msg.latitude,
      if (msg.longitude != null) 'lng': msg.longitude,
      if (msg.forwardFromId != null) 'ffid': msg.forwardFromId,
      if (msg.forwardFromNick != null) 'ffn': msg.forwardFromNick,
      if (msg.forwardFromChannelId != null) 'ffch': msg.forwardFromChannelId,
      if (msg.stickerPackPayload != null)
        'inv': jsonEncode(msg.stickerPackPayload)
      else if (msg.invitePayloadJson != null)
        'inv': msg.invitePayloadJson,
    };
  }

  static ChatMessage? _decodeMessage(Map<String, dynamic> data) {
    final id = data['id'] as String?;
    final peerId = data['p'] as String?;
    final text = data['t'] as String?;
    final ts = (data['ts'] as num?)?.toInt();
    if (id == null ||
        id.isEmpty ||
        peerId == null ||
        peerId.isEmpty ||
        ts == null) {
      return null;
    }
    final outgoingRaw = data['o'];
    final isOutgoing = outgoingRaw == true || outgoingRaw == 1;
    final statusIndex =
        (data['st'] as num?)?.toInt() ?? MessageStatus.delivered.index;
    final invRaw = data['inv'] as String?;
    String? invitePayloadJson;
    Map<String, dynamic>? stickerPackPayload;
    if (invRaw != null && invRaw.isNotEmpty) {
      try {
        final dec = jsonDecode(invRaw);
        if (dec is Map<String, dynamic> &&
            dec['type'] == ChatMessage.kStickerPackPayloadType) {
          stickerPackPayload = dec;
        } else {
          invitePayloadJson = invRaw;
        }
      } catch (_) {
        invitePayloadJson = invRaw;
      }
    }
    return ChatMessage(
      id: id,
      peerId: peerId,
      text: (text == null || text.isEmpty) ? ' ' : text,
      replyToMessageId: data['rt'] as String?,
      latitude: (data['lat'] as num?)?.toDouble(),
      longitude: (data['lng'] as num?)?.toDouble(),
      isOutgoing: isOutgoing,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      status: _statusFromIndex(statusIndex),
      forwardFromId: data['ffid'] as String?,
      forwardFromNick: data['ffn'] as String?,
      forwardFromChannelId: data['ffch'] as String?,
      invitePayloadJson: invitePayloadJson,
      stickerPackPayload: stickerPackPayload,
    );
  }

  void _suppressLocalMirror(String messageId) {
    if (messageId.isEmpty) return;
    _suppressLocalMirrorIds.add(messageId);
    Future<void>.delayed(const Duration(seconds: 5), () {
      _suppressLocalMirrorIds.remove(messageId);
    });
  }
}
