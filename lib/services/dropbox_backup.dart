import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'relay_oauth_link.dart';

/// Dropbox backend for encrypted group/channel history backups — same shape
/// as GoogleDriveChannelBackup's relay-linked subset. Dropbox has no
/// server-assigned "file id" the way Drive/OneDrive do for a brand-new
/// upload target — a file is addressed by its own /path — so [fileId] here
/// is that path (still opaque to callers, same contract as the id-based
/// providers: store what you're given, pass it back on update).
class DropboxBackup {
  DropboxBackup._();
  static final DropboxBackup instance = DropboxBackup._();

  final link = RelayOauthLink('dropbox');
  static const _content = 'https://content.dropboxapi.com/2';
  static const _api = 'https://api.dropboxapi.com/2';

  Future<void> init() => link.restore();

  String _pathFor(String fileName, String? channelId) {
    final folder = (channelId != null && channelId.isNotEmpty) ? '/$channelId' : '';
    return '/rlink_backups$folder/$fileName';
  }

  Future<String?> uploadOrUpdateEncryptedFile({
    required String fileName,
    required Uint8List ciphertext,
    String? existingFileId, // a Dropbox path, see class doc
    String? accountPairing,
    String? channelId,
  }) async {
    final token = await link.accessToken(accountPairing);
    if (token == null) return null;
    final path = (existingFileId != null && existingFileId.isNotEmpty)
        ? existingFileId
        : _pathFor(fileName, channelId);
    try {
      final resp = await http.post(
        Uri.parse('$_content/files/upload'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/octet-stream',
          'dropbox-api-arg': jsonEncode({'path': path, 'mode': 'overwrite'}),
        },
        body: ciphertext,
      );
      if (resp.statusCode != 200) {
        debugPrint('[RLINK][Dropbox] upload failed (${resp.statusCode}): ${resp.body}');
        return null;
      }
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      return (m['path_lower'] as String?) ?? path;
    } catch (e, st) {
      debugPrint('[RLINK][Dropbox] upload failed: $e\n$st');
      return null;
    }
  }

  Future<Uint8List?> downloadFileBytes(String path,
      {String? accountPairing}) async {
    if (path.isEmpty) return null;
    final token = await link.accessToken(accountPairing);
    if (token == null) return null;
    try {
      final resp = await http.post(
        Uri.parse('$_content/files/download'),
        headers: {
          'authorization': 'Bearer $token',
          'dropbox-api-arg': jsonEncode({'path': path}),
        },
      );
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (e) {
      debugPrint('[RLINK][Dropbox] downloadFileBytes failed: $e');
      return null;
    }
  }

  Future<void> deleteFileById(String? path, {String? accountPairing}) async {
    if (path == null || path.isEmpty) return;
    final token = await link.accessToken(accountPairing);
    if (token == null) return;
    try {
      await http.post(
        Uri.parse('$_api/files/delete_v2'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({'path': path}),
      );
    } catch (_) {}
  }

  /// A shared link, converted to a direct-download URL (`?dl=1` serves raw
  /// bytes instead of Dropbox's preview page). Re-shares an already-shared
  /// path by reusing the existing link instead of erroring.
  Future<String?> makePublicAndGetDownloadUrl(String path) async {
    final token = await link.accessToken();
    if (token == null) return null;
    try {
      var resp = await http.post(
        Uri.parse('$_api/sharing/create_shared_link_with_settings'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({'path': path}),
      );
      String? url;
      if (resp.statusCode == 200) {
        url = (jsonDecode(resp.body) as Map<String, dynamic>)['url'] as String?;
      } else if (resp.body.contains('shared_link_already_exists')) {
        final listResp = await http.post(
          Uri.parse('$_api/sharing/list_shared_links'),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          },
          body: jsonEncode({'path': path, 'direct_only': true}),
        );
        if (listResp.statusCode == 200) {
          final links = (jsonDecode(listResp.body)
              as Map<String, dynamic>)['links'] as List<dynamic>?;
          if (links != null && links.isNotEmpty) {
            url = (links.first as Map<String, dynamic>)['url'] as String?;
          }
        }
      } else {
        debugPrint(
            '[RLINK][Dropbox] create_shared_link failed (${resp.statusCode}): ${resp.body}');
      }
      if (url == null) return null;
      final direct = url.contains('?')
          ? url.replaceFirst(RegExp(r'dl=0'), 'dl=1')
          : '$url?dl=1';
      return direct;
    } catch (e, st) {
      debugPrint('[RLINK][Dropbox] makePublic failed: $e\n$st');
      return null;
    }
  }
}
