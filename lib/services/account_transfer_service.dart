import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/contact.dart';
import '../models/group.dart';
import 'app_settings.dart';
import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'dm_bot_flags.dart';
import 'emoji_pack_service.dart';
import 'gossip_router.dart';
import 'group_service.dart';
import 'profile_service.dart';
import 'sticker_collection_service.dart';

/// Moves the account identity itself to a new device — distinct from
/// `DeviceLinkSyncService`'s companion-device mirror (which keeps two
/// separate identities alive and never touches private key material). This
/// service deliberately shares no code with that one: every packet here
/// carries real secrets (up to and including the account's private keys),
/// so every `xfer_data` item is individually encrypted via
/// `CryptoService.encryptMessage`/`decryptMessage` — the mirror's
/// plaintext-JSON snapshot transport is NOT reused, on purpose.
///
/// Security invariants enforced here, not just documented:
/// 1. Every inbound `xfer_data` item is verified (`verifyEncryptedEnvelope`
///    + sender-matches-typed-target) BEFORE it is decrypted or acted on.
/// 2. The completion ack is a signature made with the newly adopted key
///    over a nonce tied to the specific request — not a bare "done" flag —
///    so the old device isn't just trusting a claim before it wipes itself.
/// 3. The new device keeps routing under its own (throwaway) identity until
///    it receives `xfer_wiping` (or a manual fallback), so there is never a
///    window where two live sockets both claim the transferred pubkey.
class TransferCategories {
  final bool contacts;
  final bool channels;
  final bool groups;
  final bool emojiPacks;
  final bool dmHistory;
  final bool settings;
  final bool stickers;

  const TransferCategories({
    this.contacts = true,
    this.channels = true,
    this.groups = true,
    this.emojiPacks = true,
    this.dmHistory = true,
    this.settings = true,
    this.stickers = true,
  });

  bool isSelected(String kind) => switch (kind) {
        'contact' => contacts,
        'channel' => channels,
        'group' => groups,
        'emoji_pack' => emojiPacks,
        'dm' => dmHistory,
        'settings' => settings,
        'sticker_pack' => stickers,
        _ => false,
      };

  /// Every data kind this selection expects, in send order. `keys` is not
  /// here — it's always sent first and tracked separately.
  List<String> get selectedKinds => [
        if (contacts) 'contact',
        if (channels) 'channel',
        if (groups) 'group',
        if (emojiPacks) 'emoji_pack',
        if (dmHistory) 'dm',
        if (settings) 'settings',
        if (stickers) 'sticker_pack',
      ];
}

class IncomingTransferRequest {
  final String fromPublicKey;
  final String xpk;
  final String label;
  const IncomingTransferRequest({
    required this.fromPublicKey,
    required this.xpk,
    required this.label,
  });
}

class TransferProgress {
  final int done;
  final int total;
  final String phase;
  const TransferProgress(
      {required this.done, required this.total, required this.phase});
}

class AccountTransferService {
  AccountTransferService._();
  static final AccountTransferService instance = AccountTransferService._();

  bool _initialized = false;

  /// Non-null while THIS device has an incoming request awaiting Yes/No.
  final ValueNotifier<IncomingTransferRequest?> incomingRequest =
      ValueNotifier<IncomingTransferRequest?>(null);

  /// Non-null while a transfer is actively sending (old device) or
  /// receiving (new device).
  final ValueNotifier<TransferProgress?> progress =
      ValueNotifier<TransferProgress?>(null);

  /// True once the old device has a verified completion ack — its UI
  /// unlocks the wipe button only after this.
  final ValueNotifier<bool> readyToWipe = ValueNotifier<bool>(false);

  /// True once the new device has received `xfer_wiping` (or the user
  /// used the manual fallback) — safe to go live as the real identity.
  final ValueNotifier<bool> adoptedIdentityLive = ValueNotifier<bool>(false);

  /// True if the old device explicitly declined the new device's request —
  /// distinct from `progress` being merely unset, so the onboarding UI can
  /// show "declined" rather than silently doing nothing.
  final ValueNotifier<bool> wasDenied = ValueNotifier<bool>(false);

  // Old-device (sender) state: the single in-flight/pending request.
  String? _pendingNewDeviceId;
  String? _pendingXpk;
  String? _pendingReqId;
  String? _verifiedAckProof;

