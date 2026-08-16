import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/emoji_pack.dart';
import '../services/chat_storage_service.dart';
import '../services/crypto_service.dart';
import '../services/image_service.dart';
import '../services/relay_service.dart';
import 'emoji_pack_service.dart';

/// Служебный авто-обмен кастомными эмодзи (без карточки в чате).
class EmojiPackDmService {
  EmojiPackDmService._();

  static const _uuid = Uuid();
  static const _blobFileName = 'rlink_emoji_pack_auto.json';
  static final RegExp _shortcodeRe = RegExp(r':([a-zA-Z0-9_]{1,48}):');

  static Future<String?> _recipientX25519(String canonicalPeerId) async {
    final relayKey = RelayService.instance.getPeerX25519Key(canonicalPeerId);
    if (relayKey != null && relayKey.isNotEmpty) return relayKey;
    final contact =
        await ChatStorageService.instance.getContact(canonicalPeerId);
    final stored = contact?.x25519Key?.trim();
    return stored != null && stored.isNotEmpty ? stored : null;
  }

  static Future<Map<String, dynamic>?> _buildPayloadFromShortcodes({
    required Iterable<String> shortcodes,
    required String kind,
  }) async {
    await EmojiPackService.instance.ensureInitialized();
    EmojiPackService.instance.refreshIndexSync();
    final seen = <String>{};
    final emojis = <Map<String, dynamic>>[];
    var totalBytes = 0;
    for (final raw in shortcodes) {
      final sc = raw.trim();
      if (sc.isEmpty) continue;
      final key = sc.toLowerCase();
      if (!seen.add(key)) continue;
      // NB: must NOT gate on absolutePathForShortcode() — it returns null on web,
      // which silently dropped every emoji from the auto-payload (recipient then
      // saw only ':code:'). readEmojiBytesByShortcode is web-safe (data-URL).
      final rawBytes =
          await EmojiPackService.instance.readEmojiBytesByShortcode(sc);
      if (rawBytes == null || rawBytes.isEmpty) continue;
      final encoded = base64Encode(rawBytes);
      totalBytes += encoded.length;
      if (totalBytes > 2 * 1024 * 1024) {
        break; // Increased to 2MB for larger emoji packs
      }
      emojis.add({
        'shortcode': sc,
        'data': encoded,
      });
    }
    if (emojis.isEmpty) return null;
    return {
      'type': 'emoji_auto',
      'kind': kind,
      'emojis': emojis,
    };
  }

  static Future<Map<String, dynamic>?> buildPayloadForText(
    String text, {
    String kind = 'text',
  }) async {
    final codes = <String>[];
    for (final m in _shortcodeRe.allMatches(text)) {
      final sc = m.group(1);
      if (sc != null) codes.add(sc);
    }
    if (codes.isEmpty) return null;
    return _buildPayloadFromShortcodes(shortcodes: codes, kind: kind);
  }

  /// JSON-строка для поля `eap` в gossip (канал / группа и т.д.).
  static Future<String?> buildEmojiAutoPayloadJson(
    String text, {
    String kind = 'text',
  }) async {
    final m = await buildPayloadForText(text, kind: kind);
    if (m == null) return null;
    return jsonEncode(m);
  }

  static Future<Map<String, dynamic>?> buildPayloadForStatus(
      String statusEmoji) async {
    final m =
        RegExp(r'^:([a-zA-Z0-9_]{1,48}):$').firstMatch(statusEmoji.trim());
    if (m == null) return null;
    final sc = m.group(1);
    if (sc == null || sc.isEmpty) return null;
    return _buildPayloadFromShortcodes(shortcodes: [sc], kind: 'status');
  }

