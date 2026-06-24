import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import 'ble_service.dart';
import 'channel_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'google_drive_channel_backup.dart';
import 'gossip_router.dart';
import 'image_service.dart';
import 'relay_service.dart';
import '../utils/web_file_store.dart';
import '../utils/web_image_compress.dart';

/// Read avatar/banner bytes web-safely (data: URL, OPFS, or native file).
Future<Uint8List?> _readChannelVisualBytes(String? path) async {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('data:')) return bytesFromDataUrl(path);
  final rp = ImageService.instance.resolveStoredPath(path) ?? path;
  if (kIsWeb) {
    if (isWebStoredFile(rp)) return readWebStoredFile(rp);
    return null;
  }
  try {
    final f = File(rp);
    if (f.existsSync()) return f.readAsBytes();
  } catch (_) {}
  return null;
}

/// Резерв истории канала: отдельный симметричный ключ на канал, шифрование снимка,
/// тихая доставка чанков подписчикам и опциональная копия на Google Drive у админа.
class ChannelBackupService {
  ChannelBackupService._();
  static final ChannelBackupService instance = ChannelBackupService._();

  static bool get _isMobile =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  final Map<String, _BakAssembly> _assemblies = {};
  final Map<String, _PendingDecrypt> _pendingDecryptByChannel = {};

  String _symStorageKey(String channelId) => 'chbak_sym_$channelId';

  Future<void> _writeSymKeyBytes(String channelId, Uint8List key32) async {
    final v = base64Encode(key32);
    if (_isMobile) {
      await _secure.write(key: _symStorageKey(channelId), value: v);
    } else {
      final p = await SharedPreferences.getInstance();
      await p.setString(_symStorageKey(channelId), v);
    }
  }

  Future<Uint8List?> _readSymKeyBytes(String channelId) async {
    final String? raw =
        _isMobile ? await _secure.read(key: _symStorageKey(channelId)) : null;
    final s = _isMobile
        ? raw
        : (await SharedPreferences.getInstance())
            .getString(_symStorageKey(channelId));
    if (s == null || s.isEmpty) return null;
    try {
      return Uint8List.fromList(base64Decode(s));
    } catch (_) {
      return null;
    }
  }

  /// Ключ снимка для канала (создаётся при первом резерве админом или при приёме wrap).
  Future<Uint8List> getOrCreateSymmetricKey(String channelId) async {
    final existing = await _readSymKeyBytes(channelId);
    if (existing != null && existing.length == 32) return existing;
    final rng = Random.secure();
    final key =
        Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
    await _writeSymKeyBytes(channelId, key);
    return key;
  }