  // New-device (receiver) state.
  String? _restoreTargetId;
  String? _activeReqId;
  bool _keysReceived = false;
  final Map<String, int> _receivedCounts = {};
  final Map<String, int> _expectedCounts = {};
  /// Which category kinds to wait for — learned from the `keys` packet's
  /// `categoryKinds` field (the actual categories the OLD device selected),
  /// NOT assumed to be "all of them". Getting this wrong in either
  /// direction is a real bug: assuming more than was sent means the ack
  /// never fires (waiting on a category that will never arrive); assuming
  /// fewer means acking before a selected category actually finished.
  List<String> _expectedKinds = [];

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    GossipRouter.instance.onAccountTransferRequest =
        (sourceId, fromKey, xpk, label) {
      // Anti-spam: a new request replaces whatever was pending, never stacks.
      _pendingNewDeviceId = fromKey;
      _pendingXpk = xpk;
      incomingRequest.value =
          IncomingTransferRequest(fromPublicKey: fromKey, xpk: xpk, label: label);
    };

    GossipRouter.instance.onAccountTransferDenied = (sourceId, fromKey) {
      if (fromKey.trim().toLowerCase() == _restoreTargetId) {
        progress.value = null;
        wasDenied.value = true;
      }
    };

    GossipRouter.instance.onAccountTransferData =
        (sourceId, json, kind, total, done) =>
            _handleIncomingData(sourceId, json, kind, total, done);

    GossipRouter.instance.onAccountTransferAck =
        (sourceId, fromKey, reqId, proof) {
      unawaited(_handleAck(fromKey, reqId, proof));
    };

