import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'relay_service.dart';

String? _driveFileId(String url) {
  for (final re in [
    RegExp(r'[?&]id=([A-Za-z0-9_-]+)'),
    RegExp(r'/file/d/([A-Za-z0-9_-]+)'),
    RegExp(r'/d/([A-Za-z0-9_-]+)'),
  ]) {
    final m = re.firstMatch(url);
    if (m != null) return m.group(1);
  }
  return null;
}

/// Rewrite a Google Drive URL to the relay audio proxy so the browser can
/// actually stream it (Drive's download endpoint redirects and omits CORS, so
/// an <audio> element sticks at 0s). Non-Drive URLs pass through unchanged.
String drivePlayableUrl(String url) {
  if (url.contains('/drive-audio?')) return url; // already proxied
  if (!url.contains('drive.google.com') &&
      !url.contains('drive.usercontent.google.com')) {
    return url;
  }
  final id = _driveFileId(url);
  if (id == null || id.isEmpty) return url;
  final base = RelayService.instance.serverUrl ?? RelayService.defaultServerUrl;
  final httpBase = base.startsWith('wss://')
      ? base.replaceFirst('wss://', 'https://')
      : base.startsWith('ws://')
          ? base.replaceFirst('ws://', 'http://')
          : base;
  return '$httpBase/drive-audio?id=$id';
}

/// A track we can reference by URL — nothing is stored on our servers and
/// listeners stream it instead of downloading a file.
class CatalogTrack {
  final String title;
  final String artist;
  final String streamUrl;
  final String? artworkUrl;
  final Duration duration;

  /// Which catalog this came from — shown so a 30s preview never looks like
  /// a broken full track.
  final String source;

  /// True for iTunes: a legal 30-second sample, not the whole song.
  final bool isPreview;

  const CatalogTrack({
    required this.title,
    required this.artist,
    required this.streamUrl,
    this.artworkUrl,
    this.duration = Duration.zero,
    this.source = '',
    this.isPreview = false,
  });
}

/// Free catalogs that answer from Russia without a VPN.
///
/// Internet Archive used to be here but is RKN-blocked, so its results were
/// dead links for most users — dropped. Jamendo needs a free client_id from
/// devportal.jamendo.com; until [_jamendoClientId] is filled in it just sits
/// out and the other sources cover for it.
class MusicCatalogService {
  MusicCatalogService._();
  static final instance = MusicCatalogService._();

  static const _appName = 'Rlink';

  /// Jamendo's public application id. It is designed to be sent with every API
  /// request from the client, so shipping it is expected — unlike the account's
  /// client *secret*, which is only for OAuth login and must never reach a
  /// client build.
  static const _jamendoClientId = 'fa443567';
  String? _host; // discovery node, resolved once

  /// Deezer's search API sends no CORS header, so the browser can't call it
  /// directly — route it through the relay, which returns the same JSON with
  /// `access-control-allow-origin`. Native talks to Deezer directly.
  Uri _catalogUri(Uri direct) {
    if (!kIsWeb) return direct;
    final base =
        RelayService.instance.serverUrl ?? RelayService.defaultServerUrl;
    final httpBase = base.startsWith('wss://')
        ? base.replaceFirst('wss://', 'https://')
        : base.startsWith('ws://')
            ? base.replaceFirst('ws://', 'http://')
            : base;
    return Uri.parse(
        '$httpBase/music-search?u=${Uri.encodeQueryComponent(direct.toString())}');
  }

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