  static Future<void> sendAutoPayloadToPeer({
    required String targetPeerId,
    required String fromId,
    required Map<String, dynamic> payload,
  }) async {
    if (!RelayService.instance.isConnected) return;
    final canonical = ChatStorageService.normalizeDmPeerId(targetPeerId);
    final x25519 = await _recipientX25519(canonical);
    if (x25519 == null || x25519.isEmpty) {
      throw StateError('missing_peer_encryption_key');
    }
    final jsonBytes = utf8.encode(jsonEncode(payload));
    final compressed =
        ImageService.instance.compress(Uint8List.fromList(jsonBytes));
    final sealed = await CryptoService.instance.sealMediaPayload(
      plaintext: compressed,
      recipientX25519KeyBase64: x25519,
    );
    final msgId = 'emojiauto_${_uuid.v4()}';
    await RelayService.instance.sendBlob(
      recipientKey: canonical,
      fromId: fromId,
      msgId: msgId,
      compressedData: sealed,
      isFile: true,
      fileName: _blobFileName,
    );
  }

  /// Поле gossip `eap` (JSON) в пакетах `channel_post` / `channel_comment`.
  static Future<int> installFromGossipEapField(
    Map<String, dynamic> payload, {
    required String sourcePeerId,
  }) async {
    final eapRaw = payload['eap'] as String?;
    if (eapRaw == null || eapRaw.trim().isEmpty) return 0;
    try {
      final map = jsonDecode(eapRaw) as Map<String, dynamic>;
      return await EmojiPackService.instance.installFromAutoPayload(
        map,
        sourcePeerId: sourcePeerId,
      );
    } catch (_) {
      return 0;
    }
  }

  static Future<int> receiveFromRelay({
    required String fromId,
    required Uint8List compressedData,
  }) async {
    final decoded = await ImageService.instance.openAndDecompressIncoming(
      compressedData,
    );
    final m = jsonDecode(utf8.decode(decoded));
    if (m is! Map) return 0;
    final payload = Map<String, dynamic>.from(m);
    if (payload['type'] != 'emoji_auto') return 0;
    return EmojiPackService.instance.installFromAutoPayload(
      payload,
      sourcePeerId: fromId,
    );
  }

  // ── Whole-pack sharing (a rich card in chat, like StickerPackDmService) ──
  // Distinct from the auto-payload above: this sends the WHOLE named pack —
  // every emoji, keeping its name — as an explicit "Поделиться" action. The
  // receive/import side already exists (EmojiPackCardBubble + _dmInviteMap in
  // chat_screen.dart, driven by ChatMessage.invitePayloadJson matching
  // kind/type == 'emoji_pack' — previously only reachable from the built-in
  // Emoji bot). This just adds the missing send path, reusing that same
  // payload shape ({name, emojis:[{shortcode,data}]} — installFromSharePayload
  // doesn't gate on 'type' at all) and delivering it over the blob pipeline
  // (like stickers/emoji_auto) since base64 image bytes can be sizeable —
  // the lightweight InviteDmService text pipeline is sized for channel/group
  // metadata, not that.

  static const _packChunkBytes = 30 * 1024;
  static const _packMaxSingleBlob = 800 * 1024;
  static const _packBlobFileName = 'rlink_emoji_pack_share.json';

  static Future<Map<String, dynamic>?> buildPackSharePayload(
      EmojiPack pack) async {
    await EmojiPackService.instance.ensureInitialized();
    final emojis = <Map<String, dynamic>>[];
    for (final e in pack.emojis) {
      final bytes =
          await EmojiPackService.instance.readEmojiBytesByShortcode(e.shortcode);
      if (bytes == null || bytes.isEmpty) continue;
      emojis.add({'shortcode': e.shortcode, 'data': base64Encode(bytes)});
    }
    if (emojis.isEmpty) return null;
    return {'type': 'emoji_pack', 'name': pack.name, 'emojis': emojis};
  }

  static Future<void> _sendPackPayloadBlob({
    required BuildContext? context,
    required String targetPeerId,
    required Map<String, dynamic> payload,
  }) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    final canonical = ChatStorageService.normalizeDmPeerId(targetPeerId.trim());
    final rawName = (payload['name'] as String?)?.trim() ?? '';
    final name = rawName.isEmpty ? 'Набор' : rawName;
    final previewText = '😊 Набор эмодзи «$name»';
    final msgId = 'emojipack_${_uuid.v4()}';
    final invitePayloadJson = jsonEncode(payload);

    await ChatStorageService.instance.saveMessage(ChatMessage(
      id: msgId,
      peerId: canonical,
      text: previewText,
      invitePayloadJson: invitePayloadJson,
      isOutgoing: true,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    ));

