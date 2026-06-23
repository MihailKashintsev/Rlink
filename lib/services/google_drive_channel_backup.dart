import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, debugPrint;
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/googleapis_auth.dart' as gapis;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Состояние аккаунта Google Drive для экрана настроек (квота из [about.get]).
class GoogleDriveSyncStatus {
  final String? email;
  final String? displayName;

  /// Лимит хранилища, байт (null если API не вернул).
  final int? limitBytes;

  /// Занято всего (включая Диск, Почту, Фото), байт.
  final int? usageBytes;

  const GoogleDriveSyncStatus({
    this.email,
    this.displayName,
    this.limitBytes,
    this.usageBytes,
  });

  int? get freeBytes {
    if (limitBytes == null || usageBytes == null) return null;
    if (limitBytes! <= 0) return null;
    final f = limitBytes! - usageBytes!;
    return f < 0 ? 0 : f;
  }
}

/// Загрузка зашифрованного снимка канала в Google Drive (OAuth в Google Cloud Console).
class GoogleDriveChannelBackup {
  GoogleDriveChannelBackup._();

  /// OAuth-клиент типа «Веб-приложение» — для Android нужен как [GoogleSignIn.serverClientId]
  /// при запросе токена для Google APIs.
  static const String _webClientId =
      '180782636430-cr0ogo622n3ng26aeu00j0pkn4286dvs.apps.googleusercontent.com';

  static final List<String> _driveScopes = [drive.DriveApi.driveFileScope];
  static String? _lastSignInError;
  static String? get lastSignInError => _lastSignInError;
  static bool _signInInProgress = false;

  /// Web client ID нужен на Android/iOS/macOS, чтобы выдавался access token для Google APIs.
  static final GoogleSignIn _signIn = GoogleSignIn(
    scopes: _driveScopes,
    clientId: kIsWeb ? _webClientId : null,
    serverClientId: kIsWeb ? null : _webClientId,
    forceCodeForRefreshToken:
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
  );

  // ── Manual / implicit web token (iPhone Safari PWA fallback) ──────────────
  // On iOS standalone PWA the GIS popup/redirect doesn't work. As a fallback the
  // user authorises in real Safari (implicit flow) and pastes the access token
  // back into the app. Token is short-lived (~1h, no refresh) — re-link when it
  // expires. Requires this redirect URI registered on the Web OAuth client.
  static const String manualRedirectUri =
      'https://mihailkashintsev.github.io/rlink-web/oauth.html';
  static gapis.AccessCredentials? _manualCreds;
  static String? _manualEmail;

  static String? get manualEmail => _manualEmail;

  static bool get hasValidManualCreds {
    final c = _manualCreds;
    return c != null &&
        c.accessToken.expiry
            .isAfter(DateTime.now().toUtc().add(const Duration(seconds: 30)));
  }

  /// Implicit-flow consent URL — open in real Safari, then paste the token.
  static String buildManualAuthUrl() {
    final params = <String, String>{
      'client_id': _webClientId,
      'redirect_uri': manualRedirectUri,
      'response_type': 'token',
      'scope': _driveScopes.join(' '),
      'include_granted_scopes': 'true',
      'prompt': 'consent',
    };
    final q = params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return 'https://accounts.google.com/o/oauth2/v2/auth?$q';
  }