  /// Search every reachable catalog at once and merge.
  ///
  /// Measured from Russia without a VPN: Audius answers but ~25% of its
  /// tracks redirect to community content nodes that are unreachable, so it
  /// can't be the only source. Jamendo adds full CC tracks; Deezer and iTunes
  /// cover mainstream music including Russian artists (30-second previews
  /// only, labelled as such).
  Future<List<CatalogTrack>> search(String query) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    final results = await Future.wait([
      _searchAudius(q),
      _searchJamendo(q),
      _searchDeezer(q),
      _searchItunes(q),
    ]);
    // Full tracks first, previews last — a 30s sample is a fallback, not a
    // headline result.
    final full = <CatalogTrack>[];
    final preview = <CatalogTrack>[];
    for (final list in results) {
      for (final t in list) {
        (t.isPreview ? preview : full).add(t);
      }
    }
    return [...full, ...preview];
  }

  Future<List<CatalogTrack>> _searchAudius(String q) async {
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

  /// Jamendo — full-length CC-licensed tracks. Needs a free client_id.
  Future<List<CatalogTrack>> _searchJamendo(String q) async {
    if (_jamendoClientId.isEmpty) return const [];
    try {
      // Not proxied: Jamendo answers with `access-control-allow-origin: *`, and
      // its audio host sends CORS + range too, so web talks to it directly and
      // doesn't depend on the relay being up.
      final uri = Uri.parse(
        'https://api.jamendo.com/v3.0/tracks/?client_id=$_jamendoClientId'
        '&format=json&limit=12&search=${Uri.encodeQueryComponent(q)}'
        '&audioformat=mp32',
      );
      final r = await http.get(uri).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const [];
      final list = (jsonDecode(r.body) as Map)['results'] as List?;
      if (list == null) return const [];
      return [
        for (final e in list)
          if (e is Map && e['audio'] is String && '${e['audio']}'.isNotEmpty)
            CatalogTrack(
              title: '${e['name'] ?? ''}',
              artist: '${e['artist_name'] ?? ''}',
              streamUrl: '${e['audio']}',
              artworkUrl: e['image'] as String?,
              duration: Duration(seconds: (e['duration'] as num?)?.toInt() ?? 0),
              source: 'Jamendo',
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Deezer — mainstream catalogue with good Russian coverage, no key.
  /// 30-second previews only; the preview CDN serves CORS + range, so these
  /// play in the browser directly even though the search API doesn't.
  Future<List<CatalogTrack>> _searchDeezer(String q) async {
    try {
      final direct = Uri.parse(
          'https://api.deezer.com/search?q=${Uri.encodeQueryComponent(q)}&limit=12');
      final r =
          await http.get(_catalogUri(direct)).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const [];
      final list = (jsonDecode(r.body) as Map)['data'] as List?;
      if (list == null) return const [];
      return [
        for (final e in list)
          if (e is Map && e['preview'] is String && '${e['preview']}'.isNotEmpty)
            CatalogTrack(
              title: '${e['title'] ?? ''}',
              artist: e['artist'] is Map ? '${e['artist']['name'] ?? ''}' : '',
              streamUrl: '${e['preview']}',
              artworkUrl:
                  e['album'] is Map ? e['album']['cover_medium'] as String? : null,
              duration: const Duration(seconds: 30),
              source: 'Deezer',
              isPreview: true,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// iTunes Search — mainstream catalogue (Russian included), no key.
  /// Only 30-second previews: Apple does not serve full tracks this way.
  Future<List<CatalogTrack>> _searchItunes(String q) async {
    try {
      final uri = Uri.parse(
        'https://itunes.apple.com/search?term=${Uri.encodeQueryComponent(q)}'
        '&media=music&limit=12',
      );
      final r = await http.get(uri).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return const [];
      final list = (jsonDecode(r.body) as Map)['results'] as List?;
      if (list == null) return const [];
      return [
        for (final e in list)
          if (e is Map && e['previewUrl'] is String)
            CatalogTrack(
              title: '${e['trackName'] ?? ''}',
              artist: '${e['artistName'] ?? ''}',
              streamUrl: '${e['previewUrl']}',
              artworkUrl: e['artworkUrl100'] as String?,
              duration: const Duration(seconds: 30),
              source: 'iTunes',
              isPreview: true,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static const _seeds = <String>[
    'lofi',
    'chill',
    'house',
    'jazz',
    'ambient',
    'funk',
    'techno',
    'hip hop',
    'guitar',
    'piano',
    'drum',
    'soul',
    'synth',
    'dance',
    'rock',
    'beats',
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
        final uri =
            Uri.parse('$host/v1/tracks/trending?limit=25&app_name=$_appName');
        final r = await http.get(uri).timeout(const Duration(seconds: 12));
        if (r.statusCode == 200) {
          final tracks = _parseTracks(host, jsonDecode(r.body));
          if (tracks.isNotEmpty) {
            tracks.shuffle(_rnd);
            return tracks;
          }
        }
      }
      // Линия is for listening, not sampling — no 30s previews here.
      final seed = _seeds[_rnd.nextInt(_seeds.length)];
      final lists =
          await Future.wait([_searchAudius(seed), _searchJamendo(seed)]);
      final tracks = [for (final l in lists) ...l];
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
        source: 'Audius',
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
  final String source;
  final bool isPreview;
  const MusicRef({
    required this.url,
    required this.title,
    this.artist = '',
    this.artwork,
    this.source = '',
    this.isPreview = false,
  });

  bool get isRemote => url.startsWith('http://') || url.startsWith('https://');
}

String encodeMusicRef(CatalogTrack t) {
  final q = <String>[
    't=${Uri.encodeComponent(t.title)}',
    if (t.artist.isNotEmpty) 'a=${Uri.encodeComponent(t.artist)}',
    if (t.artworkUrl != null) 'art=${Uri.encodeComponent(t.artworkUrl!)}',
    if (t.source.isNotEmpty) 's=${Uri.encodeComponent(t.source)}',
    if (t.isPreview) 'p=1',
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
  String source = '';
  var preview = false;
  if (frag.isNotEmpty && frag.contains('=')) {
    for (final part in frag.split('&')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final k = part.substring(0, i);
      final v = Uri.decodeComponent(part.substring(i + 1));
      if (k == 't') title = v;
      if (k == 'a') artist = v;
      if (k == 'art') art = v;
      if (k == 's') source = v;
      if (k == 'p') preview = v == '1';
    }
  }
  if (title.isEmpty) title = musicDisplayLabel(url);
  return MusicRef(
    url: url,
    title: title,
    artist: artist,
    artwork: art,
    source: source,
    isPreview: preview,
  );
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

Future<String?> resolvePlayableUrl(String url) async => url;

/// Can this URL actually be streamed from here?
///
/// Audius pins each track to specific community content nodes, and some are
/// unreachable from Russia — measured 6/8 playable, and a retry never helps
/// because the node is fixed per track. So dead tracks are filtered out of
/// the list instead of being offered and failing.
Future<bool> isStreamReachable(String url) async {
  if (!url.startsWith('http')) return true;
  try {
    final req = http.Request('GET', Uri.parse(url))
      ..headers['Range'] = 'bytes=0-1';
    final r = await http.Client().send(req).timeout(const Duration(seconds: 6));
    await r.stream.drain();
    return r.statusCode >= 200 && r.statusCode < 400;
  } catch (_) {
    return false;
  }
}

/// Keep only what will play.
///
/// Web is skipped on purpose. A `fetch()` probe there answers a different
/// question than "will this play": media elements load cross-origin audio
/// without CORS, so a track whose probe fails can still play fine — measured
/// on Audius trending, 2 of 8 playable tracks were discarded this way, while
/// the probing itself added ~12s before the feed appeared. VoiceService's
/// watchdog already skips a track that turns out to be dead, so the browser
/// shows the feed at once and lets that handle the rare miss.
Future<List<CatalogTrack>> filterReachable(List<CatalogTrack> tracks) async {
  if (kIsWeb) return tracks;
  // Native has no CORS, so the probe is meaningful — but it must not be paid
  // for serially. Two bytes per track, all at once.
  final ok =
      await Future.wait(tracks.map((t) => isStreamReachable(t.streamUrl)));
  return [
    for (var i = 0; i < tracks.length; i++)
      if (ok[i]) tracks[i],
  ];
}
