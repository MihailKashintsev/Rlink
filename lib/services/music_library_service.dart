import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'music_catalog_service.dart';

/// Local "liked" list. Tracks are stored as the same encoded ref the profile
/// uses (url + title/artist/artwork in the fragment), so nothing but a string
/// is ever persisted — no audio on our side.
class MusicLibraryService {
  MusicLibraryService._();
  static final instance = MusicLibraryService._();

  static const _key = 'music_liked_refs_v1';

  /// Encoded refs, newest first.
  final ValueNotifier<List<String>> liked = ValueNotifier(const []);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      liked.value = (jsonDecode(raw) as List).cast<String>();
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(liked.value));
    } catch (_) {}
  }

  bool isLiked(String ref) {
    final url = parseMusicRef(ref).url;
    return liked.value.any((r) => parseMusicRef(r).url == url);
  }

  Future<void> toggle(String ref) async {
    final url = parseMusicRef(ref).url;
    final next = liked.value.where((r) => parseMusicRef(r).url != url).toList();
    if (next.length == liked.value.length) next.insert(0, ref); // wasn't there
    liked.value = next;
    await _persist();
  }
}