  Future<int> _appliedRev(String channelId) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt('chbak_applied_$channelId') ?? 0;
  }

  Future<void> _setAppliedRev(String channelId, int rev) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('chbak_applied_$channelId', rev);
  }

  Future<String?> _readKeysFileId(String channelId) async {
    final p = await SharedPreferences.getInstance();
    return p.getString('chbak_kfid_$channelId');
  }

  Future<void> _writeKeysFileId(String channelId, String fileId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('chbak_kfid_$channelId', fileId);
  }

  Future<String?> _readSettingsFileId(String channelId) async {
    final p = await SharedPreferences.getInstance();
    return p.getString('chbak_sfid_$channelId');
  }

  Future<void> _writeSettingsFileId(String channelId, String fileId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('chbak_sfid_$channelId', fileId);
  }

  static String backupMsgId(String channelId, int rev) =>
      'chbak_${ChannelService.compactChannelId(channelId)}_$rev';

  List<String> _splitChunks(Uint8List data) {
    final chunks = <String>[];
    var offset = 0;
    // Must stay tiny: gossip drops img packets over ~500B (_kMaxImgPayloadBytes).
    while (offset < data.length) {
      final end = (offset + kImgChunkBytes).clamp(0, data.length);
      chunks.add(base64Encode(data.sublist(offset, end)));
      offset = end;
    }
    return chunks;
  }

  /// Best-effort P2P broadcast of the sealed snapshot. Runs unawaited so a large
  /// snapshot never blocks the publish (Drive is the primary delivery path).
  Future<void> _broadcastSnapshotOverGossip(
      String channelId, int rev, String adminId, Uint8List sealed) async {
    try {
      await Future.delayed(const Duration(milliseconds: 400));
      final mid = backupMsgId(channelId, rev);
      final chunks = _splitChunks(sealed);
      await GossipRouter.instance.sendChannelBackupMeta(
        channelId: channelId,
        rev: rev,
        totalChunks: chunks.length,
        adminId: adminId,
        msgId: mid,
      );
      for (var i = 0; i < chunks.length; i++) {
        await GossipRouter.instance.sendChannelBackupChunk(
          msgId: mid,
          index: i,
          base64Data: chunks[i],
        );
        if (i % 6 == 5) {
          await Future.delayed(const Duration(milliseconds: 12));
        }
      }
    } catch (e) {
      debugPrint('[RLINK][ChBak] gossip snapshot broadcast failed: $e');
    }
  }

  /// Admin-only: wrap the channel's symmetric key for [subscriberId] (using the
  /// X25519 key they sent in their history request) and deliver it P2P. Fixes a
  /// brand-new subscriber getting "нет ключа" because the admin didn't have
  /// their key in the published keys-file. Also registers the key so the next
  /// publish includes them in the keys-file.
  Future<void> sendChannelKeyToSubscriber(
      String channelId, String subscriberId, String x25519) async {
    try {
      final myId = CryptoService.instance.publicKeyHex;
      final ch = await ChannelService.instance.getChannel(channelId);
      if (ch == null || ch.adminId != myId) return;
      if (x25519.isEmpty) return;
      // Remember the key for future publishes (keys-file offline path).
      BleService.instance.registerPeerX25519Key(subscriberId, x25519);
      final key = await _readSymKeyBytes(channelId);
      if (key == null) return;
      final em = await CryptoService.instance.encryptMessage(
        plaintext: base64.encode(key),
        recipientX25519KeyBase64: x25519,
      );
      await GossipRouter.instance.sendChannelBackupKey(
        channelId: channelId,
        recipientPublicKeyHex: subscriberId,
        wrapped: em,
      );
      debugPrint(
          '[RLINK][ChBak] sent backup key to new subscriber ${subscriberId.substring(0, 8)}');
    } catch (e) {
      debugPrint('[RLINK][ChBak] sendChannelKeyToSubscriber failed: $e');
    }
  }

  Future<String?> _x25519For(String userId) async {
    final c = await ChatStorageService.instance.getContact(userId);
    final fromContact = c?.x25519Key;
    if (fromContact != null && fromContact.isNotEmpty) return fromContact;
    var k = BleService.instance.getPeerX25519Key(userId);
    if (k != null && k.isNotEmpty) return k;
    k = RelayService.instance.getPeerX25519Key(userId);
    if (k != null && k.isNotEmpty) return k;
    return null;
  }

  /// После удаления поста/комментария и т.п.: обновить Google Drive и P2P-снимок,
  /// если текущий пользователь — админ и включён резерв на Drive (как после нового поста).
  Future<void> publishBackupIfAdminDriveEnabled(String channelId) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return;
    final ch = await ChannelService.instance.getChannel(channelId);
    if (ch == null || ch.adminId != myId || !ch.driveBackupEnabled) return;
    await publishBackup(ch);
  }

  /// Публикация снимка (только админ канала).
  Future<void> publishBackup(Channel channel) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (channel.adminId != myId) return;

    final rev = channel.driveBackupRev + 1;
    final snap =
        await ChannelService.instance.buildChannelBackupSnapshot(channel.id);
    snap['rev'] = rev;
    final jsonStr = jsonEncode(snap);
    final key = await getOrCreateSymmetricKey(channel.id);
    final sealed =
        await CryptoService.instance.sealSymmetric(utf8.encode(jsonStr), key);

    // Wrap symmetric key per subscriber for gossip delivery and keys-file on Drive.
    final subs = channel.subscriberIds.toSet()..remove(myId);
    final wrappedKeys = <String, dynamic>{};
    for (final uid in subs) {
      final x = await _x25519For(uid);
      if (x == null) continue;
      final em = await CryptoService.instance.encryptMessage(
        plaintext: base64.encode(key),
        recipientX25519KeyBase64: x,
      );
      await GossipRouter.instance.sendChannelBackupKey(
        channelId: channel.id,
        recipientPublicKeyHex: uid,
        wrapped: em,
      );
      wrappedKeys[uid] = em.toJson();
    }

    // Always include the admin's OWN wrapped key in the keys file, so the owner
    // can recover the channel from Drive on a fresh device/session where the
    // local symmetric key isn't present (e.g. web secure storage didn't persist
    // it). _x25519For can't resolve self, so use our own X25519 public key.
    try {
      final adminX = CryptoService.instance.x25519PublicKeyBase64;
      if (adminX.isNotEmpty) {
        final em = await CryptoService.instance.encryptMessage(
          plaintext: base64.encode(key),
          recipientX25519KeyBase64: adminX,
        );
        wrappedKeys[myId] = em.toJson();
      }
    } catch (_) {}

    // Broadcast the snapshot to P2P peers. With media embedded the blob is large
    // and gossip caps img packets at ~500B → thousands of 90B chunks. Awaiting
    // this made "Опубликовать историю" spin forever AND blocked the Drive upload
    // below (so new subscribers saw nothing). For Drive-enabled channels skip it
    // entirely — subscribers background-pull the full snapshot from Drive. Only
    // non-Drive channels need the gossip path, and even then run it unawaited.
    if (!channel.driveBackupEnabled) {
      unawaited(_broadcastSnapshotOverGossip(channel.id, rev, myId, sealed));
    }

    String? fileId;
    String? fileUrl;
    String? keysFileId;
    String? keysFileUrl;
    String? avatarFileId;
    String? avatarUrl;
    String? bannerFileId;
    String? bannerUrl;

    // Avatar/banner cleared → also clear their stored URLs below.
    var clearAvatar = false;
    var clearBanner = false;

    if (channel.driveBackupEnabled) {
      final pairing =
          GoogleDriveChannelBackup.channelAccountPairing(channel.id);
      // Everything for this channel lives in Rlink/<channelId>/ with clean names.
      String cid() => channel.id;

      // Encrypted save file (history + content).
      fileId = await GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
        fileName: 'backup.bin',
        ciphertext: sealed,
        existingFileId: channel.driveFileId,
        accountPairing: pairing,
        channelId: cid(),
      );
      if (fileId != null) {
        fileUrl =
            await GoogleDriveChannelBackup.makePublicAndGetDownloadUrl(fileId);
      }

      // Per-subscriber wrapped keys.
      if (wrappedKeys.isNotEmpty) {
        final keysBytes = Uint8List.fromList(utf8.encode(jsonEncode({
          'v': 1,
          'channelId': channel.id,
          'rev': rev,
          'keys': wrappedKeys,
        })));
        final existingKeysFileId = await _readKeysFileId(channel.id);
        keysFileId = await GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
          fileName: 'keys.json',
          ciphertext: keysBytes,
          existingFileId: existingKeysFileId,
          accountPairing: pairing,
          channelId: cid(),
        );
        if (keysFileId != null) {
          await _writeKeysFileId(channel.id, keysFileId);
          keysFileUrl =
              await GoogleDriveChannelBackup.makePublicAndGetDownloadUrl(
                  keysFileId);
        }
      }

      // Human-readable channel settings file.
      final settingsBytes = Uint8List.fromList(utf8.encode(
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'channelId': channel.id,
          'name': channel.name,
          'username': channel.username,
          'description': channel.description,
          'avatarColor': channel.avatarColor,
          'avatarEmoji': channel.avatarEmoji,
          'adminId': channel.adminId,
          'moderatorIds': channel.moderatorIds,
          'commentsEnabled': channel.commentsEnabled,
          'driveBackupRev': rev,
          'updatedAt': DateTime.now().toIso8601String(),
        }),
      ));
      final existingSettingsId = await _readSettingsFileId(channel.id);
      final settingsId =
          await GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
        fileName: 'settings.json',
        ciphertext: settingsBytes,
        existingFileId: existingSettingsId,
        accountPairing: pairing,
        channelId: cid(),
        mimeType: 'application/json',
      );
      if (settingsId != null) await _writeSettingsFileId(channel.id, settingsId);

      // Channel avatar: upload if present, delete old file if it was cleared.
      if (channel.avatarImagePath != null) {
        final avatarBytes =
            await _readChannelVisualBytes(channel.avatarImagePath);
        if (avatarBytes != null && avatarBytes.isNotEmpty) {
          avatarFileId =
              await GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
            fileName: 'avatar.jpg',
            ciphertext: avatarBytes,
            existingFileId: channel.driveAvatarFileId,
            accountPairing: pairing,
            channelId: cid(),
            mimeType: 'image/jpeg',
          );
          if (avatarFileId != null) {
            avatarUrl =
                await GoogleDriveChannelBackup.makePublicAndGetDownloadUrl(
                    avatarFileId);
          }
        }
      } else if (channel.driveAvatarFileId != null) {
        await GoogleDriveChannelBackup.deleteFileById(channel.driveAvatarFileId,
            accountPairing: pairing);
        clearAvatar = true;
      }

      // Channel banner: same — upload new, delete old on removal.
      if (channel.bannerImagePath != null) {
        final bannerBytes =
            await _readChannelVisualBytes(channel.bannerImagePath);
        if (bannerBytes != null && bannerBytes.isNotEmpty) {
          bannerFileId =
              await GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
            fileName: 'banner.jpg',
            ciphertext: bannerBytes,
            existingFileId: channel.driveBannerFileId,
            accountPairing: pairing,
            channelId: cid(),
            mimeType: 'image/jpeg',
          );
          if (bannerFileId != null) {
            bannerUrl =
                await GoogleDriveChannelBackup.makePublicAndGetDownloadUrl(
                    bannerFileId);
          }
        }
      } else if (channel.driveBannerFileId != null) {
        await GoogleDriveChannelBackup.deleteFileById(channel.driveBannerFileId,
            accountPairing: pairing);
        clearBanner = true;
      }
    }

    final next = channel.copyWith(
      driveBackupRev: rev,
      driveFileId: fileId ?? channel.driveFileId,
      driveFileUrl: fileUrl ?? channel.driveFileUrl,
      driveKeysUrl: keysFileUrl ?? channel.driveKeysUrl,
      driveAvatarFileId:
          clearAvatar ? null : (avatarFileId ?? channel.driveAvatarFileId),
      driveAvatarUrl: clearAvatar ? null : (avatarUrl ?? channel.driveAvatarUrl),
      driveBannerFileId:
          clearBanner ? null : (bannerFileId ?? channel.driveBannerFileId),
      driveBannerUrl: clearBanner ? null : (bannerUrl ?? channel.driveBannerUrl),
      clearDriveAvatar: clearAvatar,
      clearDriveBanner: clearBanner,
    );
    await ChannelService.instance.updateChannel(next);
    await next.broadcastGossipMeta();
  }

  Future<void> _decryptAndImport(
      String channelId, int rev, Uint8List sealed) async {
    final applied = await _appliedRev(channelId);
    if (rev <= applied) return;
    final key = await _readSymKeyBytes(channelId);
    if (key == null) {
      _pendingDecryptByChannel[channelId] =
          _PendingDecrypt(rev: rev, sealed: sealed);
      return;
    }
    final plain = await CryptoService.instance.openSymmetric(sealed, key);
    if (plain == null) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (json['type'] != 'rlink_channel_backup') return;
    final jr = (json['rev'] as num?)?.toInt();
    if (jr == null || jr != rev) return;
    final channelIdJ = json['channelId'] as String?;
    if (channelIdJ != channelId) return;
    await ChannelService.instance.importChannelBackupSnapshot(channelId, json);
    await _setAppliedRev(channelId, rev);
    if (kDebugMode) {
      debugPrint('[RLINK][ChBak] Imported rev=$rev channel=$channelId');
    }
  }

  Future<void> onKeyPacket(GossipPacket packet) async {
    final cid = packet.payload['cid'] as String?;
    final emRaw = packet.payload['em'];
    if (cid == null || emRaw is! Map) return;
    try {
      final em = EncryptedMessage.fromJson(Map<String, dynamic>.from(emRaw));
      final plain = await CryptoService.instance.decryptMessage(em);
      if (plain == null) return;
      final bytes = base64Decode(plain);
      if (bytes.length != 32) return;
      await _writeSymKeyBytes(cid, Uint8List.fromList(bytes));
      final pend = _pendingDecryptByChannel.remove(cid);
      if (pend != null) {
        await _decryptAndImport(cid, pend.rev, pend.sealed);
      }
      // We just received the key — pull the Drive snapshot now in case the
      // background pull on channel open failed earlier for lack of the key.
      final ch = await ChannelService.instance.getChannel(cid);
      if (ch != null &&
          ch.driveFileUrl != null &&
          ch.driveFileUrl!.isNotEmpty) {
        unawaited(restoreFromDriveUrl(ch));
      }
    } catch (_) {}
  }

  Future<void> onMetaPacket(GossipPacket packet) async {
    final cid = packet.payload['cid'] as String?;
    final rev = (packet.payload['r'] as num?)?.toInt();
    final n = (packet.payload['n'] as num?)?.toInt();
    final from = packet.payload['from'] as String?;
    final mid = packet.payload['mid'] as String?;
    if (cid == null ||
        rev == null ||
        n == null ||
        from == null ||
        mid == null) {
      return;
    }
    if (n <= 0 || n > 200000) return;

    final my = CryptoService.instance.publicKeyHex;
    if (my.isEmpty) return;
    if (from == my) return;

    final ch = await ChannelService.instance.getChannel(cid);
    if (ch == null) return;
    if (ch.adminId != from) return;
    if (!ch.subscriberIds.contains(my) && ch.adminId != my) return;

    final applied = await _appliedRev(cid);
    if (rev <= applied) return;

    _assemblies[mid] = _BakAssembly(channelId: cid, rev: rev, total: n);
  }

  Future<void> onChunkPacket(GossipPacket packet) async {
    final mid = packet.payload['mid'] as String?;
    final idx = (packet.payload['i'] as num?)?.toInt();
    final d = packet.payload['d'] as String?;
    if (mid == null || idx == null || idx < 0 || d == null || d.isEmpty) {
      return;
    }

    final asm = _assemblies[mid];
    if (asm == null) return;
    if (idx >= asm.total) return;

    try {
      asm.parts[idx] = Uint8List.fromList(base64Decode(d));
    } catch (_) {
      return;
    }

    if (asm.parts.length != asm.total) return;
    for (var i = 0; i < asm.total; i++) {
      if (!asm.parts.containsKey(i)) return;
    }

    final ordered = BytesBuilder();
    for (var i = 0; i < asm.total; i++) {
      ordered.add(asm.parts[i]!);
    }
    _assemblies.remove(mid);

    await _decryptAndImport(asm.channelId, asm.rev, ordered.toBytes());
  }

  /// Скачивает зашифрованный снимок по публичной ссылке [channel.driveFileUrl] и импортирует историю.
  /// Возвращает true при успешном импорте. Не требует авторизации в Google — файл публичный.
  /// Если локального ключа нет — пытается получить его из файла ключей [channel.driveKeysUrl].
  /// [onStep] вызывается при смене этапа — для UI-индикаторов.
  Future<bool> restoreFromDriveUrl(Channel channel,
      {void Function(String)? onStep}) async {
    final url = channel.driveFileUrl;
    if (url == null || url.isEmpty) return false;

    onStep?.call('Проверка ключа расшифровки…');
    var key = await _readSymKeyBytes(channel.id);

    // If no local key, try fetching it from the public keys file.
    if (key == null) {
      key = await _fetchKeyFromKeysFile(channel, onStep: onStep);
      if (key == null) {
        debugPrint(
            '[RLINK][ChBak] restoreFromDriveUrl: no sym key for ${channel.id}');
        return false;
      }
    }

    try {
      onStep?.call('Скачивание из Google Drive…');
      Uint8List? sealed;

      // Owner / signed-in user: download via the authenticated Drive API. The
      // public drive.usercontent URL 403s in a browser logged into multiple
      // Google accounts, which is exactly the admin's case.
      if (channel.driveFileId != null &&
          channel.driveFileId!.isNotEmpty &&
          (GoogleDriveChannelBackup.hasRelayAccount ||
              GoogleDriveChannelBackup.hasValidManualCreds)) {
        final b = await GoogleDriveChannelBackup.downloadFileBytes(
          channel.driveFileId!,
          accountPairing:
              GoogleDriveChannelBackup.channelAccountPairing(channel.id),
        );
        if (b != null && b.isNotEmpty) sealed = b;
      }

      // Subscribers (no Drive access) — public direct-download URL.
      if (sealed == null) {
        debugPrint(
            '[RLINK][ChBak] restoreFromDriveUrl: fetching ${url.substring(0, url.length.clamp(0, 60))}…');
        final dio = Dio();
        final response = await dio.get<List<int>>(
          GoogleDriveChannelBackup.directDownloadUrl(url),
          options: Options(
              responseType: ResponseType.bytes,
              receiveTimeout: const Duration(seconds: 120)),
        );
        if (response.statusCode != 200 || response.data == null) {
          debugPrint(
              '[RLINK][ChBak] restoreFromDriveUrl: HTTP ${response.statusCode}');
          return false;
        }
        sealed = Uint8List.fromList(response.data!);
      }
      if (sealed.isEmpty) return false;
      onStep?.call('Расшифровка данных…');
      await _decryptAndImport(channel.id, channel.driveBackupRev, sealed);
      onStep?.call('Применение истории…');
      debugPrint(
          '[RLINK][ChBak] restoreFromDriveUrl: import done (${sealed.length} bytes)');
      return true;
    } catch (e, st) {
      debugPrint('[RLINK][ChBak] restoreFromDriveUrl failed: $e\n$st');
      return false;
    }
  }

  /// Скачивает публичный JSON-файл ключей, находит запись для текущего пользователя,
  /// расшифровывает симметричный ключ и сохраняет его локально.
  Future<Uint8List?> _fetchKeyFromKeysFile(Channel channel,
      {void Function(String)? onStep}) async {
    final keysUrl = channel.driveKeysUrl;
    if (keysUrl == null || keysUrl.isEmpty) return null;
    final myId = CryptoService.instance.publicKeyHex;
    if (myId.isEmpty) return null;
    try {
      onStep?.call('Получение ключа расшифровки…');
      debugPrint('[RLINK][ChBak] fetching keys file for ${channel.id}');
      String? body;

      // Owner / signed-in: authenticated download by file id (public URL 403s
      // in a multi-account browser).
      final keysFileId = await _readKeysFileId(channel.id);
      if (keysFileId != null &&
          keysFileId.isNotEmpty &&
          (GoogleDriveChannelBackup.hasRelayAccount ||
              GoogleDriveChannelBackup.hasValidManualCreds)) {
        final b = await GoogleDriveChannelBackup.downloadFileBytes(
          keysFileId,
          accountPairing:
              GoogleDriveChannelBackup.channelAccountPairing(channel.id),
        );
        if (b != null && b.isNotEmpty) body = utf8.decode(b);
      }

      if (body == null) {
        final dio = Dio();
        final response = await dio.get<String>(
          GoogleDriveChannelBackup.directDownloadUrl(keysUrl),
          options: Options(
              responseType: ResponseType.plain,
              receiveTimeout: const Duration(seconds: 30)),
        );
        if (response.statusCode != 200 || response.data == null) return null;
        body = response.data!;
      }
      final parsed = jsonDecode(body) as Map<String, dynamic>;
      final keys = parsed['keys'] as Map<String, dynamic>?;
      if (keys == null) return null;
      final myEntry = keys[myId];
      if (myEntry is! Map) return null;
      final em = EncryptedMessage.fromJson(Map<String, dynamic>.from(myEntry));
      final plain = await CryptoService.instance.decryptMessage(em);
      if (plain == null) return null;
      final bytes = base64Decode(plain);
      if (bytes.length != 32) return null;
      final key = Uint8List.fromList(bytes);
      await _writeSymKeyBytes(channel.id, key);
      debugPrint(
          '[RLINK][ChBak] key recovered from keys file for ${channel.id}');
      return key;
    } catch (e, st) {
      debugPrint('[RLINK][ChBak] _fetchKeyFromKeysFile failed: $e\n$st');
      return null;
    }
  }
}

class _PendingDecrypt {
  final int rev;
  final Uint8List sealed;

  _PendingDecrypt({required this.rev, required this.sealed});
}

class _BakAssembly {
  final String channelId;
  final int rev;
  final int total;
  final Map<int, Uint8List> parts = {};

  _BakAssembly({
    required this.channelId,
    required this.rev,
    required this.total,
  });
}
