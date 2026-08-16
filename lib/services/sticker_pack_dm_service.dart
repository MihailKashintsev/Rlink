import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/sticker_pack.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'image_service.dart';
import 'relay_service.dart';
import 'sticker_collection_service.dart';

/// Отправка карточки набора стикеров в ЛС (payload в [ChatMessage.stickerPackPayload],
/// по сети — сжатый JSON через relay blob, id сообщения с префиксом `stickerpack_`).
class StickerPackDmService {
  StickerPackDmService._();

  static const _relayChunkBytes = 30 * 1024;
  static const _maxSingleBlob = 800 * 1024;
  static const _blobFileName = 'rlink_sticker_pack.json';
  static const _uuid = Uuid();

  static Future<String?> _recipientX25519(String canonicalPeerId) async {
    final relayKey = RelayService.instance.getPeerX25519Key(canonicalPeerId);
    if (relayKey != null && relayKey.isNotEmpty) return relayKey;
    final contact =
        await ChatStorageService.instance.getContact(canonicalPeerId);
    final stored = contact?.x25519Key?.trim();
    return stored != null && stored.isNotEmpty ? stored : null;
  }

  static Future<Uint8List> _sealForPeer(
    String canonicalPeerId,
    Uint8List compressed,
  ) async {
    final x25519 = await _recipientX25519(canonicalPeerId);
    if (x25519 == null || x25519.isEmpty) {
      throw StateError('missing_peer_encryption_key');
    }
    return CryptoService.instance.sealMediaPayload(
      plaintext: compressed,
      recipientX25519KeyBase64: x25519,
    );
  }

  /// Собирает payload для БД и передачи (включает base64 байтов файлов).
  static Future<Map<String, dynamic>> buildStickerPackPayload(
    StickerPack pack,
  ) async {
    final docs = kIsWeb ? null : await getApplicationDocumentsDirectory();
    final previewPaths = <String>[];
    final stickers = <Map<String, dynamic>>[];
    for (var i = 0; i < pack.stickerRelPaths.length; i++) {
      final rel = pack.stickerRelPaths[i];
      if (i < 4) previewPaths.add(rel);
      Uint8List? bytes;
      if (kIsWeb || StickerCollectionService.isDataOrRemote(rel)) {
        if (rel.startsWith('data:')) bytes = Uri.parse(rel).data?.contentAsBytes();
      } else {
        final f = File(p.join(docs!.path, rel));
        if (await f.exists()) bytes = await f.readAsBytes();
      }
      if (bytes == null) continue;
      stickers.add({
        'rel': rel,
        'bytes': base64Encode(bytes),
      });
    }
    return {
      'type': ChatMessage.kStickerPackPayloadType,
      'id': pack.id,
      'title': pack.title,
      'previewPaths': previewPaths,
      'stickers': stickers,
    };
  }

  static Future<void> sendPackToPeer({
    required BuildContext? context,
    required String targetPeerId,
    required StickerPack pack,
  }) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;

    final canonical = ChatStorageService.normalizeDmPeerId(targetPeerId.trim());
    final payload = await buildStickerPackPayload(pack);
    if ((payload['stickers'] as List?)?.isEmpty != false) {
      _snack(context, 'В наборе нет файлов для отправки');
      return;
    }

    final msgId = 'stickerpack_${_uuid.v4()}';
    final title = (pack.title.trim().isEmpty) ? 'Набор' : pack.title.trim();
    final previewText = '🩵 Набор «$title»';

    final msg = ChatMessage(
      id: msgId,
      peerId: canonical,
      text: previewText,
      stickerPackPayload: payload,
      isOutgoing: true,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    );
    await ChatStorageService.instance.saveMessage(msg);