    GossipRouter.instance.onAccountTransferWiping = (sourceId, fromKey) {
      if (fromKey.trim().toLowerCase() != _restoreTargetId) return;
      adoptedIdentityLive.value = true;
    };
  }

  void clearIncomingRequest() {
    incomingRequest.value = null;
    _pendingNewDeviceId = null;
    _pendingXpk = null;
  }

  // ───────────────────────── new device: request ─────────────────────────

  Future<void> requestTransfer(String targetId, {String? label}) async {
    final me = CryptoService.instance;
    _restoreTargetId = targetId.trim().toLowerCase();
    _activeReqId = null;
    _keysReceived = false;
    _receivedCounts.clear();
    _expectedCounts.clear();
    _expectedKinds = [];
    wasDenied.value = false;
    adoptedIdentityLive.value = false;
    progress.value = const TransferProgress(done: 0, total: 1, phase: 'Запрос отправлен');
    await GossipRouter.instance.sendAccountTransferRequest(
      fromPublicKey: me.publicKeyHex,
      xpk: me.x25519PublicKeyBase64,
      label: label ?? defaultDeviceLabel(),
      recipientId: _restoreTargetId!,
    );
  }

  static String defaultDeviceLabel() {
    if (kIsWeb) return 'Браузер';
    try {
      if (Platform.isAndroid) return 'Android';
      if (Platform.isIOS) return 'iPhone/iPad';
      if (Platform.isMacOS) return 'Mac';
      if (Platform.isWindows) return 'Windows';
      if (Platform.isLinux) return 'Linux';
    } catch (_) {}
    return 'Устройство';
  }

  // ─────────────────── old device: approve/deny + send ───────────────────

  Future<void> deny() async {
    final target = _pendingNewDeviceId;
    clearIncomingRequest();
    if (target == null) return;
    await GossipRouter.instance.sendAccountTransferDenied(
      fromPublicKey: CryptoService.instance.publicKeyHex,
      recipientId: target,
    );
  }

  /// Approves and sends every selected category, encrypted item-by-item to
  /// the requester's ephemeral X25519 key. Each category is sent as N item
  /// packets followed by (or including, if N=0) a `{total, done}` marker so
  /// the receiver's bookkeeping is complete even for an empty category.
  Future<void> approveAndSend(TransferCategories categories) async {
    final newDeviceId = _pendingNewDeviceId;
    final xpk = _pendingXpk;
    if (newDeviceId == null || xpk == null) return;
    _pendingReqId = DateTime.now().microsecondsSinceEpoch.toString();
    clearIncomingRequest();

    final me = CryptoService.instance;
    progress.value = const TransferProgress(done: 0, total: 1, phase: 'Ключи');

    Future<void> sendItem(String kind, String plaintextJson,
        {int? total, bool done = false}) async {
      final enc = await me.encryptMessage(
        plaintext: plaintextJson,
        recipientX25519KeyBase64: xpk,
      );
      await GossipRouter.instance.sendAccountTransferData(
        encryptedJson: enc.toJson(),
        kind: kind,
        recipientId: newDeviceId,
        total: total,
        done: done,
      );
    }

    // Keys + profile — always first, always sent regardless of category
    // selection. Profile travels bundled here (not as its own category):
    // without a nickname the new device would have the identity but
    // `ProfileService.hasProfile` would stay false and main.dart's router
    // would loop it straight back to onboarding. Avatar/banner IMAGE files
    // aren't included — same media-transfer scoping trade-off as elsewhere
    // in this feature, only the profile fields that are plain values.
    final keys = await me.exportRawKeyMaterialForTransfer();
    final myProfile = ProfileService.instance.profile;
    final payload = <String, dynamic>{
      ...keys,
      // The receiver waits for exactly these kinds to complete before it
      // acks — must match what's actually sent below, category-for-category.
      'categoryKinds': categories.selectedKinds,
      if (myProfile != null) ...{
        'nickname': myProfile.nickname,
        'username': myProfile.username,
        'avatarColor': myProfile.avatarColor,
        'avatarEmoji': myProfile.avatarEmoji,
        'tags': myProfile.tags,
        'statusEmoji': myProfile.statusEmoji,
      },
    };
    await sendItem('keys', jsonEncode(payload), total: 1, done: true);

    var doneCount = 0;
    void bump(String phase) {
      doneCount++;
      progress.value =
          TransferProgress(done: doneCount, total: categories.selectedKinds.length + 1, phase: phase);
    }

    if (categories.contacts) {
      final contacts = await ChatStorageService.instance.getContacts();
      final filtered =
          contacts.where((c) => !isDmBotPeerId(c.publicKeyHex)).toList();
      for (var i = 0; i < filtered.length; i++) {
        await sendItem('contact', jsonEncode(_encodeContact(filtered[i])),
            total: i == 0 ? filtered.length : null, done: i == filtered.length - 1);
      }
      if (filtered.isEmpty) await sendItem('contact', '{}', total: 0, done: true);
      bump('Контакты');
    }

    if (categories.channels) {
      final channels = (await ChannelService.instance.getChannels())
          .where((c) => c.isPublic && !c.blocked)
          .toList();
      for (var i = 0; i < channels.length; i++) {
        final ch = channels[i];
        await sendItem(
          'channel',
          jsonEncode({
            'id': ch.id,
            'n': ch.name,
            'col': ch.avatarColor,
            'em': ch.avatarEmoji,
            'adm': ch.adminId,
          }),
          total: i == 0 ? channels.length : null,
          done: i == channels.length - 1,
        );
      }
      if (channels.isEmpty) await sendItem('channel', '{}', total: 0, done: true);
      bump('Каналы');
    }

    if (categories.groups) {
      final groups = await GroupService.instance.getGroups();
      for (var i = 0; i < groups.length; i++) {
        final g = groups[i];
        await sendItem(
          'group',
          jsonEncode({
            'id': g.id,
            'n': g.name,
            'cr': g.creatorId,
            'mem': g.memberIds,
            'mod': g.moderatorIds,
            'col': g.avatarColor,
            'em': g.avatarEmoji,
            'ca': g.createdAt,
          }),
          total: i == 0 ? groups.length : null,
          done: i == groups.length - 1,
        );
      }
      if (groups.isEmpty) await sendItem('group', '{}', total: 0, done: true);
      bump('Группы');
    }

    if (categories.emojiPacks) {
      final payloads = await EmojiPackService.instance.exportAllPacksAsPayloads();
      for (var i = 0; i < payloads.length; i++) {
        await sendItem('emoji_pack', jsonEncode(payloads[i]),
            total: i == 0 ? payloads.length : null, done: i == payloads.length - 1);
      }
      if (payloads.isEmpty) {
        await sendItem('emoji_pack', '{}', total: 0, done: true);
      }
      bump('Эмодзи');
    }

    if (categories.dmHistory) {
      final peerIds = await ChatStorageService.instance.getChatPeerIds();
      final messages = <ChatMessage>[];
      for (final peerId in peerIds) {
        if (isDmBotPeerId(peerId)) continue;
        messages.addAll(await ChatStorageService.instance.getAllMessages(peerId));
      }
      for (var i = 0; i < messages.length; i++) {
        await sendItem('dm', jsonEncode(_encodeMessage(messages[i])),
            total: i == 0 ? messages.length : null, done: i == messages.length - 1);
        if (i % 30 == 29) await Future.delayed(const Duration(milliseconds: 20));
      }
      if (messages.isEmpty) await sendItem('dm', '{}', total: 0, done: true);
      bump('Сообщения');
    }

    if (categories.settings) {
      await sendItem('settings', jsonEncode(_encodeSettings()), total: 1, done: true);
      bump('Настройки');
    }

    if (categories.stickers) {
      final packs = await StickerCollectionService.instance.loadPacks();
      for (var i = 0; i < packs.length; i++) {
        final pack = packs[i];
        final stickers = <Map<String, dynamic>>[];
        for (final rel in pack.stickerRelPaths) {
          final bytes = await _readStickerBytesWebSafe(rel);
          // Same graceful-skip ceiling the device-link mirror uses for
          // media — an oversized single item shouldn't sink the transfer.
          if (bytes == null || bytes.isEmpty || bytes.length > 400 * 1024) {
            continue;
          }
          stickers.add({'ext': _extForRel(rel), 'bytes': base64Encode(bytes)});
        }
        await sendItem(
          'sticker_pack',
          jsonEncode({'title': pack.title, 'stickers': stickers}),
          total: i == 0 ? packs.length : null,
          done: i == packs.length - 1,
        );
      }
      if (packs.isEmpty) await sendItem('sticker_pack', '{}', total: 0, done: true);
      bump('Стикеры');
    }

    progress.value = TransferProgress(
      done: categories.selectedKinds.length + 1,
      total: categories.selectedKinds.length + 1,
      phase: 'Ожидание подтверждения…',
    );
  }

  Future<void> _handleAck(String fromKey, String reqId, String proof) async {
    if (fromKey.isEmpty || reqId != _pendingReqId) return;
    final nonce = 'rlink.xfer.ack.v1|$reqId';
    // Gate 2: proof-of-possession, signed with the NEW device's now-adopted
    // key — not a bare completion flag.
    final ok = await CryptoService.instance.verifyUtf8Signature(fromKey, nonce, proof);
    if (!ok) {
      debugPrint('[XferSvc] rejected ack: bad signature for reqId=$reqId');
      return;
    }
    _verifiedAckProof = proof;
    readyToWipe.value = true;
  }

  /// Old device, once [readyToWipe] is true (or the user invokes the manual
  /// "wipe anyway" fallback for a dropped-ack edge case) — sends the
  /// fire-and-forget signal and returns; the actual data wipe is a separate
  /// call (`rlinkPerformAccountTransferWipe`), kept out of this service so
  /// this file stays about the protocol, not local storage teardown.
  Future<void> notifyWiping() async {
    final target = _pendingNewDeviceId;
    if (target == null) return;
    await GossipRouter.instance.sendAccountTransferWiping(
      fromPublicKey: CryptoService.instance.publicKeyHex,
      recipientId: target,
    );
  }

  bool get hasVerifiedAck => _verifiedAckProof != null;

  // ───────────────────────── new device: receive ─────────────────────────

  Future<void> _handleIncomingData(
    String sourceId,
    Map<String, dynamic> json,
    String kind,
    int? total,
    bool done,
  ) async {
    final target = _restoreTargetId;
    if (target == null) return; // not expecting a transfer right now
    final msg = EncryptedMessage.fromJson(json);

    // Gate 1 (non-negotiable): verify before trust, and the sender must be
    // exactly who we asked to transfer FROM — not merely "a valid signer".
    if (msg.senderPublicKey.trim().toLowerCase() != target) return;
    if (!await CryptoService.instance.verifyEncryptedEnvelope(msg)) return;
    final plaintext = await CryptoService.instance.decryptMessage(msg);
    if (plaintext == null) return;

    if (kind == 'keys') {
      try {
        final k = jsonDecode(plaintext) as Map<String, dynamic>;
        await CryptoService.instance.restoreIdentity(
          edPrivB64: k['edPriv'] as String,
          edPubB64: k['edPub'] as String,
          xPrivB64: k['xPriv'] as String,
          xPubB64: k['xPub'] as String,
        );
        _expectedKinds =
            (k['categoryKinds'] as List?)?.map((e) => e.toString()).toList() ?? [];
        final nickname = (k['nickname'] as String?)?.trim();
        if (nickname != null && nickname.isNotEmpty) {
          if (!ProfileService.instance.hasProfile) {
            await ProfileService.instance.createProfile(
              publicKeyHex: CryptoService.instance.publicKeyHex,
              nickname: nickname,
            );
          }
          await ProfileService.instance.updateProfile(
            nickname: nickname,
            username: k['username'] as String?,
            avatarColor: (k['avatarColor'] as num?)?.toInt(),
            avatarEmoji: k['avatarEmoji'] as String?,
            tags: (k['tags'] as List?)?.map((e) => e.toString()).toList(),
            statusEmoji: k['statusEmoji'] as String?,
          );
        }
        _keysReceived = true;
        _emitReceiveProgress('Ключи');
      } catch (e) {
        debugPrint('[XferSvc] keys decode failed: $e');
      }
      await _maybeSendAckIfComplete();
      return;
    }

    if (total != null) _expectedCounts[kind] = total;
    if (plaintext != '{}') {
      await _applyReceivedItem(kind, plaintext);
      _receivedCounts[kind] = (_receivedCounts[kind] ?? 0) + 1;
    }
    if (done && !_expectedCounts.containsKey(kind)) {
      _expectedCounts[kind] = _receivedCounts[kind] ?? 0;
    }
    _emitReceiveProgress(_phaseLabelFor(kind));
    await _maybeSendAckIfComplete();
  }

  void _emitReceiveProgress(String phase) {
    final doneKinds = _expectedKinds.where(_kindComplete).length + (_keysReceived ? 1 : 0);
    progress.value = TransferProgress(
      done: doneKinds,
      total: _expectedKinds.length + 1,
      phase: phase,
    );
  }

  bool _kindComplete(String kind) {
    final expected = _expectedCounts[kind];
    if (expected == null) return false;
    return (_receivedCounts[kind] ?? 0) >= expected;
  }

  Future<void> _maybeSendAckIfComplete() async {
    if (!_keysReceived) return;
    for (final k in _expectedKinds) {
      if (!_kindComplete(k)) return;
    }
    final target = _restoreTargetId;
    final reqId = _activeReqId ??= DateTime.now().microsecondsSinceEpoch.toString();
    if (target == null) return;
    final nonce = 'rlink.xfer.ack.v1|$reqId';
    final proof = await CryptoService.instance.signUtf8Message(nonce);
    await GossipRouter.instance.sendAccountTransferAck(
      fromPublicKey: CryptoService.instance.publicKeyHex,
      reqId: reqId,
      proof: proof,
      recipientId: target,
    );
    progress.value = const TransferProgress(done: 1, total: 1, phase: 'Готово — ожидание старого устройства');
  }

  Future<void> _applyReceivedItem(String kind, String plaintextJson) async {
    try {
      final data = jsonDecode(plaintextJson) as Map<String, dynamic>;
      switch (kind) {
        case 'contact':
          final c = _decodeContact(data);
          if (c != null) await ChatStorageService.instance.saveContact(c);
        case 'channel':
          await _applyChannel(data);
        case 'group':
          await _applyGroup(data);
        case 'emoji_pack':
          await EmojiPackService.instance
              .installFromSharePayload(data, replaceByName: true);
        case 'dm':
          final msg = _decodeMessage(data);
          if (msg != null) await ChatStorageService.instance.saveMessage(msg);
        case 'settings':
          await _applySettings(data);
        case 'sticker_pack':
          await _applyStickerPack(data);
      }
    } catch (e) {
      debugPrint('[XferSvc] apply $kind failed: $e');
    }
  }

  static String _phaseLabelFor(String kind) => switch (kind) {
        'contact' => 'Контакты',
        'channel' => 'Каналы',
        'group' => 'Группы',
        'emoji_pack' => 'Эмодзи',
        'dm' => 'Сообщения',
        'settings' => 'Настройки',
        'sticker_pack' => 'Стикеры',
        _ => kind,
      };

  // ───────────────────────────── encode/decode ─────────────────────────────
  // Deliberately duplicated from device_link_sync_service.dart rather than
  // shared — see the file doc-comment on why this service stays decoupled.

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

  static Future<void> _applyChannel(Map<String, dynamic> data) async {
    final id = data['id'] as String?;
    if (id == null || id.isEmpty) return;
    final myId = CryptoService.instance.publicKeyHex;
    final existing = await ChannelService.instance.getChannel(id);
    if (existing != null && !existing.subscriberIds.contains(myId)) {
      await ChannelService.instance.subscribe(id, myId);
      unawaited(GossipRouter.instance.broadcastChannelSubscribe(
        channelId: id,
        userId: myId,
        x25519: CryptoService.instance.x25519PublicKeyBase64,
      ));
    }
  }

  static Future<void> _applyGroup(Map<String, dynamic> data) async {
    final id = data['id'] as String?;
    if (id == null || id.isEmpty) return;
    final g = Group(
      id: id,
      name: (data['n'] as String?) ?? '',
      creatorId: (data['cr'] as String?) ?? '',
      memberIds:
          (data['mem'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      moderatorIds:
          (data['mod'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      avatarColor: (data['col'] as num?)?.toInt() ?? 0xFF5C6BC0,
      avatarEmoji: (data['em'] as String?) ?? '👥',
      createdAt:
          (data['ca'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
    );
    await GroupService.instance.upsertGroupsFromBackup([g]);
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

  static Map<String, dynamic> _encodeMessage(ChatMessage msg) => <String, dynamic>{
        'id': msg.id,
        'p': msg.peerId,
        't': _normalizedTextForMirror(msg),
        'o': msg.isOutgoing ? 1 : 0,
        'ts': msg.timestamp.millisecondsSinceEpoch,
        'st': msg.status.index,
        if (msg.replyToMessageId != null) 'rt': msg.replyToMessageId,
      };

  static ChatMessage? _decodeMessage(Map<String, dynamic> data) {
    final id = data['id'] as String?;
    final peerId = data['p'] as String?;
    final ts = (data['ts'] as num?)?.toInt();
    if (id == null || id.isEmpty || peerId == null || peerId.isEmpty || ts == null) {
      return null;
    }
    final outgoingRaw = data['o'];
    final statusIndex = (data['st'] as num?)?.toInt() ?? MessageStatus.delivered.index;
    return ChatMessage(
      id: id,
      peerId: peerId,
      text: (data['t'] as String?)?.isNotEmpty == true ? data['t'] as String : ' ',
      replyToMessageId: data['rt'] as String?,
      isOutgoing: outgoingRaw == true || outgoingRaw == 1,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      status: MessageStatus.values[statusIndex.clamp(0, MessageStatus.values.length - 1)],
    );
  }

  /// Curated, user-meaningful preference set — appearance, notifications,
  /// chat behavior. Deliberately excludes device-link role, relay/network
  /// config, per-peer overrides, and anything device-specific (battery
  /// thresholds, app icon variant): those don't make sense to carry to a
  /// different device.
  static Map<String, dynamic> _encodeSettings() {
    final s = AppSettings.instance;
    return {
      'appPalette': s.appPalette,
      'newDesign': s.newDesign,
      'animatedGradient': s.animatedGradient,
      'liquidGlass': s.liquidGlass,
      'chatBackground': s.chatBackground,
      'bubbleStyle': s.bubbleStyle,
      'clockFormat': s.clockFormat,
      'messageDensity': s.messageDensity,
      'compactMode': s.compactMode,
      'accentColorIndex': s.accentColorIndex,
      'fontSize': s.fontSize,
      'locale': s.locale,
      'sendOnEnter': s.sendOnEnter,
      'notificationsEnabled': s.notificationsEnabled,
      'notifSound': s.notifSound,
      'notifVibration': s.notifVibration,
      'notifyPersonal': s.notifyPersonal,
      'notifyGroups': s.notifyGroups,
      'notifyChannels': s.notifyChannels,
      'callRingtone': s.callRingtone,
      'soundTheme': s.soundTheme,
      'showReadReceipts': s.showReadReceipts,
      'showOnlineStatus': s.showOnlineStatus,
      'hideLastSeen': s.hideLastSeen,
      'autoDownloadMedia': s.autoDownloadMedia,
      'useIosStyleEmoji': s.useIosStyleEmoji,
      'quickReactionEmoji': s.quickReactionEmoji,
      'showReactionsQuickBar': s.showReactionsQuickBar,
      'useSystemGallery': s.useSystemGallery,
    };
  }

  static Future<void> _applySettings(Map<String, dynamic> d) async {
    final s = AppSettings.instance;
    Future<void> ifPresent<T>(String key, Future<void> Function(T v) apply) async {
      if (d.containsKey(key) && d[key] != null) await apply(d[key] as T);
    }

    await ifPresent<int>('appPalette', s.setAppPalette);
    await ifPresent<bool>('newDesign', s.setNewDesign);
    await ifPresent<bool>('animatedGradient', s.setAnimatedGradient);
    await ifPresent<bool>('liquidGlass', s.setLiquidGlass);
    await ifPresent<bool>('chatBackground', s.setChatBackground);
    await ifPresent<int>('bubbleStyle', s.setBubbleStyle);
    await ifPresent<int>('clockFormat', s.setClockFormat);
    await ifPresent<int>('messageDensity', s.setMessageDensity);
    await ifPresent<bool>('compactMode', s.setCompactMode);
    await ifPresent<int>('accentColorIndex', s.setAccentColor);
    await ifPresent<int>('fontSize', s.setFontSize);
    await ifPresent<String>('locale', s.setLocale);
    await ifPresent<bool>('sendOnEnter', s.setSendOnEnter);
    await ifPresent<bool>('notificationsEnabled', s.setNotificationsEnabled);
    await ifPresent<bool>('notifSound', s.setNotifSound);
    await ifPresent<bool>('notifVibration', s.setNotifVibration);
    await ifPresent<bool>('notifyPersonal', s.setNotifyPersonal);
    await ifPresent<bool>('notifyGroups', s.setNotifyGroups);
    await ifPresent<bool>('notifyChannels', s.setNotifyChannels);
    await ifPresent<int>('callRingtone', s.setCallRingtone);
    await ifPresent<int>('soundTheme', s.setSoundTheme);
    await ifPresent<bool>('showReadReceipts', s.setShowReadReceipts);
    await ifPresent<bool>('showOnlineStatus', s.setShowOnlineStatus);
    await ifPresent<bool>('hideLastSeen', s.setHideLastSeen);
    await ifPresent<bool>('autoDownloadMedia', s.setAutoDownloadMedia);
    await ifPresent<bool>('useIosStyleEmoji', s.setUseIosStyleEmoji);
    await ifPresent<String>('quickReactionEmoji', s.setQuickReactionEmoji);
    await ifPresent<bool>('showReactionsQuickBar', s.setShowReactionsQuickBar);
    await ifPresent<bool>('useSystemGallery', s.setUseSystemGallery);
  }

  static Future<void> _applyStickerPack(Map<String, dynamic> data) async {
    final title = (data['title'] as String?) ?? 'Набор';
    final rawStickers = (data['stickers'] as List?) ?? const [];
    if (rawStickers.isEmpty) return;
    final bytesList = <Uint8List>[];
    final exts = <String>[];
    for (final raw in rawStickers) {
      if (raw is! Map) continue;
      final b64 = raw['bytes'] as String?;
      if (b64 == null || b64.isEmpty) continue;
      try {
        bytesList.add(base64Decode(b64));
        exts.add((raw['ext'] as String?) ?? '.png');
      } catch (_) {}
    }
    if (bytesList.isEmpty) return;
    await StickerCollectionService.instance.importPackFromBytesList(
      title: title,
      bytesList: bytesList,
      exts: exts,
    );
  }

  static String _extForRel(String rel) {
    final clean = rel.split('#').first.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot == clean.length - 1) return '.png';
    return clean.substring(dot);
  }

  static Future<Uint8List?> _readStickerBytesWebSafe(String rel) async {
    if (rel.startsWith('data:')) {
      final comma = rel.indexOf(',');
      if (comma < 0) return null;
      try {
        return base64Decode(rel.substring(comma + 1));
      } catch (_) {
        return null;
      }
    }
    final abs = await StickerCollectionService.instance.absoluteFileForRel(rel);
    if (abs == null) return null;
    try {
      final f = File(abs);
      if (f.existsSync()) return f.readAsBytes();
    } catch (_) {}
    return null;
  }
}
