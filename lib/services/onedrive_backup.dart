import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'relay_oauth_link.dart';

/// OneDrive backend for encrypted group/channel history backups — same shape
/// as GoogleDriveChannelBackup's relay-linked subset (upload/download/make-
/// public), backed by Microsoft Graph instead of the Drive API. Files live
/// under the app's dedicated "approot" special folder (Files.ReadWrite.AppFolder
/// scope), matching Drive's drive.file minimal-privilege choice — this app
/// can only ever see files it created itself, not the user's whole OneDrive.
class OneDriveBackup {
  OneDriveBackup._();
  static final OneDriveBackup instance = OneDriveBackup._();

  final link = RelayOauthLink('onedrive');
  static const _graph = 'https://graph.microsoft.com/v1.0';

  Future<void> init() => link.restore();

  Future<String?> uploadOrUpdateEncryptedFile({
    required String fileName,
    required Uint8List ciphertext,
    String? existingFileId,
    String? accountPairing,
    String? channelId,
  }) async {
    final token = await link.accessToken(accountPairing);
    if (token == null) return null;
    final headers = {
      'authorization': 'Bearer $token',
      'content-type': 'application/octet-stream',
    };
    try {
      if (existingFileId != null && existingFileId.isNotEmpty) {
        final resp = await http.put(
          Uri.parse('$_graph/me/drive/items/$existingFileId/content'),
          headers: headers,
          body: ciphertext,
        );
        if (resp.statusCode == 200 || resp.statusCode == 201) {
          return existingFileId;
        }
        debugPrint(
            '[RLINK][OneDrive] update failed (${resp.statusCode}), creating new: ${resp.body}');
      }
      final folder = (channelId != null && channelId.isNotEmpty)
          ? '${Uri.encodeComponent(channelId)}/'
          : '';
      final path = 'rlink_backups/$folder${Uri.encodeComponent(fileName)}';
      final resp = await http.put(
        Uri.parse('$_graph/me/drive/special/approot:/$path:/content'),
        headers: headers,
        body: ciphertext,
      );
      if (resp.statusCode != 200 && resp.statusCode != 201) {
        debugPrint('[RLINK][OneDrive] create failed (${resp.statusCode}): ${resp.body}');
        return null;
      }
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      return m['id'] as String?;
    } catch (e, st) {
      debugPrint('[RLINK][OneDrive] upload failed: $e\n$st');
      return null;
    }
  }

  Future<Uint8List?> downloadFileBytes(String fileId,
      {String? accountPairing}) async {
    if (fileId.isEmpty) return null;
    final token = await link.accessToken(accountPairing);
    if (token == null) return null;
    try {
      final resp = await http.get(
        Uri.parse('$_graph/me/drive/items/$fileId/content'),
        headers: {'authorization': 'Bearer $token'},
      );
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (e) {
      debugPrint('[RLINK][OneDrive] downloadFileBytes failed: $e');
      return null;
    }
  }

  Future<void> deleteFileById(String? fileId, {String? accountPairing}) async {
    if (fileId == null || fileId.isEmpty) return;
    final token = await link.accessToken(accountPairing);
    if (token == null) return;
    try {
      await http.delete(
        Uri.parse('$_graph/me/drive/items/$fileId'),
        headers: {'authorization': 'Bearer $token'},
      );
    } catch (_) {}
  }

  /// Anonymous view link, converted to a direct-download URL via the
  /// documented `u!<base64>` shares trick (a plain webUrl opens OneDrive's
  /// web viewer instead of serving raw bytes).
  Future<String?> makePublicAndGetDownloadUrl(String fileId) async {
    final token = await link.accessToken();
    if (token == null) return null;
    try {
      final resp = await http.post(
        Uri.parse('$_graph/me/drive/items/$fileId/createLink'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({'type': 'view', 'scope': 'anonymous'}),
      );
      if (resp.statusCode != 200 && resp.statusCode != 201) {
        debugPrint('[RLINK][OneDrive] createLink failed (${resp.statusCode}): ${resp.body}');
        return null;
      }
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      final webUrl = (m['link'] as Map<String, dynamic>?)?['webUrl'] as String?;
      if (webUrl == null) return null;
      final encoded = base64Url
          .encode(utf8.encode(webUrl))
          .replaceAll('=', '')
          .replaceAll('/', '_')
          .replaceAll('+', '-');
      final shareId = 'u!$encoded';
      return 'https://api.onedrive.com/v1.0/shares/$shareId/root/content';
    } catch (e, st) {
      debugPrint('[RLINK][OneDrive] makePublic failed: $e\n$st');
      return null;
    }
  }
}
