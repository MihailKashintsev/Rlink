import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Обновления берём со СВОЕГО сервера (relay), а не с GitHub — в РФ GitHub
/// часто режется/тормозит. Relay отдаёт манифест + сами бинарники:
///   https://185.244.172.90.nip.io/updates/manifest.json
/// Манифест: { version, notes, assets: { android|windows|macos|linux|ios } }.
const _kUpdateManifestUrl =
    'https://185.244.172.90.nip.io/updates/manifest.json';

/// Уведомление UI о доступном обновлении (после фоновой проверки).
final ValueNotifier<UpdateInfo?> pendingUpdateNotifier =
    ValueNotifier<UpdateInfo?>(null);

/// Проверка обновлений доступна на всех нативных ОС (не web).
/// Установка различается: десктоп заменяет себя и перезапускается; Android
/// скачивает APK и запускает системный установщик; iOS установить сам не может
/// (песочница) — только открывает страницу загрузки, если она задана.
bool get isUpdateSupported =>
    !kIsWeb &&
    (Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isAndroid ||
        Platform.isIOS);

class UpdateInfo {
  final String version;
  final String body;
  final String downloadUrl;
  final String assetName;

  /// true = открыть [downloadUrl] в браузере (страница установки, iOS);
  /// false = скачать ассет и установить (десктоп/Android).
  final bool openExternalDownloadPage;

