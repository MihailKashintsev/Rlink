import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// A track we can reference by URL — nothing is stored on our servers and
/// listeners stream it instead of downloading a file.
class CatalogTrack {
  final String title;
  final String artist;
  final String streamUrl;
  final String? artworkUrl;
  final Duration duration;

  const CatalogTrack({
    required this.title,
    required this.artist,
    required this.streamUrl,
    this.artworkUrl,
    this.duration = Duration.zero,
  });
}

/// Audius: open catalog, public API, no key and no registration.
///
/// Jamendo is the other free source we picked, but its API requires a
/// client_id you have to register for — wire it in [searchJamendo] once that
/// id exists.
class MusicCatalogService {
  MusicCatalogService._();
  static final instance = MusicCatalogService._();

  static const _appName = 'Rlink';
  String? _host; // discovery node, resolved once

  Future<String?> _discoverHost() async {
    if (_host != null) return _host;
    try {
      final r = await http
          .get(Uri.parse('https://api.audius.co'))
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final data = (jsonDecode(r.body) as Map<String, dynamic>)['data'];
      if (data is List && data.isNotEmpty) {
        _host = data.first as String;
      }
    } catch (_) {}
    return _host;
  }

  /// Free-text search over the Audius catalog.
  Future<List<CatalogTrack>> search(String query) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final host = await _discoverHost();
    if (host == null) return const [];
    try {
      final uri = Uri.parse(
          '$host/v1/tracks/search?query=${Uri.encodeQueryComponent(q)}'
          '&app_name=$_appName');
      final r = await http.get(uri).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const [];
      return _parseTracks(host, jsonDecode(r.body));
    } catch (_) {
      return const [];
    }
  }

  static const _seeds = <String>[
    'lofi', 'chill', 'house', 'jazz', 'ambient', 'funk', 'techno', 'hip hop',
    'guitar', 'piano', 'drum', 'soul', 'synth', 'dance', 'rock', 'beats',
  ];
  final _rnd = math.Random();

  /// Endless-ish random stream ("Линия"): trending first, then random search
  /// seeds. Deliberately not a real recommender — it just keeps producing
  /// tracks nobody picked on purpose.
  Future<List<CatalogTrack>> randomStream({int page = 0}) async {
    final host = await _discoverHost();
    if (host == null) return const [];
    try {
      if (page == 0) {
        final uri = Uri.parse(
            '$host/v1/tracks/trending?limit=25&app_name=$_appName');
        final r = await http.get(uri).timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final tracks = _parseTracks(host, jsonDecode(r.body));
          if (tracks.isNotEmpty) {
            tracks.shuffle(_rnd);
            return tracks;
          }
        }
      }
      final seed = _seeds[_rnd.nextInt(_seeds.length)];
      final tracks = await search(seed);
      tracks.shuffle(_rnd);
      return tracks;
    } catch (_) {
      return const [];
    }
  }

  List<CatalogTrack> _parseTracks(String host, dynamic body) {
    final data = body is Map<String, dynamic> ? body['data'] : null;
    if (data is! List) return <CatalogTrack>[];
    final out = <CatalogTrack>[];
    for (final raw in data) {
      if (raw is! Map<String, dynamic>) continue;
      final id = raw['id'];
      if (id == null) continue;
      final user = raw['user'];
      final art = raw['artwork'];
      out.add(CatalogTrack(
        title: (raw['title'] as String?)?.trim().isNotEmpty == true
            ? raw['title'] as String
            : 'Без названия',
        artist:
            user is Map<String, dynamic> ? (user['name'] as String? ?? '') : '',
        streamUrl: '$host/v1/tracks/$id/stream?app_name=$_appName',
        artworkUrl:
            art is Map<String, dynamic> ? art['150x150'] as String? : null,
        duration: Duration(seconds: (raw['duration'] as num?)?.toInt() ?? 0),
      ));
    }
    return out;
  }

  /// A plain link someone shared — accepted as-is so "one uploads, everyone
  /// streams from the link" works with any host.
  bool looksPlayableUrl(String value) {
    final v = value.trim();
    if (!(v.startsWith('http://') || v.startsWith('https://'))) return false;
    return Uri.tryParse(v) != null;
  }
}

/// Title/artist/artwork travel in the URL fragment so profile music stays a
/// single string — no profile-schema or wire-protocol change. Servers never
/// receive a fragment, so playback is unaffected.
class MusicRef {
  final String url; // playable, fragment stripped
  final String title;
  final String artist;
  final String? artwork;
  const MusicRef({
    required this.url,
    required this.title,
    this.artist = '',
    this.artwork,
  });

  bool get isRemote => url.startsWith('http://') || url.startsWith('https://');
}

String encodeMusicRef(CatalogTrack t) {
  final q = <String>[
    't=${Uri.encodeComponent(t.title)}',
    if (t.artist.isNotEmpty) 'a=${Uri.encodeComponent(t.artist)}',
    if (t.artworkUrl != null) 'art=${Uri.encodeComponent(t.artworkUrl!)}',
  ].join('&');
  return '${t.streamUrl}#$q';
}

MusicRef parseMusicRef(String raw) {
  final hash = raw.indexOf('#');
  final url = hash >= 0 ? raw.substring(0, hash) : raw;
  final frag = hash >= 0 ? raw.substring(hash + 1) : '';
  String title = '';
  String artist = '';
  String? art;
  if (frag.isNotEmpty && frag.contains('=')) {
    for (final part in frag.split('&')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final k = part.substring(0, i);
      final v = Uri.decodeComponent(part.substring(i + 1));
      if (k == 't') title = v;
      if (k == 'a') artist = v;
      if (k == 'art') art = v;
    }
  }
  if (title.isEmpty) title = musicDisplayLabel(url);
  return MusicRef(url: url, title: title, artist: artist, artwork: art);
}

/// Human label for whatever sits in `profileMusicPath` — a file name for
/// stored files, something readable for links (a raw stream URL renders as
/// "stream?app_name=Rlink" otherwise).
String musicDisplayLabel(String path) {
  final clean = path.split('#').first;
  if (clean.startsWith('http://') || clean.startsWith('https://')) {
    final host = Uri.tryParse(clean)?.host ?? '';
    if (host.contains('audius')) return 'Трек из Audius';
    if (host.contains('jamendo')) return 'Трек из Jamendo';
    return host.isEmpty ? 'Трек по ссылке' : host;
  }
  final base = clean.split('/').last.split('\\').last;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

/// url → full ref (title/artist/artwork). The playback session only carries a
/// path and a title, so the full-screen player looks metadata up here.
/// ponytail: in-memory only — a track you didn't open in this session simply
/// falls back to the plain title.
final Map<String, String> _refByUrl = {};

void rememberTrackRef(String ref) {
  final url = parseMusicRef(ref).url;
  if (url.isNotEmpty) _refByUrl[url] = ref;
}

String? trackRefFor(String url) => _refByUrl[url];
