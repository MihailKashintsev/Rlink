import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;

// ── Cloud storage OAuth backend (durable linking for Google Drive, OneDrive,
// Dropbox) ────────────────────────────────────────────────────────────────
// Auth-code + offline (refresh-token) flow, one instance per provider. The
// relay holds each provider's client secret and every user's refresh token;
// clients only ever receive short-lived access tokens via /token.
//
//   GET  oauth/<provider>/start?p=<pairing>   -> 302 to the provider's consent screen
//   GET  oauth/<provider>/callback?code&state -> exchange code, store refresh token
//   GET  oauth/<provider>/token?p=<pairing>   -> fresh access token (auto-refreshed)
//
// <provider> is 'google', 'onedrive', or 'dropbox'.
// Env per provider: <PROVIDER>_CLIENT_ID, <PROVIDER>_CLIENT_SECRET (e.g.
// GOOGLE_CLIENT_ID, ONEDRIVE_CLIENT_ID, DROPBOX_CLIENT_ID), plus the shared
// OAUTH_REDIRECT_BASE.

String get _redirectBase => (Platform.environment['OAUTH_REDIRECT_BASE'] ??
        'https://185.244.172.90.nip.io')
    .replaceAll(RegExp(r'/+$'), '');

class _Provider {
  final String id;
  final String envPrefix;
  final String authorizeUrl;
  final String tokenUrl;
  final Map<String, String> extraAuthorizeParams;
  // Included on the initial code exchange only (not on refresh).
  final Map<String, String> extraCodeExchangeParams;
  final Future<String?> Function(String accessToken) fetchEmail;

  const _Provider({
    required this.id,
    required this.envPrefix,
    required this.authorizeUrl,
    required this.tokenUrl,
    this.extraAuthorizeParams = const {},
    this.extraCodeExchangeParams = const {},
    required this.fetchEmail,
  });

  String get clientId => Platform.environment['${envPrefix}_CLIENT_ID'] ?? '';
  String get clientSecret =>
      Platform.environment['${envPrefix}_CLIENT_SECRET'] ?? '';
  String get redirectUri => '$_redirectBase/oauth/$id/callback';
}

Future<String?> _googleEmail(String accessToken) async {
  final m = await _getJson(
      'https://www.googleapis.com/oauth2/v3/userinfo', accessToken);
  return m?['email'] as String?;
}

Future<String?> _microsoftEmail(String accessToken) async {
  final m = await _getJson('https://graph.microsoft.com/v1.0/me', accessToken);
  return (m?['mail'] as String?) ?? (m?['userPrincipalName'] as String?);
}

Future<String?> _dropboxEmail(String accessToken) async {
  final m = await _postJsonAuthed(
      'https://api.dropboxapi.com/2/users/get_current_account', accessToken);
  return m?['email'] as String?;
}

final _providers = <String, _Provider>{
  'google': _Provider(
    id: 'google',
    envPrefix: 'GOOGLE',
    authorizeUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenUrl: 'https://oauth2.googleapis.com/token',
    extraAuthorizeParams: const {
      'scope': 'https://www.googleapis.com/auth/drive.file',
      'access_type': 'offline',
      'include_granted_scopes': 'true',
      'prompt': 'consent',
    },
    fetchEmail: _googleEmail,
  ),
  'onedrive': _Provider(
    id: 'onedrive',
    envPrefix: 'ONEDRIVE',
    authorizeUrl:
        'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
    tokenUrl: 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    extraAuthorizeParams: const {
      // offline_access is what makes Microsoft hand back a refresh_token.
      'scope': 'Files.ReadWrite.AppFolder offline_access',
      'response_mode': 'query',
    },
    fetchEmail: _microsoftEmail,
  ),
  'dropbox': _Provider(
    id: 'dropbox',
    envPrefix: 'DROPBOX',
    authorizeUrl: 'https://www.dropbox.com/oauth2/authorize',
    tokenUrl: 'https://api.dropboxapi.com/oauth2/token',
    extraAuthorizeParams: const {
      // Dropbox only issues a refresh_token when this is set explicitly —
      // there's no scope-based equivalent like Google/Microsoft's.
      'token_access_type': 'offline',
    },
    fetchEmail: _dropboxEmail,
  ),
};

final File _store = File('/app/data/cloud_oauth.json');
// Pre-multi-provider store: bare-pairing-keyed, Google only. Real users'
// existing Drive links live here — merged into the new store (under the
// "google:" prefix) on every load rather than requiring a one-time,
// easy-to-forget migration step.
final File _legacyGoogleStore = File('/app/data/google_oauth.json');

