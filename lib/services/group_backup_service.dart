import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/group.dart';
import 'channel_backup_service.dart';
import 'chat_storage_service.dart';
import 'crypto_service.dart';
import 'google_drive_channel_backup.dart';
import 'group_service.dart';
import 'relay_service.dart';

/// История группы в Google Drive — то же устройство, что у каналов
/// (channel_backup_service), но проще: ключи доставляются ТОЛЬКО через
/// публичный keys.json на Drive (по записи на участника), без gossip-пакетов.
///
/// Публикует создатель/модератор: снапшот истории (+медиа) шифруется
/// симметричным ключом группы и заливается в Rlink/group_<id>/ вместе с
/// keys.json (ключ, завёрнутый для каждого участника). Ссылки едут всем через
/// group_update; новые участники фоново подтягивают историю.
class GroupBackupService {
  GroupBackupService._();
  static final GroupBackupService instance = GroupBackupService._();

  static bool get _isMobile =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  String _symKey(String groupId) => 'grpbak_sym_$groupId';
  String _revKey(String groupId) => 'grpbak_rev_$groupId';
  String _fidKey(String groupId) => 'grpbak_fid_$groupId';
  String _kidKey(String groupId) => 'grpbak_kid_$groupId';

  Future<void> _writeSymKeyBytes(String groupId, Uint8List key32) async {
    final v = base64Encode(key32);
    if (_isMobile) {
      await _secure.write(key: _symKey(groupId), value: v);
    } else {
      final p = await SharedPreferences.getInstance();
      await p.setString(_symKey(groupId), v);
    }
  }

  Future<Uint8List?> _readSymKeyBytes(String groupId) async {
    String? v;
    if (_isMobile) {
      v = await _secure.read(key: _symKey(groupId));
    } else {
      final p = await SharedPreferences.getInstance();
      v = p.getString(_symKey(groupId));
    }
    if (v == null || v.isEmpty) return null;
    try {
      return base64Decode(v);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _getOrCreateSymmetricKey(String groupId) async {
    final existing = await _readSymKeyBytes(groupId);
    if (existing != null && existing.length == 32) return existing;
    final rnd = Random.secure();
    final key = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    await _writeSymKeyBytes(groupId, key);
    return key;
  }

  Future<int> _appliedRev(String groupId) async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_revKey(groupId)) ?? 0;
  }

