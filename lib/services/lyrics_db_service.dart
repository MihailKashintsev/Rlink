import 'dart:convert';

import 'package:http/http.dart' as http;

/// One synced line from an LRC file.
class SyncedLine {
  final int startMs;
  final String text;
  const SyncedLine(this.startMs, this.text);
}

/// LRCLIB — open, free, no API key: real time-synced lyrics for known songs.
///
/// This is what Apple Music actually does: licensed, pre-timed lyrics. Speech
/// recognition on sung audio can't compete with it and never will, so we ask
/// here first and only fall back to Whisper when a track isn't in the database.
class LyricsDbService {
  LyricsDbService._();
  static final instance = LyricsDbService._();

  static const _base = 'https://lrclib.net';

  /// Exact-ish lookup, then a fuzzy search. Returns null when nothing matches.
  Future<List<SyncedLine>?> lookup({
    required String title,
    required String artist,
  }) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final direct = await _get(
      '$_base/api/get?track_name=${Uri.encodeQueryComponent(t)}'
      '&artist_name=${Uri.encodeQueryComponent(artist.trim())}',
    );
    final fromDirect = _linesFrom(direct);
    if (fromDirect != null) return fromDirect;

    // Catalog titles are messy ("Artist - Track (Remix) [FREE DL]"), so try a
    // cleaned-up free-text search too.
    final cleaned = _clean(t);
    final search = await _get(
      '$_base/api/search?q=${Uri.encodeQueryComponent(
        artist.trim().isEmpty ? cleaned : '$cleaned ${artist.trim()}',
      )}',
    );
    if (search is List) {
      for (final item in search) {
        final lines = _linesFrom(item);
        if (lines != null) return lines;
      }
    }
    return null;
  }

  String _clean(String raw) {
    var s = raw;
    s = s.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    s = s.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    return s.trim();
  }

  Future<dynamic> _get(String url) async {
    try {
      final r = await http
          .get(Uri.parse(url), headers: const {'User-Agent': 'Rlink'})
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body);
    } catch (_) {
      return null;
    }
  }

  List<SyncedLine>? _linesFrom(dynamic json) {
    if (json is! Map) return null;
    final synced = json['syncedLyrics'];
    if (synced is! String || synced.trim().isEmpty) return null;
    final lines = parseLrc(synced);
    return lines.isEmpty ? null : lines;
  }

  /// `[mm:ss.xx] text` → timed lines. Several timestamps may share one line.
  static List<SyncedLine> parseLrc(String lrc) {
    final re = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
    final out = <SyncedLine>[];
    for (final raw in lrc.split('\n')) {
      final matches = re.allMatches(raw).toList();
      if (matches.isEmpty) continue;
      final text = raw.substring(matches.last.end).trim();
      if (text.isEmpty) continue; // instrumental gap marker
      for (final m in matches) {
        final min = int.tryParse(m.group(1) ?? '0') ?? 0;
        final sec = int.tryParse(m.group(2) ?? '0') ?? 0;
        final fracRaw = m.group(3) ?? '0';
        final frac = int.tryParse(fracRaw) ?? 0;
        final ms = fracRaw.length == 3 ? frac : frac * 10;
        out.add(SyncedLine(min * 60000 + sec * 1000 + ms, text));
      }
    }
    out.sort((a, b) => a.startMs.compareTo(b.startMs));
    return out;
  }
}