  const UpdateInfo({
    required this.version,
    required this.body,
    required this.downloadUrl,
    required this.assetName,
    this.openExternalDownloadPage = false,
  });
}

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const _installChannel = MethodChannel('com.rendergames.rlink/updates');

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 5),
  ));

  ValueNotifier<double?> downloadProgress = ValueNotifier(null);

  /// Выставляется, когда обновление уже СКАЧАНО и готово к установке. UI по
  /// этому сигналу показывает окно-предупреждение «приложение перезапустится»,
  /// а затем вызывает [install]. Загрузка при этом идёт в фоне — не мешает
  /// пользоваться мессенджером.
  final ValueNotifier<UpdateInfo?> readyToInstall = ValueNotifier(null);

  String? _readyFilePath;
  UpdateInfo? _readyInfo;
  bool _downloading = false;

  /// На Android загрузка идёт в фоне (системный DownloadManager) — приложение
  /// можно свернуть, скачивание продолжится. На остальных ОС загрузка живёт
  /// в процессе приложения, поэтому его лучше не закрывать.
  bool get supportsBackgroundDownload => !kIsWeb && Platform.isAndroid;

  Future<UpdateInfo?> checkForUpdate() async {
    if (!isUpdateSupported) return null;
    try {
      final info = await PackageInfo.fromPlatform();
      final current = _normalizeVersionTag(info.version);

      final response = await _dio.getUri(
        Uri.parse(_kUpdateManifestUrl),
        options: Options(responseType: ResponseType.plain),
      );
      final data = response.data;
      final Map<String, dynamic> manifest = data is String
          ? jsonDecode(data) as Map<String, dynamic>
          : Map<String, dynamic>.from(data as Map);

      final rawVersion = manifest['version'] as String? ?? '';
      final latest = _normalizeVersionTag(rawVersion);
      if (!_isNewer(latest, current)) return null;

      final assets = manifest['assets'] is Map
          ? Map<String, dynamic>.from(manifest['assets'] as Map)
          : null;
      // На Android выбираем APK под ABI устройства (меньший файл = быстрее
      // качается): arm64 по умолчанию, отдельный arm32 для старых 32-бит.
      final abi = Platform.isAndroid ? await _deviceAbi() : '';
      final url = _assetUrlForPlatform(assets, abi);
      // iOS не может установить сам: показываем баннер только если задана
      // страница загрузки (assets.ios). Иначе не тревожим.
      if (url == null || url.isEmpty) return null;

      return UpdateInfo(
        version: rawVersion.isNotEmpty ? rawVersion : latest,
        body: manifest['notes'] as String? ?? '',
        downloadUrl: url,
        assetName: _fileNameFromUrl(url),
        openExternalDownloadPage: Platform.isIOS,
      );
    } catch (e) {
      debugPrint('[UpdateService] check failed: $e');
      return null;
    }
  }

  /// Открывает страницу загрузки в браузере (iOS / любой openExternalDownloadPage
  /// — сами установить не можем).
  Future<void> openDownloadPage(UpdateInfo info) async {
    final uri = Uri.parse(info.downloadUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Скачивает обновление В ФОНЕ, НЕ устанавливая сразу. Прогресс виден в
  /// настройках ([downloadProgress]). По завершении выставляет [readyToInstall];
  /// саму установку запускает UI — после окна с предупреждением о перезапуске.
  Future<void> startDownload(UpdateInfo info) async {
    if (!isUpdateSupported) return;
    // iOS / внешняя страница: устанавливать нечем — это не фоновый поток.
    if (info.openExternalDownloadPage || Platform.isIOS) return;
    if (_downloading) return; // уже качаем
    if (readyToInstall.value != null) return; // уже скачано, ждём установки
    _downloading = true;
    try {
      if (Platform.isAndroid) {
        // Системный DownloadManager: качает вне процесса приложения, можно
        // свернуть/выгрузить. По завершении сам выставит readyToInstall.
        await _downloadAndroidBackground(info);
      } else {
        // Десктоп: качаем во временную папку (async-IO, UI не блокируется).
        final dir = await getTemporaryDirectory();
        final filePath = '${dir.path}/${info.assetName}';
        downloadProgress.value = 0.0;
        await _downloadResilient(info, filePath);
        _markReadyToInstall(info, filePath);
      }
    } catch (e) {
      debugPrint('[UpdateService] download failed: $e');
      downloadProgress.value = null;
    } finally {
      _downloading = false;
    }
  }

  /// Помечает обновление скачанным и готовым к установке (UI покажет окно и
  /// затем вызовет [install]).
  void _markReadyToInstall(UpdateInfo info, String? path) {
    _readyInfo = info;
    _readyFilePath = path;
    downloadProgress.value = 1.0;
    readyToInstall.value = info;
  }

  /// Запускает установку уже скачанного обновления. Android — системный
  /// установщик (приложение закроется и перезапустится после установки);
  /// десктоп — распаковка поверх + перезапуск (внутри `exit(0)`).
  Future<void> install() async {
    final info = _readyInfo;
    final path = _readyFilePath;
    if (info == null) return;
    try {
      if (Platform.isAndroid) {
        if (path != null && path.isNotEmpty) await _installAndroid(path);
      } else if (Platform.isWindows) {
        if (path != null) await _installWindows(path);
      } else if (Platform.isMacOS) {
        if (path != null) await _installMacOS(path);
      } else if (Platform.isLinux) {
        if (path != null) await _installLinux(path);
      }
    } catch (e) {
      debugPrint('[UpdateService] install failed: $e');
    }
  }

  // ---- Android: фоновая загрузка через системный DownloadManager ----
  // Загрузка живёт вне приложения (своё уведомление в шторке), поэтому её можно
  // свернуть. downloadId + информацию о версии храним в prefs, чтобы «подхватить»
  // уже завершившуюся загрузку при следующем запуске (если приложение выгрузили).

  static const _prefsPendingId = 'rlink_update_dl_id';
  static const _prefsPendingVer = 'rlink_update_dl_ver';
  static const _prefsPendingUrl = 'rlink_update_dl_url';
  static const _prefsPendingAsset = 'rlink_update_dl_asset';

  bool _pollingAndroid = false;

  Future<void> _downloadAndroidBackground(UpdateInfo info) async {
    // Эта версия уже качается в фоне? Не плодим дубли — просто следим за ней.
    final prefs = await SharedPreferences.getInstance();
    final existingId = prefs.getInt(_prefsPendingId);
    if (existingId != null &&
        prefs.getString(_prefsPendingVer) == info.version) {
      downloadProgress.value = 0.0;
      await _pollAndroidDownload(existingId, info);
      return;
    }

    downloadProgress.value = 0.0;
    int? id;
    try {
      id = await _installChannel.invokeMethod<int>('downloadApk', {
        'url': info.downloadUrl,
        'fileName': info.assetName,
      });
    } catch (e) {
      debugPrint('[UpdateService] DownloadManager enqueue failed: $e');
      id = null;
    }
    if (id == null || id < 0) {
      // DownloadManager недоступен — фолбэк на устойчивую dio-загрузку.
      await _downloadViaDioResilient(info);
      return;
    }
    await _savePending(id, info);
    await _pollAndroidDownload(id, info);
  }

  Future<void> _pollAndroidDownload(int id, UpdateInfo info) async {
    if (_pollingAndroid) return; // уже следим за этой загрузкой
    _pollingAndroid = true;
    try {
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        Map<Object?, Object?>? st;
        try {
          st = await _installChannel.invokeMethod<Map<Object?, Object?>>(
              'downloadStatus', {'id': id});
        } catch (_) {
          continue;
        }
        if (st == null) continue;
        final status = st['status'] as String? ?? 'unknown';
        final downloaded = (st['downloaded'] as num?)?.toDouble() ?? 0;
        final total = (st['total'] as num?)?.toDouble() ?? 0;
        if (total > 0) {
          downloadProgress.value = (downloaded / total).clamp(0.0, 1.0);
        }
        if (status == 'successful') {
          final path = st['path'] as String?;
          await _clearPending();
          _markReadyToInstall(info, path); // не ставим сразу — ждём окна в UI
          return;
        }
        if (status == 'failed' || status == 'unknown') {
          // Системная загрузка сорвалась (или запись смахнули из шторки) —
          // устойчивый фолбэк: dio с ретраями + GitHub.
          await _clearPending();
          await _downloadViaDioResilient(info);
          return;
        }
        // pending / running / paused — продолжаем ждать.
      }
    } finally {
      _pollingAndroid = false;
    }
  }

  /// Фолбэк, когда DownloadManager недоступен/сорвался: качаем через dio
  /// (ретраи + GitHub) во временную папку и помечаем готовым к установке.
  Future<void> _downloadViaDioResilient(UpdateInfo info) async {
    if (info.downloadUrl.isEmpty) {
      downloadProgress.value = null;
      return;
    }
    final dir = await getTemporaryDirectory();
    final filePath = '${dir.path}/${info.assetName}';
    downloadProgress.value = 0.0;
    try {
      await _downloadResilient(info, filePath);
      _markReadyToInstall(info, filePath);
    } catch (e) {
      debugPrint('[UpdateService] dio fallback failed: $e');
      downloadProgress.value = null;
    }
  }

  /// При старте: если фоновая загрузка уже завершилась (в т.ч. пока приложение
  /// было выгружено) — ставим её; если ещё идёт — снова показываем прогресс.
  /// Возвращает true, если была незавершённая/готовая загрузка (тогда обычную
  /// проверку обновлений в этот запуск можно пропустить).
  Future<bool> resumePendingInstall() async {
    if (!isUpdateSupported || !Platform.isAndroid) return false;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt(_prefsPendingId);
    if (id == null) return false;
    Map<Object?, Object?>? st;
    try {
      st = await _installChannel
          .invokeMethod<Map<Object?, Object?>>('downloadStatus', {'id': id});
    } catch (_) {
      return false;
    }
    final status = st?['status'] as String?;
    final info = UpdateInfo(
      version: prefs.getString(_prefsPendingVer) ?? '',
      body: '',
      downloadUrl: prefs.getString(_prefsPendingUrl) ?? '',
      assetName: prefs.getString(_prefsPendingAsset) ?? '',
    );
    if (status == 'successful') {
      final path = st!['path'] as String?;
      await _clearPending();
      // Загрузка завершилась, пока приложения не было, — не ставим молча:
      // помечаем готовым, UI покажет окно «перезапуск для установки».
      _markReadyToInstall(info, path);
      return true;
    }
    if (status == 'pending' || status == 'running' || status == 'paused') {
      downloadProgress.value = 0.0;
      unawaited(_pollAndroidDownload(id, info)); // не блокируем старт
      return true;
    }
    await _clearPending();
    return false;
  }

  Future<void> _savePending(int id, UpdateInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsPendingId, id);
    await prefs.setString(_prefsPendingVer, info.version);
    await prefs.setString(_prefsPendingUrl, info.downloadUrl);
    await prefs.setString(_prefsPendingAsset, info.assetName);
  }

  Future<void> _clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsPendingId);
    await prefs.remove(_prefsPendingVer);
    await prefs.remove(_prefsPendingUrl);
    await prefs.remove(_prefsPendingAsset);
  }

  /// Скачивает обновление устойчиво: relay — одиночный VPS, и большой APK на
  /// мобильной сети рвётся на середине (DioException unknown → «обновление не
  /// удалось»). Ретраим relay несколько раз, затем фолбэк на GitHub-релиз (CDN).
  /// Каждая попытка качает заново (deleteOnError). Долгий receiveTimeout — файл
  /// большой (~160 МБ).
  Future<void> _downloadResilient(UpdateInfo info, String filePath) async {
    final urls = <String>[
      info.downloadUrl,
      _githubFallbackUrl(info),
    ].where((u) => u.isNotEmpty).toList();
    Object? lastErr;
    for (final url in urls) {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await _dio.download(
            url,
            filePath,
            deleteOnError: true,
            options: Options(
              headers: {'Accept': 'application/octet-stream'},
              receiveTimeout: const Duration(minutes: 20),
            ),
            onReceiveProgress: (r, t) {
              if (t > 0) downloadProgress.value = r / t;
            },
          );
          return; // success
        } catch (e) {
          lastErr = e;
          downloadProgress.value = 0.0;
          await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
    }
    throw lastErr ?? Exception('download failed');
  }

  String _githubFallbackUrl(UpdateInfo info) {
    final v = info.version.startsWith('v') ? info.version : 'v${info.version}';
    if (info.assetName.isEmpty) return '';
    return 'https://github.com/MihailKashintsev/Rlink-releases/releases/download/$v/${info.assetName}';
  }

  /// Android: отдаём APK нативному коду, который открывает системный установщик
  /// (PackageInstaller). Приложение НЕ выходит — установщик работает поверх.
  Future<void> _installAndroid(String apkPath) async {
    await _installChannel.invokeMethod('installApk', {'path': apkPath});
  }

  Future<void> _installWindows(String zipPath) async {
    final dir = await getTemporaryDirectory();
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final exePath = Platform.resolvedExecutable;
    final script =
        'Start-Sleep 2\nExpand-Archive -Force "$zipPath" "${dir.path}\\upd"\nCopy-Item "${dir.path}\\upd\\*" "$appDir" -Recurse -Force\nStart-Process "$exePath"';
    final f = File('${dir.path}\\update.ps1')..writeAsStringSync(script);
    await Process.start(
        'powershell', ['-ExecutionPolicy', 'Bypass', '-File', f.path],
        mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> _installMacOS(String zipPath) async {
    final dir = await getTemporaryDirectory();
    final appBundle =
        File(Platform.resolvedExecutable).parent.parent.parent.path;
    await Process.run('unzip', ['-o', zipPath, '-d', dir.path]);
    final script =
        'sleep 2\ncp -R "${dir.path}/Rlink.app/." "$appBundle/"\nopen "$appBundle"';
    final f = File('${dir.path}/update.sh')..writeAsStringSync(script);
    await Process.run('chmod', ['+x', f.path]);
    await Process.start('bash', [f.path], mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> _installLinux(String tarPath) async {
    final dir = await getTemporaryDirectory();
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final exePath = Platform.resolvedExecutable;
    final script =
        'sleep 2\nmkdir -p "${dir.path}/upd"\ntar -xzf "$tarPath" -C "${dir.path}/upd"\ncp -r "${dir.path}/upd/." "$appDir/"\n"$exePath" &';
    final f = File('${dir.path}/update.sh')..writeAsStringSync(script);
    await Process.run('chmod', ['+x', f.path]);
    await Process.start('bash', [f.path], mode: ProcessStartMode.detached);
    exit(0);
  }

  String? _assetUrlForPlatform(Map<String, dynamic>? assets, String abi) {
    if (assets == null) return null;
    if (Platform.isAndroid) {
      // 32-битные ARM (armeabi-v7a / armv7) — берём отдельный arm32-APK, если
      // он есть; иначе `android` (arm64, покрывает подавляющее большинство).
      final is32 = abi.startsWith('armeabi') ||
          (abi.contains('arm') && !abi.contains('64'));
      if (is32) {
        final a32 = assets['android_arm32'] as String?;
        if (a32 != null && a32.isNotEmpty) return a32;
      }
      return assets['android'] as String?;
    }
    final key = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
            ? 'macos'
            : Platform.isLinux
                ? 'linux'
                : Platform.isIOS
                    ? 'ios'
                    : null;
    if (key == null) return null;
    return assets[key] as String?;
  }

  /// Основная ABI Android-устройства (`arm64-v8a` / `armeabi-v7a` / …).
  Future<String> _deviceAbi() async {
    if (!Platform.isAndroid) return '';
    try {
      return await _installChannel.invokeMethod<String>('deviceAbi') ?? '';
    } catch (_) {
      return '';
    }
  }

  String _fileNameFromUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final name = path.split('/').last;
    return name.isEmpty ? 'rlink_update' : name;
  }

  /// Приводит `v0.1.2` / `0.1.2` к виду `v0.1.2` для сравнения.
  String _normalizeVersionTag(String v) {
    final t = v.trim();
    if (t.isEmpty) return 'v0.0.0';
    final core = t.split('-').first;
    if (core.toLowerCase().startsWith('v')) return core;
    return 'v$core';
  }

  bool _isNewer(String latest, String current) {
    try {
      final l = _parse(latest);
      final c = _parse(current);
      final n = l.length > c.length ? l.length : c.length;
      for (int i = 0; i < n; i++) {
        final li = i < l.length ? l[i] : 0;
        final ci = i < c.length ? c[i] : 0;
        if (li > ci) return true;
        if (li < ci) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  List<int> _parse(String v) => v
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('-')
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
}