  Future<void> _setAppliedRev(String groupId, int rev) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_revKey(groupId), rev);
  }

  Future<String?> _x25519For(String userId) async {
    final relayKey = RelayService.instance.getPeerX25519Key(userId);
    if (relayKey != null && relayKey.isNotEmpty) return relayKey;
    final contact = await ChatStorageService.instance.getContact(userId);
    final stored = contact?.x25519Key?.trim();
    return stored != null && stored.isNotEmpty ? stored : null;
  }

  /// Публикация истории группы в Drive. Возвращает обновлённую группу
  /// (с новым rev и публичными ссылками) или null при ошибке.
  Future<Group?> publishBackup(Group group) async {
    final myId = CryptoService.instance.publicKeyHex;
    if (!group.canModerate(myId)) return null;

    try {
      final rev = group.driveBackupRev + 1;
      final snap =
          await GroupService.instance.buildGroupBackupSnapshot(group.id);
      snap['rev'] = rev;
      final key = await _getOrCreateSymmetricKey(group.id);
      final sealed = await CryptoService.instance
          .sealSymmetric(Uint8List.fromList(utf8.encode(jsonEncode(snap))), key);

      // Ключ, завёрнутый для каждого участника (и для себя — восстановление
      // на новом устройстве).
      final wrappedKeys = <String, dynamic>{};
      for (final uid in {...group.memberIds}) {
        String? x;
        if (uid == myId) {
          final own = CryptoService.instance.x25519PublicKeyBase64;
          x = own.isNotEmpty ? own : null;
        } else {
          x = await _x25519For(uid);
        }
        if (x == null) continue;
        final em = await CryptoService.instance.encryptMessage(
          plaintext: base64Encode(key),
          recipientX25519KeyBase64: x,
        );
        wrappedKeys[uid] = em.toJson();
      }

      final prefs = await SharedPreferences.getInstance();
      // Для групп по-канальный аккаунт обычно не задан — берём активный.
      final pairing =
          GoogleDriveChannelBackup.channelAccountPairing(group.id) ??
              GoogleDriveChannelBackup.activeRelayPairing;
      final folder = 'group_${group.id}';

      final fileId = await GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
        fileName: 'backup.bin',
        ciphertext: sealed,
        existingFileId: prefs.getString(_fidKey(group.id)),
        accountPairing: pairing,
        channelId: folder,
      );
      if (fileId == null) return null;
      await prefs.setString(_fidKey(group.id), fileId);
      final fileUrl =
          await GoogleDriveChannelBackup.makePublicAndGetDownloadUrl(fileId);
      if (fileUrl == null) return null;

      String? keysUrl;
      if (wrappedKeys.isNotEmpty) {
        final keysBytes = Uint8List.fromList(utf8.encode(jsonEncode({
          'v': 1,
          'groupId': group.id,
          'rev': rev,
          'keys': wrappedKeys,
        })));
        final keysFileId =
            await GoogleDriveChannelBackup.uploadOrUpdateEncryptedFile(
          fileName: 'keys.json',
          ciphertext: keysBytes,
          existingFileId: prefs.getString(_kidKey(group.id)),
          accountPairing: pairing,
          channelId: folder,
        );
        if (keysFileId != null) {
          await prefs.setString(_kidKey(group.id), keysFileId);
          keysUrl = await GoogleDriveChannelBackup.makePublicAndGetDownloadUrl(
              keysFileId);
        }
      }

      final updated = group.copyWith(
        driveBackupEnabled: true,
        driveBackupRev: rev,
        driveHistoryUrl: fileUrl,
        driveKeysUrl: keysUrl ?? group.driveKeysUrl,
      );
      await GroupService.instance.updateGroup(updated);
      await _setAppliedRev(group.id, rev); // publisher already has everything
      GroupService.instance.broadcastGroupMeta(updated);
      debugPrint('[RLINK][GrpBak] published rev=$rev group=${group.id}');
      return updated;
    } catch (e, st) {
      debugPrint('[RLINK][GrpBak] publish failed: $e\n$st');
      return null;
    }
  }

  /// Достаёт мой симметричный ключ из публичного keys.json.
  Future<Uint8List?> _fetchKeyFromKeysFile(Group group) async {
    final url = group.driveKeysUrl;
    final myId = CryptoService.instance.publicKeyHex;
    if (url == null || url.isEmpty || myId.isEmpty) return null;
    try {
      final dio = Dio();
      final resp = await dio.get<List<int>>(
        ChannelBackupService.channelDownloadUrl(url),
        options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 60)),
      );
      if (resp.statusCode != 200 || resp.data == null) return null;
      final decoded = jsonDecode(utf8.decode(resp.data!));
      if (decoded is! Map) return null;
      final keys = decoded['keys'];
      if (keys is! Map) return null;
      final myEntry = keys[myId];
      if (myEntry is! Map) return null;
      final em = EncryptedMessage.fromJson(Map<String, dynamic>.from(myEntry));
      final plain = await CryptoService.instance.decryptMessage(em);
      if (plain == null || plain.isEmpty) return null;
      final key = base64Decode(plain);
      if (key.length != 32) return null;
      await _writeSymKeyBytes(group.id, key);
      return key;
    } catch (e) {
      debugPrint('[RLINK][GrpBak] keys fetch failed: $e');
      return null;
    }
  }

  /// Скачивает и вливает историю группы из Drive. true = импорт прошёл.
  Future<bool> restoreFromDrive(Group group) async {
    final url = group.driveHistoryUrl;
    if (url == null || url.isEmpty) return false;
    try {
      final key =
          await _readSymKeyBytes(group.id) ?? await _fetchKeyFromKeysFile(group);
      if (key == null) {
        debugPrint('[RLINK][GrpBak] no key for group ${group.id}');
        return false;
      }
      final dio = Dio();
      final resp = await dio.get<List<int>>(
        ChannelBackupService.channelDownloadUrl(url),
        options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 120)),
      );
      if (resp.statusCode != 200 || resp.data == null) return false;
      final sealed = Uint8List.fromList(resp.data!);
      final plain = await CryptoService.instance.openSymmetric(sealed, key);
      if (plain == null || plain.isEmpty) return false;
      final json = jsonDecode(utf8.decode(plain));
      if (json is! Map<String, dynamic>) return false;
      if (json['type'] != 'rlink_group_backup' ||
          json['groupId'] != group.id) {
        return false;
      }
      final added =
          await GroupService.instance.importGroupBackupSnapshot(group.id, json);
      final rev = (json['rev'] as num?)?.toInt() ?? group.driveBackupRev;
      await _setAppliedRev(group.id, rev);
      debugPrint('[RLINK][GrpBak] restored rev=$rev (+$added msgs)');
      return true;
    } catch (e, st) {
      debugPrint('[RLINK][GrpBak] restore failed: $e\n$st');
      return false;
    }
  }

  /// Фоновая подтяжка при открытии группы / получении group_update:
  /// тянет только если опубликованный rev новее применённого.
  Future<void> maybeBackgroundPull(Group group) async {
    if (group.driveHistoryUrl == null || group.driveHistoryUrl!.isEmpty) return;
    final applied = await _appliedRev(group.id);
    if (group.driveBackupRev <= applied) return;
    await restoreFromDrive(group);
  }
}