    if (canonical == myId) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.sent,
      );
      await ChatStorageService.instance.loadMessages(canonical);
      _snack(context, 'Набор сохранён');
      return;
    }

    if (!RelayService.instance.isConnected) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.failed,
      );
      _snack(context, 'Для отправки набора нужен relay');
      return;
    }

    try {
      final jsonBytes = utf8.encode(jsonEncode(payload));
      final compressed =
          ImageService.instance.compress(Uint8List.fromList(jsonBytes));
      final sealed = await _sealForPeer(canonical, compressed);

      if (sealed.length <= _maxSingleBlob) {
        await RelayService.instance.sendBlob(
          recipientKey: canonical,
          fromId: myId,
          msgId: msgId,
          compressedData: sealed,
          isFile: true,
          fileName: _blobFileName,
        );
      } else {
        final total = (sealed.length / _relayChunkBytes).ceil();
        for (var i = 0; i < total; i++) {
          final offset = i * _relayChunkBytes;
          final end = (offset + _relayChunkBytes) > sealed.length
              ? sealed.length
              : offset + _relayChunkBytes;
          final chunk = Uint8List.sublistView(sealed, offset, end);
          await RelayService.instance.sendBlobChunk(
            recipientKey: canonical,
            fromId: myId,
            msgId: msgId,
            chunkIdx: i,
            chunkTotal: total,
            chunkData: chunk,
            isFile: true,
            fileName: _blobFileName,
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }

      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.sent,
      );
      await ChatStorageService.instance.loadMessages(canonical);
      _snack(context, 'Набор отправлен');
    } catch (e, st) {
      debugPrint('[StickerPackDm] send failed: $e\n$st');
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.failed,
      );
      _snack(context, 'Не удалось отправить: $e');
    }
  }

  /// Пересылка уже полученной карточки (тот же payload).
  static Future<void> sendPayloadToPeer({
    required BuildContext? context,
    required String targetPeerId,
    required Map<String, dynamic> payload,
  }) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    if (payload['type'] != ChatMessage.kStickerPackPayloadType) return;

    final canonical = ChatStorageService.normalizeDmPeerId(targetPeerId.trim());
    final msgId = 'stickerpack_${_uuid.v4()}';
    final rawTitle = (payload['title'] as String?)?.trim() ?? '';
    final title = rawTitle.isEmpty ? 'Набор' : rawTitle;
    final previewText = '🩵 Набор «$title»';

    await ChatStorageService.instance.saveMessage(ChatMessage(
      id: msgId,
      peerId: canonical,
      text: previewText,
      stickerPackPayload: Map<String, dynamic>.from(payload),
      isOutgoing: true,
      timestamp: DateTime.now(),
      status: MessageStatus.sending,
    ));

    if (canonical == myId) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.sent,
      );
      await ChatStorageService.instance.loadMessages(canonical);
      _snack(context, 'Набор сохранён');
      return;
    }

    if (!RelayService.instance.isConnected) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.failed,
      );
      _snack(context, 'Для отправки набора нужен relay');
      return;
    }

    try {
      final jsonBytes = utf8.encode(jsonEncode(payload));
      final compressed =
          ImageService.instance.compress(Uint8List.fromList(jsonBytes));
      final sealed = await _sealForPeer(canonical, compressed);
      if (sealed.length <= _maxSingleBlob) {
        await RelayService.instance.sendBlob(
          recipientKey: canonical,
          fromId: myId,
          msgId: msgId,
          compressedData: sealed,
          isFile: true,
          fileName: _blobFileName,
        );
      } else {
        final total = (sealed.length / _relayChunkBytes).ceil();
        for (var i = 0; i < total; i++) {
          final offset = i * _relayChunkBytes;
          final end = (offset + _relayChunkBytes) > sealed.length
              ? sealed.length
              : offset + _relayChunkBytes;
          final chunk = Uint8List.sublistView(sealed, offset, end);
          await RelayService.instance.sendBlobChunk(
            recipientKey: canonical,
            fromId: myId,
            msgId: msgId,
            chunkIdx: i,
            chunkTotal: total,
            chunkData: chunk,
            isFile: true,
            fileName: _blobFileName,
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.sent,
      );
      await ChatStorageService.instance.loadMessages(canonical);
      _snack(context, 'Набор отправлен');
    } catch (e, st) {
      debugPrint('[StickerPackDm] forward failed: $e\n$st');
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msgId,
        MessageStatus.failed,
      );
      _snack(context, 'Не удалось отправить: $e');
    }
  }

  /// Входящий blob с relay (полные [data] после сборки чанков).
  /// Возвращает превью-текст для уведомлений или null, если сообщение не создано.
  /// Автоматически скачивает файлы стикеров в директорию images/stk_downloaded_*.
  static Future<String?> receiveFromRelay(
    String fromId,
    String msgId,
    Uint8List compressedData,
  ) async {
    final existing = await ChatStorageService.instance.getMessageById(msgId);
    if (existing != null && existing.stickerPackPayload != null) {
      return null;
    }

    final raw = await ImageService.instance.openAndDecompressIncoming(
      compressedData,
    );
    final jsonStr = utf8.decode(raw);
    final payload = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (payload['type'] != ChatMessage.kStickerPackPayloadType) return null;

    final title = (payload['title'] as String?)?.trim();
    final previewText = (title != null && title.isNotEmpty)
        ? '🩵 Набор «$title»'
        : '🩵 Набор стикеров';

    // Auto-download sticker files
    final stickers = payload['stickers'] as List?;
    if (stickers != null) {
      Directory? imgDir;
      if (!kIsWeb) {
        final docs = await getApplicationDocumentsDirectory();
        imgDir = Directory(p.join(docs.path, 'images'));
        if (!imgDir.existsSync()) imgDir.createSync(recursive: true);
      }

      final downloadedPaths = <String>[];
      for (var i = 0; i < stickers.length; i++) {
        try {
          final e = stickers[i] as Map?;
          if (e == null) continue;
          final b64 = e['bytes'] as String?;
          if (b64 == null || b64.isEmpty) continue;

          final bytes = base64Decode(b64);
          if (kIsWeb) {
            downloadedPaths.add('data:image/png;base64,$b64');
          } else {
            const safeExt = '.png';
            final destName = 'stk_downloaded_${msgId}_$i$safeExt';
            final dest = File(p.join(imgDir!.path, destName));
            await dest.writeAsBytes(bytes);
            downloadedPaths.add(p.join('images', destName));
          }
        } catch (e) {
          debugPrint('[StickerPackDm] download sticker $i failed: $e');
        }
      }

      // Update payload with downloaded paths
      payload['downloadedPaths'] = downloadedPaths;
    }

    final msg = ChatMessage(
      id: msgId,
      peerId: fromId,
      text: previewText,
      stickerPackPayload: payload,
      isOutgoing: false,
      timestamp: DateTime.now(),
      status: MessageStatus.delivered,
    );
    await ChatStorageService.instance.saveMessage(msg);
    await ChatStorageService.instance.loadMessages(fromId);
    return previewText;
  }

  /// Повторная отправка той же карточки (тот же [ChatMessage.id]).
  static Future<void> resendStickerPackMessage({
    required BuildContext? context,
    required ChatMessage msg,
  }) async {
    final payload = msg.stickerPackPayload;
    if (payload == null || !msg.isOutgoing) return;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;

    await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
      msg.id,
      MessageStatus.sending,
    );

    if (!RelayService.instance.isConnected) {
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msg.id,
        MessageStatus.failed,
      );
      _snack(context, 'Для отправки набора нужен relay');
      return;
    }

    try {
      final jsonBytes = utf8.encode(jsonEncode(payload));
      final compressed =
          ImageService.instance.compress(Uint8List.fromList(jsonBytes));
      final canonical = ChatStorageService.normalizeDmPeerId(msg.peerId.trim());
      final sealed = await _sealForPeer(canonical, compressed);

      if (sealed.length <= _maxSingleBlob) {
        await RelayService.instance.sendBlob(
          recipientKey: canonical,
          fromId: myId,
          msgId: msg.id,
          compressedData: sealed,
          isFile: true,
          fileName: _blobFileName,
        );
      } else {
        final total = (sealed.length / _relayChunkBytes).ceil();
        for (var i = 0; i < total; i++) {
          final offset = i * _relayChunkBytes;
          final end = (offset + _relayChunkBytes) > sealed.length
              ? sealed.length
              : offset + _relayChunkBytes;
          final chunk = Uint8List.sublistView(sealed, offset, end);
          await RelayService.instance.sendBlobChunk(
            recipientKey: canonical,
            fromId: myId,
            msgId: msg.id,
            chunkIdx: i,
            chunkTotal: total,
            chunkData: chunk,
            isFile: true,
            fileName: _blobFileName,
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msg.id,
        MessageStatus.sent,
      );
      await ChatStorageService.instance.loadMessages(canonical);
    } catch (e, st) {
      debugPrint('[StickerPackDm] resend failed: $e\n$st');
      await ChatStorageService.instance.updateMessageStatusPreserveDelivered(
        msg.id,
        MessageStatus.failed,
      );
      _snack(context, 'Повтор не удался: $e');
    }
  }

  static void _snack(BuildContext? context, String text) {
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