    if (canonical == myId) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msgId, MessageStatus.sent);
      await ChatStorageService.instance.loadMessages(canonical);
      _snack(context, 'Набор сохранён');
      return;
    }
    if (!RelayService.instance.isConnected) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msgId, MessageStatus.failed);
      _snack(context, 'Для отправки набора нужен relay');
      return;
    }
    try {
      final x25519 = await _recipientX25519(canonical);
      if (x25519 == null || x25519.isEmpty) {
        throw StateError('missing_peer_encryption_key');
      }
      final jsonBytes = utf8.encode(invitePayloadJson);
      final compressed =
          ImageService.instance.compress(Uint8List.fromList(jsonBytes));
      final sealed = await CryptoService.instance.sealMediaPayload(
        plaintext: compressed,
        recipientX25519KeyBase64: x25519,
      );
      if (sealed.length <= _packMaxSingleBlob) {
        await RelayService.instance.sendBlob(
          recipientKey: canonical,
          fromId: myId,
          msgId: msgId,
          compressedData: sealed,
          isFile: true,
          fileName: _packBlobFileName,
        );
      } else {
        final total = (sealed.length / _packChunkBytes).ceil();
        for (var i = 0; i < total; i++) {
          final offset = i * _packChunkBytes;
          final end = (offset + _packChunkBytes) > sealed.length
              ? sealed.length
              : offset + _packChunkBytes;
          await RelayService.instance.sendBlobChunk(
            recipientKey: canonical,
            fromId: myId,
            msgId: msgId,
            chunkIdx: i,
            chunkTotal: total,
            chunkData: Uint8List.sublistView(sealed, offset, end),
            isFile: true,
            fileName: _packBlobFileName,
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msgId, MessageStatus.sent);
      await ChatStorageService.instance.loadMessages(canonical);
      _snack(context, 'Набор отправлен');
    } catch (e) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
          msgId, MessageStatus.failed);
      _snack(context, 'Не удалось отправить: $e');
    }
  }

  static Future<void> sendPackToPeer({
    required BuildContext? context,
    required String targetPeerId,
    required EmojiPack pack,
  }) async {
    final payload = await buildPackSharePayload(pack);
    if (payload == null) {
      _snack(context, 'В наборе нет файлов для отправки');
      return;
    }
    await _sendPackPayloadBlob(
        context: context, targetPeerId: targetPeerId, payload: payload);
  }

  /// Forwards an already-received pack card (same payload).
  static Future<void> sendPayloadToPeer({
    required BuildContext? context,
    required String targetPeerId,
    required Map<String, dynamic> payload,
  }) async {
    final t = payload['type'] as String? ?? payload['kind'] as String?;
    if (t != 'emoji_pack') return;
    await _sendPackPayloadBlob(
      context: context,
      targetPeerId: targetPeerId,
      payload: Map<String, dynamic>.from(payload),
    );
  }

  /// Incoming `emojipack_*` blob: saves a rich card (EmojiPackCardBubble, via
  /// invitePayloadJson) the recipient can tap to import. Returns a preview
  /// string for notifications, or null if the message already exists.
  static Future<String?> receivePackShareFromRelay(
    String fromId,
    String msgId,
    Uint8List compressedData,
  ) async {
    final existing = await ChatStorageService.instance.getMessageById(msgId);
    if (existing != null && existing.invitePayloadJson != null) return null;

    final raw =
        await ImageService.instance.openAndDecompressIncoming(compressedData);
    final jsonStr = utf8.decode(raw);
    final payload = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (payload['type'] != 'emoji_pack') return null;

    final name = (payload['name'] as String?)?.trim();
    final previewText =
        (name != null && name.isNotEmpty) ? '😊 Набор эмодзи «$name»' : '😊 Набор эмодзи';

    await ChatStorageService.instance.saveMessage(ChatMessage(
      id: msgId,
      peerId: fromId,
      text: previewText,
      invitePayloadJson: jsonStr,
      isOutgoing: false,
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
    ));
    await ChatStorageService.instance.loadMessages(fromId);
    return previewText;
  }

  static void _snack(BuildContext? context, String text) {
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