  /// Accepts a bare token, a "token|expires_in" string (from oauth.html), or a
  /// full "#access_token=…&expires_in=…" fragment. Validates against Drive.
  static Future<bool> linkWithPastedToken(String raw) async {
    _lastSignInError = null;
    try {
      var token = raw.trim();
      var expiresIn = 3600;
      if (token.contains('access_token=')) {
        final frag =
            token.contains('#') ? token.substring(token.indexOf('#') + 1) : token;
        for (final pair in frag.split('&')) {
          final kv = pair.split('=');
          if (kv.length < 2) continue;
          final k = Uri.decodeComponent(kv[0]);
          final v = Uri.decodeComponent(kv[1]);
          if (k == 'access_token') token = v;
          if (k == 'expires_in') expiresIn = int.tryParse(v) ?? 3600;
        }
      } else if (token.contains('|')) {
        final parts = token.split('|');
        token = parts[0].trim();
        if (parts.length > 1) {
          expiresIn = int.tryParse(parts[1].trim()) ?? 3600;
        }
      }
      if (token.isEmpty) {
        _lastSignInError = 'Пустой код';
        return false;
      }
      final expiry = DateTime.now()
          .toUtc()
          .add(Duration(seconds: (expiresIn - 120).clamp(60, 3600)));
      final creds = gapis.AccessCredentials(
        gapis.AccessToken('Bearer', token, expiry),
        null,
        _driveScopes,
      );
      final client = gapis.authenticatedClient(http.Client(), creds);
      try {
        final about = await drive.DriveApi(client).about.get($fields: 'user');
        _manualCreds = creds;
        _manualEmail = about.user?.emailAddress;
        await _persistManual(token, expiry, _manualEmail);
        debugPrint('[RLINK][Drive] manual token linked: $_manualEmail');
        return true;
      } finally {
        client.close();
      }
    } catch (e, st) {
      debugPrint('[RLINK][Drive] linkWithPastedToken failed: $e\n$st');
      _lastSignInError = 'Код недействителен или истёк. Получите новый.';
      return false;
    }
  }

