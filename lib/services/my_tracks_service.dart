import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'google_drive_channel_backup.dart';
import 'music_catalog_service.dart';

/// A track the user uploaded to their own Google Drive.
///
/// Rlink stores nothing but the link: the file lives in the uploader's Drive,
/// and everyone else streams it from there — exactly the "one uploads,
/// everyone plays from the link" model, and the only way to have a specific
/// mainstream song, since no free catalog serves those in full.
class MyTrack {
  final String title;
  final String artist;
  final String url; // direct, CORS-safe Drive URL
  final String? artwork; // data: URL or a link

  const MyTrack({
    required this.title,
    required this.artist,
    required this.url,
    this.artwork,
  });

  Map<String, dynamic> toJson() => {
        't': title,
        'a': artist,
        'u': url,
        if (artwork != null) 'c': artwork,
      };

  static MyTrack fromJson(Map<String, dynamic> j) => MyTrack(
        title: '${j['t'] ?? ''}',
        artist: '${j['a'] ?? ''}',
        url: '${j['u'] ?? ''}',
        artwork: j['c'] as String?,
      );

  /// Same encoded ref the rest of the player speaks, so an uploaded track is
  /// indistinguishable from a catalog one — including lyrics lookup, which
  /// works off title/artist.
  CatalogTrack toCatalogTrack() => CatalogTrack(
        title: title,
        artist: artist,
        streamUrl: url,
        artworkUrl: artwork,
        source: 'Мои',
      );
}

class MyTracksService {
  MyTracksService._();
  static final instance = MyTracksService._();

  static const _key = 'my_drive_tracks_v1';

  final ValueNotifier<List<MyTrack>> tracks = ValueNotifier(const []);

  /// Progress of the current upload, 0..1; null when idle.
  final ValueNotifier<double?> uploadProgress = ValueNotifier(null);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      tracks.value = [
        for (final e in jsonDecode(raw) as List)
          MyTrack.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode([for (final t in tracks.value) t.toJson()]));
    } catch (_) {}
  }

  /// Upload audio bytes to the user's Drive and remember the resulting link.
  /// Returns the shareable ref (URL + metadata) or null with [lastError] set.
  String? lastError;

  Future<String?> upload({
    required String fileName,
    required Uint8List bytes,
    required String title,
    required String artist,
    String? artworkDataUrl,
    String mimeType = 'audio/mpeg',
  }) async {
    lastError = null;
    uploadProgress.value = 0;
    try {
      final link = await GoogleDriveChannelBackup.uploadBytesAndGetPublicLink(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
      );
      if (link == null) {
        lastError = GoogleDriveChannelBackup.lastSignInError ??
            'Не удалось загрузить на Google Drive';
        return null;
      }
      // webContentLink points at drive.google.com, which sends no CORS header
      // and 403s on the virus-scan interstitial — normalise it.
      final direct = GoogleDriveChannelBackup.directDownloadUrl(link);
      final track = MyTrack(
        title: title.trim().isEmpty ? fileName : title.trim(),
        artist: artist.trim(),
        url: direct,
        artwork: artworkDataUrl,
      );
      tracks.value = [track, ...tracks.value];
      await _persist();
      return encodeMusicRef(track.toCatalogTrack());
    } catch (e) {
      lastError = '$e';
      return null;
    } finally {
      uploadProgress.value = null;
    }
  }

  Future<void> remove(String url) async {
    tracks.value = tracks.value.where((t) => t.url != url).toList();
    await _persist();
  }
}

/// Is a Google account linked right now? Uploading needs one — the file goes
/// to the user's own Drive, not to us.
bool get isGoogleLinked =>
    GoogleDriveChannelBackup.hasRelayAccount ||
    GoogleDriveChannelBackup.hasValidManualCreds;

/// Email to show once linked (may be null even when linked).
String? get googleAccountEmail =>
    GoogleDriveChannelBackup.relayEmail ?? GoogleDriveChannelBackup.manualEmail;