Map<String, dynamic> _load() {
  Map<String, dynamic> data = {};
  try {
    if (_store.existsSync()) {
      data = jsonDecode(_store.readAsStringSync()) as Map<String, dynamic>;
    }
  } catch (_) {}
  try {
    if (_legacyGoogleStore.existsSync()) {
      final legacy = jsonDecode(_legacyGoogleStore.readAsStringSync())
          as Map<String, dynamic>;
      for (final entry in legacy.entries) {
        final key = _key('google', entry.key);
        data.putIfAbsent(key, () => entry.value);
      }
    }
  } catch (_) {}
  return data;
}

void _save(Map<String, dynamic> m) {
  try {
    _store.writeAsStringSync(jsonEncode(m));
  } catch (_) {}
}

// Per-provider record key, so the same pairing id can link independently to
// google/onedrive/dropbox without colliding.
String _key(String providerId, String pairing) => '$providerId:$pairing';

const _oauthTokenRateWindow = Duration(minutes: 1);
const _oauthTokenRateMax = 30;
final Map<String, List<DateTime>> _oauthTokenRateLimits = {};

bool _checkOauthTokenRate(String pairing) {
  final now = DateTime.now();
  final times = _oauthTokenRateLimits.putIfAbsent(pairing, () => []);
  times.removeWhere((t) => now.difference(t) > _oauthTokenRateWindow);
  if (times.length >= _oauthTokenRateMax) return false;
  times.add(now);
  return true;
}

String _esc(String s) => const HtmlEscape().convert(s);

shelf.Response _html(String body, {int status = 200}) => shelf.Response(status,
    body: body, headers: {'content-type': 'text/html; charset=utf-8'});

shelf.Response _json(Map<String, dynamic> m, {int status = 200}) =>
    shelf.Response(status, body: jsonEncode(m), headers: {
      'content-type': 'application/json',
      'access-control-allow-origin': '*',
    });

Future<Map<String, dynamic>?> _postForm(String url, Map<String, String> form,
    {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.contentType =
        ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    headers?.forEach(req.headers.add);
    final body = form.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    req.write(body);
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        if (resp.statusCode >= 200 && resp.statusCode < 300) return decoded;
        return {'error': 'http_${resp.statusCode}', ...decoded};
      }
    } catch (_) {}
    return {'error': 'http_${resp.statusCode}', 'detail': text};
  } catch (e) {
    return {'error': 'exception', 'detail': '$e'};
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>?> _getJson(String url, String accessToken) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.add('authorization', 'Bearer $accessToken');
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode == 200) return jsonDecode(text) as Map<String, dynamic>;
  } catch (_) {
  } finally {
    client.close(force: true);
  }
  return null;
}

// Dropbox's get_current_account is a POST with no body, auth via header.
Future<Map<String, dynamic>?> _postJsonAuthed(
    String url, String accessToken) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.add('authorization', 'Bearer $accessToken');
    req.headers.contentType = ContentType.json;
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode == 200) return jsonDecode(text) as Map<String, dynamic>;
  } catch (_) {
  } finally {
    client.close(force: true);
  }
  return null;
}