  static Future<void> _persistManual(
      String token, DateTime expiryUtc, String? email) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('drive_manual_token', token);
      await p.setInt('drive_manual_expiry', expiryUtc.millisecondsSinceEpoch);
      if (email != null) await p.setString('drive_manual_email', email);
    } catch (_) {}
  }

  /// Restore a still-valid manual token at startup (web).
  static Future<void> restoreManualToken() async {
    try {
      final p = await SharedPreferences.getInstance();
      final token = p.getString('drive_manual_token');
      final exp = p.getInt('drive_manual_expiry');
      if (token == null || exp == null) return;
      final expiry = DateTime.fromMillisecondsSinceEpoch(exp, isUtc: true);
      if (expiry.isBefore(DateTime.now().toUtc())) {
        await _clearManual();
        return;
      }
      _manualCreds = gapis.AccessCredentials(
        gapis.AccessToken('Bearer', token, expiry),
        null,
        _driveScopes,
      );
      _manualEmail = p.getString('drive_manual_email');
    } catch (_) {}
  }

  static Future<void> _clearManual() async {
    _manualCreds = null;
    _manualEmail = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('drive_manual_token');
      await p.remove('drive_manual_expiry');
      await p.remove('drive_manual_email');
    } catch (_) {}
  }

  // ── Durable relay-backed account (refresh token lives on the relay) ─────────
  // Works on every platform incl. iOS PWA: user consents once in a browser, the
  // relay stores the refresh token and serves short-lived access tokens forever.
  static const String relayOauthBase = 'https://185.244.172.90.nip.io';
  static String? _relayPairing;
  static String? _relayEmail;
  static gapis.AccessCredentials? _relayCreds;
  static String? _pendingPairing;

  static bool get hasRelayAccount =>
      _relayPairing != null && _relayPairing!.isNotEmpty;
  static String? get relayEmail => _relayEmail;

  /// Begin a durable link: returns the consent URL to open in a browser.
  static String startRelayLink() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(20, (_) => rnd.nextInt(256));
    final pairing =
        'rl_${DateTime.now().millisecondsSinceEpoch}_${base64Url.encode(bytes).replaceAll('=', '')}';
    _pendingPairing = pairing;
    return '$relayOauthBase/oauth/google/start?p=${Uri.encodeQueryComponent(pairing)}';
  }

  /// After the user consents in the browser, confirm the link by polling the
  /// relay for a token. Returns true once linked.
  static Future<bool> finishRelayLink() async {
    final pairing = _pendingPairing;
    if (pairing == null || pairing.isEmpty) {
      _lastSignInError = 'Сначала откройте вход';
      return false;
    }
    final creds = await _fetchRelayCreds(pairing);
    if (creds == null) {
      _lastSignInError = 'Вход ещё не подтверждён. Завершите его в браузере.';
      return false;
    }
    _relayPairing = pairing;
    _relayCreds = creds;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('drive_relay_pairing', pairing);
      if (_relayEmail != null) await p.setString('drive_relay_email', _relayEmail!);
    } catch (_) {}
    return true;
  }

  /// Fetch a fresh access token for [pairing] from the relay (it refreshes
  /// server-side). Returns null if not linked yet / unavailable.
  static Future<gapis.AccessCredentials?> _fetchRelayCreds(
      String pairing) async {
    try {
      final uri = Uri.parse(
          '$relayOauthBase/oauth/google/token?p=${Uri.encodeQueryComponent(pairing)}');
      final resp = await http.get(uri).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      if (m['ok'] != true) return null;
      final token = m['access_token'] as String?;
      if (token == null || token.isEmpty) return null;
      final expiryMs = (m['expiry_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch + 3000 * 1000;
      _relayEmail = m['email'] as String?;
      return gapis.AccessCredentials(
        gapis.AccessToken('Bearer', token,
            DateTime.fromMillisecondsSinceEpoch(expiryMs, isUtc: true)),
        null,
        _driveScopes,
      );
    } catch (e) {
      debugPrint('[RLINK][Drive] relay token fetch failed: $e');
      return null;
    }
  }

  /// Relay client, refreshing the short-lived access token when near expiry.
  static Future<gapis.AuthClient?> _relayAuthClient() async {
    final pairing = _relayPairing;
    if (pairing == null) return null;
    final cached = _relayCreds;
    final fresh = cached != null &&
        cached.accessToken.expiry
            .isAfter(DateTime.now().toUtc().add(const Duration(seconds: 60)));
    final creds = fresh ? cached : await _fetchRelayCreds(pairing);
    if (creds == null) return null;
    _relayCreds = creds;
    return gapis.authenticatedClient(http.Client(), creds);
  }

  static Future<void> restoreRelayAccount() async {
    try {
      final p = await SharedPreferences.getInstance();
      final pairing = p.getString('drive_relay_pairing');
      if (pairing != null && pairing.isNotEmpty) {
        _relayPairing = pairing;
        _relayEmail = p.getString('drive_relay_email');
      }
    } catch (_) {}
  }

  static Future<void> _clearRelay() async {
    _relayPairing = null;
    _relayEmail = null;
    _relayCreds = null;
    _pendingPairing = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('drive_relay_pairing');
      await p.remove('drive_relay_email');
    } catch (_) {}
  }

  static bool _isScopesApiUnsupported(Object error) {
    if (error is UnimplementedError) return true;
    final msg = error.toString();
    return msg.contains('canAccessScopes() has not been implemented') ||
        msg.contains('requestScopes() has not been implemented');
  }

  /// После выбора аккаунта без этого часто нет access token для Drive (особенно на новых GMS).
  static Future<bool> _ensureDriveScopes({required bool interactive}) async {
    if (_signIn.currentUser == null) return false;
    try {
      if (await _signIn.canAccessScopes(_driveScopes)) return true;
    } catch (e, st) {
      if (_isScopesApiUnsupported(e)) {
        debugPrint(
            '[RLINK][Drive] canAccessScopes unsupported → fallback path');
        return true;
      }
      debugPrint('[RLINK][Drive] canAccessScopes failed: $e\n$st');
    }
    if (!interactive) return false;
    if (!kIsWeb) await _waitForForegroundForInteractiveSignIn();
    try {
      return await _signIn.requestScopes(_driveScopes);
    } catch (e, st) {
      if (_isScopesApiUnsupported(e)) {
        debugPrint('[RLINK][Drive] requestScopes unsupported → fallback path');
        return true;
      }
      debugPrint('[RLINK][Drive] requestScopes failed: $e\n$st');
      return false;
    }
  }

  static Future<gapis.AuthClient?> _driveAuthClient({
    required bool interactive,
  }) async {
    // Durable relay account takes top priority (refresh handled server-side).
    if (hasRelayAccount) {
      final c = await _relayAuthClient();
      if (c != null) return c;
    }
    // Manual (pasted) web token next — used on iOS Safari PWA without relay.
    if (hasValidManualCreds) {
      return gapis.authenticatedClient(http.Client(), _manualCreds!);
    }
    if (!await _ensureDriveScopes(interactive: interactive)) {
      return null;
    }
    var client = await _signIn.authenticatedClient();
    if (client != null) return client;
    if (interactive && _signIn.currentUser != null) {
      if (!kIsWeb) await _waitForForegroundForInteractiveSignIn();
      var granted = false;
      try {
        granted = await _signIn.requestScopes(_driveScopes);
      } catch (e, st) {
        if (_isScopesApiUnsupported(e)) {
          debugPrint('[RLINK][Drive] requestScopes unsupported in retry path');
          granted = true;
        } else {
          debugPrint('[RLINK][Drive] requestScopes retry failed: $e\n$st');
        }
      }
      if (granted) {
        client = await _signIn.authenticatedClient();
      }
    }
    return client;
  }

  /// Текущий аккаунт без диалога (если уже входили).
  static GoogleSignInAccount? get cachedCurrentUser => _signIn.currentUser;

  /// Локально отвязывает Google-аккаунт (sign-out + revoke where supported).
  static Future<bool> disconnectCurrentUser() async {
    try {
      await _signIn.disconnect();
      debugPrint('[RLINK][Drive] disconnect() done');
    } catch (e, st) {
      debugPrint('[RLINK][Drive] disconnect() failed: $e\n$st');
    }
    try {
      await _signIn.signOut();
      debugPrint('[RLINK][Drive] signOut() done');
    } catch (e, st) {
      debugPrint('[RLINK][Drive] signOut() failed: $e\n$st');
    }
    await _clearManual();
    await _clearRelay();
    return _signIn.currentUser == null;
  }

  /// Upload arbitrary bytes (a received file/photo/video, an export, a call
  /// recording…) into a "Rlink" folder on the linked Drive. Returns true on
  /// success. Uses whichever account is active (relay/manual/GIS).
  static Future<bool> uploadBytesToDrive({
    required String fileName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
  }) async {
    _lastSignInError = null;
    try {
      if (!hasValidManualCreds && !hasRelayAccount) {
        final account = await ensureUserSignedIn(interactive: true);
        if (account == null) {
          _lastSignInError = 'Аккаунт Google не привязан';
          return false;
        }
      }
      final client = await _driveAuthClient(interactive: true);
      if (client == null) {
        _lastSignInError = 'Нет доступа к Google Drive';
        return false;
      }
      try {
        final api = drive.DriveApi(client);
        final folderId = await _ensureRlinkFolder(api);
        final media = drive.Media(
          Stream<List<int>>.value(bytes),
          bytes.length,
          contentType: mimeType,
        );
        final f = drive.File()
          ..name = fileName
          ..parents = folderId != null ? [folderId] : null;
        await api.files.create(f, uploadMedia: media);
        return true;
      } finally {
        client.close();
      }
    } catch (e, st) {
      debugPrint('[RLINK][Drive] uploadBytesToDrive failed: $e\n$st');
      _lastSignInError = '$e';
      return false;
    }
  }

  /// Find or create the app's "Rlink" folder (drive.file scope sees only files
  /// this app created, so it's a per-app folder).
  static Future<String?> _ensureRlinkFolder(drive.DriveApi api) async {
    try {
      final res = await api.files.list(
        q: "name='Rlink' and mimeType='application/vnd.google-apps.folder' and trashed=false",
        $fields: 'files(id,name)',
        spaces: 'drive',
      );
      final found = res.files;
      if (found != null && found.isNotEmpty) return found.first.id;
      final folder = drive.File()
        ..name = 'Rlink'
        ..mimeType = 'application/vnd.google-apps.folder';
      final created = await api.files.create(folder, $fields: 'id');
      return created.id;
    } catch (_) {
      return null;
    }
  }

  /// На Android интерактивный [GoogleSignIn.signIn] требует foreground Activity;
  /// при предварительном запуске Dart из [RlinkApplication] плагин может ещё не
  /// получить activity — ждём resumed и даём кадр на attach.
  static Future<void> _waitForForegroundForInteractiveSignIn() async {
    if (kIsWeb) return;
    final binding = WidgetsBinding.instance;
    if (binding.lifecycleState != AppLifecycleState.resumed) {
      for (var i = 0; i < 80; i++) {
        if (binding.lifecycleState == AppLifecycleState.resumed) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    // Кадр на attach Activity к плагину после resumed.
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  /// Пытается восстановить сессию; при [interactive] открывает выбор аккаунта.
  static Future<GoogleSignInAccount?> ensureUserSignedIn({
    bool interactive = true,
  }) async {
    _lastSignInError = null;
    // Quick path: в памяти singleton'а уже держится currentUser — после удачного
    // interactive-входа это самый надёжный источник (на iOS signInSilently
    // иногда возвращает null пока GIDSignIn не доделает restore из keychain).
    final cached = _signIn.currentUser;
    if (cached != null) {
      debugPrint('[RLINK][Drive] currentUser (cached) → ${cached.email}');
      return cached;
    }
    try {
      final silent = await _signIn.signInSilently();
      if (silent != null) {
        debugPrint('[RLINK][Drive] signInSilently → ${silent.email}');
        return silent;
      }
      debugPrint('[RLINK][Drive] signInSilently → null (no saved session)');
    } catch (e, st) {
      debugPrint('[RLINK][Drive] signInSilently threw: $e\n$st');
    }
    // Ещё раз проверим currentUser: signInSilently сам публикует его через стрим,
    // но Future возвращается раньше, чем успевает прогнаться _setCurrentUser.
    final postSilent = _signIn.currentUser;
    if (postSilent != null) {
      debugPrint(
          '[RLINK][Drive] currentUser (post-silent) → ${postSilent.email}');
      return postSilent;
    }
    if (!interactive) return null;

    if (_signInInProgress) {
      debugPrint('[RLINK][Drive] signIn already in progress, returning cached');
      return _signIn.currentUser;
    }
    _signInInProgress = true;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        await _waitForForegroundForInteractiveSignIn();
        try {
          debugPrint('[RLINK][Drive] signIn() invoked '
              '(attempt=${attempt + 1}, platform=$defaultTargetPlatform, lifecycle=${WidgetsBinding.instance.lifecycleState})');
          final a = await _signIn.signIn();
          debugPrint(
              '[RLINK][Drive] signIn() → ${a?.email ?? 'null (user canceled or silent fail)'}');
          final resolved = a ?? _signIn.currentUser;
          if (resolved != null) return resolved;
          // User cancelled — don't retry, return currentUser if any
          debugPrint(
              '[RLINK][Drive] signIn cancelled by user, stopping retries');
          break;
        } catch (e, st) {
          _lastSignInError = e.toString();
          debugPrint('[RLINK][Drive] signIn failed: $e\n$st');
        }
        await Future<void>.delayed(const Duration(milliseconds: 220));
      }
    } finally {
      _signInInProgress = false;
    }
    return _signIn.currentUser;
  }

  /// Аккаунт и квота для UI настроек. При [interactive]==false только тихий вход.
  static Future<GoogleDriveSyncStatus?> getSyncStatus({
    bool interactive = false,
  }) async {
    try {
      final account = (hasValidManualCreds || hasRelayAccount)
          ? null
          : await ensureUserSignedIn(interactive: interactive);
      if (account == null && !hasValidManualCreds && !hasRelayAccount) {
        return const GoogleDriveSyncStatus();
      }
      late final GoogleDriveSyncStatus accountOnlyStatus;
      accountOnlyStatus = GoogleDriveSyncStatus(
        email: account?.email ?? _relayEmail ?? _manualEmail,
        displayName: account?.displayName,
      );

      gapis.AuthClient? authClient;
      try {
        authClient = await _driveAuthClient(interactive: interactive);
      } catch (e, st) {
        debugPrint('[RLINK][Drive] getSyncStatus auth client failed: $e\n$st');
        return accountOnlyStatus;
      }
      if (authClient == null) {
        return accountOnlyStatus;
      }
      try {
        final api = drive.DriveApi(authClient);
        final about = await api.about.get(
          $fields: 'user,storageQuota',
        );
        int? parseQuota(String? s) {
          if (s == null || s.isEmpty) return null;
          return int.tryParse(s);
        }

        final q = about.storageQuota;
        return GoogleDriveSyncStatus(
          email: about.user?.emailAddress ??
              account?.email ??
              _relayEmail ??
              _manualEmail,
          displayName: about.user?.displayName ?? account?.displayName,
          limitBytes: parseQuota(q?.limit),
          usageBytes: parseQuota(q?.usage),
        );
      } catch (e, st) {
        debugPrint('[RLINK][Drive] getSyncStatus about.get failed: $e\n$st');
        return accountOnlyStatus;
      } finally {
        authClient.close();
      }
    } catch (e, st) {
      debugPrint('[RLINK][Drive] getSyncStatus: $e\n$st');
      return null;
    }
  }

  /// Один файл на канал: при наличии [existingFileId] содержимое перезаписывается.
  static Future<String?> uploadOrUpdateEncryptedFile({
    required String fileName,
    required Uint8List ciphertext,
    String? existingFileId,
  }) async {
    try {
      if (!hasValidManualCreds && !hasRelayAccount) {
        final account = await ensureUserSignedIn(interactive: true);
        if (account == null) return null;
      }
      final authClient = await _driveAuthClient(interactive: true);
      if (authClient == null) return null;
      try {
        final api = drive.DriveApi(authClient);
        final media = drive.Media(
          Stream<List<int>>.value(ciphertext),
          ciphertext.length,
        );

        if (existingFileId != null && existingFileId.isNotEmpty) {
          try {
            await api.files.update(
              drive.File()..name = fileName,
              existingFileId,
              uploadMedia: media,
            );
            return existingFileId;
          } catch (e) {
            debugPrint('[RLINK][Drive] update failed, creating new: $e');
          }
        }

        final created = await api.files.create(
          drive.File()..name = fileName,
          uploadMedia: media,
        );
        return created.id;
      } finally {
        authClient.close();
      }
    } catch (e, st) {
      debugPrint('[RLINK][Drive] upload failed: $e\n$st');
      return null;
    }
  }

  /// Делает файл доступным по ссылке (Anyone with link → viewer) и возвращает прямую ссылку для скачивания.
  /// Вызывается сразу после [uploadOrUpdateEncryptedFile] чтобы подписчики могли скачать снимок без авторизации.
  static Future<String?> makePublicAndGetDownloadUrl(String fileId) async {
    try {
      final authClient = await _driveAuthClient(interactive: true);
      if (authClient == null) return null;
      try {
        final api = drive.DriveApi(authClient);
        await api.permissions.create(
          drive.Permission()
            ..type = 'anyone'
            ..role = 'reader',
          fileId,
        );
        final file = await api.files.get(
          fileId,
          $fields: 'webContentLink',
        ) as drive.File;
        final url = file.webContentLink;
        debugPrint('[RLINK][Drive] makePublic ok: $fileId → $url');
        return url;
      } finally {
        authClient.close();
      }
    } catch (e, st) {
      debugPrint('[RLINK][Drive] makePublic failed: $e\n$st');
      return null;
    }
  }

  /// Удаляет файл-резерв канала на Google Drive.
  /// Возвращает true, если файл удалён или уже отсутствует.
  static Future<bool> deleteBackupFile({
    required String fileId,
    bool interactive = true,
  }) async {
    if (fileId.trim().isEmpty) return true;
    try {
      if (!hasValidManualCreds && !hasRelayAccount) {
        final account = await ensureUserSignedIn(interactive: interactive);
        if (account == null) return false;
      }
      final authClient = await _driveAuthClient(interactive: interactive);
      if (authClient == null) return false;
      try {
        final api = drive.DriveApi(authClient);
        await api.files.delete(fileId);
        debugPrint('[RLINK][Drive] delete file ok: $fileId');
        return true;
      } finally {
        authClient.close();
      }
    } catch (e, st) {
      // На некоторых аккаунтах API может вернуть 404 на уже удалённый id.
      final msg = e.toString().toLowerCase();
      if (msg.contains('404') ||
          msg.contains('not found') ||
          msg.contains('file not found')) {
        debugPrint('[RLINK][Drive] delete file treated as already removed: $e');
        return true;
      }
      debugPrint('[RLINK][Drive] delete file failed: $e\n$st');
      return false;
    }
  }
}