/// Handles `oauth/<google|onedrive|dropbox>/*`. Returns null for any other
/// path so the caller continues its normal dispatch.
Future<shelf.Response?> handleCloudOauth(shelf.Request request) async {
  final path = request.url.path; // shelf paths have no leading slash
  final match =
      RegExp(r'^oauth/(google|onedrive|dropbox)/(start|callback|token)$')
          .firstMatch(path);
  if (match == null) return null;
  final provider = _providers[match.group(1)]!;
  final step = match.group(2);

  if (provider.clientId.isEmpty) {
    return _html(
        '<h3>OAuth не настроен: нет ${provider.envPrefix}_CLIENT_ID на сервере.</h3>',
        status: 503);
  }

  // 1) start -> redirect to the provider's consent screen
  if (step == 'start') {
    final p = request.url.queryParameters['p'] ?? '';
    if (p.isEmpty) return _html('<h3>Нет параметра p.</h3>', status: 400);
    final auth = Uri.parse(provider.authorizeUrl).replace(queryParameters: {
      'client_id': provider.clientId,
      'redirect_uri': provider.redirectUri,
      'response_type': 'code',
      'state': p,
      ...provider.extraAuthorizeParams,
    });
    return shelf.Response.found(auth.toString());
  }

  if (provider.clientSecret.isEmpty) {
    return _html(
        '<h3>OAuth не настроен: нет ${provider.envPrefix}_CLIENT_SECRET на сервере.</h3>',
        status: 503);
  }

  // 2) callback -> exchange the code for tokens, store the refresh token
  if (step == 'callback') {
    final q = request.url.queryParameters;
    final err = q['error'];
    if (err != null) {
      return _html('<h3>${_esc(provider.id)} вернул ошибку: ${_esc(err)}</h3>',
          status: 400);
    }
    final code = q['code'] ?? '';
    final p = q['state'] ?? '';
    if (code.isEmpty || p.isEmpty) {
      return _html('<h3>Нет code/state.</h3>', status: 400);
    }
    final tok = await _postForm(provider.tokenUrl, {
      'code': code,
      'client_id': provider.clientId,
      'client_secret': provider.clientSecret,
      'redirect_uri': provider.redirectUri,
      'grant_type': 'authorization_code',
      ...provider.extraCodeExchangeParams,
    });
    if (tok == null || tok['error'] != null || tok['access_token'] == null) {
      return _html(
          '<h3>Не удалось обменять код: ${_esc(tok?['error']?.toString() ?? 'unknown')}</h3>',
          status: 400);
    }
    final refresh = tok['refresh_token'] as String?;
    final access = tok['access_token'] as String;
    final expiresIn = (tok['expires_in'] as num?)?.toInt() ?? 3600;
    final email = await provider.fetchEmail(access) ?? '';
    final store = _load();
    final key = _key(provider.id, p);
    final prev = store[key] as Map<String, dynamic>?;
    store[key] = {
      'refresh_token': refresh ?? prev?['refresh_token'],
      'access_token': access,
      'expiry_ms':
          DateTime.now().millisecondsSinceEpoch + (expiresIn - 60) * 1000,
      'email': email,
      'updated': DateTime.now().toIso8601String(),
    };
    _save(store);
    return _html('<!doctype html><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<div style="font-family:-apple-system,sans-serif;max-width:440px;margin:48px auto;text-align:center;color:#0f172a">'
        '<h2 style="color:#0d9488">Готово ✓</h2>'
        '<p>Аккаунт <b>${_esc(email)}</b> привязан к Rlink.</p>'
        '<p>Вернитесь в приложение — оно подхватит привязку автоматически.</p>'
        '</div>');
  }

  // 3) token -> return a fresh access token (refresh server-side if needed)
  if (step == 'token') {
    final p = request.url.queryParameters['p'] ?? '';
    if (p.isEmpty)
      return _json({'ok': false, 'error': 'no_pairing'}, status: 400);
    // `p` itself has 160 bits of secure randomness (unguessable), but nothing
    // stopped hammering this endpoint (measured ~930 req/s, 0 throttling) —
    // basic defense-in-depth against resource exhaustion / token scanning.
    if (!_checkOauthTokenRate(p)) {
      return _json({'ok': false, 'error': 'rate_limited'}, status: 429);
    }
    final store = _load();
    final key = _key(provider.id, p);
    final rec = store[key] as Map<String, dynamic>?;
    if (rec == null) {
      return _json({'ok': false, 'error': 'not_linked'}, status: 404);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    var access = rec['access_token'] as String?;
    final expiry = (rec['expiry_ms'] as num?)?.toInt() ?? 0;
    if (access == null || now >= expiry) {
      final refresh = rec['refresh_token'] as String?;
      if (refresh == null || refresh.isEmpty) {
        return _json({'ok': false, 'error': 'no_refresh'}, status: 400);
      }
      final tok = await _postForm(provider.tokenUrl, {
        'client_id': provider.clientId,
        'client_secret': provider.clientSecret,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
      });
      if (tok == null || tok['access_token'] == null) {
        return _json(
            {'ok': false, 'error': 'refresh_failed', 'detail': tok?['error']},
            status: 400);
      }
      access = tok['access_token'] as String;
      final expiresIn = (tok['expires_in'] as num?)?.toInt() ?? 3600;
      rec['access_token'] = access;
      rec['expiry_ms'] = now + (expiresIn - 60) * 1000;
      // Dropbox refresh responses don't repeat refresh_token; keep the
      // existing one. Google/Microsoft sometimes rotate it — take the new
      // one only if present.
      if (tok['refresh_token'] != null) {
        rec['refresh_token'] = tok['refresh_token'];
      }
      store[key] = rec;
      _save(store);
    }
    return _json({
      'ok': true,
      'access_token': access,
      'expiry_ms': rec['expiry_ms'],
      'email': rec['email'] ?? '',
    });
  }

  return _html('<h3>Неизвестный путь OAuth.</h3>', status: 404);
}
